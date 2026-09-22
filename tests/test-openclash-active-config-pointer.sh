#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch="$root/patches/openclash/0012-active-config-pointer-after-save.patch"

[[ -s "$patch" ]] || {
  echo 'FAIL: OpenClash active-config pointer patch is missing'
  exit 1
}

grep -Fq 'ensure_active_config_path' "$patch" || {
  echo 'FAIL: OpenClash save/import pointer helper is missing'
  exit 1
}
grep -Fq 'function action_upload_config' "$patch" || {
  echo 'FAIL: upload_config is not covered by the pointer fix'
  exit 1
}
grep -Fq 'function action_config_file_save' "$patch" || {
  echo 'FAIL: config_file_save is not covered by the pointer fix'
  exit 1
}
grep -Fq 'function action_oc_action' "$patch" || {
  echo 'FAIL: start action persistence is not covered by the pointer fix'
  exit 1
}
grep -Fq 'uci:commit("openclash")' "$patch" || {
  echo 'FAIL: active config pointer is not committed'
  exit 1
}

echo 'OPENCLASH_ACTIVE_CONFIG_POINTER_SOURCE_CONTRACT=PASS'
