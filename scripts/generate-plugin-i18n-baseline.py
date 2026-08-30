#!/usr/bin/env python3
"""Discover real LuCI zh-cn translation packages for the frozen plugin baseline.

The LuCI build system creates luci-i18n-*-zh-cn only for packages using the
LuCI translation machinery (normally ``luci.mk``) and an actual Chinese PO
tree.  A pinned external application may instead ship a verified Chinese LMO
inside its source tree.  The workflow wraps that existing upstream artifact in
an explicit luci-i18n package; arbitrary names without a PO/LMO artifact are
still not treated as translations.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def read_plugins(path: Path) -> list[str]:
    plugins: list[str] = []
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("luci-app-"):
            raise SystemExit(f"invalid baseline package: {line}")
        plugins.append(line)
    if len(plugins) != len(set(plugins)):
        raise SystemExit("duplicate baseline plugin")
    return plugins


def source_candidates(root: Path, package: str) -> list[Path]:
    """Find package directories without following repository symlink loops."""
    exact = [
        root / "applications" / package,
        root / package,
        root / "luci" / package,
        root / "luci-app-" / package,
    ]
    found = [p for p in exact if p.is_dir() and (p / "Makefile").is_file()]
    if found:
        return found
    for current, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if d not in {".git", "build_dir", "staging_dir", "tmp"}]
        if Path(current).name == package and "Makefile" in files:
            found.append(Path(current))
    return found


def has_zh_cn_source(path: Path) -> bool:
    # luci.mk aliases zh_Hans to zh-cn.  Both layouts are used by the
    # official feed and the pinned external feeds, so inspect the real PO
    # directory rather than treating a language-name file as a package.
    for language_dir in ("zh_Hans", "zh-cn", "zh_CN"):
        zh_dir = path / "po" / language_dir
        if zh_dir.is_dir() and any(p.suffix == ".po" for p in zh_dir.iterdir()):
            return True
    # Some pinned external LuCI applications ship the compiled translation
    # artifact directly.  It remains source-verifiable and is packaged by the
    # workflow under the canonical luci-i18n-* name.
    lmo_root = path / "root" / "usr" / "lib" / "lua" / "luci" / "i18n"
    if any(p.is_file() and p.name.endswith(".zh-cn.lmo") for p in lmo_root.glob("*.lmo")):
        return True
    return False


def has_separate_translation_package(path: Path, basename: str) -> bool:
    """Return whether this source defines a separate LuCI translation package.

    ``luci.mk`` dynamically defines luci-i18n-* packages from the PO tree.  A
    few packages define the same package explicitly, so accept that form as
    well.  Merely having ``po/zh-cn`` is insufficient (OpenClash embeds those
    files in luci-app-openclash).
    """
    makefile = path / "Makefile"
    if not makefile.is_file():
        return False
    text = makefile.read_text(encoding="utf-8", errors="replace")
    lines = [line.split("#", 1)[0] for line in text.splitlines()]
    if any("luci.mk" in line for line in lines):
        return True
    package_name = f"luci-i18n-{basename}-zh-cn"
    return any(package_name in line for line in lines)


def translation_package_candidates(root: Path, package: str) -> list[Path]:
    """Find explicit translation-package recipes added by the build lane."""
    found: list[Path] = []
    for current, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if d not in {".git", "build_dir", "staging_dir", "tmp"}]
        if Path(current).name == package and "Makefile" in files:
            found.append(Path(current))
    return found


def package_present(package: str, package_dirs: list[Path], rootfs: Path | None) -> bool:
    prefix = f"{package}-"
    for directory in package_dirs:
        if directory.is_dir() and any(p.name.startswith(prefix) and p.suffix == ".apk" for p in directory.rglob("*.apk")):
            return True
    if rootfs:
        db = rootfs / "lib" / "apk" / "db" / "installed"
        if db.is_file():
            return any(line.strip() == f"P:{package}" for line in db.read_text(errors="replace").splitlines())
        opkg = rootfs / "usr" / "lib" / "opkg" / "status"
        if opkg.is_file():
            return f"Package: {package}" in opkg.read_text(errors="replace")
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, action="append", default=[])
    parser.add_argument("--package-dir", type=Path, action="append", default=[])
    parser.add_argument("--rootfs", type=Path)
    parser.add_argument("--feed-commit", default="")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    plugins = read_plugins(args.baseline)
    records = []
    for plugin in plugins:
        basename = plugin[len("luci-app-") :]
        zh_package = f"luci-i18n-{basename}-zh-cn"
        sources: list[Path] = []
        for root in args.source_root:
            if root.exists():
                candidates = source_candidates(root, plugin)
                # Source-root order is the package provenance order.  Once a
                # selected feed contains this package, do not fall through to
                # a same-named package from another feed.
                if candidates:
                    sources = candidates
                    break
        available_sources = [
            p
            for p in sources
            if has_zh_cn_source(p) and has_separate_translation_package(p, basename)
        ]
        # A source tree may expose a real embedded zh-cn LMO while the
        # upstream package does not define a separate subpackage.  The
        # workflow can provide an explicit wrapper recipe for that artifact.
        if not available_sources:
            for root in args.source_root:
                candidates = translation_package_candidates(root, zh_package)
                if candidates:
                    sources = candidates
                    break
            available_sources = [
                p
                for p in sources
                if has_zh_cn_source(p) and has_separate_translation_package(p, basename)
            ]
        available = bool(available_sources)
        included = package_present(zh_package, args.package_dir, args.rootfs)
        records.append(
            {
                "plugin": plugin,
                "luci_package": plugin,
                "zh_cn_package": zh_package,
                "available": available,
                "included": included,
                "runtime_verified": False,
                "source_paths": [str(p).replace("\\", "/") for p in available_sources[:4]],
                "reason": "UPSTREAM_ZH_CN_AVAILABLE" if available else "ZH_CN_NOT_AVAILABLE_UPSTREAM",
            }
        )

    available_count = sum(1 for record in records if record["available"])
    output = {
        "baseline_plugins": len(records),
        "plugins_with_upstream_zh_cn": available_count,
        "zh_cn_packages_included": sum(1 for record in records if record["available"] and record["included"]),
        "feed_commit": args.feed_commit,
        "plugins": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        f"PLUGIN_I18N_BASELINE baseline={len(records)} available={available_count} "
        f"included={output['zh_cn_packages_included']} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
