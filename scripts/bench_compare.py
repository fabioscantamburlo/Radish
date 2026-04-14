#!/usr/bin/env python3
"""
Radish Benchmark Comparison

Compares two benchmark output files side-by-side, showing ops/s delta
and percentage change. Highlights improvements in green, regressions in red.

Usage: python3 scripts/bench_compare.py <before.txt> <after.txt>
       make bench-compare BEFORE=benchmarks/baseline.txt AFTER=benchmarks/optim_0.2.txt

A tolerance of ±5% accounts for JIT/scheduling noise — changes within
that range are shown as neutral (≈).
"""

import sys
import re

TOLERANCE = 5.0  # ±5% is noise


def parse_benchmarks(path):
    """Parse benchmark file, return dict of {name: ops_per_sec}."""
    results = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip()
            # Benchmark lines: "  <name>  <time>/op  <ops> ops/s  (<iters>)"
            m = re.match(
                r"^\s{2}(.+?)\s{2,}"  # name (2+ trailing spaces)
                r"(\S+\s+\S+/op)\s+"  # time/op
                r"([\d,]+)\s+ops/s",  # ops/s
                line,
            )
            if m:
                name = m.group(1).strip()
                ops_str = m.group(3).replace(",", "")
                try:
                    results[name] = int(ops_str)
                except ValueError:
                    pass
                continue
            # "too fast to measure" lines
            m2 = re.match(r"^\s{2}(.+?)\s{2,}.*too fast to measure", line)
            if m2:
                results[m2.group(1).strip()] = None
    return results


def fmt(n):
    if n is None:
        return "  ∞ (< 1ns)"
    return f"{n:>14,}"


def main():
    if len(sys.argv) != 3:
        print("Usage: bench_compare.py <before.txt> <after.txt>")
        print("Example: bench_compare.py benchmarks/baseline_pre_lowlevel.txt benchmarks/optim_0.2.txt")
        sys.exit(1)

    before_path, after_path = sys.argv[1], sys.argv[2]
    before = parse_benchmarks(before_path)
    after = parse_benchmarks(after_path)

    # Merge keys preserving order from 'before'
    all_names = list(before.keys())
    for name in after:
        if name not in all_names:
            all_names.append(name)

    before_label = before_path.split("/")[-1].replace(".txt", "")
    after_label = after_path.split("/")[-1].replace(".txt", "")

    print()
    print("=" * 100)
    print(f"  Benchmark Comparison: {before_label} → {after_label}")
    print("=" * 100)
    print()
    print(f"  {'Benchmark':<46} {'Before ops/s':>14}  {'After ops/s':>14}  {'Change':>10}  Verdict")
    print(f"  {'─' * 46} {'─' * 14}  {'─' * 14}  {'─' * 10}  {'─' * 10}")

    improved = regressed = neutral = new_benchmarks = 0

    for name in all_names:
        b = before.get(name)
        a = after.get(name)
        b_str = fmt(b)
        a_str = fmt(a)

        if b is None and a is None:
            verdict, change, neutral = "  ≈", "—", neutral + 1
        elif b is None or a is None:
            if b is None and a is not None:
                verdict, change, neutral = "  \033[33m?\033[0m slower?", "—", neutral + 1
            elif a is None and b is not None:
                verdict, change, improved = "  \033[32m↑\033[0m faster", "—", improved + 1
            else:
                verdict, change, neutral = "  ≈", "—", neutral + 1
        elif name not in before:
            verdict, change, new_benchmarks = "  \033[36mnew\033[0m", "—", new_benchmarks + 1
        else:
            pct = ((a - b) / b) * 100.0 if b != 0 else 0.0
            sign = "+" if pct >= 0 else ""
            change = f"{sign}{pct:.1f}%"
            if pct > TOLERANCE:
                verdict = "  \033[32m↑ faster\033[0m"
                improved += 1
            elif pct < -TOLERANCE:
                verdict = "  \033[31m↓ slower\033[0m"
                regressed += 1
            else:
                verdict = "  ≈"
                neutral += 1

        print(f"  {name:<46} {b_str}  {a_str}  {change:>10}  {verdict}")

    print()
    print("─" * 100)
    summary = f"  Summary: \033[32m{improved} improved\033[0m, \033[31m{regressed} regressed\033[0m, {neutral} neutral"
    if new_benchmarks:
        summary += f", \033[36m{new_benchmarks} new\033[0m"
    print(summary)
    print(f"  Tolerance: ±{TOLERANCE}% (changes within this range are noise)")
    print("─" * 100)
    print()

    sys.exit(1 if regressed > 0 else 0)


if __name__ == "__main__":
    main()
