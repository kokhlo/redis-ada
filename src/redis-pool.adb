--  Pool implementation: slot bookkeeping lives in the protected
--  controller, health checks and reconnects run on the caller's task
--  while the slot is exclusively owned.

with Ada.Unchecked_Deallocation;
with Redis.RESP2;                 use Redis.RESP2;

package body Redis.Pool is

   use Ada.Strings.Unbounded;
   use Redis.Connection.String_Vectors;

   procedure Free_Connection is new Ada.Unchecked_Deallocation
     (Object => Redis.Connection.Redis_Connection,
      Name   => Connection_Ref);

   --  True when the connection answers PING.
   function Is_Alive (Conn : in out Redis.Connection.Redis_Connection)
                      return Boolean
   is
      Args  : Redis.Connection.String_Vector;
      Reply : Redis.RESP2.Reply;
   begin
      Args.Append ("PING");
      Redis.Connection.Execute (Conn, Args, Reply);
      return Redis.RESP2.Kind_Of (Reply) = Redis.RESP2.Simple_String
        and then Redis.RESP2.Text (Reply) = "PONG";
   exception
      when others =>
         return False;
   end Is_Alive;

   protected body Controller is

      entry Take (Handle : out Pool_Handle) when Busy < Capacity is
      begin
         for I in Slots'Range loop
            if Slots (I).State = Ready_Slot then
               Slots (I).State := Busy_Slot;
               Busy := Busy + 1;
               Handle := Pool_Handle (I);
               return;
            end if;
         end loop;

         --  Unreachable: the barrier guarantees a free slot.
         Handle := No_Handle;
      end Take;

      procedure Give_Back (Handle : Pool_Handle) is
      begin
         if Handle /= No_Handle
           and then Positive (Handle) in Slots'Range
           and then Slots (Positive (Handle)).State = Busy_Slot
         then
            Slots (Positive (Handle)).State := Ready_Slot;
            Busy := Busy - 1;
         end if;
      end Give_Back;

      procedure Mark_Broken (Handle : Pool_Handle) is
      begin
         if Handle /= No_Handle
           and then Positive (Handle) in Slots'Range
         then
            Redis.Connection.Disconnect (Slots (Positive (Handle)).Conn.all);
         end if;
      end Mark_Broken;

      function Connection_Of (Handle : Pool_Handle) return Connection_Access is
      begin
         if Handle /= No_Handle
           and then Positive (Handle) in Slots'Range
         then
            return Connection_Access (Slots (Positive (Handle)).Conn);
         end if;
         return null;
      end Connection_Of;

      procedure Open_All
        (Host    : String;
         Port    : Positive;
         Timeout : Duration;
         Opened  : out Natural)
      is
      begin
         Opened := 0;
         for I in Slots'Range loop
            if Slots (I).Conn = null then
               Slots (I).Conn := new Redis.Connection.Redis_Connection;
            end if;

            begin
               Redis.Connection.Connect (Slots (I).Conn.all, Host, Port, Timeout);
               Opened := Opened + 1;
            exception
               when Redis.Connection.Connection_Failed =>
                  exit;
            end;
         end loop;
      end Open_All;

      procedure Close_All is
      begin
         for I in Slots'Range loop
            if Slots (I).Conn /= null then
               Redis.Connection.Disconnect (Slots (I).Conn.all);
               Free_Connection (Slots (I).Conn);
            end if;
            Slots (I).State := Ready_Slot;
         end loop;
         Busy := 0;
      end Close_All;

      function Checked_Out return Natural is (Busy);

      function Idle_Count return Natural is (Capacity - Busy);

   end Controller;

   procedure Setup
     (Pool    : in out Pool_Type;
      Host    : String;
      Port    : Positive := 6379;
      Timeout : Duration := 5.0)
   is
      Opened : Natural;
   begin
      Pool.Host    := To_Unbounded_String (Host);
      Pool.Port    := Port;
      Pool.Timeout := Timeout;

      Pool.Ctrl.Open_All (Host, Port, Timeout, Opened);

      if Opened = 0 then
         raise Connection_Failed
           with "pool setup: server unreachable at " & Host;
      end if;
   end Setup;

   procedure Acquire
     (Pool   : in out Pool_Type;
      Handle : out Pool_Handle;
      Wait   : Duration := 10.0)
   is
   begin
      Handle := No_Handle;

      select
         Pool.Ctrl.Take (Handle);
      or
         delay Wait;
         raise Timeout_Error with "no free connection within the wait period";
      end select;

      --  Health-check the connection; a slot can sit idle long enough
      --  for the server to drop it, so reconnect once before failing.
      declare
         Conn : constant Connection_Access := Pool.Ctrl.Connection_Of (Handle);
      begin
         if Conn = null then
            raise Constraint_Error with "invalid pool handle";
         end if;

         if not Is_Alive (Conn.all) then
            Pool.Ctrl.Mark_Broken (Handle);
            Redis.Connection.Connect
              (Conn.all, To_String (Pool.Host), Pool.Port, Pool.Timeout);

            if not Is_Alive (Conn.all) then
               Pool.Ctrl.Give_Back (Handle);
               Handle := No_Handle;
               raise Connection_Failed
                 with "pooled connection failed PING after reconnect";
            end if;
         end if;
      exception
         when Redis.Connection.Connection_Failed =>
            Pool.Ctrl.Give_Back (Handle);
            Handle := No_Handle;
            raise;
      end;
   end Acquire;

   procedure Release
     (Pool   : in out Pool_Type;
      Handle : in out Pool_Handle)
   is
   begin
      if Handle /= No_Handle then
         Pool.Ctrl.Give_Back (Handle);
         Handle := No_Handle;
      end if;
   end Release;

   function Connection_Of
     (Pool   : in out Pool_Type;
      Handle : Pool_Handle) return Connection_Access
   is (Pool.Ctrl.Connection_Of (Handle));

   function Checked_Out (Pool : in out Pool_Type) return Natural
     is (Pool.Ctrl.Checked_Out);

   function Idle_Count (Pool : in out Pool_Type) return Natural
     is (Pool.Ctrl.Idle_Count);

   procedure Shutdown (Pool : in out Pool_Type) is
   begin
      Pool.Ctrl.Close_All;
   end Shutdown;

end Redis.Pool;
