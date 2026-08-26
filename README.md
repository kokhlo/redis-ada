# redis-ada

A Redis client library for Ada implementing the RESP2 protocol.

## Status

**Early development** — RESP2 codec complete with tests. Connection layer and command support coming next.

## Features

- ✅ Complete RESP2 protocol codec (encode + parse)
- ✅ All 5 frame types: Simple String, Error, Integer, Bulk String, Array
- ✅ Null values (null bulk, null array)
- ✅ Nested arrays (recursive)
- ✅ Incremental parser (handles partial input)
- ✅ 60+ test cases covering edge cases

## Build

Requires **GNAT 16.1+** and **gprbuild 26.0+** (via Alire).

```bash
# Build library
gprbuild -p -P redis_ada.gpr

# Build and run tests
gprbuild -p -P redis_ada_tests.gpr
./bin/redis-resp2-tests
```

## Usage

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

## Roadmap

- [x] RESP2 codec with test suite
- [ ] TCP connection layer (sockets)
- [ ] Core commands (GET, SET, DEL, PING, KEYS, …)
- [ ] Pipeline support
- [ ] Pub/Sub
- [ ] Connection pooling
- [ ] Alire publication

## License

MIT License — see [LICENSE](LICENSE)

Copyright © 2026 Konstantin Khlopkov
