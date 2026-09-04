#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CLASSIFIER="$ROOT/scripts/classify-build-scope.sh"
REF="${1:-HEAD}"

if ! git -C "$ROOT" rev-parse --verify "${REF}^{commit}" >/dev/null 2>&1; then
  echo "ERROR: build fingerprint ref is not a commit: $REF" >&2
  exit 2
fi

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  scope="$(printf '%s\n' "$path" | bash "$CLASSIFIER")"
  case "$scope" in
    IMAGEBUILDER|SDK_BUILD|FULL_BUILD)
      if git -C "$ROOT" cat-file -e "${REF}:${path}" 2>/dev/null; then
        blob_sha="$(git -C "$ROOT" show "${REF}:${path}" | sha256sum | awk '{print $1}')"
        printf '%s\t%s\t%s\n' "$scope" "$path" "$blob_sha" >> "$manifest"
      fi
      ;;
  esac
done < <(git -C "$ROOT" ls-tree -r --name-only "$REF" | LC_ALL=C sort)

fingerprint="$(sha256sum "$manifest" | awk '{print $1}')"
printf 'arthur-build-v1:%s\n' "$fingerprint"
