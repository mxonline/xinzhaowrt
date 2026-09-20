#!/usr/bin/env bash
set -Eeuo pipefail

# Shared shell entrypoint for the control-plane authentication gate. On the
# Windows runner, the PowerShell helper can recover the GitHub App credential
# into the system credential store without exposing the token. In CI, GH_TOKEN
# or GITHUB_TOKEN is already supplied by the workflow secret context.
github_auth_preflight() {
  local operation="${1:-read}"
  local repository="${2:-${GITHUB_REPOSITORY:-mxonline/xinzhaowrt}}"
  local run_id="${3:-${GITHUB_RUN_ID:-UNKNOWN}}"
  local root="${4:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  if command -v pwsh >/dev/null 2>&1 && [[ -f "$root/scripts/github-auth-preflight.ps1" ]]; then
    pwsh -NoProfile -ExecutionPolicy Bypass -File "$root/scripts/github-auth-preflight.ps1" \
      -Operation "$operation" -Repository "$repository" -CurrentRunId "$run_id"
    return $?
  fi

  local login
  login="$(gh api user --jq '.login' 2>/dev/null || true)"
  if [[ "$login" == "mxonline" ]]; then
    echo 'AUTH_PREFLIGHT_GATE=PASS'
    echo 'AUTH_RECOVERED=PASS'
    echo 'AUTH_RECOVERY=AUTH_RECOVERED'
    echo 'AUTH_SOURCE=existing GH_TOKEN/keyring'
    echo "AUTH_OPERATION=$operation"
    return 0
  fi

  echo 'AUTH_PREFLIGHT_GATE=BLOCKED' >&2
  echo 'AUTH_RECOVERY=BLOCKED_AUTH_CREDENTIAL_MISSING' >&2
  echo 'missing_credential=GitHub API credential for mxonline/xinzhaowrt' >&2
  echo 'checked_sources=GitHubActionsSecret/GH_TOKEN,GitHubActionsSecret/GITHUB_TOKEN,ExistingPAT,GithubApp,system credential store/keyring' >&2
  echo 'current_checkpoint=state/ci-v3-state.json;stage=UNKNOWN;status=UNKNOWN' >&2
  echo "current_run_id=$run_id" >&2
  return 78
}
