#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

classifier='./scripts/classify-build-scope.sh'
[[ -x "$classifier" ]] || chmod +x "$classifier"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  contract="$(printf '%s\n' "$path" | "$classifier" --release-contract)"
  impact="$(printf '%s\n' "$contract" | sed -n 's/^RELEASE_IMPACT_CLASS=//p')"
  case "$impact" in
    FIRMWARE_INPUT|PREVIEW_BYTES)
      blob="$(git rev-parse "HEAD:$path")"
      printf '%s\t%s\n' "$path" "$blob" >> "$tmp"
      ;;
  esac
done < <(git ls-files | LC_ALL=C sort)

[[ -s "$tmp" ]] || { echo 'FIRMWARE_INPUT_FINGERPRINT_EMPTY' >&2; exit 2; }
LC_ALL=C sort -o "$tmp" "$tmp"
sha256sum "$tmp" | awk '{print $1}'
