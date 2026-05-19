#!/usr/bin/env python3
"""
Radish Network Benchmarks (Level 3)

Measures end-to-end performance over real TCP/RESP:
  - Single-client round-trip latency
  - Single-client pipelined throughput
  - Multi-client concurrent throughput
  - Command mix workloads

The script only benchmarks — it expects a running server.
Server lifecycle (Docker or native) is managed by the Makefile.

Usage:
    python3 benchmarks/bench_net.py                                  # connect to 127.0.0.1:9000
    RADISH_HOST=radish-server python3 benchmarks/bench_net.py        # connect to custom host
    make bench-net                                                   # Docker: Makefile starts/stops server
    make bench-net-native                                            # native: you start server first
"""

import os
import socket
import sys
import time
import random
import threading
import statistics
from datetime import datetime

HOST = os.environ.get("RADISH_HOST", "127.0.0.1")
PORT = int(os.environ.get("RADISH_PORT", "9000"))
NUM_KEYS = 10_000
OPS_PER_BENCH = 10_000
TRIALS = 3


# ── RESP helpers ─────────────────────────────────────────────────────────────

def encode_resp(*parts):
    """Encode a command as RESP bytes."""
    cmd = f"*{len(parts)}\r\n"
    for p in parts:
        cmd += f"${len(p)}\r\n{p}\r\n"
    return cmd.encode()


def send_resp(sock, *parts):
    sock.sendall(encode_resp(*parts))


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
        sock.recv(2)
        return f"${length}:{data.decode('utf-8', errors='replace')}"
    elif prefix == "*":
        count = int(line[1:])
        if count <= 0:
            return f"*{count}"
        items = [read_resp(sock) for _ in range(count)]
        return f"*{count}:[{', '.join(items)}]"
    return line


def connect():
    """Connect to the server, consume welcome message."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect((HOST, PORT))
    read_line(sock)  # welcome
    return sock


# ── Formatting helpers ───────────────────────────────────────────────────────

def fmt_num(n):
    return f"{n:,.0f}" if isinstance(n, float) else f"{n:,}"


def fmt_time(ns):
    if ns < 1_000:
        return f"{ns:.1f} ns"
    elif ns < 1_000_000:
        return f"{ns / 1_000:.1f} μs"
    elif ns < 1_000_000_000:
        return f"{ns / 1_000_000:.1f} ms"
    else:
        return f"{ns / 1_000_000_000:.2f} s"


def report(name, ops, elapsed_ns):
    per_op = elapsed_ns / ops
    ops_sec = ops / (elapsed_ns / 1e9)
    print(f"  {name:<50} {fmt_time(per_op):>12}/op  {fmt_num(ops_sec):>14} ops/s  ({fmt_num(ops)} ops)")


# ── Benchmark runners ────────────────────────────────────────────────────────

def bench_single_latency(sock, cmd_parts_list, num_ops):
    """Send one command, wait for response, repeat. Returns elapsed_ns."""
    t0 = time.time_ns()
    for i in range(num_ops):
        parts = cmd_parts_list[i % len(cmd_parts_list)]
        send_resp(sock, *parts)
        read_resp(sock)
    t1 = time.time_ns()
    return t1 - t0


def bench_pipeline(sock, cmd_parts_list, num_ops, batch_size):
    """Send batch_size commands, then read batch_size responses. Returns elapsed_ns."""
    t0 = time.time_ns()
    sent = 0
    while sent < num_ops:
        batch = min(batch_size, num_ops - sent)
        # Send batch
        buf = b""
        for i in range(batch):
            parts = cmd_parts_list[(sent + i) % len(cmd_parts_list)]
            buf += encode_resp(*parts)
        sock.sendall(buf)
        # Read batch
        for _ in range(batch):
            read_resp(sock)
        sent += batch
    t1 = time.time_ns()
    return t1 - t0


def bench_multi_client(num_clients, cmd_fn, ops_per_client):
    """Spawn num_clients threads, each doing ops_per_client operations. Returns total elapsed_ns."""
    barrier = threading.Barrier(num_clients + 1)
    results = [0] * num_clients

    def worker(idx):
        sock = connect()
        barrier.wait()  # sync start
        t0 = time.time_ns()
        cmd_fn(sock, ops_per_client)
        t1 = time.time_ns()
        results[idx] = t1 - t0
        send_resp(sock, "QUIT")
        read_resp(sock)
        sock.close()

    threads = []
    for i in range(num_clients):
        t = threading.Thread(target=worker, args=(i,))
        t.start()
        threads.append(t)

    barrier.wait()  # release all workers
    for t in threads:
        t.join()

    return max(results)  # wall-clock = slowest worker


def median_of(fn, trials=TRIALS):
    """Run fn() multiple times, return median result."""
    samples = [fn() for _ in range(trials)]
    return statistics.median(samples)


# ── Command generators ───────────────────────────────────────────────────────

def make_read_commands(n):
    return [("S_GET", f"str_{random.randint(1, NUM_KEYS)}") for _ in range(n)]


def make_write_commands(n):
    return [("S_INCR", f"str_{random.randint(1, NUM_KEYS)}") for _ in range(n)]


def make_mixed_commands(n):
    """90% reads, 10% writes."""
    cmds = []
    for _ in range(n):
        if random.random() < 0.9:
            cmds.append(("S_GET", f"str_{random.randint(1, NUM_KEYS)}"))
        else:
            cmds.append(("S_INCR", f"str_{random.randint(1, NUM_KEYS)}"))
    return cmds


def make_all_commands(n):
    """Diverse command mix."""
    cmds = []
    for _ in range(n):
        r = random.random()
        if r < 0.30:
            cmds.append(("S_GET", f"str_{random.randint(1, NUM_KEYS)}"))
        elif r < 0.50:
            cmds.append(("S_INCR", f"str_{random.randint(1, NUM_KEYS)}"))
        elif r < 0.60:
            cmds.append(("EXISTS", f"str_{random.randint(1, NUM_KEYS)}"))
        elif r < 0.70:
            cmds.append(("TYPE", f"str_{random.randint(1, NUM_KEYS)}"))
        elif r < 0.80:
            cmds.append(("S_LEN", f"str_{random.randint(1, NUM_KEYS)}"))
        elif r < 0.90:
            cmds.append(("PING",))
        else:
            cmds.append(("TTL", f"str_{random.randint(1, NUM_KEYS)}"))
    return cmds


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    bench_id = datetime.now().strftime("%Y%m%d_%H%M%S")

    print("=" * 78)
    print("  Radish Network Benchmarks (Level 3)")
    print("=" * 78)
    print()
    print(f"  Date: {datetime.now().isoformat()}")
    print(f"  Bench ID: {bench_id}")
    print(f"  Host: {HOST}:{PORT}")
    print(f"  Keys: {fmt_num(NUM_KEYS)}")
    print(f"  Ops per bench: {fmt_num(OPS_PER_BENCH)}")
    print(f"  Trials: {TRIALS} (median)")
    print()

    # ── Wait for server ──────────────────────────────────────────────
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
                print(f"  Start it first: make server  (Docker) or make server-native")
                sys.exit(1)
            time.sleep(1)

    time.sleep(1)

    # ── Pre-populate ─────────────────────────────────────────────────
    print(f"── Pre-populating {fmt_num(NUM_KEYS)} keys ──────────────────────────────────────────")
    sock = connect()
    for i in range(1, NUM_KEYS + 1):
        send_resp(sock, "S_SET", f"str_{i}", f"value_{i}")
        read_resp(sock)
    print(f"  Loaded {fmt_num(NUM_KEYS)} string keys")
    # Pre-populate sets (each with 5 members)
    for i in range(1, NUM_KEYS // 10 + 1):
        for j in range(1, 6):
            send_resp(sock, "SET_ADD", f"set_{i}", f"member_{j}")
            read_resp(sock)
    print(f"  Loaded {fmt_num(NUM_KEYS // 10)} set keys (5 members each)")
    send_resp(sock, "QUIT")
    read_resp(sock)
    sock.close()
    print()

    # ── 1. Single-client latency ─────────────────────────────────────
    print("── Single-Client Latency (1 cmd → 1 response) ──────────────────────────")

    read_cmds = make_read_commands(OPS_PER_BENCH)
    write_cmds = make_write_commands(OPS_PER_BENCH)
    mixed_cmds = make_mixed_commands(OPS_PER_BENCH)
    all_cmds = make_all_commands(OPS_PER_BENCH)

    elapsed = median_of(lambda: (lambda s: (bench_single_latency(s, read_cmds, OPS_PER_BENCH), s))
                        (connect())[0])
    report("S_GET (read-only)", OPS_PER_BENCH, elapsed)

    elapsed = median_of(lambda: (lambda s: (bench_single_latency(s, write_cmds, OPS_PER_BENCH), s))
                        (connect())[0])
    report("S_INCR (write-only)", OPS_PER_BENCH, elapsed)

    elapsed = median_of(lambda: (lambda s: (bench_single_latency(s, mixed_cmds, OPS_PER_BENCH), s))
                        (connect())[0])
    report("mixed 90/10 read/write", OPS_PER_BENCH, elapsed)

    elapsed = median_of(lambda: (lambda s: (bench_single_latency(s, all_cmds, OPS_PER_BENCH), s))
                        (connect())[0])
    report("all-commands mix", OPS_PER_BENCH, elapsed)

    # PING (no key, no lock — measures pure round-trip)
    ping_cmds = [("PING",)] * OPS_PER_BENCH
    elapsed = median_of(lambda: (lambda s: (bench_single_latency(s, ping_cmds, OPS_PER_BENCH), s))
                        (connect())[0])
    report("PING (pure round-trip)", OPS_PER_BENCH, elapsed)

    # Set operations
    NUM_SETS = NUM_KEYS // 10
    set_get_cmds = [("SET_GET", f"set_{random.randint(1, NUM_SETS)}") for _ in range(OPS_PER_BENCH)]
    elapsed = median_of(lambda: (lambda s: (bench_single_latency(s, set_get_cmds, OPS_PER_BENCH), s))
                        (connect())[0])
    report("SET_GET (read all members)", OPS_PER_BENCH, elapsed)

    set_len_cmds = [("SET_LEN", f"set_{random.randint(1, NUM_SETS)}") for _ in range(OPS_PER_BENCH)]
    elapsed = median_of(lambda: (lambda s: (bench_single_latency(s, set_len_cmds, OPS_PER_BENCH), s))
                        (connect())[0])
    report("SET_LEN", OPS_PER_BENCH, elapsed)

    set_add_cmds = [("SET_ADD", f"set_{random.randint(1, NUM_SETS)}", f"bench_{i}") for i in range(OPS_PER_BENCH)]
    elapsed = median_of(lambda: (lambda s: (bench_single_latency(s, set_add_cmds, OPS_PER_BENCH), s))
                        (connect())[0])
    report("SET_ADD (write)", OPS_PER_BENCH, elapsed)

    print()

    # ── 2. Single-client pipelined ───────────────────────────────────
    print("── Single-Client Pipelined (batch N → read N) ──────────────────────────")

    for batch_size in [10, 50, 100, 500]:
        elapsed = median_of(lambda bs=batch_size: (lambda s: (bench_pipeline(s, read_cmds, OPS_PER_BENCH, bs), s))
                            (connect())[0])
        report(f"S_GET pipeline batch={batch_size}", OPS_PER_BENCH, elapsed)

    print()

    for batch_size in [10, 50, 100, 500]:
        elapsed = median_of(lambda bs=batch_size: (lambda s: (bench_pipeline(s, mixed_cmds, OPS_PER_BENCH, bs), s))
                            (connect())[0])
        report(f"mixed 90/10 pipeline batch={batch_size}", OPS_PER_BENCH, elapsed)

    print()

    # ── 3. Multi-client latency ──────────────────────────────────────
    print("── Multi-Client Latency (1 cmd at a time per client) ───────────────────")

    ops_per_client = 5_000

    for num_clients in [1, 2, 4, 8]:
        def single_cmd_worker(sock, n):
            cmds = make_mixed_commands(n)
            for parts in cmds:
                send_resp(sock, *parts)
                read_resp(sock)

        elapsed = median_of(lambda nc=num_clients: bench_multi_client(nc, single_cmd_worker, ops_per_client))
        total_ops = num_clients * ops_per_client
        report(f"mixed 90/10 ({num_clients} clients)", total_ops, elapsed)

    print()

    # ── 4. Multi-client pipelined ────────────────────────────────────
    print("── Multi-Client Pipelined (batch 100 per client) ───────────────────────")

    for num_clients in [1, 2, 4, 8]:
        def pipeline_worker(sock, n):
            cmds = make_mixed_commands(n)
            batch_size = 100
            sent = 0
            while sent < n:
                batch = min(batch_size, n - sent)
                buf = b""
                for i in range(batch):
                    buf += encode_resp(*cmds[(sent + i) % len(cmds)])
                sock.sendall(buf)
                for _ in range(batch):
                    read_resp(sock)
                sent += batch

        elapsed = median_of(lambda nc=num_clients: bench_multi_client(nc, pipeline_worker, ops_per_client))
        total_ops = num_clients * ops_per_client
        report(f"mixed 90/10 pipeline ({num_clients} clients)", total_ops, elapsed)

    print()

    print("=" * 78)
    print("  Benchmark complete.")
    print("=" * 78)


if __name__ == "__main__":
    main()
