#!/usr/bin/env bash
set -u -o pipefail

# 中文说明：统一控制 GitHub Actions 云端编译。该脚本只驱动远端 workflow，绝不在本机执行 OpenWrt 编译。
# 用法：./scripts/ci-control.sh [run|watch <RUN_ID>]
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="${GITHUB_REPOSITORY:-mxonline/xinzhaowrt}"
BRANCH="${CI_BRANCH:-main}"
WORKFLOW="${CI_WORKFLOW:-build.yml}"
ACTION="${1:-run}"
RUN_ID="${2:-}"
RECORD_DIR="$PROJECT_ROOT/output/ci-runs"
mkdir -p "$RECORD_DIR"

require_gh() {
  command -v gh >/dev/null 2>&1 || {
    echo 'ERROR: 未安装 GitHub CLI（gh）。' >&2
    return 2
  }
  gh auth status --hostname github.com >/dev/null 2>&1 || {
    echo 'ERROR: GitHub CLI 未认证或缺少 workflow 权限。' >&2
    return 2
  }
}

resolve_workflow() {
  if gh workflow view "$WORKFLOW" --repo "$REPOSITORY" >/dev/null 2>&1; then
    return 0
  fi
  WORKFLOW="$(gh workflow list --repo "$REPOSITORY" --json name,path \
    --jq '.[] | select(.name == "Build XinZhaoWrt Arthur") | .path' | sed -n '1p')"
  [[ -n "$WORKFLOW" ]] || {
    echo 'ERROR: 未找到 Build XinZhaoWrt Arthur workflow。' >&2
    return 2
  }
}

start_run() {
  # 中文说明：记录触发前时间，避免取到历史运行记录。
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh workflow run "$WORKFLOW" --repo "$REPOSITORY" --ref "$BRANCH"

  local attempt=0 candidate created_at
  while (( attempt < 20 )); do
    candidate="$(gh run list --repo "$REPOSITORY" --workflow "$WORKFLOW" --branch "$BRANCH" \
      --limit 1 --json databaseId,createdAt --jq '.[0] | "\(.databaseId)\t\(.createdAt)"')"
    RUN_ID="${candidate%%$'\t'*}"
    created_at="${candidate#*$'\t'}"
    if [[ -n "$RUN_ID" && "$created_at" > "$started_at" ]]; then
      return 0
    fi
    sleep 3
    ((attempt++))
  done
  echo 'ERROR: workflow 已触发，但未能取得新的 Run ID。' >&2
  return 2
}

download_failure_artifacts() {
  local destination="$RECORD_DIR/$RUN_ID/diagnostics"
  mkdir -p "$destination"
  gh run view "$RUN_ID" --repo "$REPOSITORY" --log-failed \
    > "$destination/failed-steps.log" 2>&1 || true
  gh run download "$RUN_ID" --repo "$REPOSITORY" \
    --name "XinZhaoWrt-diagnostics-$RUN_ID" --dir "$destination" || true
  echo "DIAGNOSTICS_DIR=$destination"
}

download_firmware_artifact() {
  local destination="$RECORD_DIR/$RUN_ID/firmware"
  mkdir -p "$destination"
  gh run download "$RUN_ID" --repo "$REPOSITORY" --name XinZhaoWrt-Arthur --dir "$destination"

  local firmware
  firmware="$(find "$destination" -type f -iname '*jdcloud_re-ss-01*' | sed -n '1p')"
  [[ -n "$firmware" ]] || {
    echo 'ERROR: firmware Artifact 中未找到 jdcloud_re-ss-01 固件。' >&2
    return 1
  }
  echo "FIRMWARE=$firmware"
  if find "$destination" -type f -iname '*sha256sums*' | grep -q .; then
    # 中文说明：校验文件通常使用相对文件名，因此在其所在目录执行校验。
    while IFS= read -r checksum_file; do
      (
        cd "$(dirname "$checksum_file")"
        sha256sum -c "$(basename "$checksum_file")"
      )
    done < <(find "$destination" -type f -iname '*sha256sums*')
  else
    echo 'WARNING: Artifact 未提供 sha256sums，输出本地 SHA256。' >&2
    sha256sum "$firmware"
  fi
}

require_gh || exit $?
resolve_workflow || exit $?

case "$ACTION" in
  run)
    start_run || exit $?
    ;;
  watch)
    [[ -n "$RUN_ID" ]] || {
      echo 'ERROR: watch 模式必须提供 Run ID。' >&2
      exit 2
    }
    ;;
  *)
    echo "ERROR: 未支持的操作：$ACTION" >&2
    exit 2
    ;;
esac

echo "RUN_ID=$RUN_ID"
echo "REPOSITORY=$REPOSITORY"
echo "BRANCH=$BRANCH"

# 中文说明：必须在前台等待；if/else 吸收失败退出码，确保失败后仍进入日志与 Artifact 诊断分支。
if gh run watch "$RUN_ID" --repo "$REPOSITORY" --exit-status; then
  WATCH_RESULT=success
else
  WATCH_RESULT=failure
fi

FINAL_CONCLUSION="$(gh run view "$RUN_ID" --repo "$REPOSITORY" --json conclusion --jq '.conclusion')"
echo "FINAL_CONCLUSION=$FINAL_CONCLUSION"

if [[ "$WATCH_RESULT" == success && "$FINAL_CONCLUSION" == success ]]; then
  download_firmware_artifact
  exit 0
fi

download_failure_artifacts
exit 1
