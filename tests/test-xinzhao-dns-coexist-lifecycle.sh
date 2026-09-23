#!/bin/sh
set -eu

coordinator="${1:-files/usr/libexec/xinzhao-dns-coexist}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM

# Load the production functions without invoking the script entrypoint.
sed '$d' "$coordinator" > "$tmp"
. "$tmp"

yaml_ensure() { echo /tmp/AdGuardHome.yaml; }
yaml_restore_upstream() { restore_upstream_calls=$((restore_upstream_calls + 1)); }
set_if_changed() { :; }
commit_all() { :; }
log() { :; }

restore_upstream_calls=0
set_dnsmasq_calls=0
restore_dnsmasq_calls=0
selected_port=

oc_running() { return 0; }
port_listening() { [ "$1" = 7874 ]; }
set_dnsmasq_upstream() {
  set_dnsmasq_calls=$((set_dnsmasq_calls + 1))
  selected_port="$1"
}
restore_dnsmasq() { restore_dnsmasq_calls=$((restore_dnsmasq_calls + 1)); }

adh_stopped

[ "$restore_upstream_calls" -eq 1 ] || {
  echo "FAIL: ADH upstream was not restored" >&2
  exit 1
}
[ "$set_dnsmasq_calls" -eq 1 ] || {
  echo "FAIL: stopping ADH while OpenClash is ready did not select OpenClash DNS" >&2
  exit 1
}
[ "$selected_port" = 7874 ] || {
  echo "FAIL: expected OpenClash DNS port 7874, got $selected_port" >&2
  exit 1
}
[ "$restore_dnsmasq_calls" -eq 0 ] || {
  echo "FAIL: stopping ADH while OpenClash is ready restored direct DNS" >&2
  exit 1
}

echo XINZHAO_DNS_COEXIST_ADH_STOP_OC_READY=PASS

(
  # OpenClash owns its DNS redirect lifecycle when AdGuardHome is disabled.
  set_if_changed() {
    case "$1" in
      openclash.config.enable_redirect_dns|openclash.config.redirect_dns)
        echo "FAIL: coordinator overrode OpenClash-owned DNS state: $1=$2" >&2
        exit 1
        ;;
    esac
  }
  memory_ok() { return 0; }
  save_state() { :; }
  get() {
    case "$1" in
      openclash.config.enable_redirect_dns) echo 1 ;;
      openclash.config.redirect_dns) echo 1 ;;
      AdGuardHome.AdGuardHome.enabled) echo 0 ;;
      *) echo '' ;;
    esac
  }
  oc_running() { return 0; }
  adh_enabled() { return 1; }
  adh_running() { return 1; }
  wait_port() { [ "$1" = 7874 ]; }
  restore_agh() { :; }
  commit_all() { :; }
  set_dnsmasq_upstream() {
    [ "$1" = 7874 ] || {
      echo "FAIL: ADH-off OpenClash upstream changed to $1" >&2
      exit 1
    }
  }

  prepare_openclash
  openclash_ready
)

echo XINZHAO_DNS_COEXIST_ADH_OFF_PRESERVES_OPENCLASH_DNS=PASS

(
  attempts=0
  mkdir() {
    attempts=$((attempts + 1))
    [ "$attempts" -ge 3 ]
  }
  rmdir() { :; }
  sleep() { :; }
  log() { :; }

  if ! acquire; then
    echo "FAIL: coordinator did not wait for a transient lifecycle lock" >&2
    exit 1
  fi
  [ "$attempts" -eq 3 ] || {
    echo "FAIL: expected lock on attempt 3, got attempt $attempts" >&2
    exit 1
  }
)

echo XINZHAO_DNS_COEXIST_TRANSIENT_LOCK_WAIT=PASS
