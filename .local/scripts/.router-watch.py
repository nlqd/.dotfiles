#!/usr/bin/env python3
"""Ping-based monitor for 3 routers via secondary IPs. Reports latency stats and stability analysis."""

import subprocess
import sys
import time
import statistics
import re

ROUTERS = [
    (".1", "192.168.1.211", "8.8.8.8"),
    (".2", "192.168.1.212", "8.8.8.8"),
    (".3", "192.168.1.213", "8.8.8.8"),
]

RED = "\033[0;31m"
YEL = "\033[0;33m"
GRN = "\033[0;32m"
DIM = "\033[2m"
RST = "\033[0m"
BOLD = "\033[1m"


def ping_once(bind_ip, target, timeout=2):
    try:
        out = subprocess.run(
            ["ping", "-c", "1", "-W", str(timeout), "-I", bind_ip, target],
            capture_output=True, text=True, timeout=timeout + 1,
        )
        m = re.search(r"time=([0-9.]+)", out.stdout)
        if m:
            return float(m.group(1))
    except (subprocess.TimeoutExpired, OSError):
        pass
    return None


def percentile(data, p):
    s = sorted(data)
    k = (len(s) - 1) * p / 100
    f = int(k)
    c = f + 1
    if c >= len(s):
        return s[f]
    return s[f] + (k - f) * (s[c] - s[f])


def analyze(label, samples, total_sent):
    hits = [s for s in samples if s is not None]
    loss_count = total_sent - len(hits)
    loss_pct = loss_count * 100 / total_sent if total_sent > 0 else 0

    if not hits:
        return {
            "label": label, "min": 0, "avg": 0, "p50": 0, "p95": 0,
            "max": 0, "loss": loss_pct, "jitter": 0, "verdict": "DOWN",
        }

    mn = min(hits)
    mx = max(hits)
    avg = statistics.mean(hits)
    p50 = percentile(hits, 50)
    p95 = percentile(hits, 95)
    stdev = statistics.stdev(hits) if len(hits) > 1 else 0

    issues = []
    if loss_pct > 5:
        issues.append(f"high packet loss ({loss_pct:.0f}%)")
    elif loss_pct > 1:
        issues.append(f"some packet loss ({loss_pct:.1f}%)")
    if p95 > 100:
        issues.append(f"latency spikes (p95={p95:.0f}ms)")
    if stdev > 20:
        issues.append(f"high jitter (stdev={stdev:.0f}ms)")
    if p95 / p50 > 3 and p50 > 5:
        issues.append(f"inconsistent (p95/p50={p95/p50:.1f}x)")

    if issues:
        verdict = "; ".join(issues)
    else:
        verdict = "stable"

    return {
        "label": label, "min": mn, "avg": avg, "p50": p50, "p95": p95,
        "max": mx, "loss": loss_pct, "jitter": stdev, "verdict": verdict,
    }


def run_watch(duration_s, interval=0.5):
    for _, bind_ip, _ in ROUTERS:
        result = subprocess.run(
            ["ip", "addr", "show", "dev", "eno2"],
            capture_output=True, text=True,
        )
        if bind_ip not in result.stdout:
            print(f"{RED}error: {bind_ip} not found on eno2. Run 'sudo router-status --setup' first.{RST}")
            sys.exit(1)

    samples = {r[0]: [] for r in ROUTERS}
    total_sent = 0
    end_time = time.time() + duration_s

    dur_label = f"{duration_s}s" if duration_s < 60 else f"{duration_s // 60}m"
    print(f"\n{BOLD}Monitoring{RST}  {DIM}{dur_label}, pinging every {interval}s{RST}")
    print(f"{DIM}press Ctrl+C to stop early{RST}\n")

    try:
        while time.time() < end_time:
            total_sent += 1
            remaining = int(end_time - time.time())

            # ping all 3 in parallel using subprocess
            procs = {}
            for label, bind_ip, target in ROUTERS:
                procs[label] = subprocess.Popen(
                    ["ping", "-c", "1", "-W", "2", "-I", bind_ip, target],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )

            for label, bind_ip, target in ROUTERS:
                try:
                    out, _ = procs[label].communicate(timeout=3)
                    m = re.search(r"time=([0-9.]+)", out)
                    if m:
                        samples[label].append(float(m.group(1)))
                    else:
                        samples[label].append(None)
                except subprocess.TimeoutExpired:
                    procs[label].kill()
                    samples[label].append(None)

            # live status line
            parts = []
            for label, _, _ in ROUTERS:
                last = samples[label][-1]
                if last is None:
                    parts.append(f"{RED}{label}:LOST{RST}")
                elif last > 50:
                    parts.append(f"{YEL}{label}:{last:.0f}ms{RST}")
                else:
                    parts.append(f"{label}:{last:.0f}ms")
            status = "  ".join(parts)
            print(f"  {DIM}[{remaining:3d}s]{RST} {status}    ", end="\r", flush=True)

            time.sleep(interval)
    except KeyboardInterrupt:
        pass

    print(" " * 60, end="\r")

    # analyze
    results = []
    for label, _, _ in ROUTERS:
        results.append(analyze(label, samples[label], total_sent))

    # print report
    print(f"{BOLD}Results{RST}  {DIM}{total_sent} pings{RST}\n")

    # find any unstable routers
    unstable = [r for r in results if r["verdict"] != "stable"]
    if unstable:
        print(f"{BOLD}{RED}Unstable{RST}")
        for r in unstable:
            print(f"  {RED}{r['label']}: {r['verdict']}{RST}")
        print()

    # table
    header = f"{'Router':<8} {'min':>5} {'avg':>5} {'p50':>5} {'p95':>5} {'max':>5} {'loss':>6} {'jitter':>6}  {'verdict'}"
    print(f"{DIM}{header}{RST}")

    for r in results:
        loss_str = f"{r['loss']:.1f}%"
        jitter_str = f"{r['jitter']:.1f}"

        if r["verdict"] == "DOWN":
            color = RED
        elif r["verdict"] != "stable":
            color = YEL
        else:
            color = ""

        end_color = RST if color else ""
        line = f"{color}{r['label']:<8} {r['min']:5.0f} {r['avg']:5.1f} {r['p50']:5.0f} {r['p95']:5.0f} {r['max']:5.0f} {loss_str:>6} {jitter_str:>6}  {r['verdict']}{end_color}"
        print(line)

    print()


def parse_duration(s):
    s = s.strip().lower()
    if s.endswith("s"):
        return int(s[:-1])
    if s.endswith("m"):
        return int(s[:-1]) * 60
    return int(s)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} DURATION (e.g., 30s, 1m, 5m)", file=sys.stderr)
        sys.exit(1)
    duration = parse_duration(sys.argv[1])
    run_watch(duration)
