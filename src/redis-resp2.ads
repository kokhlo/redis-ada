--  RESP2 (REdis Serialization Protocol version 2) codec.
--  Implements parsing and serialization of the five RESP2 frame types:
--    Simple String (+OK\r\n)
--    Error (-ERR message\r\n)
--    Integer (:123\r\n)
--    Bulk String ($5\r\nhello\r\n, or $-1\r\n for null)
--    Array (*2\r\n..., or *-1\r\n for null)

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

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
   function Element (Item : Reply; Index : Positive) return Reply;

   --  Serialize a Reply into RESP2 wire format.
   function Encode (Item : Reply) return String;

   --  Parse result status.
   type Parse_Status is (Success, Need_More_Data, Protocol_Error);

   --  Parse RESP2 frames from a buffer.
   --  On Success: Reply holds the parsed frame, Consumed tells how many bytes were read.
   --  On Need_More_Data: input is incomplete (Consumed = 0).
   --  On Protocol_Error: malformed input (Consumed may be > 0).
   procedure Parse
     (Buffer   : String;
      Reply    : out Redis.RESP2.Reply;
      Status   : out Parse_Status;
      Consumed : out Natural);

private

   type Reply_Ptr;

   --  Simple linked list node for array elements.
   type Reply_Node;
   type Reply_Node_Ptr is access Reply_Node;

   type Reply is record
      Frame_Kind : Kind := Simple_String;
      --  Payload for Simple_String / Bulk_String / Error frames.
      Payload    : Unbounded_String;
      Int_Value  : Long_Long_Integer := 0;
      --  -1 marks a null array/bulk; element count otherwise.
      Count      : Integer := 0;
      --  Linked list head for array items.
      First_Item : Reply_Node_Ptr := null;
      Last_Item  : Reply_Node_Ptr := null;
   end record;

   type Reply_Ptr is access all Reply;

   type Reply_Node is record
      Data : Reply_Ptr;
      Next : Reply_Node_Ptr;
   end record;

   Null_Reply : constant Reply := (Simple_String, others => <>);

end Redis.RESP2;
