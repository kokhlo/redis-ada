# redis-ada

A Redis client library for Ada implementing the RESP2 protocol.

## Status

**v0.2 development** — RESP2 codec complete, TCP connection layer, pub/sub and connection pool added. Command convenience wrappers coming next.

## Features

- ✅ Complete RESP2 protocol codec (encode + parse)
- ✅ All 5 frame types: Simple String, Error, Integer, Bulk String, Array
- ✅ Null values (null bulk, null array)
- ✅ Nested arrays (recursive)
- ✅ Incremental parser (handles partial input)
- ✅ TCP connection layer with blocking sockets
- ✅ Command execution API (Execute with String_Vector arguments)
- ✅ Connection error handling (DNS, refused, timeout)
- ✅ Pub/Sub: SUBSCRIBE / UNSUBSCRIBE / PUBLISH / PSUBSCRIBE with timeout-driven Listen
- ✅ Connection pool: protected object, N connections, PING health-check on Acquire
- ✅ 60 RESP2 tests + 9 connection tests + 18 pub/sub & pool tests

## Build

Requires **GNAT 16.1+** and **gprbuild 26.0+** (via Alire).

```bash
# Build library
gprbuild -p -P redis_ada.gpr

# Build and run tests
gprbuild -p -P redis_ada_tests.gpr
./bin/redis-resp2-tests
./bin/redis-connection-tests  # Runs unit tests; live tests require Redis on 127.0.0.1:6380
./bin/redis-pubsub-tests      # Runs unit tests; live tests require Redis on 127.0.0.1:6380
```

## Usage

### RESP2 Codec

```ada
with Redis.RESP2; use Redis.RESP2;

--  Encode
declare
   R : constant Reply := Simple ("OK");
   Wire : constant String := Encode (R);  -- "+OK\r\n"
begin
   --  Send Wire to Redis...
end;

--  Parse
declare
   Buffer : constant String := "+OK" & ASCII.CR & ASCII.LF;
   R : Reply;
   St : Parse_Status;
   Consumed : Natural;
begin
   Parse (Buffer, R, St, Consumed);
   if St = Success then
      --  Process R...
   end if;
end;
```

### Connection Layer

```ada
with Redis.Connection; use Redis.Connection;
with Redis.RESP2;      use Redis.RESP2;

declare
   Conn  : Redis_Connection;
   Args  : String_Vector;
   Reply : Redis.RESP2.Reply;
begin
   Connect (Conn, "localhost", 6379, Timeout => 5.0);

   --  PING
   Args.Append ("PING");
   Execute (Conn, Args, Reply);
   --  Reply is now Simple_String("PONG")

   --  SET key value
   Args.Clear;
   Args.Append ("SET");
   Args.Append ("mykey");
   Args.Append ("myvalue");
   Execute (Conn, Args, Reply);
   --  Reply is now Simple_String("OK")

   --  GET key
   Args.Clear;
   Args.Append ("GET");
   Args.Append ("mykey");
   Execute (Conn, Args, Reply);
   --  Reply is now Bulk_String("myvalue")

   Disconnect (Conn);
end;
```

### Pub/Sub

A subscriber owns a dedicated connection — once SUBSCRIBE is active,
Redis only pushes event frames over it, so it cannot run regular
commands. `Listen` never blocks longer than the timeout you give it.

```ada
with Redis.Connection;
with Redis.PubSub;  use Redis.PubSub;

declare
   Sub    : Subscriber;
   Msg    : Message;
   Got_It : Listen_Status;
   Chans  : Redis.Connection.String_Vector;
begin
   Connect (Sub, "localhost", 6379);

   Chans.Append ("news");
   Subscribe (Sub, Chans);        --  returns after server confirmation

   --  Elsewhere: someone runs PUBLISH news "hello"
   Listen (Sub, 5.0, Msg, Got_It);
   if Got_It = Got_Message
     and then Msg.Kind = Message_Event
   then
      --  Channel_Text (Msg) = "news"
      --  Payload_Text (Msg) = "hello"
      null;
   end if;

   Unsubscribe (Sub, Chans);
   Disconnect (Sub);
end;
```

Pattern subscriptions work the same way with `PSubscribe` /
`PUnsubscribe`; matching deliveries arrive as `Pattern_Message_Event`
carrying both the pattern and the concrete channel.

Publishing uses any regular command connection:

```ada
with Redis.Connection;
with Redis.PubSub;

Receivers : constant Natural :=
  Redis.PubSub.Publish (Conn, "news", "hello");
--  number of subscribers that received the message
```

### Connection Pool

The pool keeps N connections and hands them out task-safely. Every
`Acquire` verifies the connection with PING and transparently
reconnects if the server dropped it while idle.

```ada
with Redis.Connection;
with Redis.Pool;     use Redis.Pool;

declare
   Pool   : Pool_Type (Size => 4);
   Handle : Pool_Handle;
   Args   : Redis.Connection.String_Vector;
   Reply  : Redis.RESP2.Reply;
begin
   Setup (Pool, "localhost", 6379, Timeout => 5.0);

   Acquire (Pool, Handle, Wait => 10.0);
   Args.Append ("GET");
   Args.Append ("mykey");
   Redis.Connection.Execute
     (Connection_Of (Pool, Handle).all, Args, Reply);
   Release (Pool, Handle);

   Shutdown (Pool);
end;
```

## Roadmap

- [x] RESP2 codec with test suite
- [x] TCP connection layer (sockets)
- [x] Command execution API (Execute with String_Vector)
- [x] Pub/Sub (SUBSCRIBE / UNSUBSCRIBE / PUBLISH / PSUBSCRIBE)
- [x] Connection pooling with health checks
- [ ] High-level command wrappers (typed API for GET, SET, etc.)
- [ ] AUTH/SELECT support
- [ ] Pipeline support
- [ ] RESP3 support
- [ ] Alire publication

## License

MIT License — see [LICENSE](LICENSE)

Copyright © 2026 Konstantin Khlopkov
