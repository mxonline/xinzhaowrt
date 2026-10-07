#!/bin/sh
set -eu

SCRIPT="${1:-}"

fail() {
    echo "FIRST_BOOT_RUNTIME_GATE: FAIL -- $*" >&2
    exit 1
}

require() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

[ -n "$SCRIPT" ] || fail "usage: $0 /path/to/99-xinzhao-defaults"
[ -f "$SCRIPT" ] || fail "defaults script not found: $SCRIPT"

for command in uci awk sha256sum mktemp; do
    require "$command"
done

fixture="$(mktemp -d /tmp/xinzhaowrt-firstboot.XXXXXX)"
cleanup() {
    rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

config_dir="$fixture/config"
bin_dir="$fixture/bin"
log_file="$fixture/logger.log"
shadow_file="$fixture/shadow"
mkdir -p "$config_dir" "$bin_dir"

cat > "$config_dir/network" <<'UCI'
config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    option ipaddr '192.168.1.1'
UCI

cat > "$shadow_file" <<'SHADOW'
root:!:0:99999:7:::
SHADOW

uci_bin="$(command -v uci)"
cat > "$bin_dir/uci" <<EOF
#!/bin/sh
exec "$uci_bin" -c "$config_dir" "\$@"
EOF
cat > "$bin_dir/logger" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$log_file"
EOF
chmod 700 "$bin_dir/uci" "$bin_dir/logger"

run_defaults() {
    PATH="$bin_dir:$PATH" \
    XINZHAO_CONFIG_DIR="$config_dir" \
    XINZHAO_SHADOW_FILE="$shadow_file" \
    XINZHAO_RUNTIME_GATE=1 \
    sh "$SCRIPT" >"$fixture/defaults.stdout" 2>"$fixture/defaults.stderr"
}

assert_eq() {
    actual="$1"
    expected="$2"
    label="$3"
    [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

run_defaults || fail "first execution returned nonzero: $(cat "$fixture/defaults.stderr")"

assert_eq "$(uci -c "$config_dir" get network.lan.ipaddr)" '192.168.6.1/24' 'LAN default'
assert_eq "$(uci -c "$config_dir" get xinzhaowrt.system.initialized 2>/dev/null || true)" '1' 'initialized marker'
assert_eq "$(uci -c "$config_dir" get xinzhaowrt.system.firmware 2>/dev/null || true)" 'XinZhaoWrt-Arthur' 'firmware marker'

root_hash="$(awk -F: '$1 == "root" { print $2; exit }' "$shadow_file")"
case "$root_hash" in
    '$6$XZArthur01$'*) ;;
    *) fail 'root credential initialization did not set the configured hash' ;;
esac

grep -q 'FIRSTBOOT_START' "$log_file" || fail 'missing FIRSTBOOT_START log'
grep -q 'LAN_CONFIG_PASS' "$log_file" || fail 'missing LAN_CONFIG_PASS log'
grep -q 'ROOT_CREDENTIAL_PASS' "$log_file" || fail 'missing ROOT_CREDENTIAL_PASS log'
grep -q 'MARKER_CONFIG_PASS' "$log_file" || fail 'missing MARKER_CONFIG_PASS log'
grep -q 'FIRSTBOOT_COMPLETE' "$log_file" || fail 'missing FIRSTBOOT_COMPLETE log'

before_network="$(sha256sum "$config_dir/network")"
before_marker="$(sha256sum "$config_dir/xinzhaowrt")"
before_shadow="$(sha256sum "$shadow_file")"

run_defaults || fail "second execution returned nonzero: $(cat "$fixture/defaults.stderr")"

assert_eq "$(sha256sum "$config_dir/network")" "$before_network" 'idempotent network config'
assert_eq "$(sha256sum "$config_dir/xinzhaowrt")" "$before_marker" 'idempotent marker config'
assert_eq "$(sha256sum "$shadow_file")" "$before_shadow" 'idempotent root credential'

echo 'FIRST_BOOT_RUNTIME_GATE: PASS'
echo 'FIRST_BOOT_IDEMPOTENCE: PASS'
