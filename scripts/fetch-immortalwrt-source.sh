#!/usr/bin/env bash
set -Eeuo pipefail

# Acquire a verified ImmortalWrt source tree from the official Git remote only.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: fetch-immortalwrt-source.sh <source-dir> <official-remote> <ref-or-commit> <output-dir>}"
SOURCE_REMOTE="${2:?missing official remote}"
REQUESTED_REF="${3:?missing ref or commit}"
OUT="${4:?missing output directory}"
FETCH_LOG="$OUT/logs/source-fetch.log"
STATE_FILE="$OUT/source-fetch.env"

mkdir -p "$OUT/logs"
: > "$FETCH_LOG"
exec > >(tee -a "$FETCH_LOG") 2>&1

fail() {
  echo "SOURCE_FETCH_ERROR: $*" >&2
  exit 1
}

normalize_remote() {
  local value="${1%/}"
  value="${value%.git}"
  printf '%s' "$value"
}

validate_source_path() {
  case "$SRC" in
    "$PROJECT_ROOT"/work/*) ;;
    *) fail "refusing to replace source outside project work directory: $SRC" ;;
  esac
}

clear_source_dir() {
  [[ -d "$SRC" ]] || mkdir "$SRC"
  find "$SRC" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

validate_official_remote() {
  case "$(normalize_remote "$SOURCE_REMOTE")" in
    https://github.com/immortalwrt/immortalwrt) ;;
    *) fail "unapproved ImmortalWrt remote: $SOURCE_REMOTE" ;;
  esac
}

retry_git() {
  local label="$1"
  shift
  local attempt
  for attempt in 1 2 3; do
    echo "SOURCE_FETCH_ATTEMPT: method=$label attempt=$attempt"
    if git -c http.version=HTTP/1.1 -c http.maxRequests=1 "$@"; then
      return 0
    fi
    echo "SOURCE_FETCH_RETRY: method=$label attempt=$attempt failed"
    sleep "$attempt"
  done
  return 1
}

resolve_commit() {
  if [[ "$REQUESTED_REF" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s' "$REQUESTED_REF"
    return
  fi

  local resolved
  resolved="$(git -c http.version=HTTP/1.1 -c http.maxRequests=1 ls-remote --refs "$SOURCE_REMOTE" "refs/heads/$REQUESTED_REF" | awk 'NR == 1 { print $1 }')"
  [[ "$resolved" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve official ref to a fixed commit: $REQUESTED_REF"
  printf '%s' "$resolved"
}

verify_reuse_gate() {
  [[ -d "$SRC/.git" ]] || return 1
  local remote actual
  remote="$(git -C "$SRC" remote get-url origin 2>/dev/null || true)"
  actual="$(normalize_remote "$remote")"
  [[ "$actual" == "$(normalize_remote "$SOURCE_REMOTE")" ]] || return 1
  git -C "$SRC" fsck --no-progress || return 1
  [[ -z "$(git -C "$SRC" status --porcelain --untracked-files=all)" ]] || return 1
  return 0
}

fetch_commit() {
  local label="$1"
  if retry_git "$label-partial" -C "$SRC" fetch --no-tags --depth=1 --filter=blob:none origin "$TARGET_COMMIT"; then
    return 0
  fi
  echo "SOURCE_FETCH_FILTER_FALLBACK: $label"
  retry_git "$label-shallow" -C "$SRC" fetch --no-tags --depth=1 origin "$TARGET_COMMIT"
}

verify_git_checkout() {
  local actual
  git -C "$SRC" -c http.version=HTTP/1.1 -c http.maxRequests=1 -c advice.detachedHead=false checkout --detach FETCH_HEAD
  actual="$(git -C "$SRC" rev-parse HEAD)"
  [[ "$actual" == "$TARGET_COMMIT" ]] || fail "commit mismatch: expected $TARGET_COMMIT got $actual"
  git -C "$SRC" fsck --no-progress
  [[ -z "$(git -C "$SRC" status --porcelain --untracked-files=all)" ]] || fail "checkout is not clean after verification"
}

write_state() {
  local method="$1"
  local integrity="$2"
  local archive_sha="${3:-}"
  {
    printf 'SOURCE_METHOD=%q\n' "$method"
    printf 'SOURCE_REMOTE=%q\n' "$SOURCE_REMOTE"
    printf 'SOURCE_COMMIT=%q\n' "$TARGET_COMMIT"
    printf 'SOURCE_INTEGRITY=%q\n' "$integrity"
    printf 'SOURCE_ARCHIVE_SHA256=%q\n' "$archive_sha"
    printf 'VERIFIED_SOURCE_CACHE=%q\n' "$SRC"
  } > "$STATE_FILE"
}

validate_source_path
validate_official_remote
TARGET_COMMIT="$(resolve_commit)"
echo "SOURCE_TARGET: ref=$REQUESTED_REF commit=$TARGET_COMMIT remote=$SOURCE_REMOTE"

if verify_reuse_gate; then
  echo "SOURCE_REUSE_GATE: PASS"
  if fetch_commit "verified_reuse"; then
    verify_git_checkout
    write_state "verified_reuse" "official_remote+clean_worktree+git_fsck+commit_match"
    exit 0
  fi
  echo "SOURCE_REUSE_FETCH_FAILED: continuing to official shallow fetch"
else
  echo "SOURCE_REUSE_GATE: NO_REUSABLE_IMMORTALWRT_CHECKOUT"
fi

clear_source_dir
git -C "$SRC" init
git -C "$SRC" remote add origin "$SOURCE_REMOTE"
if fetch_commit "official_shallow_partial"; then
  verify_git_checkout
  write_state "official_shallow_partial" "official_remote+git_fsck+commit_match"
  exit 0
fi

fail "official shallow/partial Git fetch failed after bounded retries; no archive or third-party mirror fallback is permitted"
