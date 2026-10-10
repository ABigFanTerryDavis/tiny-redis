const std = @import("std");

// ---- raw Winsock bindings (std.Io networking is broken on Windows in Zig 0.16-dev,
// so 0.0.1 talks to ws2_32 directly — fitting for a "tiny" server anyway) ----
const SOCKET: type = usize;
const INVALID_SOCKET: SOCKET = std.math.maxInt(SOCKET);
const SOCKET_ERROR: c_int = -1;
const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const IPPROTO_TCP: c_int = 6;
const SOL_SOCKET: c_int = 0xffff;
const SO_REUSEADDR: c_int = 0x0004;

const WSADATA = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?*u8,
};

const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16, // network byte order
    sin_addr: u32, // network byte order
    sin_zero: [8]u8 = .{0} ** 8,
};

extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) callconv(.winapi) c_int;
extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
extern "ws2_32" fn socket(af: c_int, @"type": c_int, protocol: c_int) callconv(.winapi) SOCKET;
extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr_in, namelen: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn accept(s: SOCKET, addr: ?*sockaddr_in, addrlen: ?*c_int) callconv(.winapi) SOCKET;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, optname: c_int, optval: *const c_int, optlen: c_int) callconv(.winapi) c_int;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn htons(port: u16) u16 {
    return (port << 8) | (port >> 8);
}
// 127.0.0.1 as u32 in network byte order
const LOOPBACK_ADDR: u32 = 0x0100007F;

const VERSION = "0.0.1";
const DEFAULT_PORT: u16 = 6399; // avoid clashing with real redis 6379
const MAXMEMORY_DEFAULT: usize = 32 * 1024 * 1024; // 32MB — "really small" guard
const MAX_BULK: usize = 1024 * 1024; // 1MB max single value for 0.0.1

const Entry = struct {
    value: []u8, // owned
    expires_at_ms: ?i64,
};

const gpa = std.heap.smp_allocator;

var store: std.StringHashMap(Entry) = undefined;
var lock_state: std.atomic.Value(u32) = .init(0);
var total_bytes: usize = 0;
var maxmemory: usize = MAXMEMORY_DEFAULT;

fn lock() void {
    while (lock_state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    lock_state.store(0, .release);
}

fn nowMs() i64 {
    return @intCast(GetTickCount64());
}

fn isExpiredAt(expires_at_ms: ?i64, now: i64) bool {
    if (expires_at_ms) |e| return now >= e;
    return false;
}

// Delete key if expired. Caller must hold lock. Returns true if deleted.
fn purgeIfExpired(key: []const u8, now: i64) bool {
    const e = store.get(key) orelse return false;
    if (!isExpiredAt(e.expires_at_ms, now)) return false;
    if (store.fetchRemove(key)) |kv| {
        total_bytes -= (kv.key.len + kv.value.value.len + 64);
        gpa.free(kv.key);
        gpa.free(kv.value.value);
        return true;
    }
    return false;
}

fn freeEntryKeyValue(key: []const u8, entry: Entry) void {
    total_bytes -= (key.len + entry.value.len + 64);
    gpa.free(key);
    gpa.free(entry.value);
}

// ---- RESP parsing ----

const ParseResult = struct {
    argc: usize,
    args: [16][]const u8, // slices into buf
    consumed: usize,
};

// Try to parse one command from buf[0..len].
// Returns null if need more data. Errors on malformed.
fn tryParseCommand(buf: []const u8) !?ParseResult {
    if (buf.len == 0) return null;
    if (buf[0] == '*') {
        // RESP array of bulk strings
        const line_end = std.mem.indexOf(u8, buf, "\r\n") orelse return null;
        const n = std.fmt.parseInt(usize, buf[1..line_end], 10) catch return error.Malformed;
        if (n == 0 or n > 16) return error.Malformed;
        var off: usize = line_end + 2;
        var res = ParseResult{ .argc = n, .args = undefined, .consumed = 0 };
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (off >= buf.len) return null;
            if (buf[off] != '$') return error.Malformed;
            const lend = std.mem.indexOf(u8, buf[off..], "\r\n") orelse return null;
            const blen = std.fmt.parseInt(usize, buf[off + 1 .. off + lend], 10) catch return error.Malformed;
            if (blen > MAX_BULK) return error.TooBig;
            off += lend + 2;
            if (off >= buf.len) return null;
            if (buf.len < off + blen + 2) return null; // need more
            res.args[i] = buf[off .. off + blen];
            off += blen;
            if (buf[off] != '\r' or buf[off + 1] != '\n') return error.Malformed;
            off += 2;
        }
        res.consumed = off;
        return res;
    } else {
        // inline: split by spaces, ends at \n
        const nl = std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
        var line = buf[0..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        var res = ParseResult{ .argc = 0, .args = undefined, .consumed = nl + 1 };
        var it = std.mem.splitScalar(u8, line, ' ');
        while (it.next()) |tok| {
            if (tok.len == 0) continue;
            if (res.argc >= 16) return error.Malformed;
            res.args[res.argc] = tok;
            res.argc += 1;
        }
        if (res.argc == 0) {
            // empty line — consume, no command
            return ParseResult{ .argc = 0, .args = undefined, .consumed = nl + 1 };
        }
        return res;
    }
}

fn upperByte(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn cmdIs(arg: []const u8, name: []const u8) bool {
    if (arg.len != name.len) return false;
    for (arg, 0..) |c, i| {
        if (upperByte(c) != name[i]) return false;
    }
    return true;
}

// ---- response helpers (write into out buf, return len) ----

fn respSimple(out: []u8, s: []const u8) usize {
    const r = std.fmt.bufPrint(out, "+{s}\r\n", .{s}) catch return 0;
    return r.len;
}

fn respErr(out: []u8, s: []const u8) usize {
    const r = std.fmt.bufPrint(out, "-{s}\r\n", .{s}) catch return 0;
    return r.len;
}

fn respInt(out: []u8, v: i64) usize {
    const r = std.fmt.bufPrint(out, ":{d}\r\n", .{v}) catch return 0;
    return r.len;
}

fn respNull(out: []u8) usize {
    @memcpy(out[0..5], "$-1\r\n");
    return 5;
}

fn respBulk(out: []u8, data: []const u8) usize {
    const h = std.fmt.bufPrint(out, "${d}\r\n", .{data.len}) catch return 0;
    const hlen = h.len;
    if (hlen + data.len + 2 > out.len) return 0;
    @memcpy(out[hlen .. hlen + data.len], data);
    @memcpy(out[hlen + data.len .. hlen + data.len + 2], "\r\n");
    return hlen + data.len + 2;
}

// Execute one parsed command. Returns response length in out.
fn execute(argc: usize, args: *const [16][]const u8, out: []u8, now: i64) usize {
    if (argc == 0) return 0;
    const cmd = args[0];

    lock();
    defer unlock();

    if (cmdIs(cmd, "PING")) {
        if (argc >= 2) return respBulk(out, args[1]);
        return respSimple(out, "PONG");
    } else if (cmdIs(cmd, "ECHO")) {
        if (argc < 2) return respErr(out, "ERR wrong number of arguments for 'echo'");
        return respBulk(out, args[1]);
    } else if (cmdIs(cmd, "COMMAND")) {
        // minimal: return empty array so clients don't choke
        if (out.len < 4) return 0;
        @memcpy(out[0..4], "*0\r\n");
        return 4;
    } else if (cmdIs(cmd, "CLIENT")) {
        return respSimple(out, "OK");
    } else if (cmdIs(cmd, "HELLO")) {
        return respSimple(out, "OK");
    } else if (cmdIs(cmd, "DBSIZE")) {
        // count non-expired (purge lazily: just count, don't sweep all for 0.0.1)
        var count: usize = 0;
        var it = store.iterator();
        while (it.next()) |kv| {
            if (!isExpiredAt(kv.value_ptr.expires_at_ms, now)) count += 1;
        }
        return respInt(out, @intCast(count));
    } else if (cmdIs(cmd, "FLUSHDB")) {
        var it = store.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.value);
        }
        store.clearRetainingCapacity();
        total_bytes = 0;
        return respSimple(out, "OK");
    } else if (cmdIs(cmd, "SET")) {
        if (argc < 3) return respErr(out, "ERR wrong number of arguments for 'set'");
        const key = args[1];
        const val = args[2];
        if (val.len > MAX_BULK) return respErr(out, "ERR value too big (1MB max in 0.0.1)");
        var exp: ?i64 = null;
        var j: usize = 3;
        while (j < argc) : (j += 1) {
            if (cmdIs(args[j], "EX") and j + 1 < argc) {
                const secs = std.fmt.parseInt(i64, args[j + 1], 10) catch return respErr(out, "ERR value is not an integer or out of range");
                exp = now + secs * 1000;
                j += 1;
            } else if (cmdIs(args[j], "PX") and j + 1 < argc) {
                const ms = std.fmt.parseInt(i64, args[j + 1], 10) catch return respErr(out, "ERR value is not an integer or out of range");
                exp = now + ms;
                j += 1;
            } else {
                return respErr(out, "ERR syntax error (0.0.1 supports SET k v [EX s] [PX ms])");
            }
        }
        // expired old copy counts as missing
        _ = purgeIfExpired(key, now);
        const old = store.get(key);
        const old_size: usize = if (old) |o| (key.len + o.value.len + 64) else 0;
        const new_size: usize = key.len + val.len + 64;
        if (total_bytes - old_size + new_size > maxmemory) {
            return respErr(out, "OOM command not allowed (tiny-redis 32MB guard)");
        }
        const key_dup = gpa.dupe(u8, key) catch return respErr(out, "ERR out of memory");
        const val_dup = gpa.dupe(u8, val) catch {
            gpa.free(key_dup);
            return respErr(out, "ERR out of memory");
        };
        if (store.fetchRemove(key)) |kv| {
            freeEntryKeyValue(kv.key, kv.value);
        }
        store.put(key_dup, .{ .value = val_dup, .expires_at_ms = exp }) catch {
            gpa.free(key_dup);
            gpa.free(val_dup);
            return respErr(out, "ERR out of memory");
        };
        total_bytes = total_bytes - old_size + new_size;
        return respSimple(out, "OK");
    } else if (cmdIs(cmd, "GET")) {
        if (argc != 2) return respErr(out, "ERR wrong number of arguments for 'get'");
        const key = args[1];
        if (purgeIfExpired(key, now)) return respNull(out);
        const e = store.get(key) orelse return respNull(out);
        return respBulk(out, e.value);
    } else if (cmdIs(cmd, "DEL")) {
        if (argc < 2) return respErr(out, "ERR wrong number of arguments for 'del'");
        var n: i64 = 0;
        var j: usize = 1;
        while (j < argc) : (j += 1) {
            _ = purgeIfExpired(args[j], now);
            if (store.fetchRemove(args[j])) |kv| {
                freeEntryKeyValue(kv.key, kv.value);
                n += 1;
            }
        }
        return respInt(out, n);
    } else if (cmdIs(cmd, "EXISTS")) {
        if (argc < 2) return respErr(out, "ERR wrong number of arguments for 'exists'");
        var n: i64 = 0;
        var j: usize = 1;
        while (j < argc) : (j += 1) {
            if (purgeIfExpired(args[j], now)) continue;
            if (store.contains(args[j])) n += 1;
        }
        return respInt(out, n);
    } else if (cmdIs(cmd, "EXPIRE")) {
        if (argc != 3) return respErr(out, "ERR wrong number of arguments for 'expire'");
        if (purgeIfExpired(args[1], now)) return respInt(out, 0);
        const kv = store.getPtr(args[1]) orelse return respInt(out, 0);
        const secs = std.fmt.parseInt(i64, args[2], 10) catch return respErr(out, "ERR value is not an integer or out of range");
        kv.expires_at_ms = now + secs * 1000;
        return respInt(out, 1);
    } else if (cmdIs(cmd, "TTL")) {
        if (argc != 2) return respErr(out, "ERR wrong number of arguments for 'ttl'");
        if (purgeIfExpired(args[1], now)) return respInt(out, -2);
        const e = store.get(args[1]) orelse return respInt(out, -2);
        const exp = e.expires_at_ms orelse return respInt(out, -1);
        var left = @divTrunc(exp - now + 999, 1000);
        if (left < 0) left = 0;
        return respInt(out, left);
    } else if (cmdIs(cmd, "INCR")) {
        if (argc != 2) return respErr(out, "ERR wrong number of arguments for 'incr'");
        if (purgeIfExpired(args[1], now)) {
            // fall through as missing -> 0
        }
        if (store.getPtr(args[1])) |kv| {
            const cur = std.fmt.parseInt(i64, kv.value, 10) catch return respErr(out, "ERR value is not an integer or out of range");
            const next = cur + 1;
            var nb: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{next}) catch return respErr(out, "ERR internal");
            const old_len = kv.value.len;
            const nd = gpa.dupe(u8, s) catch return respErr(out, "ERR out of memory");
            gpa.free(kv.value);
            kv.value = nd;
            total_bytes = total_bytes - old_len + nd.len;
            return respInt(out, next);
        } else {
            const key_dup = gpa.dupe(u8, args[1]) catch return respErr(out, "ERR out of memory");
            const val_dup = gpa.dupe(u8, "1") catch {
                gpa.free(key_dup);
                return respErr(out, "ERR out of memory");
            };
            if (total_bytes + key_dup.len + 1 + 64 > maxmemory) {
                gpa.free(key_dup);
                gpa.free(val_dup);
                return respErr(out, "OOM command not allowed (tiny-redis 32MB guard)");
            }
            store.put(key_dup, .{ .value = val_dup, .expires_at_ms = null }) catch {
                gpa.free(key_dup);
                gpa.free(val_dup);
                return respErr(out, "ERR out of memory");
            };
            total_bytes += key_dup.len + 1 + 64;
            return respInt(out, 1);
        }
    } else {
        return respErr(out, "ERR unknown command (0.0.1 supports PING ECHO SET GET DEL EXISTS EXPIRE TTL INCR DBSIZE FLUSHDB)");
    }
}

fn sendAll(fd: SOCKET, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const want: c_int = @intCast(@min(data.len - off, 8192));
        const n = send(fd, data.ptr + off, want, 0);
        if (n == SOCKET_ERROR or n == 0) return false;
        off += @as(usize, @intCast(n));
    }
    return true;
}

fn sockRecv(fd: SOCKET, buf: []u8) isize {
    const n = recv(fd, buf.ptr, @intCast(buf.len), 0);
    if (n == SOCKET_ERROR) return -1;
    return n;
}

fn handleClient(fd: SOCKET) void {
    defer _ = closesocket(fd);
    var buf: [8192]u8 = undefined;
    var pending: usize = 0;
    var out: [8704]u8 = undefined;

    while (true) {
        if (pending >= buf.len) return; // overflow guard
        const n = sockRecv(fd, buf[pending..]);
        if (n <= 0) return;
        const total = pending + @as(usize, @intCast(n));
        var off: usize = 0;
        while (off < total) {
            const parsed = tryParseCommand(buf[off..total]) catch |err| {
                const msg: []const u8 = if (err == error.TooBig) "ERR value too big" else "ERR malformed RESP";
                const rl = respErr(&out, msg);
                if (!sendAll(fd, out[0..rl])) return;
                return;
            };
            const p = parsed orelse break; // need more data
            if (p.argc == 0) {
                off += p.consumed;
                continue;
            }
            const rl = execute(p.argc, &p.args, &out, nowMs());
            if (rl == 0) return;
            if (!sendAll(fd, out[0..rl])) return;
            off += p.consumed;
        }
        // move leftover to front
        if (off < total) {
            const left = total - off;
            std.mem.copyForwards(u8, buf[0..left], buf[off..total]);
            pending = left;
        } else {
            pending = 0;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    store = std.StringHashMap(Entry).init(gpa);
    defer {
        var it = store.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.value);
        }
        store.deinit();
    }

    const arena = init.arena.allocator();

    var port: u16 = DEFAULT_PORT;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch DEFAULT_PORT;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--maxmemory") and i + 1 < args.len) {
            const mb = std.fmt.parseInt(usize, args[i + 1], 10) catch 32;
            maxmemory = mb * 1024 * 1024;
            i += 1;
        }
    }

    var wsa: WSADATA = undefined;
    if (WSAStartup(0x0202, &wsa) != 0) {
        std.debug.print("WSAStartup failed: {d}\n", .{WSAGetLastError()});
        return error.NetworkDown;
    }
    defer _ = WSACleanup();

    const listen_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listen_fd == INVALID_SOCKET) {
        std.debug.print("socket() failed: {d}\n", .{WSAGetLastError()});
        return error.NetworkDown;
    }
    defer _ = closesocket(listen_fd);

    const one: c_int = 1;
    _ = setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));

    const addr = sockaddr_in{
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr = LOOPBACK_ADDR,
    };
    if (bind(listen_fd, &addr, @sizeOf(sockaddr_in)) != 0) {
        std.debug.print("bind(127.0.0.1:{d}) failed: {d}\n", .{ port, WSAGetLastError() });
        return error.AddressInUse;
    }
    if (listen(listen_fd, 128) != 0) {
        std.debug.print("listen() failed: {d}\n", .{WSAGetLastError()});
        return error.NetworkDown;
    }

    std.debug.print("tiny-redis {s} listening on 127.0.0.1:{d} (maxmemory {d}MB)\n", .{ VERSION, port, maxmemory / (1024 * 1024) });

    while (true) {
        const fd = accept(listen_fd, null, null);
        if (fd == INVALID_SOCKET) {
            std.debug.print("accept() failed: {d}\n", .{WSAGetLastError()});
            continue;
        }
        const t = std.Thread.spawn(.{}, handleClient, .{fd}) catch |err| {
            std.debug.print("accept: spawn failed: {any}\n", .{err});
            _ = closesocket(fd);
            continue;
        };
        t.detach();
    }
}

test "resp parse set/get" {
    const raw = "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n";
    const p = try tryParseCommand(raw);
    try std.testing.expect(p != null);
    try std.testing.expectEqual(@as(usize, 3), p.?.argc);
    try std.testing.expectEqualStrings("SET", p.?.args[0]);
    try std.testing.expectEqualStrings("foo", p.?.args[1]);
    try std.testing.expectEqualStrings("bar", p.?.args[2]);
}
