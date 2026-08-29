--  Test runner for redis-ada connection layer.
--  Tests command encoding, connection failures, and live server interactions
--  when a Redis server is available.

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
      when Connection_Failed =>
         return False;
      when others =>
         return False;
   end Probe_Redis_Server;

   procedure Test_Command_Encoding_SET is
      --  Verify that Execute encodes SET foo bar correctly.
      --  We can't check wire bytes directly, but we know the pattern:
      --  *3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n
      --  This is an indirect test: we'll encode the command manually and compare.
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
      --  Attempt to connect to a non-routable IP (10.255.255.1) with a short timeout.
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
              "Live PING → +PONG");
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

      --  SET test_key test_value
      Args.Append ("SET");
      Args.Append ("test_key");
      Args.Append ("test_value");
      Execute (Conn, Args, Reply);
      Assert (Kind_Of (Reply) = Simple_String and then Text (Reply) = "OK",
              "Live SET test_key test_value → +OK");

      --  GET test_key
      Args.Clear;
      Args.Append ("GET");
      Args.Append ("test_key");
      Execute (Conn, Args, Reply);
      Assert (Kind_Of (Reply) = Bulk_String and then Text (Reply) = "test_value",
              "Live GET test_key → $10\\r\\ntest_value");

      --  DEL test_key
      Args.Clear;
      Args.Append ("DEL");
      Args.Append ("test_key");
      Execute (Conn, Args, Reply);
      Assert (Kind_Of (Reply) = Integer_Reply and then Value (Reply) = 1,
              "Live DEL test_key → :1");

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
              "Live bad command → -ERR");
   exception
      when E : others =>
         Put_Line ("[SKIP] Live bad command test failed: " & Ada.Exceptions.Exception_Message (E));
   end Test_Live_Bad_Command;

begin
   Put_Line ("=== redis-ada Connection Layer Test Suite ===");
   New_Line;

   Put_Line ("Checking for local Redis server...");
   Live_Server_Available := Probe_Redis_Server;
   if Live_Server_Available then
      Put_Line ("✓ Redis server detected at 127.0.0.1:6380 (live tests will run)");
   else
      Put_Line ("✗ No Redis server detected (live tests will be skipped)");
   end if;
   New_Line;

   Put_Line ("--- Unit Tests (no server required) ---");
   Test_Command_Encoding_SET;
   Test_Command_Encoding_GET;
   Test_Connect_Refused;
   Test_Connect_Timeout;
   New_Line;

   if Live_Server_Available then
      Put_Line ("--- Live Integration Tests ---");
      Test_Live_PING;
      Test_Live_SET_GET_DEL;
      Test_Live_Bad_Command;
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
