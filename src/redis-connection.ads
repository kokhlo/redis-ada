--  TCP connection layer for Redis over RESP2.
--  Provides a blocking socket-based Execute API that sends RESP2 commands
--  and receives replies.

with GNAT.Sockets;
with Ada.Containers.Indefinite_Vectors;
with Redis.RESP2;

package Redis.Connection is

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);
   subtype String_Vector is String_Vectors.Vector;

   type Redis_Connection is limited private;

   Connection_Failed : exception;
   Protocol_Error    : exception;

   --  Maximum bytes buffered for a single reply before giving up
   --  (guards against a peer that never terminates a frame).
   Max_Reply_Bytes : constant := 64 * 1024 * 1024;  -- 64 MiB

   --  Establish a TCP connection to a Redis server.
   --  The timeout applies to DNS resolution, connect, and later sends and
   --  receives on the socket.
   --  Raises Connection_Failed on DNS failure, connection refused, or timeout.
   procedure Connect
     (Conn    : in out Redis_Connection;
      Host    : String;
      Port    : Positive := 6379;
      Timeout : Duration := 5.0);

   --  Send a command (as an array of strings) and receive the reply.
   --  Args(1) is the command name (e.g. "PING"), Args(2..N) are arguments.
   --  An empty Args vector is a usage error and raises Protocol_Error
   --  before anything is written to the socket.
   --  Raises Protocol_Error on malformed server response; the connection
   --  is then marked dead (a resynchronising read is not possible without
   --  talking to the server again, so the caller must reconnect).
   --  Raises Connection_Failed on I/O errors or server disconnect.
   procedure Execute
     (Conn  : in out Redis_Connection;
      Args  : String_Vector;
      Reply : out Redis.RESP2.Reply);

   --  Close the connection.
   procedure Disconnect (Conn : in out Redis_Connection);

   --  Check if the connection is established.
   function Is_Connected (Conn : Redis_Connection) return Boolean;

private

   use GNAT.Sockets;

   type Redis_Connection is limited record
      Socket    : Socket_Type := No_Socket;
      Connected : Boolean     := False;
   end record;

end Redis.Connection;
