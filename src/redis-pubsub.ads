--  Publish/Subscribe: subscriber connections with timeout-driven Listen
--  plus a PUBLISH wrapper for regular command connections.
--
--  Redis requires a dedicated connection per subscriber: once SUBSCRIBE
--  is active the server only pushes event frames over that connection,
--  so it can no longer be used for request/response commands.

with Ada.Strings.Unbounded;
with GNAT.Sockets;
with Redis.Connection;
with Redis.RESP2;

package Redis.PubSub is

   --  Kinds of frames that arrive on a subscribed connection.
   type Event_Kind is
     (Message_Event,          --  payload delivered on a channel
      Pattern_Message_Event,  --  payload delivered via a pattern subscription
      Subscribe_Event,        --  confirmation of SUBSCRIBE
      Unsubscribe_Event,      --  confirmation of UNSUBSCRIBE
      PSubscribe_Event,       --  confirmation of PSUBSCRIBE
      PUnsubscribe_Event,     --  confirmation of PUNSUBSCRIBE
      Pong_Event);            --  reply to PING sent while subscribed

   --  One decoded server frame. Channel, Pattern and Payload are
   --  unbounded because they are binary-safe bulk strings of any length;
   --  Count carries the subscription counter attached to (un)subscribe
   --  confirmations.
   type Message is record
      Kind    : Event_Kind := Message_Event;
      Channel : Ada.Strings.Unbounded.Unbounded_String;
      Pattern : Ada.Strings.Unbounded.Unbounded_String;
      Payload : Ada.Strings.Unbounded.Unbounded_String;
      Count   : Long_Long_Integer := 0;
   end record;

   Null_Message : constant Message;

   function Channel_Text (M : Message) return String;
   function Pattern_Text (M : Message) return String;
   function Payload_Text (M : Message) return String;

   --  Decode a parsed array reply into an event. Raises Protocol_Error
   --  when the frame is not a valid pub/sub push.
   function Decode_Event (Frame : Redis.RESP2.Reply) return Message;

   type Listen_Status is (Got_Message, No_Message);

   type Subscriber is limited private;

   Connection_Failed : exception renames Redis.Connection.Connection_Failed;
   Protocol_Error    : exception renames Redis.Connection.Protocol_Error;

   --  Open the dedicated subscriber connection.
   procedure Connect
     (Sub     : in out Subscriber;
      Host    : String;
      Port    : Positive := 6379;
      Timeout : Duration := 5.0);

   --  Subscribe to channels. Returns only after the server confirmed
   --  every channel, so messages published afterwards cannot be missed.
   procedure Subscribe
     (Sub      : in out Subscriber;
      Channels : Redis.Connection.String_Vector);

   --  Unsubscribe from channels. An empty vector unsubscribes from all
   --  channels; those confirmations then surface through Listen.
   procedure Unsubscribe
     (Sub      : in out Subscriber;
      Channels : Redis.Connection.String_Vector);

   --  Subscribe to glob-style patterns (for example "news.*").
   procedure PSubscribe
     (Sub      : in out Subscriber;
      Patterns : Redis.Connection.String_Vector);

   procedure PUnsubscribe
     (Sub      : in out Subscriber;
      Patterns : Redis.Connection.String_Vector);

   --  Wait up to Timeout for the next event on the subscription.
   --  Returns No_Message when nothing arrived in time; never blocks
   --  longer than Timeout.
   procedure Listen
     (Sub     : in out Subscriber;
      Timeout : Duration;
      Msg     : out Message;
      Status  : out Listen_Status);

   procedure Disconnect (Sub : in out Subscriber);

   function Is_Connected (Sub : Subscriber) return Boolean;

   --  Publish Payload on Channel over a regular command connection.
   --  Returns the number of subscribers that received the message.
   function Publish
     (Conn    : in out Redis.Connection.Redis_Connection;
      Channel : String;
      Payload : String) return Natural;

private

   Null_Message : constant Message := (others => <>);

   type Subscriber is limited record
      Socket    : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Connected : Boolean := False;
      --  Bytes received but not yet consumed by a decoded frame.
      Buffer    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Redis.PubSub;
