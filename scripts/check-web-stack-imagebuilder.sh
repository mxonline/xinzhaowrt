#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/arthur-fast-candidate.yml"
OVERLAY="$ROOT/files/etc/uci-defaults/98-xinzhao-web-stack"
UHTTPD_INIT="$ROOT/files/etc/init.d/uhttpd"

grep -qF -- '-uhttpd' "$WORKFLOW" || { echo 'ERROR: ImageBuilder does not remove uhttpd'; exit 1; }
grep -qF -- '-uhttpd-mod-ubus' "$WORKFLOW" || { echo 'ERROR: ImageBuilder does not remove uhttpd-mod-ubus'; exit 1; }
grep -qF 'XINZHAO_NGINX_PRIMARY=1' "$UHTTPD_INIT" || { echo 'ERROR: uhttpd init guard is not a Nginx no-op'; exit 1; }
grep -qF 'XINZHAO_NGINX_PRIMARY=1' "$WORKFLOW" || { echo 'ERROR: runtime gate does not verify the uhttpd init guard'; exit 1; }
grep -qF '/etc/init.d/nginx restart' "$OVERLAY" || { echo 'ERROR: Nginx restart guard missing'; exit 1; }
grep -qF '/etc/init.d/uhttpd disable' "$OVERLAY" || { echo 'ERROR: defensive uhttpd disable missing'; exit 1; }

echo 'WEB_STACK_IMAGEBUILDER_STATIC_CHECK: PASS'
