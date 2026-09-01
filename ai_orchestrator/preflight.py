import json
import os
import shutil
import sys
from pathlib import Path


def inspect_project(root):
    root = Path(root)
    build_env = root / "build.env"
    config = root / "config" / "arthur.config"
    plugins = root / "config" / "required-plugins.txt"
    known_good_path = root / "production" / "known-good.json"
    source_tree = build_env.exists() and config.exists() and plugins.exists()
    config_text = config.read_text(encoding="utf-8") if config.exists() else ""
    build_text = build_env.read_text(encoding="utf-8") if build_env.exists() else ""
    required_count = 0
    if plugins.exists():
        required_count = len(
            [line for line in plugins.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")]
        )
    known_good = False
    try:
        metadata = json.loads(known_good_path.read_text(encoding="utf-8"))
        known_good = (
            metadata.get("verified") is True
            and metadata.get("device") == "jdcloud_re-ss-01"
            and metadata.get("target") == "qualcommax"
            and metadata.get("subtarget") == "ipq60xx"
        )
    except (OSError, ValueError):
        pass
    checks = {
        "python_supported": sys.version_info >= (3, 10),
        "source_tree": source_tree,
        "target_profile": all(
            value in build_text or value in config_text
            for value in ("jdcloud_re-ss-01", "qualcommax", "ipq60xx")
        ),
        "required_plugins": required_count,
        "known_good": known_good,
        "state_store": True,
    }
    # The Windows control plane is not the OpenWrt build environment.  Do not
    # turn the absence of Linux-only uci/make into a false pre-build blocker or
    # install substitute binaries.  The pinned source validation and actual
    # build run on the GitHub Linux runner.
    if os.name == "nt":
        host_tools = {"uci": "NOT_APPLICABLE", "make": "NOT_APPLICABLE"}
    else:
        host_tools = {
            name: "PASS" if shutil.which(name) else "UNKNOWN"
            for name in ("uci", "make")
        }
    build_plane = {
        "executor": "github-actions",
        "runner": "ubuntu-24.04",
        "host_tools": host_tools,
        "feed_provenance": "PINNED_SOURCE_VALIDATION_REQUIRED_ON_LINUX",
        "source_locks": {
            "known_good": (root / "config" / "arthur-known-good.lock").is_file(),
            "quickstart": (root / "config" / "istore-quickstart.lock").is_file(),
            "package_validation": (root / "scripts" / "check-package-sources.sh").is_file(),
        },
    }
    status = "READY" if checks["source_tree"] and checks["target_profile"] and checks["required_plugins"] == 22 and known_good else "INVALID_ENVIRONMENT"
    return {"status": status, "checks": checks, "build_plane": build_plane, "root": str(root)}
