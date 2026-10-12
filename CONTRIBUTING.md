# Contributing

Thanks for considering a contribution to redis-ada.

## Getting started

You need an Ada toolchain. The easiest path is [Alire](https://alire.ada.dev/):

```bash
alr toolchain --select --disable-assistant gnat_native=14.2.1 gprbuild=25.0.1
```

Build and test:

```bash
alr build                    # library
gprbuild -p -P redis_ada_tests.gpr
./bin/redis-resp2-tests      # codec suite, no server needed
./bin/redis-connection-tests # unit part; live tests need Redis on 127.0.0.1:6380
```

For the live integration tests:

```bash
docker run -d -p 6380:6379 redis:7
```

## What CI runs

Every push and PR builds on Linux and macOS across GNAT 13.2 / 14.2 / 16.1,
runs both test suites, and on Linux additionally runs the connection suite
against a real Redis 7 container. The `alire-check` job builds a dependent
crate pinned to your checkout — keep `alire.toml` and `redis_ada.gpr`
consumable. A PR is not done until CI is green.

## Code style

- GNAT default style, 3-space indent, `Title_Case` identifiers. If you use
  GNAT Studio, this is out of the box.
- Every public subprogram gets a comment explaining its contract, not its
  mechanics.
- The build uses `-gnatwa -gnatwe` (all warnings, warnings as errors). New
  code must compile warning-free.
- No tabs, no trailing whitespace, ASCII only.

## Commit messages

Conventional one-liners: `fix:`, `feat:`, `docs:`, `chore:`, `test:` in
imperative mood, no ticket IDs — e.g. `fix: reject bulk lengths below -1`.

## Pull requests

- Small and focused: one logical change per PR, with a test that fails
  without the code change.
- New protocol behavior needs a test in `test/redis-resp2-tests.adb` or
  `test/redis-connection-tests.adb` first (RED), then the fix (GREEN).
- Regenerate nothing: `obj/`, `bin/`, `lib/` are build artifacts and are
  never committed.

## Releasing (maintainers)

- Bump `version` in `alire.toml` and the version badge in `README.md`
  in the same commit. Fixes bump the patch, features bump the minor.
- Tag `vX.Y.Z`; the release workflow enforces the version match, builds,
  runs the tests, and attaches a source archive + SHA-512 to the GitHub
  Release.
- Publishing to alire-index is a separate PR there (pin by commit SHA,
  not by tarball hash).
