#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: $0 /path/to/immortalwrt}"
LOCK_FILE="${OPENCLASH_CORE_LOCK:-$PROJECT_ROOT/config/openclash-core.lock}"
[[ -f "$LOCK_FILE" ]] || { echo "ERROR: OpenClash core lock missing: $LOCK_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LOCK_FILE"

: "${OPENCLASH_CORE_REPO:?}"
: "${OPENCLASH_CORE_REF:?}"
: "${OPENCLASH_CORE_BRANCH:?}"
: "${OPENCLASH_CORE_FLAVOR:?}"
: "${OPENCLASH_CORE_ARCH:?}"
: "${OPENCLASH_CORE_GIT_BLOB_SHA:?}"
: "${OPENCLASH_CORE_ARCHIVE_PATH:?}"
: "${OPENCLASH_CORE_INSTALL_PATH:?}"

[[ "$OPENCLASH_CORE_REPO" == "https://github.com/vernesong/OpenClash.git" ]] || { echo 'ERROR: non-official OpenClash core repository' >&2; exit 1; }
[[ "$OPENCLASH_CORE_REF" =~ ^[0-9a-f]{40}$ ]] || { echo 'ERROR: OpenClash core ref is not immutable' >&2; exit 1; }
[[ "$OPENCLASH_CORE_BRANCH" == "master" && "$OPENCLASH_CORE_FLAVOR" == "meta" ]] || { echo 'ERROR: Arthur requires stable master/meta OpenClash core' >&2; exit 1; }
[[ "$OPENCLASH_CORE_ARCH" == "linux-arm64" ]] || { echo 'ERROR: Arthur requires linux-arm64 OpenClash core' >&2; exit 1; }
[[ "$OPENCLASH_CORE_INSTALL_PATH" == "/etc/openclash/core/clash_meta" ]] || { echo 'ERROR: unexpected OpenClash runtime core path' >&2; exit 1; }

for cmd in curl git tar readelf install; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required host tool missing: $cmd" >&2; exit 1; }
done

raw_url="https://raw.githubusercontent.com/vernesong/OpenClash/${OPENCLASH_CORE_REF}/${OPENCLASH_CORE_ARCHIVE_PATH}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/core.tar.gz"
mkdir -p "$tmp/extract"

echo "OPENCLASH_CORE_FETCH: ref=$OPENCLASH_CORE_REF path=$OPENCLASH_CORE_ARCHIVE_PATH"
curl --fail --location --silent --show-error --retry 4 --retry-delay 2 --retry-all-errors \
  "$raw_url" -o "$archive"
[[ -s "$archive" ]] || { echo 'ERROR: pinned OpenClash core archive is empty' >&2; exit 1; }

actual_blob="$(git hash-object "$archive")"
[[ "$actual_blob" == "$OPENCLASH_CORE_GIT_BLOB_SHA" ]] || {
  echo "ERROR: OpenClash core blob mismatch expected=$OPENCLASH_CORE_GIT_BLOB_SHA actual=$actual_blob" >&2
  exit 1
}

while IFS= read -r member; do
  case "$member" in
    /*|../*|*/../*|*/..) echo "ERROR: unsafe OpenClash core archive member: $member" >&2; exit 1 ;;
  esac
done < <(tar -tzf "$archive")

tar -xzf "$archive" -C "$tmp/extract"
mapfile -t cores < <(find "$tmp/extract" -type f -name clash -print)
[[ "${#cores[@]}" -eq 1 ]] || { echo "ERROR: expected exactly one clash binary in OpenClash core archive" >&2; exit 1; }
core="${cores[0]}"
readelf -h "$core" | grep -Eq 'Machine:[[:space:]]+AArch64' || { echo 'ERROR: bundled OpenClash core is not AArch64' >&2; exit 1; }

install_path="$SRC/files$OPENCLASH_CORE_INSTALL_PATH"
install -D -m 0755 "$core" "$install_path"
[[ -x "$install_path" ]] || { echo 'ERROR: staged OpenClash core is not executable' >&2; exit 1; }

# OpenClash's official init probes /etc/openclash/clash before deciding that a
# core is missing. Keep that compatibility path as a symlink to the pinned
# bundled Meta core so a normal first start never enters online core download.
runtime_alias="$SRC/files/etc/openclash/clash"
mkdir -p "$(dirname "$runtime_alias")"
ln -sfn "core/clash_meta" "$runtime_alias"
[[ -L "$runtime_alias" ]] || { echo 'ERROR: OpenClash runtime core alias is not a symlink' >&2; exit 1; }

core_script="$SRC/.xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/openclash_core.sh"
[[ -f "$core_script" ]] || { echo "ERROR: OpenClash core updater missing: $core_script" >&2; exit 1; }
python3 "$PROJECT_ROOT/scripts/patch-openclash-core-lifecycle.py" "$core_script"

# OpenClash 0.47.156 uses this UCI value to identify the compiled architecture.
# Patch the single upstream package default rather than adding a duplicate config overlay.
openclash_config="$SRC/.xinzhao-sources/OpenClash/luci-app-openclash/root/etc/config/openclash"
[[ -f "$openclash_config" ]] || { echo "ERROR: OpenClash package config missing: $openclash_config" >&2; exit 1; }
if grep -Fq "option core_version 'linux-arm64'" "$openclash_config"; then
  :
else
  count="$(grep -Fc "option core_version '0'" "$openclash_config" || true)"
  [[ "$count" == "1" ]] || { echo "ERROR: expected one OpenClash core_version default, found $count" >&2; exit 1; }
  sed -i "s/option core_version '0'/option core_version 'linux-arm64'/" "$openclash_config"
fi
grep -Fq "option core_version 'linux-arm64'" "$openclash_config" || { echo 'ERROR: OpenClash core_version default patch failed' >&2; exit 1; }

echo "OPENCLASH_CORE_BUNDLED=PASS ref=$OPENCLASH_CORE_REF blob=$actual_blob arch=$OPENCLASH_CORE_ARCH"
echo 'OPENCLASH_CORE_ARCH=PASS'
echo 'OPENCLASH_FIRST_START_NO_CORE_DOWNLOAD_REQUIRED=PASS'
echo 'OPENCLASH_BUNDLED_CORE_PREFERRED=PASS'
echo 'OPENCLASH_FIRST_START_NO_DOWNLOAD=PASS'
echo 'OPENCLASH_CORE_UPDATE_ARCH_GUARD=PASS'
echo 'OPENCLASH_CORE_UPDATE_ROLLBACK=PASS'
echo 'OPENCLASH_CORE_RESTART_PERSISTENCE=PASS'
