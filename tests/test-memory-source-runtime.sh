#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
init_dir="$fixture/init.d"
config_dir="$fixture/adguardhome"
log="$fixture/actions.log"
mkdir -p "$init_dir" "$config_dir"
printf '%s\n' 'http:' '  address: 0.0.0.0:3000' > "$config_dir/adguardhome.yaml"
for service in adguardhome AdGuardHome quickfile; do
  cat > "$init_dir/$service" <<'SERVICE'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$1" >> "${TEST_ACTION_LOG:?}"
SERVICE
  chmod +x "$init_dir/$service"
done
PROJECT_DEFAULTS="$root/files/etc/uci-defaults/96-xinzhao-adguardhome-defaults" \
XINZHAO_INIT_DIR="$init_dir" \
XINZHAO_ADGUARD_CONFIG_DIR="$config_dir" \
XINZHAO_ADGUARD_CONFIG_FILE="$config_dir/adguardhome.yaml" \
TEST_ACTION_LOG="$log" \
  sh -c 'exec "$PROJECT_DEFAULTS"'
for service in adguardhome AdGuardHome quickfile; do
  grep -Fxq "$service stop" "$log" || { echo "MEMORY_SOURCE_RUNTIME_GATE: FAIL -- $service not stopped" >&2; exit 1; }
  grep -Fxq "$service disable" "$log" || { echo "MEMORY_SOURCE_RUNTIME_GATE: FAIL -- $service not disabled" >&2; exit 1; }
done
! grep -Eq '^quickstart ' "$log" || { echo 'MEMORY_SOURCE_RUNTIME_GATE: FAIL -- QuickStart modified' >&2; exit 1; }
[[ -s "$config_dir/adguardhome.yaml" ]] || { echo 'MEMORY_SOURCE_RUNTIME_GATE: FAIL -- config seed lost' >&2; exit 1; }
echo 'MEMORY_SOURCE_RUNTIME_GATE=PASS'
