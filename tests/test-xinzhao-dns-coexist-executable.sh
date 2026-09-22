#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="$(git -C "$root" ls-files -s -- files/usr/libexec/xinzhao-dns-coexist | awk '{print $1}')"
[[ "$mode" == "100755" ]] || {
  echo "FAIL: DNS coexistence coordinator must be executable, got ${mode:-missing}" >&2
  exit 1
}
echo 'XINZHAO_DNS_COEXIST_EXECUTABLE=PASS'
