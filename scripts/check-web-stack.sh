#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$root/tests/test-quickstart-web-stack-source.sh"
echo 'WEB_STACK_STATIC_GATE: PASS'
