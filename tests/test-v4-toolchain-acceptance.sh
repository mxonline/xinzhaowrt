#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/scripts/v4-verify-toolchain.sh"

[[ -x "$VERIFY" ]] || {
  echo 'FAIL: missing executable scripts/v4-verify-toolchain.sh' >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'sdk\n' > "$dir/immortalwrt-sdk-test.tar.zst"
  printf 'imagebuilder\n' > "$dir/immortalwrt-imagebuilder-test.tar.zst"
  printf 'packages\n' > "$dir/package-repositories.tar.gz"
  cp "$ROOT/config/arthur-known-good.lock" "$dir/arthur-known-good.lock"
  cat > "$dir/toolchain-provenance.json" <<'JSON'
{
  "schema_version": "1.0",
  "lane": "TOOLCHAIN_BOOTSTRAP",
  "known_good_tag": "v0.1.0",
  "device": "jdcloud_re-ss-01",
  "target": "qualcommax",
  "subtarget": "ipq60xx",
  "upstream_commit": "27e26e324bee0b0c2a4eb58e2e9121fea5d43194"
}
JSON
  (
    cd "$dir"
    sha256sum immortalwrt-sdk-test.tar.zst \
      immortalwrt-imagebuilder-test.tar.zst \
      package-repositories.tar.gz \
      arthur-known-good.lock \
      toolchain-provenance.json > SHA256SUMS
  )
}

valid="$tmp/valid"
make_fixture "$valid"
TOOLCHAIN_DIR="$valid" "$VERIFY" >/dev/null
[[ -s "$valid/toolchain-acceptance.json" ]]
grep -q '"status": "verified"' "$valid/toolchain-acceptance.json"
grep -q '"known_good_tag": "v0.1.0"' "$valid/toolchain-acceptance.json"

bad_checksum="$tmp/bad-checksum"
make_fixture "$bad_checksum"
printf 'corrupt\n' >> "$bad_checksum/immortalwrt-sdk-test.tar.zst"
if TOOLCHAIN_DIR="$bad_checksum" "$VERIFY" >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted a checksum mismatch' >&2
  exit 1
fi

bad_commit="$tmp/bad-commit"
make_fixture "$bad_commit"
python3 - "$bad_commit/toolchain-provenance.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
d['upstream_commit'] = '0000000000000000000000000000000000000000'
json.dump(d, open(p, 'w', encoding='utf-8'), indent=2)
PY
(
  cd "$bad_commit"
  sha256sum immortalwrt-sdk-test.tar.zst \
    immortalwrt-imagebuilder-test.tar.zst \
    package-repositories.tar.gz \
    arthur-known-good.lock \
    toolchain-provenance.json > SHA256SUMS
)
if TOOLCHAIN_DIR="$bad_commit" "$VERIFY" >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted mismatched Known-Good provenance' >&2
  exit 1
fi

bad_lock="$tmp/bad-lock"
make_fixture "$bad_lock"
printf 'corrupt-lock\n' >> "$bad_lock/arthur-known-good.lock"
(
  cd "$bad_lock"
  sha256sum immortalwrt-sdk-test.tar.zst \
    immortalwrt-imagebuilder-test.tar.zst \
    package-repositories.tar.gz \
    arthur-known-good.lock \
    toolchain-provenance.json > SHA256SUMS
)
if TOOLCHAIN_DIR="$bad_lock" "$VERIFY" >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted a Known-Good lock mismatch' >&2
  exit 1
fi

missing="$tmp/missing"
make_fixture "$missing"
rm -f "$missing/immortalwrt-imagebuilder-test.tar.zst"
if TOOLCHAIN_DIR="$missing" "$VERIFY" >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted missing ImageBuilder' >&2
  exit 1
fi

echo 'PASS: v4 toolchain acceptance gate behavior is correct.'
