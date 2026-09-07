#!/usr/bin/env python3
"""
fleet-monitor.py - Data Center Ops Home Lab

Runs health-check.sh in JSON mode on every node in the fleet (locally for the
node it runs on, over SSH for the rest), aggregates the results into a single
dashboard, appends a CSV history line per check, and exits with the worst
status found so it can gate a cron job or CI step.

Designed to run on web01 (10.10.10.11), which reaches app01 (10.10.10.12) over
the private 10.10.10.0/24 link using key-based SSH.

Usage:
    ./fleet-monitor.py                    # human dashboard
    ./fleet-monitor.py --json             # machine readable
    ./fleet-monitor.py --csv /srv/data/logs/health.csv
    ./fleet-monitor.py --quiet            # only print WARN/CRIT

Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 collection error
"""

import argparse
import csv
import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone

LAB_ROOT = os.environ.get("LAB_ROOT", os.path.expanduser("~/data-center-lab"))
HEALTH_SCRIPT = os.path.join(LAB_ROOT, "monitoring", "health-check.sh")

FLEET = [
    {"name": "web01", "ip": "10.10.10.11", "transport": "local", "role": "web front-end",
     "ports": "22 80", "urls": "http://10.10.10.11/health"},
    {"name": "app01", "ip": "10.10.10.12", "transport": "ssh", "ssh_user": "sysadmin",
     "role": "application back-end", "ports": "22 8080",
     "urls": "http://10.10.10.12:8080/health"},
]

STATUS_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
RANK_EXIT = {0: 0, 1: 1, 2: 2, 3: 3}

COLOURS = {"OK": "\033[32m", "WARN": "\033[33m", "CRIT": "\033[31m",
           "UNKNOWN": "\033[35m", "OFF": "\033[0m", "HDR": "\033[1;36m"}


def colour(text, status, enabled):
    if not enabled:
        return text
    return f"{COLOURS.get(status, '')}{text}{COLOURS['OFF']}"


def build_command(node, peer_ip):
    """Return the argv used to collect JSON health data from one node."""
    ports = node.get("ports", "22")
    urls = node.get("urls", "")
    remote = f"{HEALTH_SCRIPT} -j -p {peer_ip} -l {shlex.quote(ports)} -u {shlex.quote(urls)}"
    if node["transport"] == "local":
        return ["bash", HEALTH_SCRIPT, "-j", "-p", peer_ip, "-l", ports, "-u", urls]
    return [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
        "-o", "StrictHostKeyChecking=accept-new",
        f"{node['ssh_user']}@{node['ip']}", remote,
    ]


def collect(node, peer_ip, timeout=45):
    """Run the health check on a node and return its parsed JSON payload."""
    cmd = build_command(node, peer_ip)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"host": node["name"], "ip": node["ip"], "overall": "UNKNOWN",
                "error": f"collection timed out after {timeout}s", "checks": []}
    except FileNotFoundError as exc:
        return {"host": node["name"], "ip": node["ip"], "overall": "UNKNOWN",
                "error": str(exc), "checks": []}

    stdout = proc.stdout.strip()
    if not stdout:
        return {"host": node["name"], "ip": node["ip"], "overall": "UNKNOWN",
                "error": f"no output (rc={proc.returncode}): {proc.stderr.strip()[:200]}",
                "checks": []}
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as exc:
        return {"host": node["name"], "ip": node["ip"], "overall": "UNKNOWN",
                "error": f"unparseable output: {exc}", "checks": []}

    data["node"] = node["name"]
    data["role"] = node["role"]
    data["ip"] = node["ip"]
    data["transport"] = node["transport"]
    return data


def worst_status(results):
    rank = 0
    for res in results:
        for chk in res.get("checks", []):
            rank = max(rank, STATUS_RANK.get(chk["status"], 3))
        if res.get("overall") == "UNKNOWN":
            rank = max(rank, 3)
    return rank


def print_dashboard(results, quiet, use_colour):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    width = 74
    print("=" * width)
    print(f" FLEET HEALTH DASHBOARD                          {now}")
    print("=" * width)

    for res in results:
        node = res.get("node", res.get("host", "?"))
        overall = res.get("overall", "UNKNOWN")
        badge = {"OK": "OK", "WARNING": "WARN", "CRITICAL": "CRIT"}.get(overall, "UNKNOWN")
        head = f"\n{node}  ({res.get('ip')})  role={res.get('role', '-')}  via={res.get('transport', '-')}"
        print(head)
        print(f"  status: {colour(badge, badge, use_colour)}")

        if res.get("error"):
            print(f"  ERROR : {res['error']}")
            continue

        counts = {"OK": 0, "WARN": 0, "CRIT": 0}
        for chk in res["checks"]:
            counts[chk["status"]] = counts.get(chk["status"], 0) + 1
        print(f"  checks: {counts.get('OK', 0)} OK / {counts.get('WARN', 0)} WARN / "
              f"{counts.get('CRIT', 0)} CRIT")

        for chk in res["checks"]:
            if quiet and chk["status"] == "OK":
                continue
            tag = colour(f"{chk['status']:<4}", chk["status"], use_colour)
            print(f"    {tag}  {chk['check']:<26} {chk['detail']}")

    # Cross-node summary of anything not OK
    problems = [(res.get("node"), c) for res in results for c in res.get("checks", [])
                if c["status"] != "OK"]
    print("\n" + "=" * width)
    if not problems and all(r.get("overall") != "UNKNOWN" for r in results):
        print(" FLEET: " + colour("ALL SYSTEMS OK", "OK", use_colour))
    else:
        print(f" FLEET: {len(problems)} issue(s) requiring attention")
        for node, chk in problems:
            print(f"   - {node}: [{chk['status']}] {chk['check']} - {chk['detail']}")
        for res in results:
            if res.get("error"):
                print(f"   - {res.get('node')}: [UNKNOWN] collection failed - {res['error']}")
    print("=" * width)


def append_csv(path, results):
    new_file = not os.path.exists(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    stamp = datetime.now(timezone.utc).isoformat()
    with open(path, "a", newline="") as fh:
        writer = csv.writer(fh)
        if new_file:
            writer.writerow(["timestamp", "node", "ip", "check", "status", "value", "detail"])
        for res in results:
            for chk in res.get("checks", []):
                writer.writerow([stamp, res.get("node"), res.get("ip"), chk["check"],
                                 chk["status"], chk.get("value", ""), chk["detail"]])
    return path


def main():
    ap = argparse.ArgumentParser(description="Aggregate health across the lab fleet")
    ap.add_argument("--json", action="store_true", help="emit aggregated JSON")
    ap.add_argument("--quiet", action="store_true", help="only show non-OK checks")
    ap.add_argument("--csv", metavar="PATH", help="append results to a CSV history file")
    ap.add_argument("--no-colour", action="store_true")
    args = ap.parse_args()

    use_colour = sys.stdout.isatty() and not args.no_colour and not args.json

    results = []
    for node in FLEET:
        peer = next(n["ip"] for n in FLEET if n["name"] != node["name"])
        results.append(collect(node, peer))

    if args.csv:
        append_csv(args.csv, results)

    rank = worst_status(results)

    if args.json:
        print(json.dumps({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "fleet_status": ["OK", "WARNING", "CRITICAL", "UNKNOWN"][rank],
            "nodes": results,
        }, indent=2))
    else:
        print_dashboard(results, args.quiet, use_colour)

    sys.exit(RANK_EXIT[rank])


if __name__ == "__main__":
    main()
