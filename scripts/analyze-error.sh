#!/usr/bin/env bash
set -uo pipefail

# 中文说明：分析完整云端日志，定位 feeds、defconfig 和正式编译阶段的真实错误。
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/output/logs"
LOG="${1:-$OUT_DIR/build.log}"
FEED_ERROR="${2:-$OUT_DIR/feed-error.txt}"
SUMMARY="$OUT_DIR/error-summary.txt"
REPORT="$OUT_DIR/failure-report.txt"
CONTEXT="$OUT_DIR/error-context.txt"
mkdir -p "$OUT_DIR"

# 中文说明：Feed Check 报告非空时优先作为失败事实来源，避免读取被跳过的 build.log。
IS_FEED_FAILURE=0
if [[ -s "$FEED_ERROR" ]]; then
  IS_FEED_FAILURE=1
  if [[ -s "$OUT_DIR/feed-check.log" ]]; then
    LOG="$OUT_DIR/feed-check.log"
  fi
fi

RUN_ID="${GITHUB_RUN_ID:-unknown}"
COMMIT_SHA="${GITHUB_SHA:-unknown}"
SOURCE_REPO="${IMMORTAL_SOURCE_REPO:-${SOURCE_REPO:-unknown}}"
SOURCE_REF="${IMMORTAL_SOURCE_REF:-${SOURCE_REF:-unknown}}"

if [[ ! -s "$LOG" ]]; then
  {
    echo "诊断输入日志不存在：$LOG"
    if (( IS_FEED_FAILURE == 1 )); then
      echo "Failure stage: Feed Check"
      cat "$FEED_ERROR"
    fi
    echo "GitHub Actions Run ID: $RUN_ID"
    echo "Commit SHA: $COMMIT_SHA"
  } > "$SUMMARY"
  cp "$SUMMARY" "$REPORT"
  cp "$SUMMARY" "$CONTEXT"
  exit 0
fi

FEED_FAILED_COMMAND=''
FEED_EXIT_CODE=''
FEED_FIRST_ERROR=''
if (( IS_FEED_FAILURE == 1 )); then
  FEED_FAILED_COMMAND="$(sed -n 's/^Failed command: //p' "$FEED_ERROR" | sed -n '1p')"
  FEED_EXIT_CODE="$(sed -n 's/^Exit code: //p' "$FEED_ERROR" | sed -n '1p')"
  FEED_FIRST_ERROR="$(sed -n 's/^First real error: //p' "$FEED_ERROR" | sed -n '1p')"
fi

# 中文说明：覆盖 package、feed、Makefile、依赖、shell、资源和下载错误。
ERROR_PATTERN='ERROR:|failed to build|make\[[^]]*\].*(Error|error)|configure error|Collecting package info.*(failed|error)|package info.*failed|feeds[[:space:]]+(update|install).*(failed|error)|Updating feed.*(failed|error)|Ignoring feed.*(failed|error|index missing)|Create index file.*(failed|error)|package index.*(failed|error)|Makefile.*(parse|syntax|error)|parse error|Error evaluating|duplicate package|package conflict|conflict.*package|dependency( on)? .*does not exist|dependency error|syntax error|shell error|/bin/(ba)?sh:.*(not found|error)|No space left|out of memory|(^|[^[:alpha:]])killed([^[:alpha:]]|$)|download[[:space:]_-]*(failure|failed|error)|failed.*download|fatal:|clone.*(failed|error)|git.*(failed|error)|feed.*(failed|error|missing)|MISSING_PACKAGE|MISSING_SOURCE|MISSING: CONFIG_PACKAGE|MISSING CONFIG_PACKAGE'
# 中文说明：先让 grep 完整读取并写入临时文件，禁止使用 grep | head，避免大日志触发 Broken pipe。
MATCH_FILE="$(mktemp)"
REAL_ERROR_FILE="$(mktemp)"
cleanup_match_files() {
  rm -f "$MATCH_FILE" "$REAL_ERROR_FILE"
}
trap cleanup_match_files EXIT
grep -nEi "$ERROR_PATTERN" "$LOG" > "$MATCH_FILE" || true

# 中文说明：优先识别第一个真实 ERROR；若日志只出现分类错误，则回退到第一个匹配项。
REAL_ERROR_PATTERN='(^|[^[:alpha:]])ERROR(:|[[:space:]])|failed to build|make\[[^]]*\].*(Error|error)|configure error|Collecting package info.*(failed|error)|package info.*failed|feeds[[:space:]]+(update|install).*(failed|error)|Updating feed.*(failed|error)|Create index file.*(failed|error)|package index.*(failed|error)|Makefile.*(parse|syntax|error)|parse error|Error evaluating|duplicate package|package conflict|conflict.*package|dependency( on)? .*does not exist|dependency error|syntax error|shell error|/bin/(ba)?sh:.*(not found|error)|No space left|out of memory|(^|[^[:alpha:]])killed([^[:alpha:]]|$)|download[[:space:]_-]*(failure|failed|error)|failed.*download|fatal:|clone.*(failed|error)|git.*(failed|error)|feed.*(failed|error|missing)'
grep -nEi "$REAL_ERROR_PATTERN" "$LOG" > "$REAL_ERROR_FILE" || true
FIRST_ERROR="$(sed -n '1p' "$REAL_ERROR_FILE")"
[[ -n "$FIRST_ERROR" ]] || FIRST_ERROR="$(sed -n '1p' "$MATCH_FILE")"
[[ -n "$FIRST_ERROR" ]] || FIRST_ERROR="未匹配到预定义错误模式；请查看完整 build.log。"

if (( IS_FEED_FAILURE == 1 )); then
  STAGE='Feed Check'
  [[ -n "$FEED_FIRST_ERROR" ]] && FIRST_ERROR="$FEED_FIRST_ERROR"
else
  if grep -qiE 'MISSING: CONFIG_PACKAGE|MISSING CONFIG_PACKAGE|make defconfig|configuration written to .config' "$LOG"; then
    STAGE='make defconfig / 配置保留检查'
  elif grep -qiE 'Collecting package info.*(failed|error)|feeds[[:space:]]+(update|install)|Updating feed|Create index file|package index|MISSING_PACKAGE|MISSING_SOURCE' "$LOG"; then
    STAGE='OpenWrt feeds / package index / source preflight'
  elif grep -qiE 'download[[:space:]_-]*(failure|failed|error)|failed.*download|make download' "$LOG"; then
    STAGE='源码下载'
  elif grep -qiE '\[7/9\]|make\[[^]]*\]|failed to build|recipe for target' "$LOG"; then
    STAGE='make world / 固件编译'
  else
    STAGE='构建初始化或依赖安装'
  fi
fi

FIRST_ERROR_LINE="$(printf '%s\n' "$FIRST_ERROR" | cut -d: -f1)"
LAST_ERROR_MATCH="$(sed -n '$p' "$REAL_ERROR_FILE")"
[[ -n "$LAST_ERROR_MATCH" ]] || LAST_ERROR_MATCH="$(sed -n '$p' "$MATCH_FILE")"
LAST_ERROR_LINE="$(printf '%s\n' "$LAST_ERROR_MATCH" | cut -d: -f1)"
[[ "$FIRST_ERROR_LINE" =~ ^[0-9]+$ ]] || FIRST_ERROR_LINE=1
[[ "$LAST_ERROR_LINE" =~ ^[0-9]+$ ]] || LAST_ERROR_LINE="$FIRST_ERROR_LINE"

failure_commands() {
  # 中文说明：提取 shell、make、feeds 和 git 命令，避免只看到最终 exit code。
  grep -nEi '(^|[[:space:]])(make([[:space:]]|\[)|git[[:space:]]|feeds[[:space:]]|\./scripts/|sudo[[:space:]]|Cloning into|Updating feed)' "$LOG" || true
}

extract_names() {
  grep -oEi 'CONFIG_PACKAGE_[A-Za-z0-9_.+-]+|luci-app-[A-Za-z0-9_.+-]+|package/feeds/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|[[:space:]](quickstart|taskd|smartdns|pbr|samba4|adguardhome)[[:space:]]' "$LOG" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u || true
}

extract_feeds() {
  grep -oEi 'feed[=/[:space:]]+[A-Za-z0-9_.-]+|package/feeds/[A-Za-z0-9_.-]+' "$LOG" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u || true
}

exit_lines="$(grep -nEi 'exit code|exit status|Process completed with exit code|returned[[:space:]]+[0-9]+' "$LOG" || true)"
if (( IS_FEED_FAILURE == 1 )) && [[ -n "$FEED_EXIT_CODE" ]]; then
  exit_lines="Feed Check exit code: $FEED_EXIT_CODE"
fi
[[ -n "$exit_lines" ]] || exit_lines='未在日志中明确打印 exit code；外层 shell 失败状态见 GitHub Actions。'

context_block() {
  local label="$1" line="$2" start end
  start=$((line - 500)); (( start < 1 )) && start=1
  end=$((line + 500))
  echo "===== $label：第 ${line} 行，前后各500行 ====="
  sed -n "${start},${end}p" "$LOG"
  echo
}

# 中文说明：单独保存两处 ERROR 上下文，不再只保留最后100行。
{
  echo "GitHub Actions Run ID: $RUN_ID"
  echo "Commit SHA: $COMMIT_SHA"
  echo "失败阶段: $STAGE"
  echo "第一个错误行: $FIRST_ERROR_LINE"
  echo "最后一个错误行: $LAST_ERROR_LINE"
  echo
  context_block '第一次真实错误' "$FIRST_ERROR_LINE"
  if [[ "$LAST_ERROR_LINE" != "$FIRST_ERROR_LINE" ]]; then
    context_block '最后一次真实错误' "$LAST_ERROR_LINE"
  else
    echo '===== 最后一次真实错误与第一次相同，已在上方完整列出 ====='
  fi
  echo
  echo '===== 失败命令上下文 ====='
  failure_commands
  echo
  echo '===== exit code / exit status ====='
  printf '%s\n' "$exit_lines"
} > "$CONTEXT"

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
  echo "Failure stage: $STAGE"
  echo "Failed command: ${FEED_FAILED_COMMAND:-见下方失败命令上下文}"
  echo "Exit code: ${FEED_EXIT_CODE:-见下方 exit code / exit status}"
  echo "First real error: $FIRST_ERROR"
  echo "Last relevant log lines:"
  tail -n 200 "$LOG"
  echo
  echo "失败阶段：$STAGE"
  echo "失败命令：${FEED_FAILED_COMMAND:-见下方失败命令上下文}"
  if [[ -z "$FEED_FAILED_COMMAND" ]]; then
    failure_commands | tail -n 30
  fi
  echo "真实错误：$FIRST_ERROR"
  echo "相关package："
  extract_names
  echo "相关feed："
  extract_feeds
  echo "exit code："
  printf '%s\n' "$exit_lines"
  echo
  echo '最后200行完整日志：'
  tail -n 200 "$LOG"
  echo
  echo '最后200行关键日志：'
  tail -n 200 "$MATCH_FILE"
  write_section 'MISSING_PACKAGE 列表' 'MISSING_PACKAGE'
  write_section 'MISSING_SOURCE 列表' 'MISSING_SOURCE'
  write_section 'make defconfig 后缺失 CONFIG 列表' 'MISSING: CONFIG_PACKAGE|MISSING CONFIG_PACKAGE'
  echo
  echo '建议处理方向：'
  if grep -qiE 'Collecting package info|feeds[[:space:]]+(update|install)|Updating feed|Create index file|package index|MISSING_PACKAGE|MISSING_SOURCE|duplicate package|package conflict|feed.*(failed|error|missing)' "$LOG"; then
    echo '- 检查 feeds.conf、feed 更新/安装顺序、index 生成、package Makefile 来源和重复包冲突。'
  fi
  if grep -qiE 'MISSING: CONFIG_PACKAGE|MISSING CONFIG_PACKAGE|dependency( on)? .*does not exist|dependency error' "$LOG"; then
    echo '- 检查 make defconfig 前 package 依赖、架构条件、select/depends 和配置符号。'
  fi
  if grep -qiE 'Makefile.*(parse|syntax|error)|parse error|syntax error|shell error|/bin/(ba)?sh:' "$LOG"; then
    echo '- 检查 Makefile 语法、shell 引号/命令替换和 feed package 元数据。'
  fi
  if grep -qiE 'No space left|out of memory|(^|[^[:alpha:]])killed([^[:alpha:]]|$)' "$LOG"; then
    echo '- 检查云端磁盘空间、JOBS 并发数、内存和缓存占用。'
  fi
  if grep -qiE 'download[[:space:]_-]*(failure|failed|error)|failed.*download' "$LOG"; then
    echo '- 检查 dl 缓存、下载 URL、网络重试和源码哈希。'
  fi
  echo '- 下载 error-context.txt 查看第一次/最后一次错误前后500行；保留完整 build.log。'
} > "$SUMMARY"

{
  cat "$SUMMARY"
  echo
  echo '===== 错误上下文文件 ====='
  echo "$CONTEXT"
  echo
  echo '===== 详细错误分类 ====='
  write_section 'Collecting package info / package index' 'Collecting package info.*(failed|error)|package info.*failed|Create index file.*(failed|error)|package index.*(failed|error)'
  write_section 'feeds update/install' 'feeds[[:space:]]+(update|install).*(failed|error)|Updating feed.*(failed|error)|Ignoring feed.*(failed|error|index missing)'
  write_section 'Makefile / syntax / shell' 'Makefile.*(parse|syntax|error)|parse error|Error evaluating|syntax error|shell error|/bin/(ba)?sh:'
  write_section 'duplicate / conflict' 'duplicate package|package conflict|conflict.*package'
  write_section 'dependency' 'dependency( on)? .*does not exist|dependency error'
  write_section '资源 / 下载' 'No space left|out of memory|(^|[^[:alpha:]])killed([^[:alpha:]]|$)|download[[:space:]_-]*(failure|failed|error)|failed.*download'
  write_section 'Git/feed' 'fatal:|clone.*(failed|error)|git.*(failed|error)|feed.*(failed|error|missing)'
  echo
  echo '===== 完整日志文件 ====='
  echo "$LOG"
} > "$REPORT"

echo "Error summary: $SUMMARY"
echo "Error context: $CONTEXT"
echo "Failure report: $REPORT"
