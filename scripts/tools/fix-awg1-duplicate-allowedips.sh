#!/usr/bin/env bash
# Fix duplicate awg1 AllowedIPs on VPS1.
#
# Default mode applies the fix. Use --dry-run to only print the planned changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
elif [[ -n "${1:-}" ]]; then
    echo "Usage: bash scripts/tools/fix-awg1-duplicate-allowedips.sh [--dry-run]" >&2
    exit 2
fi

VPS1_IP=""
VPS1_USER=""
VPS1_KEY=""
VPS1_PASS=""
load_defaults_from_files

VPS1_USER="${VPS1_USER:-root}"
VPS1_KEY="$(expand_tilde "${VPS1_KEY}")"
[[ -z "${VPS1_PASS}" ]] && VPS1_KEY="$(auto_pick_key_if_missing "${VPS1_KEY}")"
VPS1_KEY="$(prepare_key_for_ssh "${VPS1_KEY}")"
trap cleanup_temp_keys EXIT

require_vars "fix-awg1-duplicate-allowedips.sh" VPS1_IP VPS1_USER
if [[ -z "${VPS1_KEY}" && -z "${VPS1_PASS}" ]]; then
    err "VPS1_KEY or VPS1_PASS is required"
fi

ssh_args=(-F /dev/null -o ControlMaster=no -o ControlPath=none
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
          -o BatchMode=no -o LogLevel=ERROR)

remote=(ssh "${ssh_args[@]}")
if [[ -n "${VPS1_KEY}" && -f "${VPS1_KEY}" ]]; then
    remote+=(-i "${VPS1_KEY}")
fi
remote+=("${VPS1_USER}@${VPS1_IP}")

mode="apply"
[[ "${DRY_RUN}" == "1" ]] && mode="dry-run"

cat <<'PY' | "${remote[@]}" "sudo VPN_FIX_MODE='${mode}' python3 -"
import os
import shutil
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

CONF = Path("/etc/amnezia/amneziawg/awg1.conf")
MODE = os.environ.get("VPN_FIX_MODE", "apply")
DRY_RUN = MODE == "dry-run"


def run(cmd):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)


def parse_conf(text):
    lines = text.splitlines(keepends=True)
    peers = []
    current = None
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "[Peer]":
            if current is not None:
                current["end"] = idx
            current = {"start": idx, "end": len(lines), "public_key": "", "allowed": ""}
            peers.append(current)
        elif current is not None and stripped.startswith("PublicKey"):
            current["public_key"] = stripped.split("=", 1)[1].strip()
        elif current is not None and stripped.startswith("AllowedIPs"):
            current["allowed"] = stripped.split("=", 1)[1].strip()
    return lines, peers


def runtime_dump():
    out = run(["awg", "show", "awg1", "dump"]).splitlines()[1:]
    result = {}
    for line in out:
        parts = line.split("\t")
        if len(parts) >= 8:
            result[parts[0]] = {
                "endpoint": parts[2],
                "allowed": parts[3],
                "handshake": int(parts[4] or 0),
                "rx": int(parts[5] or 0),
                "tx": int(parts[6] or 0),
            }
    return result


def score(peer, rt, now):
    info = rt.get(peer["public_key"], {})
    endpoint = info.get("endpoint", "(none)") != "(none)"
    hs = info.get("handshake", 0)
    has_hs = hs > 0
    age = now - hs if hs else 10**9
    transfer = info.get("rx", 0) + info.get("tx", 0)
    rt_allowed_matches = info.get("allowed") == peer["allowed"]
    return (1 if endpoint else 0, 1 if has_hs else 0, -age, 1 if rt_allowed_matches else 0, transfer)


if not CONF.exists():
    print(f"ERROR: missing {CONF}", file=sys.stderr)
    sys.exit(1)

text = CONF.read_text()
lines, peers = parse_conf(text)
rt = runtime_dump()
now = int(time.time())

by_ip = defaultdict(list)
for peer in peers:
    if not peer["public_key"] or not peer["allowed"]:
        continue
    ip = peer["allowed"].split("/")[0]
    by_ip[ip].append(peer)

to_remove = []
to_keep = []
for ip, items in sorted(by_ip.items()):
    if len(items) <= 1:
        continue
    keep = max(items, key=lambda p: score(p, rt, now))
    to_keep.append((ip, keep))
    for peer in items:
        if peer is not keep:
            to_remove.append((ip, peer, keep))

print(f"mode={MODE}")
if not to_remove:
    print("No duplicate AllowedIPs found.")
    sys.exit(0)

print("Planned duplicate fixes:")
for ip, peer, keep in to_remove:
    r_peer = rt.get(peer["public_key"], {})
    r_keep = rt.get(keep["public_key"], {})
    print(
        f"- ip={ip} keep={keep['public_key'][:16]} "
        f"keep_endpoint={r_keep.get('endpoint', 'missing')} "
        f"keep_allowed_runtime={r_keep.get('allowed', 'missing')} "
        f"remove={peer['public_key'][:16]} "
        f"remove_endpoint={r_peer.get('endpoint', 'missing')} "
        f"remove_allowed_runtime={r_peer.get('allowed', 'missing')}"
    )

if DRY_RUN:
    sys.exit(0)

backup = CONF.with_suffix(CONF.suffix + f".bak.{time.strftime('%Y%m%d-%H%M%S')}")
shutil.copy2(CONF, backup)

remove_ranges = {(peer["start"], peer["end"]) for _, peer, _ in to_remove}
new_lines = []
idx = 0
while idx < len(lines):
    matched = None
    for start, end in remove_ranges:
        if idx == start:
            matched = end
            break
    if matched is not None:
        idx = matched
        continue
    new_lines.append(lines[idx])
    idx += 1
CONF.write_text("".join(new_lines))

for ip, peer, keep in to_remove:
    subprocess.run(["awg", "set", "awg1", "peer", peer["public_key"], "remove"], check=False)
for ip, keep in to_keep:
    subprocess.run(["awg", "set", "awg1", "peer", keep["public_key"], "allowed-ips", f"{ip}/32"], check=True)

print(f"Backup: {backup}")
print("Applied runtime and config changes.")

rt_after = runtime_dump()
bad = []
for pub, info in rt_after.items():
    if info.get("allowed") == "(none)" and info.get("endpoint") != "(none)":
        bad.append(pub[:16])
if bad:
    print("WARNING: peers with endpoint but no AllowedIPs remain: " + ", ".join(bad))
    sys.exit(3)
print("Post-check OK: no endpoint peers with AllowedIPs=(none).")
PY
