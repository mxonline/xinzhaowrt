#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.github/workflows/arthur-update-v3.yml"
SYNC="$ROOT/.github/workflows/arthur-production-state-sync.yml"
CONTROL="$ROOT/.github/workflows/arthur-control-plane.yml"

require() {
  grep -Fq -- "$2" "$1" || { echo "FAIL: $3" >&2; exit 1; }
}

require "$BUILD" 'project_commit' 'Candidate metadata must store the frozen firmware source SHA'
require "$BUILD" 'build_control_commit' 'Candidate metadata must separate the validation/control commit'
require "$BUILD" 'ARTHUR_CANDIDATE_SHA: ${{ steps.source.outputs.source_sha }}' 'validation build must use the frozen source SHA'
require "$BUILD" 'PREBUILD_VALIDATION_SHA: ${{ github.sha }}' 'validation build must check evidence from the control commit'
require "$BUILD" '--target "$FIRMWARE_SOURCE_SHA"' 'Candidate Release must target the frozen firmware source commit'

require "$SYNC" 'Arthur-v3-Candidate-$run_id' 'state sync must recover the immutable Candidate artifact'
require "$SYNC" 'build_control_commit' 'state sync must verify the separate control commit'
require "$SYNC" 'CANDIDATE_SOURCE_IDENTITY=PASS' 'state sync must report both source identities'
require "$SYNC" "resume.get('source', {}).get('accepted_source_sha'" 'state sync must compare firmware source to accepted source state'

require "$CONTROL" 'scripts/arthur-firmware-resume.ps1 -SkipExternal' 'canonical dispatch must require the formal Resume Gate'
require "$CONTROL" 'scripts/check-openclash-adh-prebuild-live.py' 'canonical dispatch must run the current prebuild gate'
require "$CONTROL" 'VALIDATION_SHA' 'canonical dispatch must separate evidence SHA from firmware source SHA'
require "$CONTROL" 'PREBUILD_OPENCLASH_ADH_LIVE_GATE=PASS' 'prebuild marker must be explicit before dispatch'

echo 'ARTHUR_V016_SOURCE_IDENTITY=PASS'
