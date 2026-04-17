#!/usr/bin/env python3
"""
Radish Smoke Test

Exercises every command over RESP and asserts expected responses.

Usage:
    python3 scripts/smoke_test.py              # Docker mode (builds, starts, tests, cleans up)
    python3 scripts/smoke_test.py --native     # Native mode (expects server already running)

Environment variables (for --native mode):
    RADISH_HOST   Server hostname (default: 127.0.0.1)
    RADISH_PORT   Server port (default: 9000)
"""

import os
import socket
import subprocess
import sys
import time

HOST = os.environ.get("RADISH_HOST", "127.0.0.1")
PORT = int(os.environ.get("RADISH_PORT", "9000"))
PASS = 0
FAIL = 0


# ── Docker helpers ───────────────────────────────────────────────────────────

def run(cmd, check=True):
    subprocess.run(cmd, shell=True, check=check, capture_output=True)


def run_visible(cmd, check=True):
    subprocess.run(cmd, shell=True, check=check)


def cleanup():
    print("\n── Cleaning up ─────────────────────────────────────────────────────────")
    run("docker compose down --timeout 5", check=False)


# ── RESP helpers ─────────────────────────────────────────────────────────────

def send_resp(sock, *parts):
    cmd = f"*{len(parts)}\r\n"
    for p in parts:
        cmd += f"${len(p)}\r\n{p}\r\n"
    sock.sendall(cmd.encode())


def read_line(sock):
    buf = b""
    while True:
        ch = sock.recv(1)
        if not ch:
            return ""
        buf += ch
        if buf.endswith(b"\r\n"):
            return buf[:-2].decode("utf-8", errors="replace")


def read_resp(sock):
    line = read_line(sock)
    if not line:
        return ""
    prefix = line[0]
    if prefix in ("+", "-", ":"):
        return line
    elif prefix == "$":
        length = int(line[1:])
        if length == -1:
            return "$-1"
        data = b""
        while len(data) < length:
            data += sock.recv(length - len(data))
        sock.recv(2)  # \r\n
        return f"${length}:{data.decode('utf-8', errors='replace')}"
    elif prefix == "*":
        count = int(line[1:])
        if count <= 0:
            return f"*{count}"
        items = [read_resp(sock) for _ in range(count)]
        return f"*{count}:[{', '.join(items)}]"
    return line


# ── Assertions ───────────────────────────────────────────────────────────────

def assert_contains(name, response, expected):
    global PASS, FAIL
    if expected in response:
        PASS += 1
        print(f"  \033[32m✓\033[0m {name}")
    else:
        FAIL += 1
        print(f"  \033[31m✗\033[0m {name}")
        print(f"    expected to contain: {expected}")
        print(f"    got: {response}")


def assert_ok(name, response):
    global PASS, FAIL
    if "-ERR" not in response and response != "":
        PASS += 1
        print(f"  \033[32m✓\033[0m {name}")
    else:
        FAIL += 1
        print(f"  \033[31m✗\033[0m {name}")
        print(f"    got: {response}")


def assert_equals(name, response, expected):
    global PASS, FAIL
    if response == expected:
        PASS += 1
        print(f"  \033[32m✓\033[0m {name}")
    else:
        FAIL += 1
        print(f"  \033[31m✗\033[0m {name}")
        print(f"    expected: {expected}")
        print(f"    got: {response}")


def assert_error(name, response):
    global PASS, FAIL
    if response.startswith("-ERR"):
        PASS += 1
        print(f"  \033[32m✓\033[0m {name}")
    else:
        FAIL += 1
        print(f"  \033[31m✗\033[0m {name}")
        print(f"    expected: -ERR ...")
        print(f"    got: {response}")


def assert_nil(name, response):
    global PASS, FAIL
    if response == "$-1":
        PASS += 1
        print(f"  \033[32m✓\033[0m {name}")
    else:
        FAIL += 1
        print(f"  \033[31m✗\033[0m {name}")
        print(f"    expected: $-1 (nil)")
        print(f"    got: {response}")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    native_mode = "--native" in sys.argv
    mode_label = "native (server already running)" if native_mode else "Docker"

    print("=" * 78)
    print("  Radish Smoke Test")
    print("=" * 78)
    print(f"  Mode: {mode_label}")
    print(f"  Server: {HOST}:{PORT}")
    print()

    try:
        if native_mode:
            # ── Native mode: expect server already running ───────────
            print("── Connecting to server ──────────────────────────────────────────────────")
            for i in range(1, 31):
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    s.settimeout(2)
                    s.connect((HOST, PORT))
                    s.close()
                    print(f"  Server reachable on {HOST}:{PORT}")
                    break
                except (ConnectionRefusedError, OSError):
                    if i == 30:
                        print(f"  Server not reachable on {HOST}:{PORT} after 30s")
                        sys.exit(1)
                    time.sleep(1)
        else:
            # ── Docker mode: build & start ───────────────────────────
            print("── Building Docker image ─────────────────────────────────────────────────")
            run_visible("docker compose build --quiet")

            print("── Starting server ───────────────────────────────────────────────────────")
            run_visible("docker compose up -d radish-server")

            print("── Waiting for server to be healthy ──────────────────────────────────────")
            for i in range(1, 91):
                result = subprocess.run(
                    "docker inspect --format='{{.State.Health.Status}}' radish-server",
                    shell=True, capture_output=True, text=True,
                )
                status = result.stdout.strip().strip("'")
                if status == "healthy":
                    print(f"  Server healthy after {i}s")
                    break
                if i == 90:
                    print(f"  \033[31mServer failed to become healthy after 90s\033[0m")
                    cleanup()
                    sys.exit(1)
                time.sleep(1)

        time.sleep(1)
        print()
        print("── Running command tests ─────────────────────────────────────────────────")
        print()

        # Connect
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10)
        sock.connect((HOST, PORT))
        welcome = read_line(sock)
        print(f"  Welcome: {welcome}")
        print()

        # ── String Commands ──────────────────────────────────────────────────
        print("\033[1mString Commands\033[0m")

        send_resp(sock, "PING")
        assert_contains("PING", read_resp(sock), "PONG")

        send_resp(sock, "S_SET", "key1", "hello")
        assert_contains("S_SET key1 hello", read_resp(sock), ":1")

        send_resp(sock, "S_GET", "key1")
        assert_contains("S_GET key1", read_resp(sock), "hello")

        send_resp(sock, "S_SET", "numkey", "10")
        assert_contains("S_SET numkey 10", read_resp(sock), ":1")

        send_resp(sock, "S_INCR", "numkey")
        assert_contains("S_INCR numkey", read_resp(sock), ":1")

        send_resp(sock, "S_GINCR", "numkey")
        assert_equals("S_GINCR numkey → returns 11 (pre-incr)", read_resp(sock), ":11")

        send_resp(sock, "S_INCRBY", "numkey", "5")
        assert_contains("S_INCRBY numkey 5", read_resp(sock), ":1")

        send_resp(sock, "S_GINCRBY", "numkey", "3")
        assert_equals("S_GINCRBY numkey 3 → returns 17 (pre-incr)", read_resp(sock), ":17")

        send_resp(sock, "S_APPEND", "key1", "_world")
        assert_contains("S_APPEND key1 _world", read_resp(sock), ":1")

        send_resp(sock, "S_RPAD", "key1", "20", "x")
        assert_contains("S_RPAD key1 20 x", read_resp(sock), ":1")

        send_resp(sock, "S_LPAD", "key1", "25", "y")
        assert_contains("S_LPAD key1 25 y", read_resp(sock), ":1")

        send_resp(sock, "S_GETRANGE", "key1", "1", "5")
        assert_contains("S_GETRANGE key1 1 5", read_resp(sock), "$")

        send_resp(sock, "S_LEN", "key1")
        assert_equals("S_LEN key1 → 25", read_resp(sock), ":25")

        send_resp(sock, "S_SET", "key2", "hello")
        assert_contains("S_SET key2 hello", read_resp(sock), ":1")

        send_resp(sock, "S_LCS", "key1", "key2")
        assert_contains("S_LCS key1 key2", read_resp(sock), "*2:")

        send_resp(sock, "S_COMPLEN", "key1", "key2")
        assert_equals("S_COMPLEN key1 key2 → 0 (different lengths)", read_resp(sock), ":0")

        print()

        # ── List Commands ────────────────────────────────────────────────────
        print("\033[1mList Commands\033[0m")

        send_resp(sock, "L_ADD", "mylist", "item1")
        assert_contains("L_ADD mylist item1", read_resp(sock), ":1")

        send_resp(sock, "L_PREPEND", "mylist", "item0")
        assert_contains("L_PREPEND mylist item0", read_resp(sock), ":1")

        send_resp(sock, "L_APPEND", "mylist", "item2")
        assert_contains("L_APPEND mylist item2", read_resp(sock), ":1")

        send_resp(sock, "L_GET", "mylist")
        assert_contains("L_GET mylist", read_resp(sock), "*3:")

        send_resp(sock, "L_RANGE", "mylist", "1", "2")
        assert_contains("L_RANGE mylist 1 2", read_resp(sock), "*2:")

        send_resp(sock, "L_LEN", "mylist")
        assert_equals("L_LEN mylist → 3", read_resp(sock), ":3")

        send_resp(sock, "L_POP", "mylist")
        assert_contains("L_POP mylist → item2", read_resp(sock), "item2")

        send_resp(sock, "L_DEQUEUE", "mylist")
        assert_contains("L_DEQUEUE mylist → item0", read_resp(sock), "item0")

        # Build lists for trim/move
        for cmd in [("L_ADD", "trimlist", "a"), ("L_APPEND", "trimlist", "b"),
                     ("L_APPEND", "trimlist", "c")]:
            send_resp(sock, *cmd)
            read_resp(sock)

        send_resp(sock, "L_TRIMR", "trimlist", "2")
        assert_contains("L_TRIMR trimlist 2", read_resp(sock), ":1")

        for cmd in [("L_ADD", "trimlist2", "x"), ("L_APPEND", "trimlist2", "y"),
                     ("L_APPEND", "trimlist2", "z")]:
            send_resp(sock, *cmd)
            read_resp(sock)

        send_resp(sock, "L_TRIML", "trimlist2", "2")
        assert_contains("L_TRIML trimlist2 2", read_resp(sock), ":1")

        send_resp(sock, "L_ADD", "movesrc", "moveitem")
        read_resp(sock)
        send_resp(sock, "L_ADD", "movedst", "base")
        read_resp(sock)

        send_resp(sock, "L_MOVE", "movedst", "movesrc")
        assert_contains("L_MOVE movedst movesrc", read_resp(sock), ":1")

        print()

        # ── Key Management ───────────────────────────────────────────────────
        print("\033[1mKey Management Commands\033[0m")

        send_resp(sock, "EXISTS", "key1")
        assert_contains("EXISTS key1", read_resp(sock), ":1")

        send_resp(sock, "DEL", "key2")
        assert_contains("DEL key2", read_resp(sock), ":1")

        send_resp(sock, "TYPE", "key1")
        assert_contains("TYPE key1", read_resp(sock), "string")

        send_resp(sock, "S_SET", "ttlkey", "val", "300")
        assert_contains("S_SET ttlkey val 300", read_resp(sock), ":1")

        send_resp(sock, "TTL", "ttlkey")
        assert_contains("TTL ttlkey → positive", read_resp(sock), ":")

        send_resp(sock, "PERSIST", "ttlkey")
        assert_contains("PERSIST ttlkey", read_resp(sock), ":1")

        send_resp(sock, "EXPIRE", "key1", "600")
        assert_contains("EXPIRE key1 600", read_resp(sock), ":1")

        send_resp(sock, "S_SET", "renamekey", "val")
        read_resp(sock)
        send_resp(sock, "RENAME", "renamekey", "newname")
        assert_contains("RENAME renamekey newname", read_resp(sock), "OK")

        print()

        # ── Context Commands ─────────────────────────────────────────────────
        print("\033[1mContext Commands\033[0m")

        send_resp(sock, "KLIST")
        assert_contains("KLIST", read_resp(sock), "*")

        send_resp(sock, "DBSIZE")
        assert_contains("DBSIZE → positive count", read_resp(sock), ":")

        print()

        # ── Transaction Commands ─────────────────────────────────────────────
        print("\033[1mTransaction Commands\033[0m")

        send_resp(sock, "MULTI")
        assert_contains("MULTI", read_resp(sock), "OK")

        send_resp(sock, "S_SET", "txkey", "1")
        assert_contains("S_SET txkey 1 (queued)", read_resp(sock), "QUEUED")

        send_resp(sock, "S_INCR", "txkey")
        assert_contains("S_INCR txkey (queued)", read_resp(sock), "QUEUED")

        send_resp(sock, "EXEC")
        assert_ok("EXEC", read_resp(sock))

        send_resp(sock, "MULTI")
        assert_contains("MULTI (for discard)", read_resp(sock), "OK")

        send_resp(sock, "S_SET", "disckey", "abc")
        assert_contains("S_SET disckey (queued)", read_resp(sock), "QUEUED")

        send_resp(sock, "DISCARD")
        assert_contains("DISCARD", read_resp(sock), "OK")

        print()

        # ── WRONGTYPE Validation ─────────────────────────────────────────────
        print("\033[1mWRONGTYPE Validation\033[0m")

        # mylist still exists as a list (has 1 element: item1, after pop+dequeue)
        send_resp(sock, "S_GET", "mylist")
        assert_error("S_GET on list key → WRONGTYPE", read_resp(sock))

        send_resp(sock, "S_INCR", "mylist")
        assert_error("S_INCR on list key → WRONGTYPE", read_resp(sock))

        send_resp(sock, "S_APPEND", "mylist", "nope")
        assert_error("S_APPEND on list key → WRONGTYPE", read_resp(sock))

        send_resp(sock, "L_GET", "key1")
        assert_error("L_GET on string key → WRONGTYPE", read_resp(sock))

        send_resp(sock, "L_APPEND", "key1", "nope")
        assert_error("L_APPEND on string key → WRONGTYPE", read_resp(sock))

        send_resp(sock, "L_POP", "key1")
        assert_error("L_POP on string key → WRONGTYPE", read_resp(sock))

        print()

        # ── TTL Expiration ───────────────────────────────────────────────────
        print("\033[1mTTL Expiration\033[0m")

        send_resp(sock, "S_SET", "shortlived", "ephemeral", "2")
        assert_contains("S_SET shortlived with 2s TTL", read_resp(sock), ":1")

        send_resp(sock, "EXISTS", "shortlived")
        assert_equals("EXISTS shortlived → 1 (before expiry)", read_resp(sock), ":1")

        send_resp(sock, "S_GET", "shortlived")
        assert_contains("S_GET shortlived → ephemeral (before expiry)", read_resp(sock), "ephemeral")

        print("  ⏳ Waiting 3s for TTL expiration...")
        time.sleep(3)

        send_resp(sock, "EXISTS", "shortlived")
        assert_equals("EXISTS shortlived → 0 (after expiry)", read_resp(sock), ":0")

        send_resp(sock, "S_GET", "shortlived")
        assert_nil("S_GET shortlived → nil (after expiry)", read_resp(sock))

        send_resp(sock, "TYPE", "shortlived")
        assert_nil("TYPE shortlived → nil (after expiry)", read_resp(sock))

        send_resp(sock, "TTL", "shortlived")
        assert_nil("TTL shortlived → nil (after expiry)", read_resp(sock))

        print()

        # ── Error Cases ──────────────────────────────────────────────────────
        print("\033[1mError Cases\033[0m")

        # S_INCR on non-integer
        send_resp(sock, "S_SET", "notanum", "hello")
        read_resp(sock)
        send_resp(sock, "S_INCR", "notanum")
        assert_error("S_INCR on non-integer → ERR", read_resp(sock))

        # S_GET on missing key → nil
        send_resp(sock, "S_GET", "totally_missing")
        assert_nil("S_GET missing key → nil", read_resp(sock))

        # EXISTS on missing key → 0
        send_resp(sock, "EXISTS", "totally_missing")
        assert_equals("EXISTS missing key → 0", read_resp(sock), ":0")

        # DEL on missing key → nil
        send_resp(sock, "DEL", "totally_missing")
        assert_nil("DEL missing key → nil", read_resp(sock))

        # TYPE on missing key → nil
        send_resp(sock, "TYPE", "totally_missing")
        assert_nil("TYPE missing key → nil", read_resp(sock))

        # TTL on missing key → nil
        send_resp(sock, "TTL", "totally_missing")
        assert_nil("TTL missing key → nil", read_resp(sock))

        # EXPIRE with invalid TTL
        send_resp(sock, "EXPIRE", "key1", "notanumber")
        assert_error("EXPIRE with non-integer TTL → ERR", read_resp(sock))

        send_resp(sock, "EXPIRE", "key1", "0")
        assert_error("EXPIRE with zero TTL → ERR", read_resp(sock))

        send_resp(sock, "EXPIRE", "key1", "-5")
        assert_error("EXPIRE with negative TTL → ERR", read_resp(sock))

        # EXEC without MULTI
        send_resp(sock, "EXEC")
        assert_error("EXEC without MULTI → ERR", read_resp(sock))

        # DISCARD without MULTI
        send_resp(sock, "DISCARD")
        assert_error("DISCARD without MULTI → ERR", read_resp(sock))

        # RENAME missing key
        send_resp(sock, "RENAME", "ghost", "newghost")
        assert_nil("RENAME missing key → nil", read_resp(sock))

        # S_SET duplicate key
        send_resp(sock, "S_SET", "key1", "duplicate")
        assert_error("S_SET duplicate key → ERR", read_resp(sock))

        # L_ADD duplicate key
        send_resp(sock, "L_ADD", "mylist", "duplicate")
        assert_error("L_ADD duplicate list key → ERR", read_resp(sock))

        print()

        # ── Tighter Value Assertions ─────────────────────────────────────────
        print("\033[1mValue Assertions\033[0m")

        # Verify S_GET returns exact value
        send_resp(sock, "S_SET", "exact_test", "precise_value")
        read_resp(sock)
        send_resp(sock, "S_GET", "exact_test")
        assert_equals("S_GET exact_test → precise_value", read_resp(sock), "$13:precise_value")

        # Verify S_INCR chain produces correct value
        send_resp(sock, "S_SET", "counter", "0")
        read_resp(sock)
        for _ in range(5):
            send_resp(sock, "S_INCR", "counter")
            read_resp(sock)
        send_resp(sock, "S_GET", "counter")
        assert_equals("S_GET counter after 5 increments → 5", read_resp(sock), "$1:5")

        # Verify S_INCRBY
        send_resp(sock, "S_INCRBY", "counter", "10")
        read_resp(sock)
        send_resp(sock, "S_GET", "counter")
        assert_equals("S_GET counter after INCRBY 10 → 15", read_resp(sock), "$2:15")

        # Verify L_LEN after known operations
        send_resp(sock, "L_ADD", "countlist", "a")
        read_resp(sock)
        send_resp(sock, "L_APPEND", "countlist", "b")
        read_resp(sock)
        send_resp(sock, "L_APPEND", "countlist", "c")
        read_resp(sock)
        send_resp(sock, "L_LEN", "countlist")
        assert_equals("L_LEN countlist → 3", read_resp(sock), ":3")

        # Verify TYPE returns correct type string
        send_resp(sock, "TYPE", "counter")
        assert_contains("TYPE counter → string", read_resp(sock), "string")

        send_resp(sock, "TYPE", "countlist")
        assert_contains("TYPE countlist → list", read_resp(sock), "list")

        # Verify TTL on key without TTL returns -1
        send_resp(sock, "TTL", "counter")
        assert_equals("TTL counter (no TTL) → -1", read_resp(sock), ":-1")

        print()

        # ── Server Commands ──────────────────────────────────────────────────
        print("\033[1mServer Commands\033[0m")

        send_resp(sock, "BGSAVE")
        assert_contains("BGSAVE", read_resp(sock), "Background")

        send_resp(sock, "FLUSHDB")
        assert_contains("FLUSHDB", read_resp(sock), "OK")

        send_resp(sock, "DBSIZE")
        assert_contains("DBSIZE after FLUSHDB", read_resp(sock), ":0")

        print()

        # Done
        send_resp(sock, "QUIT")
        read_resp(sock)
        sock.close()

    finally:
        if not native_mode:
            cleanup()

    # Results
    total = PASS + FAIL
    print("=" * 78)
    print()
    if FAIL == 0:
        print(f"  \033[32mAll {total} tests passed\033[0m ({PASS}/{total})")
        print()
        print("=" * 78)
        sys.exit(0)
    else:
        print(f"  \033[31m{FAIL}/{total} tests failed\033[0m ({PASS} passed)")
        print()
        print("=" * 78)
        sys.exit(1)


if __name__ == "__main__":
    main()
