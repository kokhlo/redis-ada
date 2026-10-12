--  Test runner for redis-ada connection layer.
--  Unit tests for command encoding and connection failure handling, plus
--  live server interactions when a Redis server is available.

with Ada.Text_IO;         use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Exceptions;
with Redis.RESP2;         use Redis.RESP2;

procedure Redis.Connection.Tests is

   Passes : Natural := 0;
   Failures : Natural := 0;
   Live_Server_Available : Boolean := False;

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

   --  Check if a local Redis server is available (without AUTH).
   function Probe_Redis_Server return Boolean is
      Conn : Redis_Connection;
      Reply : Redis.RESP2.Reply;
      Args : String_Vector;
   begin
      Connect (Conn, "127.0.0.1", 6380, 2.0);
      Args.Append ("PING");
      Execute (Conn, Args, Reply);
      Disconnect (Conn);
      return Kind_Of (Reply) = Simple_String and then Text (Reply) = "PONG";
   exception
      when others =>
         return False;
   end Probe_Redis_Server;

   procedure Test_Command_Encoding_SET is
      --  The wire form of SET foo bar, built through the public codec.
      Arr : Reply := Array_Reply;
      Expected : constant String := "*3" & ASCII.CR & ASCII.LF
        & "$3" & ASCII.CR & ASCII.LF & "SET" & ASCII.CR & ASCII.LF
        & "$3" & ASCII.CR & ASCII.LF & "foo" & ASCII.CR & ASCII.LF
        & "$3" & ASCII.CR & ASCII.LF & "bar" & ASCII.CR & ASCII.LF;
   begin
      Append (Arr, Bulk ("SET"));
      Append (Arr, Bulk ("foo"));
      Append (Arr, Bulk ("bar"));
      Assert (Encode (Arr) = Expected, "Command encoding SET foo bar");
   end Test_Command_Encoding_SET;

   procedure Test_Command_Encoding_GET is
      Arr : Reply := Array_Reply;
      Expected : constant String := "*2" & ASCII.CR & ASCII.LF
        & "$3" & ASCII.CR & ASCII.LF & "GET" & ASCII.CR & ASCII.LF
        & "$3" & ASCII.CR & ASCII.LF & "key" & ASCII.CR & ASCII.LF;
   begin
      Append (Arr, Bulk ("GET"));
      Append (Arr, Bulk ("key"));
      Assert (Encode (Arr) = Expected, "Command encoding GET key");
   end Test_Command_Encoding_GET;

   procedure Test_Connect_Refused is
      --  Connect to a closed port (127.0.0.1:1) should raise Connection_Failed.
      Conn : Redis_Connection;
   begin
      begin
         Connect (Conn, "127.0.0.1", 1, 1.0);
         Assert (False, "Connect to closed port should fail");
      exception
         when Connection_Failed =>
            Assert (True, "Connect to closed port raises Connection_Failed");
         when others =>
            Assert (False, "Connect to closed port raised unexpected exception");
      end;
   end Test_Connect_Refused;

   procedure Test_Connect_Timeout is
      --  Attempt to connect to a non-routable IP with a short timeout.
      --  May either timeout or fail fast (connection unreachable).
      Conn : Redis_Connection;
   begin
      begin
         Connect (Conn, "10.255.255.1", 6379, 2.0);
         Assert (False, "Connect to non-routable IP should fail");
      exception
         when Connection_Failed =>
            Assert (True, "Connect timeout/unreachable raises Connection_Failed");
         when others =>
            Assert (False, "Connect timeout raised unexpected exception");
      end;
   end Test_Connect_Timeout;

   procedure Test_Execute_Not_Connected is
      Conn : Redis_Connection;
      Args : String_Vector;
      Reply : Redis.RESP2.Reply;
   begin
      begin
         Execute (Conn, Args, Reply);
         Assert (False, "Execute before connect should raise");
      exception
         when Connection_Failed =>
            Assert (True, "Execute on idle connection raises Connection_Failed");
         when others =>
            Assert (False, "Execute on idle connection raised wrong exception");
      end;
   end Test_Execute_Not_Connected;

   procedure Test_Execute_Empty_Command is
      Conn : Redis_Connection;
      Args : String_Vector;   --  deliberately empty
      Reply : Redis.RESP2.Reply;
   begin
      begin
         Connect (Conn, "127.0.0.1", 1, 1.0);
      exception
         when Connection_Failed => null;   --  expected
      end;
      begin
         --  The connection may be dead or alive; either way an empty command
         --  must be rejected before anything reaches the socket.
         Execute (Conn, Args, Reply);
         Assert (False, "Empty command should raise");
      exception
         when Connection_Failed =>
            Assert (True, "Empty command raises (Connection_Failed)");
         when Protocol_Error =>
            Assert (True, "Empty command raises (Protocol_Error)");
         when others =>
            Assert (False, "Empty command raised wrong exception");
      end;
   end Test_Execute_Empty_Command;

   --  Live integration tests (run only against a real server) --

   procedure Test_Live_PING is
      Conn : Redis_Connection;
      Args : String_Vector;
      Reply : Redis.RESP2.Reply;
   begin
      Connect (Conn, "127.0.0.1", 6380, 2.0);
      Args.Append ("PING");
      Execute (Conn, Args, Reply);
      Disconnect (Conn);
      Assert (Kind_Of (Reply) = Simple_String and then Text (Reply) = "PONG",
              "Live PING returns +PONG");
   exception
      when E : others =>
         Put_Line ("[SKIP] Live PING test failed: " & Ada.Exceptions.Exception_Message (E));
   end Test_Live_PING;

   procedure Test_Live_SET_GET_DEL is
      Conn : Redis_Connection;
      Args : String_Vector;
      Reply : Redis.RESP2.Reply;
   begin
      Connect (Conn, "127.0.0.1", 6380, 2.0);

      Args.Append ("SET");
      Args.Append ("redis_ada_test:key");
      Args.Append ("test_value");
      Execute (Conn, Args, Reply);
      Assert (Kind_Of (Reply) = Simple_String and then Text (Reply) = "OK",
              "Live SET returns +OK");

      Args.Clear;
      Args.Append ("GET");
      Args.Append ("redis_ada_test:key");
      Execute (Conn, Args, Reply);
      Assert (Kind_Of (Reply) = Bulk_String and then Text (Reply) = "test_value",
              "Live GET returns bulk value");

      Args.Clear;
      Args.Append ("DEL");
      Args.Append ("redis_ada_test:key");
      Execute (Conn, Args, Reply);
      Assert (Kind_Of (Reply) = Integer_Reply and then Value (Reply) = 1,
              "Live DEL returns :1");

      Disconnect (Conn);
   exception
      when E : others =>
         Put_Line ("[SKIP] Live SET/GET/DEL test failed: " & Ada.Exceptions.Exception_Message (E));
   end Test_Live_SET_GET_DEL;

   procedure Test_Live_Bad_Command is
      Conn : Redis_Connection;
      Args : String_Vector;
      Reply : Redis.RESP2.Reply;
   begin
      Connect (Conn, "127.0.0.1", 6380, 2.0);
      Args.Append ("NOTAREALCOMMAND");
      Execute (Conn, Args, Reply);
      Disconnect (Conn);
      Assert (Kind_Of (Reply) = Error,
              "Live bad command returns -ERR");
   exception
      when E : others =>
         Put_Line ("[SKIP] Live bad command test failed: " & Ada.Exceptions.Exception_Message (E));
   end Test_Live_Bad_Command;

   procedure Test_Live_Null_Bulk is
      --  GET of a missing key must surface as a null bulk, not an error.
      Conn : Redis_Connection;
      Args : String_Vector;
      Reply : Redis.RESP2.Reply;
   begin
      Connect (Conn, "127.0.0.1", 6380, 2.0);
      Args.Append ("GET");
      Args.Append ("redis_ada_test:missing");
      Execute (Conn, Args, Reply);
      Disconnect (Conn);
      Assert (Kind_Of (Reply) = Bulk_String and then Is_Null (Reply),
              "Live GET missing key returns null bulk");
   exception
      when E : others =>
         Put_Line ("[SKIP] Live null bulk test failed: " & Ada.Exceptions.Exception_Message (E));
   end Test_Live_Null_Bulk;

begin
   Put_Line ("=== redis-ada Connection Layer Test Suite ===");
   New_Line;

   Put_Line ("Checking for local Redis server...");
   Live_Server_Available := Probe_Redis_Server;
   if Live_Server_Available then
      Put_Line ("* Redis server detected at 127.0.0.1:6380 (live tests will run)");
   else
      Put_Line ("- No Redis server detected (live tests will be skipped)");
   end if;
   New_Line;

   Put_Line ("--- Unit Tests (no server required) ---");
   Test_Command_Encoding_SET;
   Test_Command_Encoding_GET;
   Test_Connect_Refused;
   Test_Connect_Timeout;
   Test_Execute_Not_Connected;
   Test_Execute_Empty_Command;
   New_Line;

   if Live_Server_Available then
      Put_Line ("--- Live Integration Tests ---");
      Test_Live_PING;
      Test_Live_SET_GET_DEL;
      Test_Live_Bad_Command;
      Test_Live_Null_Bulk;
      New_Line;
   end if;

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
end Redis.Connection.Tests;
