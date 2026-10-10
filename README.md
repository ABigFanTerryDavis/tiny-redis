# tiny-redis 0.0.1

Redis for really small servers. One static binary (~500KB), no deps, no config files.

Written in Zig. Speaks just enough RESP2 to work with `redis-cli` and any Redis client.

## Run

```
zig build -Doptimize=ReleaseSmall
.\zig-out\bin\tiny_redis.exe --port 6399 --maxmemory 32
```

- `--port` (default `6399`, so it never fights a real Redis on 6379)
- `--maxmemory` in MB (default `32`) — `SET`s past the guard fail with `OOM`, so a tiny box never OOMs

## 0.0.1 commands

`PING` `ECHO` `SET` (with `EX`/`PX`) `GET` `DEL` `EXISTS` `EXPIRE` `TTL` `INCR` `DBSIZE` `FLUSHDB`

Plus silent stubs for `COMMAND` / `CLIENT` / `HELLO` so clients don't choke on connect.

Limits: 1MB max value, 16 args max, in-memory only (restart = empty). Persistence (AOF) lands in 0.0.2.

## Test

```
py test_001.py
```

## Notes

- Zero-dependency networking: talks to Winsock (`ws2_32`) directly, because `std.Io` TCP is still broken on Windows in Zig 0.16-dev.
- Single-process, thread-per-connection, spinlock-guarded store. Good for side projects, games, and $4 VPSs — not for real production (yet).
