#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "ARTHUR_OPENCLASH_ADH_STATIC: FAIL -- $*" >&2; exit 1; }
pass() { echo "ARTHUR_OPENCLASH_ADH_STATIC: PASS -- $*"; }

sot="$root/production/openclash-adguardhome-coexistence.json"
targets="$root/production/ARTHUR_PRODUCT_TARGETS.md"
coordinator="$root/files/usr/libexec/xinzhao-dns-coexist"
agh_init="$root/files/etc/init.d/AdGuardHome"
openclash_patch="$root/patches/openclash/0010-arthur-coexistence-memory-and-dns.patch"
default_dns_patch="$root/patches/openclash/0011-arthur-default-no-dns-hijack.patch"
device_verify="$root/scripts/real-device-verify.ps1"

[[ -s "$sot" ]] || fail 'coexistence Source of Truth is missing'
[[ -s "$targets" ]] || fail 'Arthur product target Source of Truth is missing'
for needle in \
  '"port": 53' \
  '"openclash_dns_port": 7874' \
  '"adguardhome_dns_port": 1745' \
  'LAN:dnsmasq:53 -> AdGuardHome:1745 -> OpenClash:7874' \
  '"dnsmasq_upstream": "127.0.0.1#1745"' \
  '"adguardhome_upstream": "127.0.0.1:7874"' \
  '"firewall_dns_hijack": false' \
  '"state_restore": true' \
  '"reboot_reconcile": true'; do
  grep -Fq "$needle" "$sot" || fail "Source of Truth missing: $needle"
done

grep -Eq "^[[:space:]]*option enabled '0'[[:space:]]*$" "$root/files/etc/config/AdGuardHome" || fail 'AdGuardHome is not default-disabled'
grep -Eq "^[[:space:]]*option redirect 'none'[[:space:]]*$" "$root/files/etc/config/AdGuardHome" || fail 'AdGuardHome redirect default is not none'
grep -Fq 'AdGuardHome.AdGuardHome.enabled' "$device_verify" || fail 'device verifier does not inspect the authoritative AdGuardHome UCI namespace'
! grep -Fq 'uci -q get adguardhome.config.enabled' "$device_verify" || fail 'device verifier still trusts the non-authoritative lowercase AdGuardHome namespace'
grep -Fq 'port: 1745' "$root/files/etc/AdGuardHome.yaml" || fail 'Arthur AdGuardHome DNS port is not 1745'
! grep -Fq 'port: 5553' "$root/files/etc/AdGuardHome.yaml" || fail 'released 5553 DNS port remains in candidate YAML'
! grep -Fq 'edns_client_subnet: false' "$root/files/etc/AdGuardHome.yaml" || fail 'AdGuardHome EDNS client subnet uses the incompatible legacy scalar form'
grep -Fq 'custom_ip: ""' "$root/files/etc/AdGuardHome.yaml" || fail 'AdGuardHome EDNS client subnet compatibility mapping is missing'
! grep -Eq '^[[:space:]]*clients:[[:space:]]*\[\]' "$root/files/etc/AdGuardHome.yaml" || fail 'AdGuardHome clients uses the incompatible legacy list form'
grep -Fq 'runtime_sources:' "$root/files/etc/AdGuardHome.yaml" || fail 'AdGuardHome clients runtime_sources mapping is missing'
grep -Fq "option maxprocs '1'" "$root/files/etc/config/AdGuardHome" || fail 'AdGuardHome GOMAXPROCS guard missing'
grep -Fq "option memlimit '64'" "$root/files/etc/config/AdGuardHome" || fail 'AdGuardHome GOMEMLIMIT guard missing'

for needle in \
  'prepare-openclash' 'prepare-adh' 'adh-ready' 'openclash-ready' \
  'adh-stopped' 'openclash-stopped' 'boot-reconcile' \
  '127.0.0.1#$1' 'yaml_set_upstream' ; do
  grep -Fq "$needle" "$coordinator" || fail "coordinator lifecycle contract missing: $needle"
done
grep -Fq 'MemAvailable' "$coordinator" || fail 'coordinator memory floor is missing'
grep -Fq 'wait_port "$OC_PORT"' "$coordinator" || fail 'OpenClash listener readiness is missing'
grep -Fq 'wait_port "$ADH_PORT"' "$coordinator" || fail 'AdGuardHome listener readiness is missing'
grep -Fq 'xinzhao-dns-coexist' "$agh_init" || fail 'AdGuardHome init is not connected to coordinator'

grep -Fq 'GOMEMLIMIT="96MiB"' "$openclash_patch" || fail 'OpenClash core memory limit is missing'
grep -Fq 'procd_running "openclash-watchdog"' "$openclash_patch" || fail 'OpenClash watchdog single-flight guard is missing'
grep -Fq 'openclash-ready' "$openclash_patch" || fail 'OpenClash readiness hook is missing'
grep -Fq 'prepare-openclash' "$openclash_patch" || fail 'OpenClash preflight hook is missing'
grep -Fq "option enable_redirect_dns '0'" "$default_dns_patch" || fail 'OpenClash default DNS hijack disable patch is missing'

source_root="${OPENCLASH_SOURCE_ROOT:-$root/work/feed-check/immortalwrt/feeds/luci/applications}"
source_dir="$source_root/luci-app-openclash"
[[ -d "$source_dir" ]] || fail "prepared OpenClash source is missing: $source_dir"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cp -R "$source_dir" "$tmp_dir/luci-app-openclash"
(
  cd "$tmp_dir"
  for patch in "$root"/patches/openclash/*.patch; do
    git apply --no-index "$patch"
  done
)
pass 'complete OpenClash candidate patch series applies to prepared source'

pass 'SOT, ports, default state, lifecycle, memory guards and patch application verified'
