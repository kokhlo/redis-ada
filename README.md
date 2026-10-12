# redis-ada

[![CI](https://github.com/kokhlo/redis-ada/actions/workflows/build-test.yml/badge.svg)](https://github.com/kokhlo/redis-ada/actions/workflows/build-test.yml)
[![Alire](https://img.shields.io/badge/redis-0.3.0-blue)](https://github.com/kokhlo/redis-ada/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Redis client library for Ada implementing the RESP2 protocol.

## Status

**v0.3 development** — RESP2 codec hardened, TCP connection layer added. Command convenience wrappers and pooling coming next.

## Features

- Complete RESP2 protocol codec (encode + parse)
- All 5 frame types: Simple String, Error, Integer, Bulk String, Array
- Null values (null bulk, null array)
- Nested arrays (recursive, bounded at depth 128)
- Incremental parser (handles partial input, pipelining-safe `Consumed`)
- Strict wire syntax: only plain decimal integers accepted; bulk/array
  lengths beyond protocol limits are rejected as `Protocol_Error`
- Automatic memory management: `Reply` is controlled — copies are deep,
  finalization reclaims nested frames (no leaks, no dangling elements)
- TCP connection layer with blocking sockets and send/receive timeouts
- Command execution API (Execute with String_Vector arguments)
- Connection error handling (DNS, refused, timeout); dead connection
  detection after protocol errors and server disconnects
- 115 codec assertions + 10 connection assertions (6 unit + 4 live)

## Installation

With [Alire](https://alire.ada.dev/):

```bash
alr with redis
```

The crate is published in the Alire index as `redis`. It builds with any
GNAT community release from 13.2 onward (13.2 / 14.2 / 16.1 are covered by
CI, on both Linux and macOS).

## Build

```bash
# Build library (any recent GNAT + gprbuild; Alire toolchains work)
gprbuild -p -P redis_ada.gpr

# Build and run tests
gprbuild -p -P redis_ada_tests.gpr
./bin/redis-resp2-tests
./bin/redis-connection-tests  # Unit part always runs; live tests need Redis on 127.0.0.1:6380
```

For the live integration tests:

```bash
docker run -d -p 6380:6379 redis:7
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
   null;
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
      --  Process R...  (bytes after Consumed belong to the next frame)
      null;
   end if;
end;
```

`Reply` is a controlled type: assignment copies, `Element` results, and
scope exits are all safe — nested array memory is reclaimed automatically,
and elements handed out are independent copies of the source frame.

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

After a `Protocol_Error` from `Execute` the connection is marked dead:
reattempting `Execute` raises `Connection_Failed` until you `Connect`
again. `Execute` also rejects an empty command vector before writing
anything to the socket.

## Roadmap

- [x] RESP2 codec with test suite
- [x] TCP connection layer (sockets)
- [x] Command execution API (Execute with String_Vector)
- [x] Published in the Alire index as `redis`
- [ ] High-level command wrappers (typed API for GET, SET, etc.)
- [ ] AUTH/SELECT support
- [ ] Pipeline support
- [ ] Pub/Sub
- [ ] Connection pooling
- [ ] RESP3 support

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — build/test commands, code style,
PR conventions.

## License

MIT License — see [LICENSE](LICENSE)

Copyright © 2026 Konstantin Khlopkov
