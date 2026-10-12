--  TCP connection layer for Redis over RESP2.

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Exceptions;        use Ada.Exceptions;
with Ada.Streams;           use Ada.Streams;
with GNAT.Sockets;          use GNAT.Sockets;

package body Redis.Connection is

   --  Maximum buffer size for reading server replies.
   Read_Buffer_Size : constant := 8192;

   procedure Connect
     (Conn    : in out Redis_Connection;
      Host    : String;
      Port    : Positive := 6379;
      Timeout : Duration := 5.0)
   is
      Address : Sock_Addr_Type;
   begin
      if Conn.Connected then
         Disconnect (Conn);
      end if;

      --  Resolve hostname and connect with timeout.
      begin
         --  Resolve the address.
         Address.Addr := Addresses (Get_Host_By_Name (Host), 1);
         Address.Port := Port_Type (Port);

         --  Create a TCP socket.
         Create_Socket (Conn.Socket, Family_Inet, Socket_Stream);

         --  Set socket timeouts: connect, then every later send/receive.
         Set_Socket_Option
           (Conn.Socket,
            Socket_Level,
            (Name => Receive_Timeout, Timeout => Timeout));
         Set_Socket_Option
           (Conn.Socket,
            Socket_Level,
            (Name => Send_Timeout, Timeout => Timeout));

         --  Connect synchronously (blocking).
         Connect_Socket (Conn.Socket, Address);
         Conn.Connected := True;

      exception
         when E : Host_Error =>
            raise Connection_Failed with "DNS resolution failed: " & Exception_Message (E);
         when E : Socket_Error =>
            if Conn.Socket /= No_Socket then
               Close_Socket (Conn.Socket);
               Conn.Socket := No_Socket;
            end if;
            raise Connection_Failed with "Connection failed: " & Exception_Message (E);
         when E : others =>
            if Conn.Socket /= No_Socket then
               Close_Socket (Conn.Socket);
               Conn.Socket := No_Socket;
            end if;
            raise Connection_Failed with "Unexpected error: " & Exception_Message (E);
      end;
   end Connect;

   procedure Execute
     (Conn  : in out Redis_Connection;
      Args  : String_Vector;
      Reply : out Redis.RESP2.Reply)
   is
      use Redis.RESP2;
      use String_Vectors;

      Command        : Redis.RESP2.Reply := Array_Reply;
      Wire           : Unbounded_String;
      Channel        : Stream_Access;
      Buffer         : Stream_Element_Array (1 .. Read_Buffer_Size);
      Last           : Stream_Element_Offset;
      Accumulated    : Unbounded_String := Null_Unbounded_String;
      Parse_Status   : Redis.RESP2.Parse_Status;
      Consumed       : Natural;
   begin
      if not Conn.Connected or else Conn.Socket = No_Socket then
         raise Connection_Failed with "Not connected";
      end if;

      --  An empty command would send an empty RESP2 array; Redis closes the
      --  connection on such input. Reject it before touching the socket.
      if Is_Empty (Args) then
         raise Protocol_Error with "Empty command";
      end if;

      --  Build a RESP2 array of bulk strings from the arguments.
      for S of Args loop
         Append (Command, Bulk (S));
      end loop;

      Wire := To_Unbounded_String (Encode (Command));

      --  Send the command.
      begin
         Channel := Stream (Conn.Socket);
         String'Write (Channel, To_String (Wire));
      exception
         when E : Socket_Error =>
            Conn.Connected := False;
            raise Connection_Failed with "Write failed: " & Exception_Message (E);
      end;

      --  Read the reply incrementally until the parser succeeds.
      loop
         begin
            Receive_Socket (Conn.Socket, Buffer, Last);
         exception
            when E : Socket_Error =>
               Conn.Connected := False;
               raise Connection_Failed with "Read failed: " & Exception_Message (E);
         end;

         if Last < Buffer'First then
            Conn.Connected := False;
            raise Connection_Failed with "Server closed connection";
         end if;

         --  Convert Stream_Element_Array to String and accumulate.
         declare
            Chunk : String (1 .. Integer (Last - Buffer'First + 1));
         begin
            for I in Buffer'First .. Last loop
               Chunk (Integer (I - Buffer'First + 1)) := Character'Val (Buffer (I));
            end loop;
            Append (Accumulated, Chunk);
         end;

         --  Bound the accumulator: without a cap a misbehaving peer can
         --  make us buffer without limit.
         if Length (Accumulated) > Max_Reply_Bytes then
            Conn.Connected := False;
            raise Connection_Failed with "Reply exceeds "
              & Integer'Image (Max_Reply_Bytes / (1024 * 1024)) & " MiB limit";
         end if;

         --  Attempt to parse.
         declare
            Full_Buffer : constant String := To_String (Accumulated);
         begin
            Parse (Full_Buffer, Reply, Parse_Status, Consumed);

            case Parse_Status is
               when Success =>
                  --  Remove consumed bytes from the accumulator (for
                  --  pipelining support later). For now, we expect the
                  --  full reply to be consumed.
                  return;

               when Need_More_Data =>
                  --  Continue reading.
                  null;

               when Redis.RESP2.Protocol_Error =>
                  --  Stream desynchronisation cannot be recovered locally:
                  --  mark the connection dead so the caller reconnects.
                  Conn.Connected := False;
                  raise Protocol_Error with "Malformed server response";
            end case;
         end;
      end loop;
   end Execute;

   procedure Disconnect (Conn : in out Redis_Connection) is
   begin
      if Conn.Socket /= No_Socket then
         Close_Socket (Conn.Socket);
         Conn.Socket := No_Socket;
      end if;
      Conn.Connected := False;
   end Disconnect;

   function Is_Connected (Conn : Redis_Connection) return Boolean is
     (Conn.Connected and then Conn.Socket /= No_Socket);

end Redis.Connection;
