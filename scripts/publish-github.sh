#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-mxonline/xinzhaowrt}"
VISIBILITY="${VISIBILITY:-public}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v gh >/dev/null 2>&1 || {
  echo "ERROR: GitHub CLI (gh) is required."
  exit 1
}
gh auth status >/dev/null

if [[ ! -d .git ]]; then
  git init
  git branch -M main
fi

if ! git config user.name >/dev/null 2>&1; then
  git config user.name "XinZhaoWrt Builder"
fi
if ! git config user.email >/dev/null 2>&1; then
  git config user.email "xinzhaowrt@localhost"
fi

git add .
if ! git diff --cached --quiet; then
  git commit -m "feat: initialize XinZhaoWrt Arthur v0.1.0"
fi

if ! gh repo view "$REPO" >/dev/null 2>&1; then
  gh repo create "$REPO" \
    --"$VISIBILITY" \
    --description "新肇网络Wrt-京东云亚瑟固件 / JDCloud RE-SS-01" \
    --source . \
    --remote origin \
    --push
else
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "https://github.com/$REPO.git"
  fi
  git push -u origin main
fi

echo "Published: https://github.com/$REPO"
