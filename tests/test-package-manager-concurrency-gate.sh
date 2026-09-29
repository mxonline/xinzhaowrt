#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-package-manager-concurrency-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -x "$GATE" ]] || {
  echo "FAIL: package-manager concurrency gate must be executable" >&2
  exit 1
}

cat > "$TMP/idle.ps" <<'EOF'
  PID USER       VSZ STAT COMMAND
    1 root      1600 S    /sbin/procd
  812 root      3000 S    /usr/sbin/uhttpd
EOF

idle_out="$(PACKAGE_MANAGER_PS_FILE="$TMP/idle.ps" "$GATE")"
grep -Fxq 'PACKAGE_MANAGER_CONCURRENCY_GATE=PASS' <<<"$idle_out"
grep -Fxq 'PACKAGE_MANAGER_SINGLE_FLIGHT=PASS' <<<"$idle_out"
grep -Fxq 'REPEATED_UPDATE_AUTHORIZED=YES' <<<"$idle_out"

for case_name in apk luci quickstart; do
  case "$case_name" in
    apk)
      line=' 2100 root  4100 S apk update -v'
      ;;
    luci)
      line=' 2101 root  4100 S /usr/libexec/package-manager-call update'
      ;;
    quickstart)
      line=' 2102 root  4100 S /usr/libexec/quickstart health apk update'
      ;;
  esac
  printf 'PID USER VSZ STAT COMMAND\n%s\n' "$line" > "$TMP/$case_name.ps"
  set +e
  out="$(PACKAGE_MANAGER_PS_FILE="$TMP/$case_name.ps" "$GATE" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 2 ]] || {
    echo "FAIL: $case_name active updater must block the gate, rc=$rc" >&2
    exit 1
  }
  grep -Fxq 'PACKAGE_MANAGER_CONCURRENCY_GATE=BLOCKED' <<<"$out"
  grep -Fxq 'REPEATED_UPDATE_AUTHORIZED=NO' <<<"$out"
  grep -Fxq 'FIRST_REAL_ERROR=PACKAGE_MANAGER_UPDATE_ALREADY_RUNNING' <<<"$out"
done

python3 - "$ROOT/production/product-goal-contract.json" <<'PY'
import json, sys
contract=json.load(open(sys.argv[1], encoding='utf-8'))
gate=contract['package_manager_concurrency_gate']
assert gate['required'] is True
assert gate['single_flight_required'] is True
assert gate['unknown_concurrency_fails_closed'] is True
assert gate['repeated_update_forbidden_until_gate_passes'] is True
assert gate['diagnostic_order'] == ['PACKAGE_MANAGER_CONCURRENCY','DNS_TLS_ROUTING','MIRROR_REPLACEMENT']
assert gate['machine_gate_script'] == 'scripts/check-package-manager-concurrency-gate.sh'
assert gate['package_source_change_build_requires_live_concurrency_gate_pass'] is True
assert set(gate['clients_must_serialize']) == {
    'CLI_APK_UPDATE','LUCI_PACKAGE_MANAGER_REFRESH','QUICKSTART_PACKAGE_SOURCE_HEALTH_CHECK'
}
PY

echo 'PACKAGE_MANAGER_CONCURRENCY_GATE_REGRESSION=PASS'
