with Ada.Strings.Fixed;

package body Redis.RESP2 is

   CRLF : constant String := (1 => ASCII.CR, 2 => ASCII.LF);

   function Simple (Value : String) return Reply is
   begin
      return (Frame_Kind => Simple_String,
              Payload    => To_Unbounded_String (Value),
              others     => <>);
   end Simple;

   function Error_Reply (Message : String) return Reply is
   begin
      return (Frame_Kind => Error,
              Payload    => To_Unbounded_String (Message),
              others     => <>);
   end Error_Reply;

   function Number (Value : Long_Long_Integer) return Reply is
   begin
      return (Frame_Kind => Integer_Reply,
              Int_Value  => Value,
              others     => <>);
   end Number;

   function Bulk (Value : String) return Reply is
   begin
      return (Frame_Kind => Bulk_String,
              Payload    => To_Unbounded_String (Value),
              Count      => Value'Length,
              others     => <>);
   end Bulk;

   function Null_Bulk return Reply is
   begin
      return (Frame_Kind => Bulk_String,
              Count      => -1,
              others     => <>);
   end Null_Bulk;

   function Null_Array return Reply is
   begin
      return (Frame_Kind => Array_Frame,
              Count      => -1,
              others     => <>);
   end Null_Array;

   function Array_Reply return Reply is
   begin
      return (Frame_Kind => Array_Frame,
              Count      => 0,
              others     => <>);
   end Array_Reply;

   procedure Append (To : in out Reply; Item : Reply) is
      Node : constant Reply_Node_Ptr :=
        new Reply_Node'(Data => new Reply'(Item), Next => null);
   begin
      if To.First_Item = null then
         To.First_Item := Node;
         To.Last_Item := Node;
      else
         To.Last_Item.Next := Node;
         To.Last_Item := Node;
      end if;
      To.Count := To.Count + 1;
   end Append;

   function Kind_Of (Item : Reply) return Kind is (Item.Frame_Kind);

   function Is_Null (Item : Reply) return Boolean is
     (Item.Count = -1 and then (Item.Frame_Kind = Bulk_String
                                or else Item.Frame_Kind = Array_Frame));

   function Text (Item : Reply) return String is
     (To_String (Item.Payload));

   function Value (Item : Reply) return Long_Long_Integer is
     (Item.Int_Value);

   function Length (Item : Reply) return Integer is
     (Item.Count);

   function Element (Item : Reply; Index : Positive) return Reply is
      Current : Reply_Node_Ptr := Item.First_Item;
   begin
      for I in 2 .. Index loop
         if Current = null then
            raise Constraint_Error with "Index out of range";
         end if;
         Current := Current.Next;
      end loop;

      if Current = null or else Current.Data = null then
         raise Constraint_Error with "Index out of range";
      end if;

      return Current.Data.all;
   end Element;

   function Encode (Item : Reply) return String is
      use Ada.Strings.Fixed;
   begin
      case Item.Frame_Kind is
         when Simple_String =>
            return "+" & To_String (Item.Payload) & CRLF;

         when Error =>
            return "-" & To_String (Item.Payload) & CRLF;

         when Integer_Reply =>
            return ":" & Trim (Long_Long_Integer'Image (Item.Int_Value), Ada.Strings.Both) & CRLF;

         when Bulk_String =>
            if Item.Count = -1 then
               return "$-1" & CRLF;
            else
               return "$" & Trim (Integer'Image (Item.Count), Ada.Strings.Both) & CRLF
                 & To_String (Item.Payload) & CRLF;
            end if;

         when Array_Frame =>
            if Item.Count = -1 then
               return "*-1" & CRLF;
            else
               declare
                  Result : Unbounded_String :=
                    To_Unbounded_String ("*" & Trim (Integer'Image (Item.Count), Ada.Strings.Both) & CRLF);
                  Current : Reply_Node_Ptr := Item.First_Item;
               begin
                  while Current /= null loop
                     Append (Result, Encode (Current.Data.all));
                     Current := Current.Next;
                  end loop;
                  return To_String (Result);
               end;
            end if;
      end case;
   end Encode;

   --  Helper: check if we have at least Count bytes remaining from Pos.
   function Remaining (Buffer : String; Pos : Positive; Count : Natural) return Boolean is
     (Pos + Count - 1 <= Buffer'Last);

   --  Helper: find next CRLF starting from Pos. Returns 0 if not found.
   function Find_CRLF (Buffer : String; Start : Positive) return Natural is
   begin
      for I in Start .. Buffer'Last - 1 loop
         if Buffer (I) = ASCII.CR and then Buffer (I + 1) = ASCII.LF then
            return I;
         end if;
      end loop;
      return 0;
   end Find_CRLF;

   --  Recursive descent parser for RESP2 frames.
   procedure Parse_Frame
     (Buffer   : String;
      Start    : Positive;
      Reply    : out Redis.RESP2.Reply;
      Status   : out Parse_Status;
      Consumed : out Natural);

   procedure Parse_Frame
     (Buffer   : String;
      Start    : Positive;
      Reply    : out Redis.RESP2.Reply;
      Status   : out Parse_Status;
      Consumed : out Natural)
   is
      Pos        : Positive := Start;
      CRLF_Pos   : Natural;
      Len        : Integer;
      Arr_Count  : Integer;
      Sub_Reply  : Redis.RESP2.Reply;
      Sub_Status : Parse_Status;
      Sub_Cons   : Natural;
   begin
      --  Need at least one byte for the type marker.
      if Pos > Buffer'Last then
         Status := Need_More_Data;
         Consumed := 0;
         return;
      end if;

      case Buffer (Pos) is
         when '+' =>
            --  Simple String: +OK\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status := Need_More_Data;
               Consumed := 0;
               return;
            end if;
            Reply := Simple (Buffer (Pos + 1 .. CRLF_Pos - 1));
            Consumed := CRLF_Pos + 2 - Start;
            Status := Success;

         when '-' =>
            --  Error: -ERR message\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status := Need_More_Data;
               Consumed := 0;
               return;
            end if;
            Reply := Error_Reply (Buffer (Pos + 1 .. CRLF_Pos - 1));
            Consumed := CRLF_Pos + 2 - Start;
            Status := Success;

         when ':' =>
            --  Integer: :123\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status := Need_More_Data;
               Consumed := 0;
               return;
            end if;
            declare
               Num_Str : constant String := Buffer (Pos + 1 .. CRLF_Pos - 1);
            begin
               Reply := Number (Long_Long_Integer'Value (Num_Str));
               Consumed := CRLF_Pos + 2 - Start;
               Status := Success;
            exception
               when Constraint_Error =>
                  Status := Protocol_Error;
                  Consumed := CRLF_Pos + 2 - Start;
            end;

         when '$' =>
            --  Bulk String: $5\r\nhello\r\n or $-1\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status := Need_More_Data;
               Consumed := 0;
               return;
            end if;

            declare
               Len_Str : constant String := Buffer (Pos + 1 .. CRLF_Pos - 1);
            begin
               Len := Integer'Value (Len_Str);
            exception
               when Constraint_Error =>
                  Status := Protocol_Error;
                  Consumed := CRLF_Pos + 2 - Start;
                  return;
            end;

            if Len = -1 then
               --  Null bulk string.
               Reply := Null_Bulk;
               Consumed := CRLF_Pos + 2 - Start;
               Status := Success;
            else
               --  Check we have Len bytes + CRLF after the first CRLF.
               Pos := CRLF_Pos + 2;
               if not Remaining (Buffer, Pos, Len + 2) then
                  Status := Need_More_Data;
                  Consumed := 0;
                  return;
               end if;

               --  Verify trailing CRLF.
               if Buffer (Pos + Len) /= ASCII.CR or else Buffer (Pos + Len + 1) /= ASCII.LF then
                  Status := Protocol_Error;
                  Consumed := Pos + Len + 2 - Start;
                  return;
               end if;

               Reply := Bulk (Buffer (Pos .. Pos + Len - 1));
               Consumed := Pos + Len + 2 - Start;
               Status := Success;
            end if;

         when '*' =>
            --  Array: *2\r\n... or *-1\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status := Need_More_Data;
               Consumed := 0;
               return;
            end if;

            declare
               Count_Str : constant String := Buffer (Pos + 1 .. CRLF_Pos - 1);
            begin
               Arr_Count := Integer'Value (Count_Str);
            exception
               when Constraint_Error =>
                  Status := Protocol_Error;
                  Consumed := CRLF_Pos + 2 - Start;
                  return;
            end;

            if Arr_Count = -1 then
               Reply := Null_Array;
               Consumed := CRLF_Pos + 2 - Start;
               Status := Success;
            else
               Reply := Array_Reply;
               Pos := CRLF_Pos + 2;

               for I in 1 .. Arr_Count loop
                  Parse_Frame (Buffer, Pos, Sub_Reply, Sub_Status, Sub_Cons);
                  if Sub_Status /= Success then
                     Status := Sub_Status;
                     if Sub_Status = Need_More_Data then
                        Consumed := 0;
                     else
                        Consumed := Pos + Sub_Cons - Start;
                     end if;
                     return;
                  end if;

                  Append (Reply, Sub_Reply);
                  Pos := Pos + Sub_Cons;
               end loop;

               Consumed := Pos - Start;
               Status := Success;
            end if;

         when others =>
            Status := Protocol_Error;
            Consumed := 1;
      end case;
   end Parse_Frame;

   procedure Parse
     (Buffer   : String;
      Reply    : out Redis.RESP2.Reply;
      Status   : out Parse_Status;
      Consumed : out Natural)
   is
   begin
      if Buffer'Length = 0 then
         Status := Need_More_Data;
         Consumed := 0;
         return;
      end if;

      Parse_Frame (Buffer, Buffer'First, Reply, Status, Consumed);
   end Parse;

end Redis.RESP2;
