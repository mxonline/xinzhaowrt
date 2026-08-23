#!/usr/bin/env bash
set -uo pipefail

# 中文说明：统一分析云端完整日志，生成可上传的摘要和详细失败报告。
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${1:-$PROJECT_ROOT/output/logs/build.log}"
OUT_DIR="$PROJECT_ROOT/output/logs"
SUMMARY="$OUT_DIR/error-summary.txt"
REPORT="$OUT_DIR/failure-report.txt"
mkdir -p "$OUT_DIR"

RUN_ID="${GITHUB_RUN_ID:-unknown}"
COMMIT_SHA="${GITHUB_SHA:-unknown}"
SOURCE_REPO="${IMMORTAL_SOURCE_REPO:-${SOURCE_REPO:-unknown}}"
SOURCE_REF="${IMMORTAL_SOURCE_REF:-${SOURCE_REF:-unknown}}"

if [[ ! -f "$LOG" ]]; then
  printf '诊断输入日志不存在：%s\n' "$LOG" > "$SUMMARY"
  cp "$SUMMARY" "$REPORT"
  exit 0
fi

# 只匹配真实失败线索，避免把普通 WARNING 当成首个错误。
KEY_PATTERN='MISSING_PACKAGE|MISSING_SOURCE|MISSING: CONFIG_PACKAGE|MISSING CONFIG_PACKAGE|ERROR:|failed to build|make\[[^]]*\].*(Error|error)|configure error|dependency( on)? .*does not exist|No space left|out of memory|(^|[^[:alpha:]])killed([^[:alpha:]]|$)|download[[:space:]_-]*(failure|failed|error)|failed.*download|fatal:|clone.*(failed|error)|git.*(failed|error)|feed.*(failed|error|missing)'
FIRST_ERROR="$(grep -nEi "$KEY_PATTERN" "$LOG" | head -n 1 || true)"
[[ -n "$FIRST_ERROR" ]] || FIRST_ERROR="未匹配到预定义错误模式；请查看完整 build.log。"

if grep -qiE 'MISSING: CONFIG_PACKAGE|MISSING CONFIG_PACKAGE|make defconfig|configuration written to .config' "$LOG"; then
  STAGE='make defconfig / 配置保留检查'
elif grep -qiE 'MISSING_PACKAGE|MISSING_SOURCE|feeds update|Updating feed|git clone|Cloning into' "$LOG"; then
  STAGE='源码、feed 或 package preflight'
elif grep -qiE 'download[[:space:]_-]*(failure|failed|error)|failed.*download|make download' "$LOG"; then
  STAGE='源码下载'
elif grep -qiE '\[7/9\]|make\[[^]]*\]|failed to build|recipe for target' "$LOG"; then
  STAGE='make world / 固件编译'
else
  STAGE='构建初始化或依赖安装'
fi

write_section() {
  local title="$1" pattern="$2"
  printf '\n[%s]\n' "$title"
  grep -nEi "$pattern" "$LOG" || true
}

{
  echo '新肇网络Wrt 自动失败摘要'
  echo "GitHub Actions Run ID: $RUN_ID"
  echo "Commit SHA: $COMMIT_SHA"
  echo "ImmortalWrt source repo: $SOURCE_REPO"
  echo "Source ref: $SOURCE_REF"
  echo "失败阶段: $STAGE"
  echo "第一个真实错误: $FIRST_ERROR"
  echo
  echo '最后100行关键日志:'
  grep -nEi "$KEY_PATTERN" "$LOG" | tail -n 100 || tail -n 100 "$LOG"
  write_section 'MISSING_PACKAGE 列表' 'MISSING_PACKAGE'
  write_section 'MISSING_SOURCE 列表' 'MISSING_SOURCE'
  write_section 'make defconfig 后缺失 CONFIG 列表' 'MISSING: CONFIG_PACKAGE|MISSING CONFIG_PACKAGE'
  echo
  echo '建议检查对象:'
  if grep -qiE 'MISSING_PACKAGE|MISSING_SOURCE|feed.*(failed|error|missing)|clone.*(failed|error)' "$LOG"; then
    echo '- 检查 feeds.conf、feed 更新结果、package Makefile 路径和来源映射。'
  fi
  if grep -qiE 'MISSING: CONFIG_PACKAGE|MISSING CONFIG_PACKAGE|dependency( on)? .*does not exist' "$LOG"; then
    echo '- 检查 make defconfig 前 package 依赖、架构条件、select/depends 和配置符号。'
  fi
  if grep -qiE 'No space left|out of memory|(^|[^[:alpha:]])killed([^[:alpha:]]|$)' "$LOG"; then
    echo '- 检查云端磁盘空间、JOBS 并发数、内存和缓存占用。'
  fi
  if grep -qiE 'download[[:space:]_-]*(failure|failed|error)|failed.*download' "$LOG"; then
    echo '- 检查 dl 缓存、下载 URL、网络重试和源码哈希。'
  fi
  echo '- 保留并查看 output/logs/build.log 中的完整上下文。'
} > "$SUMMARY"

{
  cat "$SUMMARY"
  echo
  echo '===== 详细分类诊断 ====='
  write_section 'ERROR' 'ERROR:|failed to build|make\[[^]]*\].*(Error|error)|configure error'
  write_section '依赖不存在' 'dependency( on)? .*does not exist|dependency does not exist'
  write_section '资源耗尽' 'No space left|out of memory|(^|[^[:alpha:]])killed([^[:alpha:]]|$)'
  write_section '下载失败' 'download[[:space:]_-]*(failure|failed|error)|failed.*download'
  write_section 'Git/feed 失败' 'fatal:|clone.*(failed|error)|git.*(failed|error)|feed.*(failed|error|missing)'
  echo
  echo '===== 完整日志文件 ====='
  echo "$LOG"
} > "$REPORT"

echo "Error summary: $SUMMARY"
echo "Failure report: $REPORT"
