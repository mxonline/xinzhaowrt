#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cat > "$fixture/input.json" <<'JSON'
{
  "test_mode": "POST_RELEASE_DEVICE_TEST",
  "connection": {"status": "PASS", "error": null},
  "updater": {"events": ["download", "replace", "chmod", "execute"], "candidate_paths": ["/tmp/openclash-core-update/123/clash_meta.new"], "samples": [{"pid": "123", "rss_kb": "2048", "pss_kb": "1800"}], "peak_rss_kb": 2048, "peak_pss_kb": 1800},
  "mihomo": {"processes": [{"pid": "456", "rss_kb": "32768", "pss_kb": "30100", "exe": "/etc/openclash/core/mihomo"}], "samples": [], "peak_rss_kb": 32768, "peak_pss_kb": 30100},
  "memory": {"samples": [65536, 64000], "memavailable_floor_kb": 64000},
  "resident_services": {"adguardhome": [], "quickfile": [], "quickstart": [], "init_state": []},
  "sysupgrade_preserved_state": {"uci": ["adguardhome.enabled=0"], "init_links": [], "disable_logic_observed": true},
  "concurrency": {"updater_pids": [{"name": "openclash_core.sh", "pids": "123"}], "lock_state": ["held"], "simultaneous_candidates": false},
  "segfaults": {"actual_binary_argv": [{"exe": "/tmp/openclash-core-update/123/clash_meta.new", "argv": "/tmp/openclash-core-update/123/clash_meta.new -v", "pid": "123"}], "log_excerpt": ["SIGSEGV"], "evidence_status": "PRESENT"}
}
JSON

PWSH_BIN="${PWSH_BIN:-pwsh}"
if command -v "$PWSH_BIN" >/dev/null 2>&1; then
  PWSH_BIN="$(command -v "$PWSH_BIN")"
else
  PWSH_BIN='/c/Users/chenz/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
fi
if [[ ! -x "$PWSH_BIN" && ! -f "$PWSH_BIN" ]]; then
  echo 'OPENCLASH_RUNTIME_FORENSICS=SKIP no pwsh on host'
  exit 0
fi
"$PWSH_BIN" -NoProfile -File "$root/scripts/openclash-runtime-forensics.ps1" \
  -DeviceIp 127.0.0.1 -OutFile "$fixture/forensics.json" -FixtureFile "$fixture/input.json"

PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || PYTHON_BIN=python
"$PYTHON_BIN" - "$fixture/forensics.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
assert data['test_mode'] == 'POST_RELEASE_DEVICE_TEST'
for key in ('updater', 'mihomo', 'memory', 'resident_services', 'segfaults'):
    assert key in data, key
assert data['updater']['events']
assert data['memory']['samples']
assert data['segfaults']['actual_binary_argv']
PY

echo 'OPENCLASH_RUNTIME_FORENSICS=PASS'
