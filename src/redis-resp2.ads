--  RESP2 (REdis Serialization Protocol version 2) codec.
--  Implements parsing and serialization of the five RESP2 frame types:
--    Simple String (+OK\r\n)
--    Error (-ERR message\r\n)
--    Integer (:123\r\n)
--    Bulk String ($5\r\nhello\r\n, or $-1\r\n for null)
--    Array (*2\r\nn..., or *-1\r\n for null)
--
--  Reply is a controlled type: assignment, copies and finalization are
--  by-value (deep). Elements returned by Element are independent of the
--  source frame; memory for array elements is reclaimed automatically.

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Finalization;

package Redis.RESP2 is

   --  The five RESP2 frame kinds as defined by the protocol.
   type Kind is (Simple_String, Error, Integer_Reply, Bulk_String, Array_Frame);

   type Reply is private;

   Null_Reply : constant Reply;

   --  Constructors for each frame type.
   function Simple (Value : String) return Reply;
   function Error_Reply (Message : String) return Reply;
   function Number (Value : Long_Long_Integer) return Reply;
   function Bulk (Value : String) return Reply;
   function Null_Bulk return Reply;
   function Null_Array return Reply;
   function Array_Reply return Reply;

   --  Append an element to an array reply.
   procedure Append (To : in out Reply; Item : Reply);

   --  Query frame kind and null status.
   function Kind_Of (Item : Reply) return Kind;
   function Is_Null (Item : Reply) return Boolean;

   --  Access payload for Simple_String, Bulk_String, and Error frames.
   function Text (Item : Reply) return String;

   --  Access Integer frame value.
   function Value (Item : Reply) return Long_Long_Integer;

   --  Array element count. Null arrays report -1.
   function Length (Item : Reply) return Integer;

   --  Array element access (1-based indexing).
   --  The returned frame is an independent copy; mutating it (e.g. with
   --  Append) never affects the source array.
   function Element (Item : Reply; Index : Positive) return Reply;

   --  Serialize a Reply into RESP2 wire format.
   function Encode (Item : Reply) return String;

   --  Parse result status.
   type Parse_Status is (Success, Need_More_Data, Protocol_Error);

   --  Parse exactly one RESP2 frame from the front of Buffer.
   --  On Success: Reply holds the parsed frame, Consumed tells how many bytes
   --  were read; any trailing bytes belong to the next frame (pipelining).
   --  On Need_More_Data: input is incomplete (Consumed = 0).
   --  On Protocol_Error: malformed input (Consumed may be > 0).
   --  Malformed means: unknown type marker; numbers that are not plain
   --  optional-minus decimal integers; bulk lengths other than -1/0..512 MiB;
   --  array counts other than -1/0..1_000_000; nesting deeper than 128.
   procedure Parse
     (Buffer   : String;
      Reply    : out Redis.RESP2.Reply;
      Status   : out Parse_Status;
      Consumed : out Natural);

private

   --  Simple linked list node for array elements. Each node owns its
   --  element by value, so the controlled-type machinery of Reply reclaims
   --  nested frames recursively.
   type Reply_Node;
   type Reply_Node_Ptr is access Reply_Node;

   type Reply is new Ada.Finalization.Controlled with record
      Frame_Kind : Kind := Simple_String;
      --  Payload for Simple_String / Bulk_String / Error frames.
      Payload    : Unbounded_String;
      Int_Value  : Long_Long_Integer := 0;
      --  -1 marks a null array/bulk; element count otherwise.
      Count      : Integer := 0;
      --  Linked list head/tail for array items.
      First_Item : Reply_Node_Ptr := null;
      Last_Item  : Reply_Node_Ptr := null;
   end record;

   --  Deep-copy the element list on assignment/copy.
   overriding procedure Adjust (Item : in out Reply);
   --  Free the element list (recursively, via node finalization).
   overriding procedure Finalize (Item : in out Reply);

   type Reply_Node is record
      Data : Reply;
      Next : Reply_Node_Ptr;
   end record;

   Null_Reply : constant Reply :=
     (Ada.Finalization.Controlled with others => <>);

end Redis.RESP2;
