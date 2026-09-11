#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FEED_CHECK_ROOT="${FEED_CHECK_ROOT:?FEED_CHECK_ROOT must point to the prepared source root}"
SOURCE="${OPENCLASH_YML_SOURCE:-$FEED_CHECK_ROOT/.xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/yml_change.sh}"
YAML_SOURCE="${OPENCLASH_YAML_SOURCE:-$FEED_CHECK_ROOT/.xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/YAML.rb}"

[[ -f "$SOURCE" ]] || {
  echo "FAIL: OpenClash YAML rewrite source is missing: $SOURCE" >&2
  exit 1
}
[[ -f "$YAML_SOURCE" ]] || {
  echo "FAIL: OpenClash YAML helper source is missing: $YAML_SOURCE" >&2
  exit 1
}

grep -Fq "'device' => 'utun'" "$SOURCE" || {
  echo "FAIL: YAML rewrite must preserve OpenClash's expected TUN device" >&2
  exit 1
}
grep -Fq "Dir.children('/sys/class/net')" "$SOURCE" || {
  echo "FAIL: YAML rewrite must enumerate network devices without a shell fork" >&2
  exit 1
}
if grep -Fq '%x{ls -l /sys/class/net/' "$SOURCE"; then
  echo "FAIL: YAML rewrite still forks ls/awk while building local_exclude" >&2
  exit 1
fi
grep -Fq "File.foreach('/etc/config/openclash')" "$YAML_SOURCE" || {
  echo "FAIL: YAML helper must read age settings without spawning a shell" >&2
  exit 1
}
if grep -Fq 'IO.popen(cmd_public' "$YAML_SOURCE" || grep -Fq 'IO.popen(cmd_secret' "$YAML_SOURCE"; then
  echo "FAIL: YAML helper still forks /bin/sh for age settings" >&2
  exit 1
fi

echo "PASS: OpenClash YAML rewrite avoids shell forks and retains device: utun"
