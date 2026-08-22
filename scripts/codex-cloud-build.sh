#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
# shellcheck disable=SC1091
source ./build.env

export QUIET_BUILD=1
export REUSE_SOURCE=1
export JOBS="${JOBS:-$(nproc)}"

./scripts/verify-project.sh
./scripts/build.sh "${1:-$SOURCE_REF}"
