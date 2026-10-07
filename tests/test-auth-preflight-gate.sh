#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$root/scripts/github-auth-preflight.ps1"
controller="$root/scripts/ci-controller-v3.ps1"
dispatcher="$root/scripts/github-app-auth.ps1"

[[ -f "$helper" ]] || { echo 'FAIL: AUTH_PREFLIGHT_GATE helper is missing.' >&2; exit 1; }
grep -Fq 'AUTH_PREFLIGHT_GATE' "$helper" || { echo 'FAIL: helper must expose AUTH_PREFLIGHT_GATE.' >&2; exit 1; }
grep -Fq 'AUTH_RECOVERY' "$helper" || { echo 'FAIL: helper must expose AUTH_RECOVERY.' >&2; exit 1; }
grep -Fq 'BLOCKED_AUTH_CREDENTIAL_MISSING' "$helper" || { echo 'FAIL: helper must expose the structured auth blocker.' >&2; exit 1; }
grep -Fq 'GitHubApp' "$helper" || { echo 'FAIL: helper must support GitHub App credential recovery.' >&2; exit 1; }
grep -Fq 'keyring' "$helper" || { echo 'FAIL: helper must support system credential-store recovery.' >&2; exit 1; }
! grep -Eiq 'device[ -]?flow|verification code|open github' "$helper" || { echo 'FAIL: auth recovery must not fall back to Device Flow.' >&2; exit 1; }

grep -Fq 'Invoke-GitHubAuthPreflight' "$controller" || { echo 'FAIL: v3 controller must gate GitHub operations.' >&2; exit 1; }
grep -Fq 'Invoke-GitHubAuthPreflight' "$dispatcher" || { echo 'FAIL: GitHub App dispatcher must gate GitHub operations.' >&2; exit 1; }

if command -v pwsh >/dev/null 2>&1; then
  result="$(pwsh -NoProfile -ExecutionPolicy Bypass -File "$helper" -Operation workflow -ProbeOnly -Repository mxonline/xinzhaowrt)"
  grep -Fq 'AUTH_PREFLIGHT_GATE=PASS' <<<"$result" || { echo 'FAIL: authenticated preflight did not pass.' >&2; exit 1; }
  grep -Fq 'AUTH_RECOVERED=PASS' <<<"$result" || { echo 'FAIL: preflight did not report recovered authentication.' >&2; exit 1; }
  ! grep -Eiq 'gho_|ghs_|github_pat_|token=' <<<"$result" || { echo 'FAIL: preflight output leaked credential material.' >&2; exit 1; }
fi

echo 'PASS: AUTH_PREFLIGHT_GATE contract is present and credential-safe.'
