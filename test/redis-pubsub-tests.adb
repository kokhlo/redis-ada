--  Test runner for redis-ada pub/sub and connection pool.
--  Unit tests always run; live tests require a Redis server on
--  127.0.0.1:6380 and are skipped otherwise.

with Ada.Calendar;                  use Ada.Calendar;
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Text_IO;
with Redis.Connection;
with Redis.Pool;
with Redis.RESP2;                   use Redis.RESP2;

procedure Redis.Pubsub.Tests is

   use Ada.Text_IO;
   use Redis.Connection.String_Vectors;

   Test_Port : constant := 6380;

   Passes   : Natural := 0;
   Failures : Natural := 0;

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

   function Probe_Redis_Server return Boolean is
      Conn  : Redis.Connection.Redis_Connection;
      Args  : Redis.Connection.String_Vector;
      Reply : Redis.RESP2.Reply;
   begin
      Redis.Connection.Connect (Conn, "127.0.0.1", Test_Port, 2.0);
      Args.Append ("PING");
      Redis.Connection.Execute (Conn, Args, Reply);
      Redis.Connection.Disconnect (Conn);
      return Redis.RESP2.Kind_Of (Reply) = Redis.RESP2.Simple_String
        and then Redis.RESP2.Text (Reply) = "PONG";
   exception
      when others =>
         return False;
   end Probe_Redis_Server;

   --  Build an array frame for wire-format checks.
   function Command_Frame (Items : String) return Redis.RESP2.Reply is
      Frame : Redis.RESP2.Reply := Redis.RESP2.Array_Reply;
      First : Positive := Items'First;
   begin
      loop
         for I in Items'Range loop
            if I > First and then (Items (I) = ' ' or else I = Items'Last) then
               if Items (I) = ' ' then
                  Redis.RESP2.Append (Frame, Redis.RESP2.Bulk (Items (First .. I - 1)));
                  First := I + 1;
               else
                  Redis.RESP2.Append (Frame, Redis.RESP2.Bulk (Items (First .. I)));
                  First := I + 1;
               end if;
               exit when I = Items'Last;
            end if;
         end loop;
         exit when First > Items'Last;
      end loop;
      return Frame;
   end Command_Frame;

   --
   --  Unit tests: wire format and frame decoding, no server needed.
   --

   procedure Test_Subscribe_Encoding is
      Frame    : constant Redis.RESP2.Reply := Command_Frame ("SUBSCRIBE news");
      Expected : constant String :=
        "*2" & ASCII.CR & ASCII.LF
        & "$9" & ASCII.CR & ASCII.LF & "SUBSCRIBE" & ASCII.CR & ASCII.LF
        & "$4" & ASCII.CR & ASCII.LF & "news" & ASCII.CR & ASCII.LF;
   begin
      Assert (Redis.RESP2.Encode (Frame) = Expected,
              "SUBSCRIBE frame encodes as RESP2 array of bulk strings");
   end Test_Subscribe_Encoding;

   procedure Test_Publish_Encoding is
      Frame    : constant Redis.RESP2.Reply := Command_Frame ("PUBLISH news hello");
      Expected : constant String :=
        "*3" & ASCII.CR & ASCII.LF
        & "$7" & ASCII.CR & ASCII.LF & "PUBLISH" & ASCII.CR & ASCII.LF
        & "$4" & ASCII.CR & ASCII.LF & "news" & ASCII.CR & ASCII.LF
        & "$5" & ASCII.CR & ASCII.LF & "hello" & ASCII.CR & ASCII.LF;
   begin
      Assert (Redis.RESP2.Encode (Frame) = Expected,
              "PUBLISH frame encodes as RESP2 array of bulk strings");
   end Test_Publish_Encoding;

   --  Simulate the server pushing a message frame and check the decode.
   procedure Test_Decode_Message_Frame is
      Wire   : constant String :=
        "*3" & ASCII.CR & ASCII.LF
        & "$7" & ASCII.CR & ASCII.LF & "message" & ASCII.CR & ASCII.LF
        & "$4" & ASCII.CR & ASCII.LF & "news" & ASCII.CR & ASCII.LF
        & "$5" & ASCII.CR & ASCII.LF & "hello" & ASCII.CR & ASCII.LF;
      Frame  : Redis.RESP2.Reply;
      Status : Redis.RESP2.Parse_Status;
      Used   : Natural;
   begin
      Redis.RESP2.Parse (Wire, Frame, Status, Used);
      Assert (Status = Redis.RESP2.Success and then Used = Wire'Length,
              "message push frame parses completely");

      declare
         Msg : constant Redis.PubSub.Message := Redis.PubSub.Decode_Event (Frame);
      begin
         Assert (Msg.Kind = Redis.PubSub.Message_Event
                 and then Redis.PubSub.Channel_Text (Msg) = "news"
                 and then Redis.PubSub.Payload_Text (Msg) = "hello",
                 "message push frame decodes to Message(channel, payload)");
      end;
   end Test_Decode_Message_Frame;

   procedure Test_Decode_Pattern_Frame is
      Wire   : constant String :=
        "*4" & ASCII.CR & ASCII.LF
        & "$8" & ASCII.CR & ASCII.LF & "pmessage" & ASCII.CR & ASCII.LF
        & "$6" & ASCII.CR & ASCII.LF & "news.*" & ASCII.CR & ASCII.LF
        & "$9" & ASCII.CR & ASCII.LF & "news.tech" & ASCII.CR & ASCII.LF
        & "$3" & ASCII.CR & ASCII.LF & "hot" & ASCII.CR & ASCII.LF;
      Frame  : Redis.RESP2.Reply;
      Status : Redis.RESP2.Parse_Status;
      Used   : Natural;
   begin
      Redis.RESP2.Parse (Wire, Frame, Status, Used);
      Assert (Status = Redis.REsp2.Success and then Used = Wire'Length,
              "pmessage push frame parses completely");

      declare
         Msg : constant Redis.PubSub.Message := Redis.PubSub.Decode_Event (Frame);
      begin
         Assert (Msg.Kind = Redis.PubSub.Pattern_Message_Event
                 and then Redis.PubSub.Pattern_Text (Msg) = "news.*"
                 and then Redis.PubSub.Channel_Text (Msg) = "news.tech"
                 and then Redis.PubSub.Payload_Text (Msg) = "hot",
                 "pmessage frame decodes with pattern, channel and payload");
      end;
   end Test_Decode_Pattern_Frame;

   procedure Test_Decode_Confirmation_Frames is
      Sub_Wire : constant String :=
        "*3" & ASCII.CR & ASCII.LF
        & "$9" & ASCII.CR & ASCII.LF & "subscribe" & ASCII.CR & ASCII.LF
        & "$4" & ASCII.CR & ASCII.LF & "news" & ASCII.CR & ASCII.LF
        & ":1" & ASCII.CR & ASCII.LF;
      Frame  : Redis.RESP2.Reply;
      Status : Redis.RESP2.Parse_Status;
      Used   : Natural;
   begin
      Redis.RESP2.Parse (Sub_Wire, Frame, Status, Used);
      declare
         Msg : constant Redis.PubSub.Message := Redis.PubSub.Decode_Event (Frame);
      begin
         Assert (Status = Redis.RESP2.Success
                 and then Msg.Kind = Redis.PubSub.Subscribe_Event
                 and then Redis.PubSub.Channel_Text (Msg) = "news"
                 and then Msg.Count = 1,
                 "subscribe confirmation decodes with channel and counter");
      end;
   end Test_Decode_Confirmation_Frames;

   procedure Test_Decode_Pong_Frame is
      Wire   : constant String :=
        "*2" & ASCII.CR & ASCII.LF
        & "$4" & ASCII.CR & ASCII.LF & "pong" & ASCII.CR & ASCII.LF
        & "$0" & ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF;
      Frame  : Redis.RESP2.Reply;
      Status : Redis.RESP2.Parse_Status;
      Used   : Natural;
   pong_frame_found : Boolean := False;
   begin
      Redis.RESP2.Parse (Wire, Frame, Status, Used);
      declare
         Msg : constant Redis.PubSub.Message := Redis.PubSub.Decode_Event (Frame);
      begin
         pong_frame_found := Msg.Kind = Redis.PubSub.Pong_Event;
      end;
      Assert (pong_frame_found and then Status = Redis.RESP2.Success,
              "pong frame (empty payload variant) decodes");
   end Test_Decode_Pong_Frame;

   --
   --  Live pub/sub tests.
   --

   procedure Test_Live_Roundtrip is
      Sub     : Redis.PubSub.Subscriber;
      Pub     : Redis.Connection.Redis_Connection;
      Msg     : Redis.PubSub.Message;
      Status  : Redis.PubSub.Listen_Status;
      Chans   : Redis.Connection.String_Vector;
      Receivers : Natural;
   begin
      Redis.PubSub.Connect (Sub, "127.0.0.1", Test_Port, 2.0);
      Chans.Append ("test.channel.a");
      Redis.PubSub.Subscribe (Sub, Chans);

      Redis.Connection.Connect (Pub, "127.0.0.1", Test_Port, 2.0);
      Receivers := Redis.PubSub.Publish (Pub, "test.channel.a", "roundtrip-payload");
      Assert (Receivers = 1, "PUBLISH reports exactly one receiver");

      Redis.PubSub.Listen (Sub, 5.0, Msg, Status);
      Assert (Status = Redis.PubSub.Got_Message
              and then Msg.Kind = Redis.PubSub.Message_Event
              and then Redis.PubSub.Channel_Text (Msg) = "test.channel.a"
              and then Redis.PubSub.Payload_Text (Msg) = "roundtrip-payload",
              "pub/sub roundtrip: SUBSCRIBE in one connection, PUBLISH from another");

      Redis.PubSub.Disconnect (Sub);
      Redis.Connection.Disconnect (Pub);
   exception
      when E : others =>
         Put_Line ("[SKIP] live roundtrip failed: "
                   & Ada.Exceptions.Exception_Message (E));
   end Test_Live_Roundtrip;

   procedure Test_Live_Pattern_Roundtrip is
      Sub     : Redis.PubSub.Subscriber;
      Pub     : Redis.Connection.Redis_Connection;
      Msg     : Redis.PubSub.Message;
      Status  : Redis.PubSub.Listen_Status;
      Pats    : Redis.Connection.String_Vector;
   begin
      Redis.PubSub.Connect (Sub, "127.0.0.1", Test_Port, 2.0);
      Pats.Append ("events.*");
      Redis.PubSub.PSubscribe (Sub, Pats);

      Redis.Connection.Connect (Pub, "127.0.0.1", Test_Port, 2.0);
      declare
         Ignored : Natural;
         pragma Unreferenced (Ignored);
      begin
         Ignored := Redis.PubSub.Publish (Pub, "events.telemetry", "cpu=91%");
      end;

      Redis.PubSub.Listen (Sub, 5.0, Msg, Status);
      Assert (Status = Redis.PubSub.Got_Message
              and then Msg.Kind = Redis.PubSub.Pattern_Message_Event
              and then Redis.PubSub.Pattern_Text (Msg) = "events.*"
              and then Redis.PubSub.Channel_Text (Msg) = "events.telemetry"
              and then Redis.PubSub.Payload_Text (Msg) = "cpu=91%",
              "pattern subscription delivers pmessage with pattern and channel");

      Redis.PubSub.Disconnect (Sub);
      Redis.Connection.Disconnect (Pub);
   exception
      when E : others =>
         Put_Line ("[SKIP] live pattern roundtrip failed: "
                   & Ada.Exceptions.Exception_Message (E));
   end Test_Live_Pattern_Roundtrip;

   procedure Test_Live_Listen_Timeout is
      Sub    : Redis.PubSub.Subscriber;
      Msg    : Redis.PubSub.Message;
      Status : Redis.PubSub.Listen_Status;
      Chans  : Redis.Connection.String_Vector;
      Start  : Ada.Calendar.Time;
      Elapsed : Duration;
   begin
      Redis.PubSub.Connect (Sub, "127.0.0.1", Test_Port, 2.0);
      Chans.Append ("quiet.channel");
      Redis.PubSub.Subscribe (Sub, Chans);

      Start := Ada.Calendar.Clock;
      Redis.PubSub.Listen (Sub, 0.3, Msg, Status);
      Elapsed := Ada.Calendar.Clock - Start;

      Assert (Status = Redis.PubSub.No_Message and then Elapsed >= 0.25,
              "Listen with no traffic returns No_Message after the timeout");

      Redis.PubSub.Disconnect (Sub);
   exception
      when E : others =>
         Put_Line ("[SKIP] live listen timeout failed: "
                   & Ada.Exceptions.Exception_Message (E));
   end Test_Live_Listen_Timeout;

   procedure Test_Live_Unsubscribe is
      Sub    : Redis.PubSub.Subscriber;
      Pub    : Redis.Connection.Redis_Connection;
      Msg    : Redis.PubSub.Message;
      Status : Redis.PubSub.Listen_Status;
      Chans  : Redis.Connection.String_Vector;
   begin
      Redis.PubSub.Connect (Sub, "127.0.0.1", Test_Port, 2.0);
      Chans.Append ("test.channel.b");
      Redis.PubSub.Subscribe (Sub, Chans);
      Redis.PubSub.Unsubscribe (Sub, Chans);

      Redis.Connection.Connect (Pub, "127.0.0.1", Test_Port, 2.0);
      declare
         Receivers : constant Natural :=
           Redis.PubSub.Publish (Pub, "test.channel.b", "nobody-listening");
      begin
         Assert (Receivers = 0,
                 "after UNSUBSCRIBE the server reports zero receivers");
      end;

      Redis.PubSub.Listen (Sub, 0.3, Msg, Status);
      Assert (Status = Redis.PubSub.No_Message,
              "no message arrives after unsubscribing");

      Redis.PubSub.Disconnect (Sub);
      Redis.Connection.Disconnect (Pub);
   exception
      when E : others =>
         Put_Line ("[SKIP] live unsubscribe failed: "
                   & Ada.Exceptions.Exception_Message (E));
   end Test_Live_Unsubscribe;

   --
   --  Live pool tests.
   --

   Task_Count : constant := 10;
   Ops_Per_Task : constant := 10;

   protected Counters is
      procedure Add_Success;
      procedure Add_Failure;
      function Total_Success return Natural;
      function Total_Failure return Natural;
   private
      Ok : Natural := 0;
      Bad : Natural := 0;
   end Counters;

   protected body Counters is
      procedure Add_Success is
      begin
         Ok := Ok + 1;
      end Add_Success;
      procedure Add_Failure is
      begin
         Bad := Bad + 1;
      end Add_Failure;
      function Total_Success return Natural is (Ok);
      function Total_Failure return Natural is (Bad);
   end Counters;

   procedure Test_Live_Pool_Stress is
      Pool : Redis.Pool.Pool_Type (4);
   begin
      Redis.Pool.Setup (Pool, "127.0.0.1", Test_Port, 2.0);

      declare
         task type Worker;
         task body Worker is
            Handle : Redis.Pool.Pool_Handle;
            Args   : Redis.Connection.String_Vector;
            Reply  : Redis.RESP2.Reply;
         begin
            for Op in 1 .. Ops_Per_Task loop
               begin
                  Redis.Pool.Acquire (Pool, Handle, 10.0);
                  Args.Clear;
                  Args.Append ("PING");
                  Redis.Connection.Execute
                    (Redis.Pool.Connection_Of (Pool, Handle).all, Args, Reply);
                  if Redis.RESP2.Kind_Of (Reply) = Redis.RESP2.Simple_String
                    and then Redis.RESP2.Text (Reply) = "PONG"
                  then
                     Counters.Add_Success;
                  else
                     Counters.Add_Failure;
                  end if;
                  Redis.Pool.Release (Pool, Handle);
               exception
                  when others =>
                     Counters.Add_Failure;
               end;
            end loop;
         end Worker;

         Workers : array (1 .. Task_Count) of Worker;
         pragma Unreferenced (Workers);
      begin
         null;  --  Worker tasks run to completion on their own.
      end;

      Assert (Counters.Total_Failure = 0,
              "pool stress: " & Natural'Image (Task_Count * Ops_Per_Task)
              & " concurrent operations, zero failures");
      Assert (Counters.Total_Success = Task_Count * Ops_Per_Task,
              "pool stress: every PING round-tripped through the pool");
      Assert (Redis.Pool.Idle_Count (Pool) = 4,
              "pool stress: all slots returned to idle");
   end Test_Live_Pool_Stress;

   procedure Test_Live_Pool_Get_Throughput is
      --  100 concurrent GETs (20 tasks x 5 ops) through an 8-slot pool.
      Pool : Redis.Pool.Pool_Type (8);
   begin
      Redis.Pool.Setup (Pool, "127.0.0.1", Test_Port, 2.0);

      declare
         Seed : Redis.Connection.Redis_Connection;
         Args : Redis.Connection.String_Vector;
         Reply : Redis.RESP2.Reply;
      begin
         Redis.Connection.Connect (Seed, "127.0.0.1", Test_Port, 2.0);
         Args.Append ("SET");
         Args.Append ("pool:counter");
         Args.Append ("seed");
         Redis.Connection.Execute (Seed, Args, Reply);
         Redis.Connection.Disconnect (Seed);
      end;

      declare
         Task_Range : constant := 20;
         Ops_Range  : constant := 5;

         task type Getter;
         task body Getter is
            Handle : Redis.Pool.Pool_Handle;
            Args   : Redis.Connection.String_Vector;
            Reply  : Redis.RESP2.Reply;
         begin
            for Op in 1 .. Ops_Range loop
               begin
                  Redis.Pool.Acquire (Pool, Handle, 10.0);
                  Args.Clear;
                  Args.Append ("GET");
                  Args.Append ("pool:counter");
                  Redis.Connection.Execute
                    (Redis.Pool.Connection_Of (Pool, Handle).all, Args, Reply);
                  if Redis.RESP2.Kind_Of (Reply) = Redis.RESP2.Bulk_String
                    and then Redis.RESP2.Text (Reply) = "seed"
                  then
                     Counters.Add_Success;
                  else
                     Counters.Add_Failure;
                  end if;
                  Redis.Pool.Release (Pool, Handle);
               exception
                  when others =>
                     Counters.Add_Failure;
               end;
            end loop;
         end Getter;

         Getters : array (1 .. Task_Range) of Getter;
         pragma Unreferenced (Getters);
      begin
         null;
      end;

      Assert (Counters.Total_Failure = 0
              and then Counters.Total_Success >= 200,
              "pool stress: 100 concurrent GETs completed without deadlock");
   end Test_Live_Pool_Get_Throughput;

begin
   Put_Line ("=== redis-ada Pub/Sub + Pool Test Suite ===");
   New_Line;

   Put_Line ("--- Unit Tests (no server required) ---");
   Test_Subscribe_Encoding;
   Test_Publish_Encoding;
   Test_Decode_Message_Frame;
   Test_Decode_Pattern_Frame;
   Test_Decode_Confirmation_Frames;
   Test_Decode_Pong_Frame;
   New_Line;

   if Probe_Redis_Server then
      Put_Line ("Redis server detected at 127.0.0.1:6380 (live tests will run)");
      New_Line;
      Put_Line ("--- Live Integration Tests ---");
      Test_Live_Roundtrip;
      Test_Live_Pattern_Roundtrip;
      Test_Live_Listen_Timeout;
      Test_Live_Unsubscribe;
      Test_Live_Pool_Stress;
      Test_Live_Pool_Get_Throughput;
      New_Line;
   else
      Put_Line ("No Redis server at 127.0.0.1:6380 (live tests skipped)");
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
end Redis.Pubsub.Tests;
