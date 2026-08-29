# redis-ada

A Redis client library for Ada implementing the RESP2 protocol.

## Status

**v0.2 development** — RESP2 codec complete, TCP connection layer added. Command convenience wrappers and pooling coming next.

## Features

- ✅ Complete RESP2 protocol codec (encode + parse)
- ✅ All 5 frame types: Simple String, Error, Integer, Bulk String, Array
- ✅ Null values (null bulk, null array)
- ✅ Nested arrays (recursive)
- ✅ Incremental parser (handles partial input)
- ✅ TCP connection layer with blocking sockets
- ✅ Command execution API (Execute with String_Vector arguments)
- ✅ Connection error handling (DNS, refused, timeout)
- ✅ 60+ RESP2 tests + 9 connection tests (4 unit + 5 live)

## Build

Requires **GNAT 16.1+** and **gprbuild 26.0+** (via Alire).

```bash
# Build library
gprbuild -p -P redis_ada.gpr

# Build and run tests
gprbuild -p -P redis_ada_tests.gpr
./bin/redis-resp2-tests
./bin/redis-connection-tests  # Runs unit tests; live tests require Redis on 127.0.0.1:6380
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

## Roadmap

- [x] RESP2 codec with test suite
- [x] TCP connection layer (sockets)
- [x] Command execution API (Execute with String_Vector)
- [ ] High-level command wrappers (typed API for GET, SET, etc.)
- [ ] AUTH/SELECT support
- [ ] Pipeline support
- [ ] Pub/Sub
- [ ] Connection pooling
- [ ] RESP3 support
- [ ] Alire publication

## License

MIT License — see [LICENSE](LICENSE)

Copyright © 2026 Konstantin Khlopkov
