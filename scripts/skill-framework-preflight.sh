#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/production/skill-framework-state.json"

baseline='BLOCKED'
if "$ROOT/scripts/baseline-integrity-gate.sh" >/tmp/xinzhao-skill-framework-baseline.out 2>/tmp/xinzhao-skill-framework-baseline.err; then
  baseline='PASS'
fi

BASELINE_STATUS="$baseline" python3 - "$ROOT" "$STATE" <<'PY'
import json
import os
import pathlib
import sys
from datetime import datetime, timezone

root = pathlib.Path(sys.argv[1])
state_path = pathlib.Path(sys.argv[2])

agents = (root / "AGENTS.md").read_text(encoding="utf-8")
production_doc = (root / "knowledge/OPENWRT-PRODUCTION-V4.md").read_text(encoding="utf-8")
v4 = json.loads((root / "production/v4-state.json").read_text(encoding="utf-8"))
known_good = json.loads((root / "production/known-good.json").read_text(encoding="utf-8"))

conflicts = []
real_device_lane = (v4.get("lanes") or {}).get("REAL_DEVICE")
if real_device_lane == "HUMAN_REVIEW_GATE":
    conflicts.append("production/v4-state.json contains HUMAN_REVIEW_GATE for REAL_DEVICE")

manual_markers = (
    "Flashing instructions must remain human-reviewed",
    "写入路由器前必须经过人工确认",
    "人工审核安全门",
)
for marker in manual_markers:
    if marker in agents or marker in production_doc:
        conflicts.append(f"stale human/manual flash policy: {marker}")

flash_method_path = root / "production/arthur-flash-method.json"
verified_flash_method = "BLOCKED"
if flash_method_path.exists():
    try:
        method = json.loads(flash_method_path.read_text(encoding="utf-8"))
        if method.get("status") == "VERIFIED" and method.get("remote_upgrader") == "/sbin/sysupgrade":
            verified_flash_method = "VERIFIED"
    except (OSError, json.JSONDecodeError):
        verified_flash_method = "BLOCKED"

baseline = os.environ.get("BASELINE_STATUS", "BLOCKED")
flash_policy_sync = "PASS" if not conflicts else "BLOCKED"
framework_mode = "SHADOW" if baseline == "PASS" and flash_policy_sync == "PASS" and verified_flash_method == "VERIFIED" else "DRY_RUN_ONLY"

state = {
    "schema_version": "0.1",
    "framework": "Agent Skill Framework",
    "project": "新肇网络Wrt-京东云亚瑟固件",
    "device": "jdcloud_re-ss-01",
    "framework_mode": framework_mode,
    "baseline_integrity": baseline,
    "flash_policy_sync": flash_policy_sync,
    "verified_flash_method": verified_flash_method,
    "production_takeover": False,
    "build_requested": False,
    "flash_requested": False,
    "known_good_tag": known_good.get("stable_tag"),
    "known_good_sha256": known_good.get("sha256"),
    "conflicts": conflicts,
    "next_action": "Implement and test framework in isolation; do not take over the active Arthur production loop.",
    "updated_at": datetime.now(timezone.utc).isoformat(),
}

state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(state, ensure_ascii=False))

if baseline != "PASS":
    raise SystemExit(2)
PY
