#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

STATE="$TEST_ROOT/state"
BIN="$TEST_ROOT/bin"
mkdir -p "$STATE" "$BIN"
printf '%s\n' '192.168.1.1/24' > "$STATE/network.lan.ipaddr"
printf '%s\n' 'root:$6$already-set$hash:0:0:99999:7:::' > "$TEST_ROOT/shadow"

cat > "$BIN/uci" <<'UCI'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${TEST_UCI_STATE:?}"
log="${TEST_UCI_LOG:?}"
quiet=0
[[ "${1:-}" == '-q' ]] && { quiet=1; shift; }
command="${1:?uci command required}"
shift
key_file() { printf '%s/%s' "$state" "${1//\//_}"; }
case "$command" in
  get)
    key="${1:?uci key required}"
    file="$(key_file "$key")"
    [[ -f "$file" ]] || exit 1
    cat "$file"
    ;;
  set)
    assignment="${1:?uci assignment required}"
    key="${assignment%%=*}"
    value="${assignment#*=}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s\n' "$value" > "$(key_file "$key")"
    ;;
  batch)
    staged="$state/.batch"
    : > "$staged"
    committed=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        set\ *) printf '%s\n' "${line#set }" >> "$staged" ;;
        commit\ xinzhaowrt) committed=1 ;;
      esac
    done
    if (( committed )); then
      while IFS= read -r assignment; do
        key="${assignment%%=*}"
        value="${assignment#*=}"
        value="${value#\'}"
        value="${value%\'}"
        printf '%s\n' "$value" > "$(key_file "$key")"
      done < "$staged"
    fi
    rm -f "$staged"
    ;;
  commit)
    case "${1:?uci config required}" in
      network) [[ -f "$(key_file 'network.lan.ipaddr')" ]] || exit 1 ;;
      xinzhaowrt) [[ -f "$(key_file 'xinzhaowrt.system')" ]] || exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    printf 'unexpected uci command: %s\n' "$command" >&2
    exit 64
    ;;
esac
printf '%s %s\n' "$command" "$*" >> "$log"
UCI
chmod +x "$BIN/uci"

cat > "$BIN/logger" <<'LOGGER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${TEST_LOGGER_LOG:?}"
LOGGER
chmod +x "$BIN/logger"

SCRIPT_COPY="$TEST_ROOT/99-xinzhao-defaults"
sed "s|/etc/shadow|$TEST_ROOT/shadow|g; s|/tmp/shadow.xinzhaowrt|$TEST_ROOT/shadow.xinzhaowrt|g" \
  "$PROJECT_ROOT/files/etc/uci-defaults/99-xinzhao-defaults" | tr -d '\r' > "$SCRIPT_COPY"

shell_args=()
[[ "${TEST_TRACE:-0}" == '1' ]] && shell_args=(-x)
PATH="$BIN:$PATH" \
TEST_UCI_STATE="$STATE" \
TEST_UCI_LOG="$TEST_ROOT/uci.log" \
TEST_LOGGER_LOG="$TEST_ROOT/logger.log" \
XINZHAO_CONFIG_DIR="$STATE" \
XINZHAO_FIRSTBOOT_LOG="$TEST_ROOT/firstboot.log" \
sh "${shell_args[@]}" "$SCRIPT_COPY"

[[ "$(<"$STATE/network.lan.ipaddr")" == '192.168.6.1/24' ]] || {
  echo 'FAIL: first boot must replace the CIDR-form upstream LAN default.' >&2
  exit 1
}
[[ "$(<"$STATE/xinzhaowrt.system")" == 'system' ]] || {
  echo 'FAIL: first boot must persist xinzhaowrt.system.' >&2
  exit 1
}
[[ "$(<"$STATE/xinzhaowrt.system.initialized")" == '1' ]] || {
  echo 'FAIL: first boot must persist xinzhaowrt.system.initialized=1.' >&2
  exit 1
}
grep -Fxq -- 'FIRSTBOOT_START' "$TEST_ROOT/firstboot.log" || {
  echo 'FAIL: first boot must persist its start stage.' >&2
  exit 1
}
grep -Fxq -- 'FIRSTBOOT_COMPLETE' "$TEST_ROOT/firstboot.log" || {
  echo 'FAIL: first boot must persist its completion stage.' >&2
  exit 1
}

echo 'PASS: first-boot defaults replace CIDR LAN defaults and persist their marker.'
