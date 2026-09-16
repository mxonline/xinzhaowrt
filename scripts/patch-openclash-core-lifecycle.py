#!/usr/bin/env python3
"""Patch the upstream OpenClash updater for Arthur's bundled Meta core."""
from pathlib import Path
import sys

def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch-openclash-core-lifecycle.py <openclash_core.sh>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    guard = r'''# XinZhaoWrt: prefer the bundled Meta core on ordinary startup.
if [ -z "$2" ] && [ -z "$3" ] && [ -x "/etc/openclash/core/clash_meta" ]; then
   LOG_TIP "Bundled Meta Core already present, skip online download"
   dec_job_counter_and_restart 0
   del_lock
   exit 0
fi
'''
    needle = 'TARGET_CORE_PATH="$meta_core_path"\n'
    if "Bundled Meta Core already present, skip online download" not in text:
        if needle not in text:
            raise SystemExit("OpenClash core updater anchor missing")
        text = text.replace(needle, needle + guard, 1)
    arch_guard = r'''core_is_aarch64() {
   local file="$1" bytes
   if command -v readelf >/dev/null 2>&1; then
      readelf -h "$file" 2>/dev/null | grep -Eq 'Class:[[:space:]]+ELF64' &&
      readelf -h "$file" 2>/dev/null | grep -Eq 'Machine:[[:space:]]+AArch64'
      return $?
   fi
   bytes="$(od -An -tx1 -N20 "$file" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
   set -- $bytes
   [ "$#" -ge 20 ] && [ "$1" = 7f ] && [ "$2" = 45 ] && [ "$3" = 4c ] && [ "$4" = 46 ] &&
   [ "$5" = 02 ] && [ "$6" = 01 ] && [ "${19:-}" = b7 ] && [ "${20:-}" = 00 ]
}

'''
    needle = 'if [ "$CORE_TYPE" = "Oix" ]; then\n'
    if "core_is_aarch64() {" not in text:
        if needle not in text:
            raise SystemExit("OpenClash core type anchor missing")
        text = text.replace(needle, arch_guard + needle, 1)
    old = '''                  [ "$extract_success" = "true" ] && { extract_err=$(chmod 4755 "$TMP_FILE" 2>&1) || extract_success=false; }
                  [ "$extract_success" = "true" ] && { extract_err=$("$TMP_FILE" -v 2>&1) || extract_success=false; }
'''
    new = '''                  [ "$extract_success" = "true" ] && { extract_err=$(chmod 0755 "$TMP_FILE" 2>&1) || extract_success=false; }
                  [ "$extract_success" = "true" ] && {
                     if ! core_is_aarch64 "$TMP_FILE"; then
                        extract_err="architecture guard rejected non-AArch64 core"
                        extract_success=false
                     fi
                  }
                  [ "$extract_success" = "true" ] && { extract_err=$("$TMP_FILE" -v 2>&1) || extract_success=false; }
'''
    if old in text:
        text = text.replace(old, new, 1)
    elif "architecture guard rejected non-AArch64 core" not in text:
        raise SystemExit("OpenClash core validation anchor missing")
    old = '''               mv_err=$(mv -f "$TMP_FILE" "$TARGET_CORE_PATH" 2>&1)

               if [ "$?" == "0" ]; then
                  LOG_TIP "【"$CORE_TYPE"】Core Update Successful"
                  UPDATE_SUCCESS=1
                  restart=1
                  break
               else
'''
    new = '''               known_good="${TARGET_CORE_PATH}.known-good.$$"
               [ -f "$TARGET_CORE_PATH" ] && cp -fp "$TARGET_CORE_PATH" "$known_good"
               mv_err=$(mv -f "$TMP_FILE" "$TARGET_CORE_PATH" 2>&1)

               if [ "$?" == "0" ] && core_is_aarch64 "$TARGET_CORE_PATH" && "$TARGET_CORE_PATH" -v >/dev/null 2>&1; then
                  LOG_TIP "【"$CORE_TYPE"】Core Update Successful"
                  rm -f "$known_good"
                  UPDATE_SUCCESS=1
                  restart=1
                  break
               else
                  if [ -f "$known_good" ]; then
                     mv -f "$known_good" "$TARGET_CORE_PATH"
                  else
                     rm -f "$TARGET_CORE_PATH"
                  fi
                  rm -f "$TMP_FILE"
                  [ -n "$mv_err" ] || mv_err="post-install core validation failed"
'''
    if old in text:
        text = text.replace(old, new, 1)
    elif "post-install core validation failed" not in text:
        raise SystemExit("OpenClash core replacement anchor missing")
    path.write_text(text, encoding="utf-8")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
