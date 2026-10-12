with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

package body Redis.RESP2 is

   CRLF : constant String := (1 => ASCII.CR, 2 => ASCII.LF);

   --  Protocol limits (see redis protocol limits documentation).
   Max_Bulk_Length  : constant := 512 * 1024 * 1024;  -- 512 MiB
   Max_Array_Length : constant := 1_000_000;
   Max_Nesting      : constant := 128;

   procedure Free is new Ada.Unchecked_Deallocation
     (Object => Reply_Node, Name => Reply_Node_Ptr);

   --  Deep-copy the node list of Source; returns first and last nodes of
   --  the freshly allocated copy.
   procedure Copy_List (Source : Reply_Node_Ptr; Target_First : out Reply_Node_Ptr;
                       Target_Last : out Reply_Node_Ptr);

   procedure Copy_List (Source : Reply_Node_Ptr; Target_First : out Reply_Node_Ptr;
                       Target_Last : out Reply_Node_Ptr)
   is
      Last : Reply_Node_Ptr := null;
      Cur  : Reply_Node_Ptr := Source;
   begin
      Target_First := null;
      Target_Last  := null;
      while Cur /= null loop
         declare
            Node : constant Reply_Node_Ptr :=
              new Reply_Node'(Data => Cur.Data, Next => null);
            --  Cur.Data is a controlled Reply: the allocator performs a
            --  deep copy via Adjust, so nested lists are copied too.
         begin
            if Target_First = null then
               Target_First := Node;
            else
               Last.Next := Node;
            end if;
            Last := Node;
            Cur  := Cur.Next;
         end;
      end loop;
      Target_Last := Last;
   end Copy_List;

   procedure Adjust (Item : in out Reply) is
      First, Last : Reply_Node_Ptr;
   begin
      Copy_List (Item.First_Item, First, Last);
      Item.First_Item := First;
      Item.Last_Item  := Last;
   end Adjust;

   procedure Finalize (Item : in out Reply) is
      Cur  : Reply_Node_Ptr := Item.First_Item;
      Next : Reply_Node_Ptr;
   begin
      while Cur /= null loop
         Next := Cur.Next;
         --  Note: freeing a node finalizes Data (a controlled Reply), which
         --  recursively frees nested lists.
         Free (Cur);
         Cur := Next;
      end loop;
      Item.First_Item := null;
      Item.Last_Item  := null;
   end Finalize;

   function Simple (Value : String) return Reply is
   begin
      return (Ada.Finalization.Controlled with
              Frame_Kind => Simple_String,
              Payload    => To_Unbounded_String (Value),
              others     => <>);
   end Simple;

   function Error_Reply (Message : String) return Reply is
   begin
      return (Ada.Finalization.Controlled with
              Frame_Kind => Error,
              Payload    => To_Unbounded_String (Message),
              others     => <>);
   end Error_Reply;

   function Number (Value : Long_Long_Integer) return Reply is
   begin
      return (Ada.Finalization.Controlled with
              Frame_Kind => Integer_Reply,
              Int_Value  => Value,
              others     => <>);
   end Number;

   function Bulk (Value : String) return Reply is
   begin
      return (Ada.Finalization.Controlled with
              Frame_Kind => Bulk_String,
              Payload    => To_Unbounded_String (Value),
              Count      => Value'Length,
              others     => <>);
   end Bulk;

   function Null_Bulk return Reply is
   begin
      return (Ada.Finalization.Controlled with
              Frame_Kind => Bulk_String,
              Count      => -1,
              others     => <>);
   end Null_Bulk;

   function Null_Array return Reply is
   begin
      return (Ada.Finalization.Controlled with
              Frame_Kind => Array_Frame,
              Count      => -1,
              others     => <>);
   end Null_Array;

   function Array_Reply return Reply is
   begin
      return (Ada.Finalization.Controlled with
              Frame_Kind => Array_Frame,
              Count      => 0,
              others     => <>);
   end Array_Reply;

   procedure Append (To : in out Reply; Item : Reply) is
      Node : constant Reply_Node_Ptr :=
        new Reply_Node'(Data => Item, Next => null);
      --  Item is copied into the node by the allocator (controlled Adjust).
   begin
      if To.First_Item = null then
         To.First_Item := Node;
         To.Last_Item  := Node;
      else
         To.Last_Item.Next := Node;
         To.Last_Item      := Node;
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

      if Current = null then
         raise Constraint_Error with "Index out of range";
      end if;

      return Current.Data;  --  controlled return: deep copy via Adjust
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
                  Result  : Unbounded_String :=
                    To_Unbounded_String ("*" & Trim (Integer'Image (Item.Count), Ada.Strings.Both) & CRLF);
                  Current : Reply_Node_Ptr := Item.First_Item;
               begin
                  while Current /= null loop
                     Append (Result, Encode (Current.Data));
                     Current := Current.Next;
                  end loop;
                  return To_String (Result);
               end;
            end if;
      end case;
   end Encode;

   --  Helper: check if we have at least Count bytes remaining from Pos.
   function Remaining (Buffer : String; Pos : Positive; Count : Long_Long_Integer)
                       return Boolean
   is
     ((Long_Long_Integer (Buffer'Last) - Long_Long_Integer (Pos) + 1) >= Count);

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

   --  Strict decimal integer scan: optional '-' followed by 1+ digits.
   --  No spaces, no '+', no underscores, no Ada extensions.
   --  Returns False on empty/invalid input. Sets Overflow when the digits
   --  denote a value outside Long_Long_Integer.
   procedure Scan_Integer
     (S        : String;
      Value    : out Long_Long_Integer;
      Valid    : out Boolean;
      Overflow : out Boolean)
   is
   begin
      Value    := 0;
      Overflow := False;
      Valid    := False;

      if S'Length = 0 then
         return;
      end if;

      declare
         First : constant Positive := S'First;
         Neg   : constant Boolean  := S (First) = '-';
         Start : Positive := First + (if Neg then 1 else 0);
         Acc   : Long_Long_Integer := 0;
      begin
         if Start > S'Last then        --  "-" alone or empty digits
            return;
         end if;

         for I in Start .. S'Last loop
            if S (I) not in '0' .. '9' then
               return;
            end if;
         end loop;

         for I in Start .. S'Last loop
            declare
               Digit : constant Long_Long_Integer :=
                 Long_Long_Integer (Character'Pos (S (I)) - Character'Pos ('0'));
            begin
               --  Acc * 10 + Digit with overflow check
               if Acc > (Long_Long_Integer'Last - Digit) / 10 then
                  Overflow := True;
                  return;
               end if;
               Acc := Acc * 10 + Digit;
            end;
         end loop;

         if Neg then
            --  The most negative value has no positive counterpart; accept
            --  it explicitly to keep the range symmetric.
            if Acc > -(Long_Long_Integer'First + 1) then
               Overflow := True;
               return;
            end if;
            Value := -Acc;
         else
            Value := Acc;
         end if;

         Valid := True;
      end;
   end Scan_Integer;

   --  Frame parser. Depth limits recursion for nested arrays.
   procedure Parse_Frame
     (Buffer   : String;
      Start    : Positive;
      Depth    : Natural;
      Reply    : out Redis.RESP2.Reply;
      Status   : out Parse_Status;
      Consumed : out Natural);

   procedure Parse_Frame
     (Buffer   : String;
      Start    : Positive;
      Depth    : Natural;
      Reply    : out Redis.RESP2.Reply;
      Status   : out Parse_Status;
      Consumed : out Natural)
   is
      Pos        : Positive := Start;
      CRLF_Pos   : Natural;
      Len        : Long_Long_Integer;
      Arr_Count  : Long_Long_Integer;
      Valid      : Boolean;
      Overflow   : Boolean;
      Sub_Reply  : Redis.RESP2.Reply;
      Sub_Status : Parse_Status;
      Sub_Cons   : Natural;
   begin
      --  Need at least one byte for the type marker.
      if Pos > Buffer'Last then
         Status   := Need_More_Data;
         Consumed := 0;
         return;
      end if;

      case Buffer (Pos) is
         when '+' =>
            --  Simple String: +OK\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status   := Need_More_Data;
               Consumed := 0;
               return;
            end if;
            Reply    := Simple (Buffer (Pos + 1 .. CRLF_Pos - 1));
            Consumed := CRLF_Pos + 2 - Start;
            Status   := Success;

         when '-' =>
            --  Error: -ERR message\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status   := Need_More_Data;
               Consumed := 0;
               return;
            end if;
            Reply    := Error_Reply (Buffer (Pos + 1 .. CRLF_Pos - 1));
            Consumed := CRLF_Pos + 2 - Start;
            Status   := Success;

         when ':' =>
            --  Integer: :123\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status   := Need_More_Data;
               Consumed := 0;
               return;
            end if;
            declare
               Num_Str : constant String := Buffer (Pos + 1 .. CRLF_Pos - 1);
               N       : Long_Long_Integer;
            begin
               Scan_Integer (Num_Str, N, Valid, Overflow);
               if not Valid then
                  Status   := Protocol_Error;
                  Consumed := CRLF_Pos + 2 - Start;
                  return;
               end if;
               Reply    := Number (N);
               Consumed := CRLF_Pos + 2 - Start;
               Status   := Success;
            end;

         when '$' =>
            --  Bulk String: $5\r\nhello\r\n or $-1\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status   := Need_More_Data;
               Consumed := 0;
               return;
            end if;

            declare
               Len_Str : constant String := Buffer (Pos + 1 .. CRLF_Pos - 1);
            begin
               Scan_Integer (Len_Str, Len, Valid, Overflow);
               if not Valid then
                  Status   := Protocol_Error;
                  Consumed := CRLF_Pos + 2 - Start;
                  return;
               end if;
            end;

            if Len = -1 then
               --  Null bulk string.
               Reply    := Null_Bulk;
               Consumed := CRLF_Pos + 2 - Start;
               Status   := Success;
            elsif Len < -1 or else Overflow or else Len > Max_Bulk_Length then
               Status   := Protocol_Error;
               Consumed := CRLF_Pos + 2 - Start;
               return;
            else
               --  Check we have Len bytes + CRLF after the first CRLF.
               Pos := CRLF_Pos + 2;
               if not Remaining (Buffer, Pos, Len + 2) then
                  Status   := Need_More_Data;
                  Consumed := 0;
                  return;
               end if;

               --  Verify trailing CRLF.
               if Buffer (Pos + Integer (Len)) /= ASCII.CR
                 or else Buffer (Pos + Integer (Len) + 1) /= ASCII.LF
               then
                  Status   := Protocol_Error;
                  Consumed := Pos + Integer (Len) + 2 - Start;
                  return;
               end if;

               Reply    := Bulk (Buffer (Pos .. Pos + Integer (Len) - 1));
               Consumed := Pos + Integer (Len) + 2 - Start;
               Status   := Success;
            end if;

         when '*' =>
            --  Array: *2\r\n... or *-1\r\n
            CRLF_Pos := Find_CRLF (Buffer, Pos + 1);
            if CRLF_Pos = 0 then
               Status   := Need_More_Data;
               Consumed := 0;
               return;
            end if;

            declare
               Count_Str : constant String := Buffer (Pos + 1 .. CRLF_Pos - 1);
            begin
               Scan_Integer (Count_Str, Arr_Count, Valid, Overflow);
               if not Valid then
                  Status   := Protocol_Error;
                  Consumed := CRLF_Pos + 2 - Start;
                  return;
               end if;
            end;

            if Arr_Count = -1 then
               Reply    := Null_Array;
               Consumed := CRLF_Pos + 2 - Start;
               Status   := Success;
            elsif Arr_Count < -1 or else Overflow
              or else Arr_Count > Max_Array_Length
            then
               Status   := Protocol_Error;
               Consumed := CRLF_Pos + 2 - Start;
               return;
            else
               if Depth >= Max_Nesting then
                  Status   := Protocol_Error;
                  Consumed := CRLF_Pos + 2 - Start;
                  return;
               end if;

               Reply := Array_Reply;
               Pos   := CRLF_Pos + 2;

               for I in 1 .. Arr_Count loop
                  Parse_Frame (Buffer, Pos, Depth + 1, Sub_Reply, Sub_Status, Sub_Cons);
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
               Status   := Success;
            end if;

         when others =>
            Status   := Protocol_Error;
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
         Status   := Need_More_Data;
         Consumed := 0;
         return;
      end if;

      Parse_Frame (Buffer, Buffer'First, 0, Reply, Status, Consumed);
   end Parse;

end Redis.RESP2;
