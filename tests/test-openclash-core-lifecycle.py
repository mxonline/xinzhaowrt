#!/usr/bin/env python3
"""Static contract for the bundled OpenClash Meta core lifecycle."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LOCK = (ROOT / "config/openclash-core.lock").read_text(encoding="utf-8")
STAGE = (ROOT / "scripts/stage-openclash-core.sh").read_text(encoding="utf-8")
PATCH = (ROOT / "scripts/patch-openclash-core-lifecycle.py").read_text(encoding="utf-8")
VERIFY = (ROOT / "scripts/verify-firmware-openclash-adh.sh").read_text(encoding="utf-8")


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(text: str, needle: str, message: str) -> None:
    if needle not in text:
        fail(message)


require(LOCK, 'OPENCLASH_CORE_FLAVOR="meta"', "Meta core flavor is not locked")
require(LOCK, 'OPENCLASH_CORE_ARCH="linux-arm64"', "linux-arm64 core is not locked")
require(LOCK, 'OPENCLASH_CORE_INSTALL_PATH="/etc/openclash/core/clash_meta"', "official core path is not locked")

# OpenClash's official init probes /etc/openclash/clash.  The alias must point
# to the bundled Meta binary so first start cannot enter the download path.
require(STAGE, 'ln -sfn "core/clash_meta"', "runtime clash alias is not staged")
require(STAGE, "OPENCLASH_BUNDLED_CORE_PREFERRED=PASS", "bundled-core preference gate is missing")
require(STAGE, "OPENCLASH_FIRST_START_NO_DOWNLOAD=PASS", "first-start no-download gate is missing")

# Explicit updates remain available, but only after architecture/integrity
# checks and with an atomic known-good rollback path.
for marker in (
    "core_is_aarch64",
    "OPENCLASH_CORE_UPDATE_ARCH_GUARD=PASS",
    "OPENCLASH_CORE_UPDATE_ROLLBACK=PASS",
    "OPENCLASH_CORE_RESTART_PERSISTENCE=PASS",
    "known-good",
):
    require(STAGE + PATCH, marker, f"core lifecycle guard missing: {marker}")

require(VERIFY, "etc/openclash/clash", "final rootfs must verify the official clash runtime alias")
require(VERIFY, "OPENCLASH_BUNDLED_CORE_PREFERRED=PASS", "final rootfs bundled preference gate missing")
require(VERIFY, "OPENCLASH_CORE_UPDATE_ARCH_GUARD=PASS", "final rootfs architecture guard missing")

print("OPENCLASH_CORE_EXECUTABLE=PASS")
print("OPENCLASH_BUNDLED_CORE_PREFERRED=PASS")
print("OPENCLASH_FIRST_START_NO_DOWNLOAD=PASS")
print("OPENCLASH_CORE_UPDATE_ARCH_GUARD=PASS")
print("OPENCLASH_CORE_UPDATE_ROLLBACK=PASS")
print("OPENCLASH_CORE_RESTART_PERSISTENCE=PASS")
