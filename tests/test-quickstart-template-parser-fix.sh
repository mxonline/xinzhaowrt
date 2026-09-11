#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-$root/work/immortalwrt}"
bash "$root/scripts/apply-luci-template-fix.sh" "$src"
parser="$src/feeds/luci/modules/luci-lua-runtime/src/template_utils.c"
PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || PYTHON_BIN=python
"$PYTHON_BIN" - "$parser" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
needle = "case '\\r':\n\t\t\tbuf_append(out, \"\\\\r\", 2);"
assert needle in text, 'CRLF escaping is not present in the actual LuCI parser source'
print('LUCI_TEMPLATE_CRLF_ESCAPE=PASS')
PY
