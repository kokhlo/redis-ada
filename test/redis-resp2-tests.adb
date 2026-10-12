--  Test runner for redis-ada RESP2 codec.
--  Plain Ada test suite with assertion-based checks.

with Ada.Text_IO;         use Ada.Text_IO;
with Ada.Command_Line;

procedure Redis.RESP2.Tests is

   Passes : Natural := 0;
   Failures : Natural := 0;

   CRLF : constant String := (1 => ASCII.CR, 2 => ASCII.LF);

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if Condition then
         Passes := Passes + 1;
         Put_Line ("[PASS] " & Message);
      else
         Failures := Failures + 1;
         Put_Line ("[FAIL] " & Message);
      end if;
   end Assert;

   procedure Test_Simple_String_Encode is
      R : constant Reply := Simple ("OK");
      Wire : constant String := Encode (R);
   begin
      Assert (Wire = "+OK" & ASCII.CR & ASCII.LF, "Simple string encode");
   end Test_Simple_String_Encode;

   procedure Test_Error_Encode is
      R : constant Reply := Error_Reply ("ERR something went wrong");
      Wire : constant String := Encode (R);
   begin
      Assert (Wire = "-ERR something went wrong" & ASCII.CR & ASCII.LF, "Error encode");
   end Test_Error_Encode;

   procedure Test_Integer_Encode is
      R1 : constant Reply := Number (123);
      R2 : constant Reply := Number (-456);
      W1 : constant String := Encode (R1);
      W2 : constant String := Encode (R2);
   begin
      Assert (W1 = ":123" & ASCII.CR & ASCII.LF, "Positive integer encode");
      Assert (W2 = ":-456" & ASCII.CR & ASCII.LF, "Negative integer encode");
   end Test_Integer_Encode;

   procedure Test_Bulk_String_Encode is
      R : constant Reply := Bulk ("hello");
      Wire : constant String := Encode (R);
   begin
      Assert (Wire = "$5" & ASCII.CR & ASCII.LF & "hello" & ASCII.CR & ASCII.LF,
              "Bulk string encode");
   end Test_Bulk_String_Encode;

   procedure Test_Null_Bulk_Encode is
      R : constant Reply := Null_Bulk;
      Wire : constant String := Encode (R);
   begin
      Assert (Wire = "$-1" & ASCII.CR & ASCII.LF, "Null bulk encode");
   end Test_Null_Bulk_Encode;

   procedure Test_Null_Array_Encode is
      R : constant Reply := Null_Array;
      Wire : constant String := Encode (R);
   begin
      Assert (Wire = "*-1" & ASCII.CR & ASCII.LF, "Null array encode");
   end Test_Null_Array_Encode;

   procedure Test_Array_Encode is
      R : Reply := Array_Reply;
   begin
      Append (R, Simple ("OK"));
      Append (R, Number (42));
      declare
         Wire : constant String := Encode (R);
      begin
         Assert (Wire = "*2" & ASCII.CR & ASCII.LF
                   & "+OK" & ASCII.CR & ASCII.LF
                   & ":42" & ASCII.CR & ASCII.LF,
                 "Array encode");
      end;
   end Test_Array_Encode;

   procedure Test_Parse_Simple_String is
      Wire : constant String := "+OK" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Parse simple string status");
      Assert (Kind_Of (R) = Simple_String, "Parse simple string kind");
      Assert (Text (R) = "OK", "Parse simple string text");
      Assert (Cons = Wire'Length, "Parse simple string consumed");
   end Test_Parse_Simple_String;

   procedure Test_Parse_Error is
      Wire : constant String := "-ERR bad command" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Parse error status");
      Assert (Kind_Of (R) = Error, "Parse error kind");
      Assert (Text (R) = "ERR bad command", "Parse error text");
   end Test_Parse_Error;

   procedure Test_Parse_Integer is
      Wire : constant String := ":9876" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Parse integer status");
      Assert (Kind_Of (R) = Integer_Reply, "Parse integer kind");
      Assert (Value (R) = 9876, "Parse integer value");
   end Test_Parse_Integer;

   procedure Test_Parse_Negative_Integer is
      Wire : constant String := ":-123" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Parse negative integer status");
      Assert (Value (R) = -123, "Parse negative integer value");
   end Test_Parse_Negative_Integer;

   procedure Test_Parse_Bulk_String is
      Wire : constant String := "$5" & ASCII.CR & ASCII.LF & "world" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Parse bulk string status");
      Assert (Kind_Of (R) = Bulk_String, "Parse bulk string kind");
      Assert (Text (R) = "world", "Parse bulk string text");
      Assert (not Is_Null (R), "Parse bulk string not null");
   end Test_Parse_Bulk_String;

   procedure Test_Parse_Null_Bulk is
      Wire : constant String := "$-1" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Parse null bulk status");
      Assert (Is_Null (R), "Parse null bulk is null");
      Assert (Kind_Of (R) = Bulk_String, "Parse null bulk kind");
   end Test_Parse_Null_Bulk;

   procedure Test_Parse_Null_Array is
      Wire : constant String := "*-1" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Parse null array status");
      Assert (Is_Null (R), "Parse null array is null");
      Assert (Kind_Of (R) = Array_Frame, "Parse null array kind");
   end Test_Parse_Null_Array;

   procedure Test_Parse_Array is
      Wire : constant String := "*2" & ASCII.CR & ASCII.LF
        & "$3" & ASCII.CR & ASCII.LF & "abc" & ASCII.CR & ASCII.LF
        & ":7" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Parse array status");
      Assert (Kind_Of (R) = Array_Frame, "Parse array kind");
      Assert (Length (R) = 2, "Parse array length");
      Assert (Text (Element (R, 1)) = "abc", "Parse array elem 1");
      Assert (Value (Element (R, 2)) = 7, "Parse array elem 2");
   end Test_Parse_Array;

   procedure Test_Parse_Nested_Array is
      Wire : constant String := "*2" & ASCII.CR & ASCII.LF
        & "*1" & ASCII.CR & ASCII.LF & ":5" & ASCII.CR & ASCII.LF
        & "+nested" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Parse nested array status");
      Assert (Length (R) = 2, "Parse nested array length");
      Assert (Kind_Of (Element (R, 1)) = Array_Frame, "Parse nested array elem 1 kind");
      Assert (Length (Element (R, 1)) = 1, "Parse nested inner array length");
      Assert (Value (Element (Element (R, 1), 1)) = 5, "Parse nested inner array elem");
      Assert (Text (Element (R, 2)) = "nested", "Parse nested array elem 2");
   end Test_Parse_Nested_Array;

   procedure Test_Parse_Partial_Input is
      Wire : constant String := "+OK";  --  Missing CRLF
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Need_More_Data, "Parse partial input status");
      Assert (Cons = 0, "Parse partial input consumed");
   end Test_Parse_Partial_Input;

   procedure Test_Parse_Byte_By_Byte is
      Wire : constant String := ":42" & ASCII.CR & ASCII.LF;
      Buffer : String (1 .. 10) := (others => ' ');
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      --  Feed one byte at a time until success.
      for I in Wire'Range loop
         Buffer (1 .. I) := Wire (Wire'First .. Wire'First + I - 1);
         Parse (Buffer (1 .. I), R, St, Cons);
         if I < Wire'Last then
            Assert (St = Need_More_Data, "Parse byte-by-byte need more at" & Integer'Image (I));
         else
            Assert (St = Success, "Parse byte-by-byte success");
            Assert (Value (R) = 42, "Parse byte-by-byte value");
         end if;
      end loop;
   end Test_Parse_Byte_By_Byte;

   procedure Test_Bulk_With_Embedded_CRLF is
      --  Bulk string containing CRLF in the middle.
      Payload : constant String := "line1" & ASCII.CR & ASCII.LF & "line2";
      R : constant Reply := Bulk (Payload);
      Wire : constant String := Encode (R);
      R2 : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R2, St, Cons);
      Assert (St = Success, "Parse bulk with embedded CRLF status");
      Assert (Text (R2) = Payload, "Parse bulk with embedded CRLF text");
   end Test_Bulk_With_Embedded_CRLF;

   procedure Test_Roundtrip_All_Types is
      R_Simple : constant Reply := Simple ("hello");
      R_Error : constant Reply := Error_Reply ("ERR test");
      R_Int : constant Reply := Number (999);
      R_Bulk : constant Reply := Bulk ("data");
      R_Null_Bulk : constant Reply := Null_Bulk;
      R_Null_Arr : constant Reply := Null_Array;
      R_Array : Reply := Array_Reply;

      R2 : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Append (R_Array, Simple ("x"));
      Append (R_Array, Number (1));

      --  Roundtrip each type.
      declare
         W : constant String := Encode (R_Simple);
      begin
         Parse (W, R2, St, Cons);
         Assert (St = Success and then Text (R2) = "hello", "Roundtrip simple string");
      end;

      declare
         W : constant String := Encode (R_Error);
      begin
         Parse (W, R2, St, Cons);
         Assert (St = Success and then Text (R2) = "ERR test", "Roundtrip error");
      end;

      declare
         W : constant String := Encode (R_Int);
      begin
         Parse (W, R2, St, Cons);
         Assert (St = Success and then Value (R2) = 999, "Roundtrip integer");
      end;

      declare
         W : constant String := Encode (R_Bulk);
      begin
         Parse (W, R2, St, Cons);
         Assert (St = Success and then Text (R2) = "data", "Roundtrip bulk");
      end;

      declare
         W : constant String := Encode (R_Null_Bulk);
      begin
         Parse (W, R2, St, Cons);
         Assert (St = Success and then Is_Null (R2), "Roundtrip null bulk");
      end;

      declare
         W : constant String := Encode (R_Null_Arr);
      begin
         Parse (W, R2, St, Cons);
         Assert (St = Success and then Is_Null (R2), "Roundtrip null array");
      end;

      declare
         W : constant String := Encode (R_Array);
      begin
         Parse (W, R2, St, Cons);
         Assert (St = Success and then Length (R2) = 2, "Roundtrip array");
      end;
   end Test_Roundtrip_All_Types;

   procedure Test_Protocol_Error_Bad_Marker is
      Wire : constant String := "X123" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Protocol_Error, "Parse protocol error bad marker");
   end Test_Protocol_Error_Bad_Marker;

   procedure Test_Protocol_Error_Bad_Integer is
      Wire : constant String := ":abc" & ASCII.CR & ASCII.LF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Protocol_Error, "Parse protocol error bad integer");
   end Test_Protocol_Error_Bad_Integer;

   --  ------------------------------------------------------------------
   --  Regression tests for parser hardening (strict numbers, length
   --  limits, depth limit, reply ownership).
   --  ------------------------------------------------------------------

   procedure Test_Parse_Strict_Integer_Syntax is
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (":+5" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Integer with explicit plus rejected");
      Parse (": 5" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Integer with leading space rejected");
      Parse (":5 " & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Integer with trailing space rejected");
      Parse (":" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Empty integer rejected");
      Parse (":5x" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Integer with trailing junk rejected");
   end Test_Parse_Strict_Integer_Syntax;

   procedure Test_Parse_Strict_Bulk_Length_Syntax is
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse ("$+5" & CRLF & "hello" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Bulk length with plus rejected");
      Parse ("$5x" & CRLF & "hello" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Bulk length with junk rejected");
      Parse ("$" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Empty bulk length rejected");
      Parse ("$1_0" & CRLF & "hello" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Bulk length with underscore rejected");
   end Test_Parse_Strict_Bulk_Length_Syntax;

   procedure Test_Parse_Strict_Array_Count_Syntax is
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse ("*+2" & CRLF & ":1" & CRLF & ":2" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Array count with plus rejected");
      Parse ("*2x" & CRLF & ":1" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Array count with junk rejected");
      Parse ("*" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Empty array count rejected");
   end Test_Parse_Strict_Array_Count_Syntax;

   procedure Test_Parse_Negative_Lengths_Rejected is
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse ("$-2" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Bulk length -2 rejected (only -1 is null)");
      Parse ("*-2" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Array count -2 rejected (only -1 is null)");
   end Test_Parse_Negative_Lengths_Rejected;

   procedure Test_Parse_Oversized_Lengths_Rejected is
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      --  Above the 512 MiB bulk limit: rejected immediately instead of
      --  reporting Need_More_Data (which would make the caller buffer it).
      Parse ("$600000000" & CRLF & "x", R, St, Cons);
      Assert (St = Protocol_Error, "Oversized bulk length rejected");
      --  Above the 1,000,000 element array limit.
      Parse ("*2000000000" & CRLF, R, St, Cons);
      Assert (St = Protocol_Error, "Oversized array count rejected");
      --  Larger than any Integer: rejected without overflow.
      Parse ("$99999999999999999999" & CRLF & "x", R, St, Cons);
      Assert (St = Protocol_Error, "Unrepresentable bulk length rejected");
   end Test_Parse_Oversized_Lengths_Rejected;

   procedure Test_Parse_Empty_Payloads is
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse ("+" & CRLF, R, St, Cons);
      Assert (St = Success and then Text (R) = "", "Empty simple string accepted");
      Assert (Cons = 3, "Empty simple string consumed");
      Parse ("$0" & CRLF & CRLF, R, St, Cons);
      Assert (St = Success and then Text (R) = "", "Empty bulk string accepted");
      Parse ("*0" & CRLF, R, St, Cons);
      Assert (St = Success and then Length (R) = 0, "Empty array accepted");
   end Test_Parse_Empty_Payloads;

   procedure Test_Parse_Array_Byte_By_Byte is
      Wire : constant String := "*2" & CRLF
        & "$3" & CRLF & "abc" & CRLF
        & ":7" & CRLF;
   begin
      --  Every strict prefix of a composite frame must report Need_More_Data.
      for I in 1 .. Wire'Length - 1 loop
         declare
            R : Reply;
            St : Parse_Status;
            Cons : Natural;
         begin
            Parse (Wire (Wire'First .. Wire'First + I - 1), R, St, Cons);
            Assert (St = Need_More_Data and then Cons = 0,
                    "Array byte-by-byte partial at" & Integer'Image (I));
         end;
      end loop;

      declare
         R : Reply;
         St : Parse_Status;
         Cons : Natural;
      begin
         Parse (Wire, R, St, Cons);
         Assert (St = Success, "Array byte-by-byte final success");
         Assert (Cons = Wire'Length, "Array byte-by-byte consumed");
         Assert (Length (R) = 2, "Array byte-by-byte length");
         Assert (Text (Element (R, 1)) = "abc", "Array byte-by-byte elem 1");
         Assert (Value (Element (R, 2)) = 7, "Array byte-by-byte elem 2");
      end;
   end Test_Parse_Array_Byte_By_Byte;

   procedure Test_Parse_Trailing_Data_Consumed is
      --  Parse reads exactly one frame; trailing bytes stay for the caller
      --  (pipelining). Consumed must point at the end of the first frame.
      Wire : constant String := "*1" & CRLF & ":1" & CRLF & "XYZ";
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Trailing data: success");
      Assert (Cons = 8, "Trailing data: consumed covers first frame only");
      Assert (Length (R) = 1, "Trailing data: frame content intact");
   end Test_Parse_Trailing_Data_Consumed;

   procedure Test_Parse_Depth_Limit is
      OK_Wire  : Unbounded_String;
      Bad_Wire : Unbounded_String;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
   begin
      for I in 1 .. 100 loop
         Append (OK_Wire, "*1" & CRLF);
      end loop;
      Append (OK_Wire, ":1" & CRLF);
      Parse (To_String (OK_Wire), R, St, Cons);
      Assert (St = Success, "Nesting depth 100 accepted");

      for I in 1 .. 200 loop
         Append (Bad_Wire, "*1" & CRLF);
      end loop;
      Append (Bad_Wire, ":1" & CRLF);
      Parse (To_String (Bad_Wire), R, St, Cons);
      Assert (St = Protocol_Error, "Nesting depth beyond limit rejected");
   end Test_Parse_Depth_Limit;

   procedure Test_Element_Copy_Independence is
      Wire : constant String := "*2" & CRLF
        & "*1" & CRLF & ":5" & CRLF
        & "+x" & CRLF;
      R : Reply;
      St : Parse_Status;
      Cons : Natural;
      E : Reply;
   begin
      Parse (Wire, R, St, Cons);
      Assert (St = Success, "Copy independence: parse ok");
      E := Element (R, 1);          --  must be an independent deep copy
      Append (E, Number (42));      --  must not touch the source frame
      Assert (Length (E) = 2, "Copy independence: copy grows");
      Assert (Length (Element (R, 1)) = 1, "Copy independence: source unchanged");
   end Test_Element_Copy_Independence;

   procedure Test_Assignment_Deep_Copy is
      A : Reply := Array_Reply;
      B : Reply;
   begin
      Append (A, Number (1));
      Append (A, Number (2));
      B := A;                        --  must deep-copy the element list
      Append (B, Number (3));
      Assert (Length (A) = 2, "Assignment deep copy: source unchanged");
      Assert (Length (B) = 3, "Assignment deep copy: target grows");
      Assert (Value (Element (B, 3)) = 3, "Assignment deep copy: new element readable");
   end Test_Assignment_Deep_Copy;

   procedure Test_Copy_Outlives_Source is
      E : Reply;
   begin
      declare
         Wire : constant String := "*1" & CRLF & "*1" & CRLF & ":5" & CRLF;
         R : Reply;
         St : Parse_Status;
         Cons : Natural;
      begin
         Parse (Wire, R, St, Cons);
         Assert (St = Success, "Outlives source: parse ok");
         E := Element (Element (R, 1), 1);
      end;  --  R goes out of scope; its node list is reclaimed
      Assert (Kind_Of (E) = Integer_Reply and then Value (E) = 5,
              "Copy of element survives finalization of source");
   end Test_Copy_Outlives_Source;

begin
   Put_Line ("=== redis-ada RESP2 Codec Test Suite ===");
   New_Line;

   Test_Simple_String_Encode;
   Test_Error_Encode;
   Test_Integer_Encode;
   Test_Bulk_String_Encode;
   Test_Null_Bulk_Encode;
   Test_Null_Array_Encode;
   Test_Array_Encode;

   Test_Parse_Simple_String;
   Test_Parse_Error;
   Test_Parse_Integer;
   Test_Parse_Negative_Integer;
   Test_Parse_Bulk_String;
   Test_Parse_Null_Bulk;
   Test_Parse_Null_Array;
   Test_Parse_Array;
   Test_Parse_Nested_Array;

   Test_Parse_Partial_Input;
   Test_Parse_Byte_By_Byte;
   Test_Bulk_With_Embedded_CRLF;
   Test_Roundtrip_All_Types;

   Test_Protocol_Error_Bad_Marker;
   Test_Protocol_Error_Bad_Integer;

   Test_Parse_Strict_Integer_Syntax;
   Test_Parse_Strict_Bulk_Length_Syntax;
   Test_Parse_Strict_Array_Count_Syntax;
   Test_Parse_Negative_Lengths_Rejected;
   Test_Parse_Oversized_Lengths_Rejected;
   Test_Parse_Empty_Payloads;
   Test_Parse_Array_Byte_By_Byte;
   Test_Parse_Trailing_Data_Consumed;
   Test_Parse_Depth_Limit;
   Test_Element_Copy_Independence;
   Test_Assignment_Deep_Copy;
   Test_Copy_Outlives_Source;

   New_Line;
   Put_Line ("=== Summary ===");
   Put_Line ("Passes:   " & Natural'Image (Passes));
   Put_Line ("Failures: " & Natural'Image (Failures));

   if Failures = 0 then
      Put_Line ("ALL TESTS PASSED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Put_Line ("SOME TESTS FAILED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Redis.RESP2.Tests;
