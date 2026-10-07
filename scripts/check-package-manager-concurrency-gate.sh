#!/bin/sh
set -eu

snapshot_file="${PACKAGE_MANAGER_PS_FILE:-}"
if [ -n "$snapshot_file" ]; then
  [ -f "$snapshot_file" ] || {
    echo "PACKAGE_MANAGER_CONCURRENCY_GATE=FAIL"
    echo "PACKAGE_MANAGER_SINGLE_FLIGHT=UNKNOWN"
    echo "REPEATED_UPDATE_AUTHORIZED=NO"
    echo "FIRST_REAL_ERROR=PROCESS_SNAPSHOT_MISSING"
    exit 2
  }
  ps_snapshot="$(cat "$snapshot_file")"
else
  ps_snapshot="$(ps w 2>/dev/null || ps 2>/dev/null || true)"
fi

matches="$(
  printf '%s\n' "$ps_snapshot" |
    grep -E '([[:space:]/]|^)apk([[:space:]]+[^[:space:]]+)*[[:space:]]+update([[:space:]]|$)|/usr/libexec/package-manager-call[[:space:]]+update([[:space:]]|$)|quickstart.*apk[[:space:]]+update([[:space:]]|$)' |
    grep -v 'check-package-manager-concurrency-gate' || true
)"

if [ -n "$matches" ]; then
  count="$(printf '%s\n' "$matches" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
else
  count=0
fi

echo "PACKAGE_MANAGER_ACTIVE_UPDATE_PROCESSES=$count"

if [ "$count" -ne 0 ]; then
  echo "PACKAGE_MANAGER_CONCURRENCY_GATE=BLOCKED"
  echo "PACKAGE_MANAGER_SINGLE_FLIGHT=UNKNOWN"
  echo "REPEATED_UPDATE_AUTHORIZED=NO"
  echo "FIRST_REAL_ERROR=PACKAGE_MANAGER_UPDATE_ALREADY_RUNNING"
  printf '%s\n' "$matches" | sed 's/^/ACTIVE_UPDATE: /'
  exit 2
fi

echo "PACKAGE_MANAGER_CONCURRENCY_GATE=PASS"
echo "PACKAGE_MANAGER_SINGLE_FLIGHT=PASS"
echo "REPEATED_UPDATE_AUTHORIZED=YES"
