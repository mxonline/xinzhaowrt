#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CLASSIFIER="$ROOT/scripts/classify-build-scope.sh"

if [[ $# -eq 2 ]]; then
  BASE="$1"
  HEAD="$2"
  paths="$(git -C "$ROOT" diff --name-only "$BASE" "$HEAD")"
elif [[ $# -eq 0 ]]; then
  paths="$(cat)"
else
  echo 'usage: source-impact-gate.sh [BASE HEAD]' >&2
  exit 2
fi

scope="$(printf '%s\n' "$paths" | bash "$CLASSIFIER")"
case "$scope" in
  DOC_ONLY|FAST_GATE)
    printf 'NO_FIRMWARE_CHANGE\t%s\n' "$scope"
    ;;
  IMAGEBUILDER|SDK_BUILD|FULL_BUILD)
    printf 'FIRMWARE_IMPACT\t%s\n' "$scope"
    ;;
  *)
    echo "ERROR: unsupported scope from classifier: $scope" >&2
    exit 3
    ;;
esac
