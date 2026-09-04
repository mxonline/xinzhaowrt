#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$root/files/usr/libexec/xinzhao/luci-upgrade-converge.sh"
hotplug="$root/files/etc/hotplug.d/iface/95-xinzhao-luci-converge"

[[ -f "$helper" ]] || { echo "FAIL: missing preserved-upgrade LuCI convergence helper: $helper" >&2; exit 1; }
[[ -f "$hotplug" ]] || { echo "FAIL: missing LAN hotplug convergence trigger: $hotplug" >&2; exit 1; }

grep -Fq '${ACTION:-}' "$hotplug" || { echo 'FAIL: hotplug trigger must gate on ACTION.' >&2; exit 1; }
grep -Fq "= 'ifup'" "$hotplug" || { echo 'FAIL: hotplug trigger must run only on ifup.' >&2; exit 1; }
grep -Fq '${INTERFACE:-}' "$hotplug" || { echo 'FAIL: hotplug trigger must gate on INTERFACE.' >&2; exit 1; }
grep -Fq "= 'lan'" "$hotplug" || { echo 'FAIL: hotplug trigger must bind to LAN.' >&2; exit 1; }
grep -Fq 'sh /usr/libexec/xinzhao/luci-upgrade-converge.sh' "$hotplug" || { echo 'FAIL: LAN hotplug must execute the convergence helper through /bin/sh.' >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/persist"

cat > "$tmp/bin/uci" <<'UCI'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${TEST_UCI_STATE:?}"
[[ "${1:-}" == '-q' ]] && shift
cmd="${1:?uci command required}"
shift
keyfile() { printf '%s/%s' "$state" "${1//\//_}"; }
case "$cmd" in
  get)
    file="$(keyfile "${1:?uci key required}")"
    [[ -f "$file" ]] || exit 1
    cat "$file"
    ;;
  set)
    assignment="${1:?uci assignment required}"
    key="${assignment%%=*}"
    value="${assignment#*=}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s\n' "$value" > "$(keyfile "$key")"
    ;;
  commit)
    [[ "${1:-}" == 'luci' ]] || exit 64
    printf 'commit luci\n' >> "${TEST_UCI_LOG:?}"
    ;;
  *) exit 64 ;;
esac
UCI
chmod +x "$tmp/bin/uci"

cat > "$tmp/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${TEST_LOGGER_LOG:?}"
LOGGER
chmod +x "$tmp/bin/logger"

write_state() { printf '%s\n' "$2" > "$tmp/state/${1//\//_}"; }
read_state() { cat "$tmp/state/${1//\//_}"; }

commit_a='1111111111111111111111111111111111111111'
commit_b='2222222222222222222222222222222222222222'
printf 'Firmware: XinZhaoWrt\nVersion: 0.1.3\nGit Commit: %s\n' "$commit_a" > "$tmp/build-info"
write_state 'luci.main.lang' 'en'
write_state 'luci.main.mediaurlbase' '/luci-static/bootstrap'
write_state 'luci.main.homepage' 'admin/status/overview'

run_helper() {
  PATH="$tmp/bin:$PATH" \
  TEST_UCI_STATE="$tmp/state" TEST_UCI_LOG="$tmp/uci.log" TEST_LOGGER_LOG="$tmp/logger.log" \
  XINZHAO_BUILD_INFO="$tmp/build-info" XINZHAO_STATE_DIR="$tmp/persist" \
  XINZHAO_UCI="$tmp/bin/uci" XINZHAO_LOGGER="$tmp/bin/logger" \
  sh "$helper"
}

run_helper
[[ "$(read_state 'luci.main.lang')" == 'zh_cn' ]] || { echo 'FAIL: preserved upgrade must converge LuCI to zh_cn.' >&2; exit 1; }
[[ "$(read_state 'luci.main.mediaurlbase')" == '/luci-static/argon' ]] || { echo 'FAIL: preserved upgrade must converge Argon.' >&2; exit 1; }
[[ "$(read_state 'luci.main.homepage')" == 'admin/quickstart' ]] || { echo 'FAIL: preserved upgrade must converge QuickStart homepage.' >&2; exit 1; }
[[ "$(read_state 'luci.themes.Argon')" == '/luci-static/argon' ]] || { echo 'FAIL: Argon must be registered.' >&2; exit 1; }
[[ "$(read_state 'luci.themes.KuCat')" == '/luci-static/kucat' ]] || { echo 'FAIL: KuCat must remain selectable.' >&2; exit 1; }
[[ "$(cat "$tmp/persist/luci-migration-commit")" == "$commit_a" ]] || { echo 'FAIL: migration marker must bind the exact firmware Git commit.' >&2; exit 1; }

# A user choice made after convergence must survive ordinary reboots/events.
write_state 'luci.main.lang' 'en'
run_helper
[[ "$(read_state 'luci.main.lang')" == 'en' ]] || { echo 'FAIL: same firmware commit must not overwrite a later user language choice.' >&2; exit 1; }

# A new firmware commit must converge preserved config again exactly once.
printf 'Firmware: XinZhaoWrt\nVersion: 0.1.3\nGit Commit: %s\n' "$commit_b" > "$tmp/build-info"
run_helper
[[ "$(read_state 'luci.main.lang')" == 'zh_cn' ]] || { echo 'FAIL: new firmware commit must reconverge preserved LuCI config.' >&2; exit 1; }
[[ "$(cat "$tmp/persist/luci-migration-commit")" == "$commit_b" ]] || { echo 'FAIL: migration marker must advance to the new firmware commit.' >&2; exit 1; }

echo 'PRESERVED_UPGRADE_LUCI_CONVERGENCE=PASS'
echo 'PRESERVED_UPGRADE_ONE_SHOT_PER_COMMIT=PASS'
echo 'PRESERVED_UPGRADE_HOTPLUG_TRIGGER=PASS'
