#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
ACCEPTED = ROOT / "production/accepted-preview/arthur-adh-quickstart.json"
MANAGER_PREFIXES = (
    "files/etc/AdGuardHome.yaml",
    "files/etc/config/AdGuardHome",
    "files/etc/init.d/AdGuardHome",
    "files/usr/lib/lua/luci/controller/AdGuardHome.lua",
    "files/usr/lib/lua/luci/model/cbi/AdGuardHome/",
    "files/usr/lib/lua/luci/view/AdGuardHome/",
    "files/usr/share/AdGuardHome/",
    "files/usr/share/luci/menu.d/luci-app-adguardhome.json",
    "files/usr/share/rpcd/acl.d/luci-app-adguardhome.json",
    "files/www/luci-static/resources/adguardhome/",
    "files/www/luci-static/resources/view/luci-app-adguardhome/",
)


def accepted_bytes(overlay: str, expected: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(ROOT), "show", f"HEAD:{overlay}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    data = result.stdout
    candidates = [data, data.replace(b"\r\n", b"\n")]
    normalized = data.replace(b"\r\n", b"\n")
    candidates.append(normalized.replace(b"\n", b"\r\n"))
    for candidate in candidates:
        if hashlib.sha256(candidate).hexdigest() == expected:
            return candidate
    raise AssertionError(f"accepted source bytes do not match the manifest: {overlay}")


def run_verifier(rootfs: Path, manifest: Path, package: Path) -> subprocess.CompletedProcess[str]:
    manager_package = rootfs.parent / "luci-app-adguardhome-manager.mk"
    source_root = rootfs.parent / "source-root"
    return subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/verify-final-rootfs-adh-manager.py"),
            str(rootfs),
            str(manifest),
            str(package),
            str(manager_package),
            str(source_root),
            "--accepted-manifest",
            str(ACCEPTED),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )


def main() -> int:
    accepted = json.loads(ACCEPTED.read_text(encoding="utf-8"))
    entries = [
        item
        for item in accepted["frozen_files"]
        if any(item["overlay"].startswith(prefix) for prefix in MANAGER_PREFIXES)
    ]
    required = {
        "files/usr/lib/lua/luci/controller/AdGuardHome.lua",
        "files/usr/lib/lua/luci/model/cbi/AdGuardHome/overview.lua",
        "files/usr/lib/lua/luci/view/AdGuardHome/overview.htm",
        "files/usr/share/luci/menu.d/luci-app-adguardhome.json",
        "files/usr/share/rpcd/acl.d/luci-app-adguardhome.json",
        "files/etc/config/AdGuardHome",
        "files/etc/init.d/AdGuardHome",
    }
    present = {item["overlay"] for item in entries}
    missing = required - present
    if missing:
        raise AssertionError(f"accepted manager manifest is incomplete: {sorted(missing)}")

    with tempfile.TemporaryDirectory(prefix="arthur-adh-rootfs-") as tmp_text:
        tmp = Path(tmp_text)
        rootfs = tmp / "rootfs"
        rootfs.mkdir()
        for item in entries:
            overlay = item["overlay"]
            target = rootfs / Path(overlay).relative_to("files")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(accepted_bytes(overlay, item["sha256"]))
            os.chmod(target, int(item["mode"], 8))

        manifest = tmp / "firmware.manifest"
        manifest.write_text(
            "luci-app-adguardhome - 26.test\n"
            "luci-app-adguardhome-manager - 1.0.test\n"
            "adguardhome - 0.107.test\n"
            "luci-base - 26.test\n"
            "luci-compat - 26.test\n"
            "rpcd-mod-file - 2025.test\n",
            encoding="utf-8",
        )
        package = tmp / "luci-app-adguardhome.mk"
        package.write_text(
            "LUCI_DEPENDS:=+adguardhome +luci-base\n"
            "LUCI_EXTRA_DEPENDS:=adguardhome (>=0.107.73-r3)\n",
            encoding="utf-8",
        )
        manager_package = tmp / "luci-app-adguardhome-manager.mk"
        manager_package.write_text(
            "DEPENDS:=+luci-app-adguardhome +luci-compat +rpcd-mod-file\n",
            encoding="utf-8",
        )
        package_archive = tmp / "source-root/bin/packages/test/luci-app-adguardhome-manager-1.0-r1.apk"
        package_archive.parent.mkdir(parents=True, exist_ok=True)
        package_archive.write_bytes(b"test package archive marker")

        result = run_verifier(rootfs, manifest, package)
        if result.returncode != 0:
            raise AssertionError(f"valid final rootfs was rejected:\n{result.stdout}")
        for marker in (
            "ADH_LUCI_FULL_MANAGER=PASS",
            "ADH_LIFECYCLE_START_STOP_RESTART=PASS",
            "ADH_ENABLE_DISABLE=PASS",
            "ADH_DEFAULT_STATE=DISABLED",
        ):
            if marker not in result.stdout:
                raise AssertionError(f"verifier did not report {marker}:\n{result.stdout}")

        overview = rootfs / "usr/lib/lua/luci/view/AdGuardHome/overview.htm"
        overview.write_text("corrupted view", encoding="utf-8")
        result = run_verifier(rootfs, manifest, package)
        if result.returncode == 0 or "hash mismatch" not in result.stdout.lower():
            raise AssertionError(f"corrupted manager view was not rejected:\n{result.stdout}")

    print("FINAL_ROOTFS_ADH_MANAGER_CONTRACT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
