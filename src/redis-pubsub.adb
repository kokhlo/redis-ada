--  Subscriber implementation: one dedicated socket, an accumulation
--  buffer for partial frames, and select()-based waits bounded by a
--  caller-supplied timeout.

with Ada.Calendar;
with Ada.Exceptions;
with Ada.Streams;                 use Ada.Streams;
with Redis.RESP2;                 use Redis.RESP2;

package body Redis.PubSub is

   use Ada.Strings.Unbounded;
   use GNAT.Sockets;
   use Redis.Connection.String_Vectors;

   Read_Chunk_Size : constant := 4096;

   --  Encode a command (arguments vector) as a RESP2 array frame.
   function Frame_With (Args : Redis.Connection.String_Vector)
                        return Redis.RESP2.Reply
   is
      Frame : Redis.RESP2.Reply := Redis.RESP2.Array_Reply;
   begin
      for S of Args loop
         Redis.RESP2.Append (Frame, Redis.RESP2.Bulk (S));
      end loop;
      return Frame;
   end Frame_With;

   procedure Send_Command
     (Sub  : in out Subscriber;
      Args : Redis.Connection.String_Vector)
   is
      Wire  : constant String := Redis.RESP2.Encode (Frame_With (Args));
      Raw   : Stream_Element_Array (1 .. Stream_Element_Offset (Wire'Length));
      Last  : Stream_Element_Offset;
   begin
      for I in Wire'Range loop
         Raw (Stream_Element_Offset (I) - Stream_Element_Offset (Wire'First) + 1)
           := Stream_Element (Character'Pos (Wire (I)));
      end loop;

      Send_Socket (Sub.Socket, Raw, Last);
   exception
      when E : Socket_Error =>
         Sub.Connected := False;
         raise Connection_Failed
           with "pub/sub write failed: " & Ada.Exceptions.Exception_Message (E);
   end Send_Command;

   --  Read whatever the socket currently offers and append it to the
   --  buffer. On a blocking socket this waits up to the socket receive
   --  timeout configured at Connect.
   procedure Receive_Chunk (Sub : in out Subscriber) is
      Raw  : Stream_Element_Array (1 .. Read_Chunk_Size);
      Last : Stream_Element_Offset;
      Text : String (1 .. Read_Chunk_Size);
   begin
      Receive_Socket (Sub.Socket, Raw, Last);
      if Last < Raw'First then
         Sub.Connected := False;
         raise Connection_Failed with "server closed the subscription";
      end if;

      for I in Raw'First .. Last loop
         Text (Integer (I)) := Character'Val (Raw (I));
      end loop;
      Append (Sub.Buffer, Text (1 .. Integer (Last)));
   exception
      when E : Socket_Error =>
         Sub.Connected := False;
         raise Connection_Failed
           with "pub/sub read failed: " & Ada.Exceptions.Exception_Message (E);
   end Receive_Chunk;

   --  Try to decode one buffered frame. Available is False when the
   --  buffer holds only a partial frame.
   procedure Next_Buffered_Event
     (Sub       : in out Subscriber;
      Msg       : out Message;
      Available : out Boolean)
   is
      Buffer_Text : constant String := To_String (Sub.Buffer);
      Frame       : Redis.RESP2.Reply;
      Status      : Redis.RESP2.Parse_Status;
      Used        : Natural;
   begin
      Available := False;
      if Buffer_Text'Length = 0 then
         return;
      end if;

      Redis.RESP2.Parse (Buffer_Text, Frame, Status, Used);
      case Status is
         when Redis.RESP2.Success =>
            Delete (Sub.Buffer, 1, Used);
            Msg := Decode_Event (Frame);
            Available := True;
         when Redis.RESP2.Need_More_Data =>
            null;
         when Redis.RESP2.Protocol_Error =>
            raise Protocol_Error with "malformed pub/sub frame";
      end case;
   end Next_Buffered_Event;

   --  Block until a complete frame is buffered, then decode it. Bounded
   --  by the socket receive timeout, so a silent server cannot hang the
   --  caller forever.
   procedure Wait_Event (Sub : in out Subscriber; Msg : out Message) is
      Available : Boolean;
   begin
      loop
         Next_Buffered_Event (Sub, Msg, Available);
         if Available then
            return;
         end if;
         Receive_Chunk (Sub);
      end loop;
   end Wait_Event;

   --  Drain exactly one confirmation per requested channel or pattern
   --  and reject anything else that arrives meanwhile.
   procedure Expect_Confirmations
     (Sub       : in out Subscriber;
      Count     : Positive;
      Expected  : Event_Kind)
   is
      Msg       : Message;
      Remaining : Natural := Count;
   begin
      while Remaining > 0 loop
         Wait_Event (Sub, Msg);
         if Msg.Kind /= Expected then
            raise Protocol_Error with "unexpected frame while confirming subscription";
         end if;
         Remaining := Remaining - 1;
      end loop;
   end Expect_Confirmations;

   procedure Connect
     (Sub     : in out Subscriber;
      Host    : String;
      Port    : Positive := 6379;
      Timeout : Duration := 5.0)
   is
      Address : Sock_Addr_Type;
   begin
      if Sub.Connected then
         Disconnect (Sub);
      end if;

      Address.Addr := Addresses (Get_Host_By_Name (Host), 1);
      Address.Port := Port_Type (Port);

      Create_Socket (Sub.Socket, Family_Inet, Socket_Stream);
      Set_Socket_Option
        (Sub.Socket,
         Socket_Level,
         (Name => Receive_Timeout, Timeout => Timeout));
      Connect_Socket (Sub.Socket, Address);

      Sub.Buffer    := Null_Unbounded_String;
      Sub.Connected := True;
   exception
      when E : others =>
         if Sub.Socket /= No_Socket then
            Close_Socket (Sub.Socket);
            Sub.Socket := No_Socket;
         end if;
         raise Connection_Failed
           with "subscriber connect failed: " & Ada.Exceptions.Exception_Message (E);
   end Connect;

   procedure Subscribe
     (Sub      : in out Subscriber;
      Channels : Redis.Connection.String_Vector)
   is
      Args : Redis.Connection.String_Vector;
   begin
      if not Sub.Connected then
         raise Connection_Failed with "subscriber not connected";
      end if;
      if Channels.Is_Empty then
         return;
      end if;

      Args.Append ("SUBSCRIBE");
      for C of Channels loop
         Args.Append (C);
      end loop;

      Send_Command (Sub, Args);
      Expect_Confirmations (Sub, Natural (Channels.Length), Subscribe_Event);
   end Subscribe;

   procedure Unsubscribe
     (Sub      : in out Subscriber;
      Channels : Redis.Connection.String_Vector)
   is
      Args : Redis.Connection.String_Vector;
   begin
      if not Sub.Connected then
         raise Connection_Failed with "subscriber not connected";
      end if;

      Args.Append ("UNSUBSCRIBE");
      for C of Channels loop
         Args.Append (C);
      end loop;

      Send_Command (Sub, Args);
      if not Channels.Is_Empty then
         Expect_Confirmations (Sub, Natural (Channels.Length), Unsubscribe_Event);
      end if;
   end Unsubscribe;

   procedure PSubscribe
     (Sub      : in out Subscriber;
      Patterns : Redis.Connection.String_Vector)
   is
      Args : Redis.Connection.String_Vector;
   begin
      if not Sub.Connected then
         raise Connection_Failed with "subscriber not connected";
      end if;
      if Patterns.Is_Empty then
         return;
      end if;

      Args.Append ("PSUBSCRIBE");
      for P of Patterns loop
         Args.Append (P);
      end loop;

      Send_Command (Sub, Args);
      Expect_Confirmations (Sub, Natural (Patterns.Length), PSubscribe_Event);
   end PSubscribe;

   procedure PUnsubscribe
     (Sub      : in out Subscriber;
      Patterns : Redis.Connection.String_Vector)
   is
      Args : Redis.Connection.String_Vector;
   begin
      if not Sub.Connected then
         raise Connection_Failed with "subscriber not connected";
      end if;

      Args.Append ("PUNSUBSCRIBE");
      for P of Patterns loop
         Args.Append (P);
      end loop;

      Send_Command (Sub, Args);
      if not Patterns.Is_Empty then
         Expect_Confirmations (Sub, Natural (Patterns.Length), PUnsubscribe_Event);
      end if;
   end PUnsubscribe;

   procedure Listen
     (Sub     : in out Subscriber;
      Timeout : Duration;
      Msg     : out Message;
      Status  : out Listen_Status)
   is
      use Ada.Calendar;
      Deadline      : constant Time := Clock + Timeout;
      Read_Set      : Socket_Set_Type;
      Write_Set     : Socket_Set_Type;
      Select_Result : Selector_Status;
      Available     : Boolean;
   begin
      Status := No_Message;
      Msg    := Null_Message;

      if not Sub.Connected then
         raise Connection_Failed with "subscriber not connected";
      end if;

      --  A frame may already be buffered by an earlier oversized read.
      Next_Buffered_Event (Sub, Msg, Available);
      if Available then
         Status := Got_Message;
         return;
      end if;

      --  One total budget for the whole call: each select() round gets
      --  only the time still remaining, so a peer trickling partial
      --  frames cannot extend the wait beyond Timeout.
      loop
         exit when Clock >= Deadline;

         declare
            Remaining : constant Duration := Deadline - Clock;
         begin
            Empty (Read_Set);
            Empty (Write_Set);
            Set (Read_Set, Sub.Socket);

            Check_Selector
              (Null_Selector, Read_Set, Write_Set, Select_Result, Remaining);

            case Select_Result is
               when Completed =>
                  Receive_Chunk (Sub);
                  Next_Buffered_Event (Sub, Msg, Available);
                  if Available then
                     Status := Got_Message;
                     return;
                  end if;
               when Expired | Aborted =>
                  exit;
            end case;
         end;
      end loop;
   end Listen;

   procedure Disconnect (Sub : in out Subscriber) is
   begin
      if Sub.Socket /= No_Socket then
         Close_Socket (Sub.Socket);
         Sub.Socket := No_Socket;
      end if;
      Sub.Connected := False;
      Sub.Buffer    := Null_Unbounded_String;
   end Disconnect;

   function Is_Connected (Sub : Subscriber) return Boolean is
     (Sub.Connected and then Sub.Socket /= No_Socket);

   function Channel_Text (M : Message) return String is
     (To_String (M.Channel));

   function Pattern_Text (M : Message) return String is
     (To_String (M.Pattern));

   function Payload_Text (M : Message) return String is
     (To_String (M.Payload));

   function Decode_Event (Frame : Redis.RESP2.Reply) return Message is
      package R2 renames Redis.RESP2;
   begin
      if R2.Kind_Of (Frame) /= R2.Array_Frame or else R2.Length (Frame) < 2 then
         raise Protocol_Error with "pub/sub frame must be a non-empty array";
      end if;

      declare
         Header_Reply : constant R2.Reply := R2.Element (Frame, 1);
      begin
         if R2.Kind_Of (Header_Reply) /= R2.Bulk_String then
            raise Protocol_Error with "pub/sub frame header must be a bulk string";
         end if;

         declare
            Header : constant String := R2.Text (Header_Reply);
         begin
            if Header = "message" and then R2.Length (Frame) = 3 then
               return Message'
                 (Kind    => Message_Event,
                  Channel => To_Unbounded_String (R2.Text (R2.Element (Frame, 2))),
                  Pattern => Null_Unbounded_String,
                  Payload => To_Unbounded_String (R2.Text (R2.Element (Frame, 3))),
                  Count   => 0);

            elsif Header = "pmessage" and then R2.Length (Frame) = 4 then
               return Message'
                 (Kind    => Pattern_Message_Event,
                  Channel => To_Unbounded_String (R2.Text (R2.Element (Frame, 3))),
                  Pattern => To_Unbounded_String (R2.Text (R2.Element (Frame, 2))),
                  Payload => To_Unbounded_String (R2.Text (R2.Element (Frame, 4))),
                  Count   => 0);

            elsif Header = "subscribe" and then R2.Length (Frame) = 3 then
               return Message'
                 (Kind    => Subscribe_Event,
                  Channel => To_Unbounded_String (R2.Text (R2.Element (Frame, 2))),
                  Pattern => Null_Unbounded_String,
                  Payload => Null_Unbounded_String,
                  Count   => R2.Value (R2.Element (Frame, 3)));

            elsif Header = "unsubscribe" and then R2.Length (Frame) = 3 then
               return Message'
                 (Kind    => Unsubscribe_Event,
                  Channel => To_Unbounded_String (R2.Text (R2.Element (Frame, 2))),
                  Pattern => Null_Unbounded_String,
                  Payload => Null_Unbounded_String,
                  Count   => R2.Value (R2.Element (Frame, 3)));

            elsif Header = "psubscribe" and then R2.Length (Frame) = 3 then
               return Message'
                 (Kind    => PSubscribe_Event,
                  Channel => To_Unbounded_String (R2.Text (R2.Element (Frame, 2))),
                  Pattern => Null_Unbounded_String,
                  Payload => Null_Unbounded_String,
                  Count   => R2.Value (R2.Element (Frame, 3)));

            elsif Header = "punsubscribe" and then R2.Length (Frame) = 3 then
               return Message'
                 (Kind    => PUnsubscribe_Event,
                  Channel => To_Unbounded_String (R2.Text (R2.Element (Frame, 2))),
                  Pattern => Null_Unbounded_String,
                  Payload => Null_Unbounded_String,
                  Count   => R2.Value (R2.Element (Frame, 3)));

            elsif Header = "pong" and then R2.Length (Frame) = 2 then
               return Message'
                 (Kind    => Pong_Event,
                  Channel => Null_Unbounded_String,
                  Pattern => Null_Unbounded_String,
                  Payload => To_Unbounded_String (R2.Text (R2.Element (Frame, 2))),
                  Count   => 0);

            elsif Header = "pong" and then R2.Length (Frame) = 3 then
               return Message'
                 (Kind    => Pong_Event,
                  Channel => To_Unbounded_String (R2.Text (R2.Element (Frame, 2))),
                  Pattern => Null_Unbounded_String,
                  Payload => To_Unbounded_String (R2.Text (R2.Element (Frame, 3))),
                  Count   => 0);
            end if;

            raise Protocol_Error with "unknown pub/sub frame: " & Header;
         end;
      end;
   end Decode_Event;

   function Publish
     (Conn    : in out Redis.Connection.Redis_Connection;
      Channel : String;
      Payload : String) return Natural
   is
      Args : Redis.Connection.String_Vector;
      R    : Redis.RESP2.Reply;
   begin
      Args.Append ("PUBLISH");
      Args.Append (Channel);
      Args.Append (Payload);

      Redis.Connection.Execute (Conn, Args, R);

      if Redis.RESP2.Kind_Of (R) /= Redis.RESP2.Integer_Reply then
         raise Protocol_Error with "PUBLISH: unexpected reply kind";
      end if;

      return Natural (Redis.RESP2.Value (R));
   end Publish;

end Redis.PubSub;
