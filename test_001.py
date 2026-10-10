import socket

def cmd(*args):
    out = f"*{len(args)}\r\n".encode()
    for a in args:
        if isinstance(a, str):
            a = a.encode()
        out += f"${len(a)}\r\n".encode() + a + b"\r\n"
    return out

TESTS = [
    (cmd("PING"), b"+PONG\r\n"),
    (cmd("SET", "foo", "bar"), b"+OK\r\n"),
    (cmd("GET", "foo"), b"$3\r\nbar\r\n"),
    (cmd("GET", "missing"), b"$-1\r\n"),
    (cmd("INCR", "counter"), b":1\r\n"),
    (cmd("INCR", "counter"), b":2\r\n"),
    (cmd("EXISTS", "foo", "missing"), b":1\r\n"),
    (cmd("TTL", "foo"), b":-1\r\n"),
    (cmd("SET", "temp", "x", "EX", "100"), b"+OK\r\n"),
    (cmd("TTL", "temp"), None),  # just print, value varies
    (cmd("DBSIZE"), None),
    (cmd("DEL", "foo"), b":1\r\n"),
    (cmd("GET", "foo"), b"$-1\r\n"),
]

s = socket.socket()
s.settimeout(5)
s.connect(("127.0.0.1", 6399))
fails = 0
for req, want in TESTS:
    s.sendall(req)
    got = s.recv(4096)
    status = "OK " if (want is None or got == want) else "FAIL"
    if status == "FAIL":
        fails += 1
    print(f"{status} {req!r} -> {got!r}" + ("" if want is None else f" (want {want!r})"))
s.close()
print("ALL PASS" if fails == 0 else f"{fails} FAILURES")
