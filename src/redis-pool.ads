--  Connection pool: a fixed set of Redis connections shared between
--  tasks. A protected controller hands out slots; liveness is verified
--  with PING on Acquire (outside the pool lock), with one reconnect
--  attempt before giving up.

with Ada.Strings.Unbounded;
with Redis.Connection;

package Redis.Pool is

   Connection_Failed : exception renames Redis.Connection.Connection_Failed;
   Protocol_Error    : exception renames Redis.Connection.Protocol_Error;
   Timeout_Error     : exception;

   --  Identifies the pooled connection between Acquire and Release.
   --  0 means "no handle".
   type Pool_Handle is new Natural;

   No_Handle : constant Pool_Handle := 0;

   --  Runs commands on the acquired connection.
   type Connection_Access is access all Redis.Connection.Redis_Connection;

   type Pool_Type (Size : Positive) is limited private;

   --  Connect every slot to Host:Port. Raises Connection_Failed when
   --  the server cannot be reached at all.
   procedure Setup
     (Pool    : in out Pool_Type;
      Host    : String;
      Port    : Positive := 6379;
      Timeout : Duration := 5.0);

   --  Reserve a connection, waiting at most Wait for a free slot.
   --  The connection is verified with PING first and reconnected once
   --  if the check fails. Raises Timeout_Error when no slot becomes
   --  free in time, Connection_Failed when the server is unreachable.
   procedure Acquire
     (Pool   : in out Pool_Type;
      Handle : out Pool_Handle;
      Wait   : Duration := 10.0);

   --  Return a connection to the pool. Releasing No_Handle or an
   --  already released handle is a no-op.
   procedure Release
     (Pool   : in out Pool_Type;
      Handle : in out Pool_Handle);

   --  Access the connection behind a checked-out handle. The handle
   --  must come from Acquire and not be released yet; returns null
   --  for No_Handle.
   function Connection_Of
     (Pool   : in out Pool_Type;
      Handle : Pool_Handle) return Connection_Access;

   function Checked_Out (Pool : in out Pool_Type) return Natural;
   function Idle_Count (Pool : in out Pool_Type) return Natural;

   --  Disconnect and free every slot.
   procedure Shutdown (Pool : in out Pool_Type);

private

   --  Connections are allocated once at Setup and freed at Shutdown,
   --  so slots can hand out stable access values.
   type Connection_Ref is access all Redis.Connection.Redis_Connection;

   type Slot_State is (Busy_Slot, Ready_Slot);

   type Connection_Slot is record
      Conn  : Connection_Ref;
      State : Slot_State := Ready_Slot;
   end record;

   type Slot_Array is array (Positive range <>) of Connection_Slot;

   --  Serializes slot bookkeeping only; socket I/O always happens on
   --  the caller's task while the slot is checked out.
   protected type Controller (Capacity : Positive) is

      --  Reserve any free slot; blocks while all are checked out.
      entry Take (Handle : out Pool_Handle);

      --  Return a slot to the free set.
      procedure Give_Back (Handle : Pool_Handle);

      --  Drop the slot's connection; it is reconnected on next use.
      procedure Mark_Broken (Handle : Pool_Handle);

      function Connection_Of (Handle : Pool_Handle) return Connection_Access;

      --  Connect all slots; Opened reports how many succeeded.
      procedure Open_All
        (Host    : String;
         Port    : Positive;
         Timeout : Duration;
         Opened  : out Natural);

      --  Disconnect and deallocate all slot connections.
      procedure Close_All;

      function Checked_Out return Natural;
      function Idle_Count return Natural;

   private
      Busy  : Natural := 0;
      Slots : Slot_Array (1 .. Capacity);
   end Controller;

   type Pool_Type (Size : Positive) is limited record
      Ctrl    : Controller (Size);
      Host    : Ada.Strings.Unbounded.Unbounded_String;
      Port    : Positive := 6379;
      Timeout : Duration := 5.0;
   end record;

end Redis.Pool;
