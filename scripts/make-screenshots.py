#!/usr/bin/env python3
"""
make-screenshots.py

The lab host is headless, so "screenshots" are produced by rendering the real
captured command output in evidence/ into terminal-style PNG images. Nothing is
retyped or edited: each image is a slice of a capture file, and the window title
names the source file so any image can be traced back to its evidence.

Slices are located by matching marker text rather than fixed line numbers, so
edits to the capture files cannot silently shift what an image shows.

Usage:
    python3 make-screenshots.py [evidence_dir] [screenshot_dir]

Defaults: evidence/ -> screenshots/
"""

import os
import re
import sys
from PIL import Image, ImageDraw, ImageFont

# --- appearance -------------------------------------------------------------
FONT_REGULAR = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
]
FONT_BOLD = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
]

BG, CHROME, TITLE = (24, 26, 32), (44, 47, 56), (176, 183, 196)
TEXT, PROMPT, COMMENT = (214, 219, 227), (126, 200, 255), (128, 137, 154)
GREEN, YELLOW, RED, CYAN = (126, 211, 141), (232, 193, 106), (232, 118, 118), (108, 205, 205)

FONT_SIZE, LINE_HEIGHT, PAD, CHROME_H = 15, 21, 18, 34
MAX_LINES, MAX_COLS = 46, 108


def load_font(paths, size):
    for path in paths:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


FONT = load_font(FONT_REGULAR, FONT_SIZE)
FONT_B = load_font(FONT_BOLD, FONT_SIZE)
FONT_TITLE = load_font(FONT_BOLD, 13)


def colour_for(line):
    """Colour a whole line by its shape, approximating terminal highlighting."""
    stripped = line.strip()
    if stripped.startswith(("$", "[web01", "[app01")):
        return PROMPT, FONT_B
    if stripped.startswith(("###", "===", "---")):
        return CYAN, FONT_B
    if re.search(r"\b(CRIT|CRITICAL|FAILED|emerg|Permission denied|refused|DEGRADED|"
                 r"No such file|Address already in use|100% packet loss|error)\b", line):
        return RED, FONT
    if re.search(r"\b(WARN|WARNING|INCOMPLETE|notice)\b", line):
        return YELLOW, FONT
    if re.search(r"\b(OK|LISTEN|REACHABLE|ACCEPT|Accepted|SUCCESSFUL|RESTORED|"
                 r"0% packet loss|HTTP 200|syntax is ok|successful|ready)\b", line):
        return GREEN, FONT
    if stripped.startswith(("#", "NOTE", "(", "^")):
        return COMMENT, FONT
    return TEXT, FONT


def render(lines, title, out_path):
    lines = [line.replace("\t", "    ").rstrip("\r\n") for line in lines]
    lines = [ln if len(ln) <= MAX_COLS else ln[:MAX_COLS - 1] + "\u2026" for ln in lines]
    if len(lines) > MAX_LINES:
        lines = lines[:MAX_LINES - 1] + ["\u2026 (output truncated for the screenshot)"]

    width = PAD * 2 + int(MAX_COLS * FONT_SIZE * 0.601)
    height = CHROME_H + PAD * 2 + LINE_HEIGHT * max(len(lines), 4)

    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img)

    draw.rectangle([0, 0, width, CHROME_H], fill=CHROME)
    for i, colour in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = 18 + i * 20
        draw.ellipse([cx - 6, CHROME_H // 2 - 6, cx + 6, CHROME_H // 2 + 6], fill=colour)
    draw.text((88, CHROME_H // 2 - 7), title, font=FONT_TITLE, fill=TITLE)

    y = CHROME_H + PAD
    for line in lines:
        colour, font = colour_for(line)
        draw.text((PAD, y), line, font=font, fill=colour)
        y += LINE_HEIGHT

    img.save(out_path)
    return width, height


def slice_between(lines, start_marker, end_marker, max_lines=MAX_LINES):
    """Return lines from the first start_marker up to (not including) end_marker."""
    start = next((i for i, ln in enumerate(lines) if start_marker in ln), None)
    if start is None:
        return None
    if end_marker:
        end = next((i for i, ln in enumerate(lines[start + 1:], start + 1)
                    if end_marker in ln), len(lines))
    else:
        end = len(lines)
    return lines[start:min(end, start + max_lines)]


# (output name, capture file, start marker, end marker, window title)
SHOTS = [
    ("01-network-connectivity.png", "01-network-setup.txt",
     "ip netns exec web01 ip -brief addr show", "ip netns exec web01 ip neigh show",
     "web01 / app01 - static addressing, routes and bidirectional ping"),

    ("02-ssh-validation.png", "01-network-setup.txt",
     "ip netns exec web01 ip neigh show", None,
     "ARP table, listening sockets, cross-host HTTP and key-based SSH"),

    ("03-users-permissions.png", "02-users-permissions-firewall.txt",
     "/etc/passwd", "$ getfacl /srv/webcontent",
     "Users, groups and managed directory permissions"),

    ("04-acls-and-sudo.png", "02-users-permissions-firewall.txt",
     "$ getfacl /srv/webcontent", "FIREWALL - app01",
     "POSIX ACLs, live permission proofs and sudo policy"),

    ("05-firewall-rules.png", "02-users-permissions-firewall.txt",
     "FIREWALL - app01", None,
     "app01 - default-deny INPUT chain with packet counters"),

    ("06-nginx-service.png", "06-service-management.txt",
     "1. STATUS", "4. STOP",
     "nginx service lifecycle - status, config validation, reload"),

    ("07-health-monitor.png", "08-health-check.txt",
     "SERVER HEALTH REPORT", "########## app01",
     "health-check.sh on web01"),

    ("08-fleet-monitor.png", "09-fleet-monitor.txt",
     "FLEET HEALTH DASHBOARD", None,
     "fleet-monitor.py - both nodes collected, app01 over SSH"),

    ("09-raid-capability-check.png", "07-raid1-mirror-drill.txt",
     "1. Kernel md (RAID) subsystem check", "2. Mirror drill",
     "RAID1: kernel md subsystem check - driver absent, documented not worked around"),

    ("10-raid1-simulation.png", "07-raid1-mirror-drill.txt",
     "4. Simulate disk failure", None,
     "RAID1 lifecycle simulation: member failure, degraded operation, rebuild, verify"),

    ("INC-001-triage.png", "inc-01-network.txt",
     "2. SYMPTOM", "Confirm from the peer side",
     "INC-001 network outage - symptom and layered triage"),

    ("INC-002-root-cause.png", "inc-02-ssh.txt",
     "3b. Verbose client output", "ROOT CAUSE",
     "INC-002 SSH lockout - verbose client trace and server-side root cause"),

    ("INC-003-triage.png", "inc-03-service.txt",
     "2. SYMPTOM", "3e. Identify the squatting process",
     "INC-003 service outage - config error and port conflict"),

    ("INC-003-resolution.png", "inc-03-service.txt",
     "4. FIX", None,
     "INC-003 service outage - fix and verification"),

    ("INC-004-symptom.png", "inc-04-diskfull.txt",
     "2. SYMPTOM", "3b. Walk down the tree",
     "INC-004 disk full - ENOSPC as the app user, root still writing into the reserve"),

    ("INC-004-du-vs-df.png", "inc-04-diskfull.txt",
     "5. THE TRAP", "6c. Identify the holder",
     "INC-004 - du says empty, df says full: a deleted file still held open"),

    ("INC-004-resolution.png", "inc-04-diskfull.txt",
     "7. RECLAIM THE SPACE", None,
     "INC-004 - reclaiming space through /proc/<pid>/fd without a restart"),

    ("INC-005-triage.png", "inc-05-permissions.txt",
     "2. SYMPTOM", "3e. Walk every component",
     "INC-005 - HTTP 403, error log errno 13, and the worker's real user"),

    ("INC-005-resolution.png", "inc-05-permissions.txt",
     "4. TRIAGE - part B", None,
     "INC-005 - group model restored, SGID inheritance verified"),
]


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "evidence"
    dst = sys.argv[2] if len(sys.argv) > 2 else "screenshots"
    os.makedirs(dst, exist_ok=True)

    made = 0
    for name, capture, start_marker, end_marker, title in SHOTS:
        path = os.path.join(src, capture)
        if not os.path.exists(path):
            print(f"SKIP {name}: missing {capture}")
            continue
        with open(path, errors="replace") as handle:
            lines = handle.readlines()
        chunk = slice_between(lines, start_marker, end_marker)
        if not chunk:
            print(f"SKIP {name}: marker not found in {capture} ({start_marker!r})")
            continue
        width, height = render(chunk, f"{title}    [source: evidence/{capture}]",
                               os.path.join(dst, name))
        print(f"{name:32s} {width}x{height}  <- {capture} ({len(chunk)} lines)")
        made += 1
    print(f"\n{made} screenshots written to {dst}/")


if __name__ == "__main__":
    main()
