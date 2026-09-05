#!/usr/bin/env python3
"""Isolated diagnostic probe for the Arthur headless Codex runtime.

This script intentionally stops before creating or resuming any Arthur production
runtime.  It verifies that the current process loads control-plane modules from
the expected clean checkout and that the explicit headless model binding is in
effect.  The remote model catalog is never queried.
"""

import asyncio
import importlib.metadata
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

EXIT = {
    "PROBE_OK": 0,
    "MODULE_ROOT_DRIFT": 10,
    "MODEL_BINDING_DRIFT": 11,
    "CODEX_IMPORT_FAILED": 12,
    "ACCOUNT_PREFLIGHT_FAILED": 13,
    "PROBE_INTERNAL_ERROR": 14,
}


def _under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _emit(payload, exit_class):
    payload["exit_class"] = exit_class
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True), flush=True)
    return EXIT[exit_class]


async def _account_probe():
    from ai_orchestrator import adapters

    module = adapters._import_sdk()
    executor = adapters.AsyncCodexExecutor(Path.cwd())
    codex = executor._new_codex(module)
    try:
        await codex.account()
    finally:
        if hasattr(codex, "close"):
            await codex.close()


def main() -> int:
    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "python_executable": sys.executable,
        "cwd": str(Path.cwd().resolve()),
        "sys_path": list(sys.path),
        "ai_orchestrator_file": None,
        "codex_compat_file": None,
        "configured_model": os.environ.get("HEADLESS_CODEX_MODEL", "").strip(),
        "effective_model": None,
        "openai_codex_version": None,
        "account_preflight_ok": False,
        "model_catalog_skipped": True,
    }

    raw_root = os.environ.get("ARTHUR_CONTROL_PLANE_CODE_ROOT", "").strip()
    if not raw_root:
        payload["error"] = "ARTHUR_CONTROL_PLANE_CODE_ROOT is not set"
        return _emit(payload, "PROBE_INTERNAL_ERROR")

    expected_root = Path(raw_root).resolve()
    sys.path.insert(0, str(expected_root))
    payload["sys_path"] = list(sys.path)

    try:
        import ai_orchestrator
        from ai_orchestrator import adapters, codex_compat
    except Exception as exc:
        payload["error_type"] = type(exc).__name__
        payload["error"] = str(exc)
        return _emit(payload, "CODEX_IMPORT_FAILED")

    try:
        module_file = Path(ai_orchestrator.__file__).resolve()
        compat_file = Path(codex_compat.__file__).resolve()
        payload["ai_orchestrator_file"] = str(module_file)
        payload["codex_compat_file"] = str(compat_file)
        payload["effective_model"] = codex_compat.configured_headless_codex_model()

        try:
            payload["openai_codex_version"] = importlib.metadata.version("openai-codex")
        except importlib.metadata.PackageNotFoundError:
            payload["openai_codex_version"] = None

        if not _under(module_file, expected_root) or not _under(compat_file, expected_root):
            return _emit(payload, "MODULE_ROOT_DRIFT")

        configured = payload["configured_model"] or codex_compat.DEFAULT_HEADLESS_CODEX_MODEL
        payload["configured_model"] = configured
        if payload["effective_model"] != configured:
            return _emit(payload, "MODEL_BINDING_DRIFT")

        if os.environ.get("ARTHUR_PROBE_SKIP_ACCOUNT") == "1":
            payload["account_preflight_ok"] = True
            return _emit(payload, "PROBE_OK")

        try:
            asyncio.run(_account_probe())
        except adapters.SDKUnavailable as exc:
            payload["error_type"] = type(exc).__name__
            payload["error"] = str(exc)
            return _emit(payload, "CODEX_IMPORT_FAILED")
        except Exception as exc:
            payload["error_type"] = type(exc).__name__
            payload["error"] = str(exc)
            return _emit(payload, "ACCOUNT_PREFLIGHT_FAILED")

        payload["account_preflight_ok"] = True
        return _emit(payload, "PROBE_OK")
    except Exception as exc:
        payload["error_type"] = type(exc).__name__
        payload["error"] = str(exc)
        return _emit(payload, "PROBE_INTERNAL_ERROR")


if __name__ == "__main__":
    raise SystemExit(main())
