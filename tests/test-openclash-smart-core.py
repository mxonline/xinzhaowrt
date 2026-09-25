from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import io
import os


ROOT = Path(__file__).resolve().parents[1]
STAGER = ROOT / "scripts/stage-openclash-core.py"
SELECTOR = ROOT / "files/usr/libexec/xinzhao-openclash-core-select"
SMART_PATCH = ROOT / "patches/openclash/0014-smart-core-bundle-and-runtime-selection.patch"


def git_blob_sha1(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def fake_aarch64_elf() -> bytes:
    image = bytearray(64)
    image[:4] = b"\x7fELF"
    image[4:7] = bytes((2, 1, 1))
    struct.pack_into("<H", image, 18, 183)
    return bytes(image)


def run_selector(config: Path, meta: Path, smart: Path, digest: Path) -> subprocess.CompletedProcess[str]:
    shell = shutil.which("bash") or shutil.which("sh")
    if not shell and sys.platform == "win32":
        candidates = (
            Path("C:/Program Files/Git/bin/bash.exe"),
            Path("C:/Program Files/Git/usr/bin/bash.exe"),
        )
        shell = next((str(path) for path in candidates if path.is_file()), None)
    if not shell:
        raise AssertionError("POSIX shell is required to exercise the installed core selector")
    env = os.environ.copy()
    if sys.platform == "win32" and "Git/bin/bash.exe" in shell.replace("\\", "/"):
        env["PATH"] = str(Path(shell).parent.parent / "usr/bin") + os.pathsep + env.get("PATH", "")
    return subprocess.run(
        [shell, str(SELECTOR), str(config), str(meta), str(smart), str(digest)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
        env=env,
    )


def run_selector_with_uci(
    config: Path,
    meta: Path,
    smart: Path,
    digest: Path,
    *,
    oix_token: str = "",
    smart_enable: str = "",
    core_type: str = "",
) -> subprocess.CompletedProcess[str]:
    shell = shutil.which("bash") or shutil.which("sh")
    if not shell and sys.platform == "win32":
        candidates = (
            Path("C:/Program Files/Git/bin/bash.exe"),
            Path("C:/Program Files/Git/usr/bin/bash.exe"),
        )
        shell = next((str(path) for path in candidates if path.is_file()), None)
    if not shell:
        raise AssertionError("POSIX shell is required to exercise the installed core selector")
    env = os.environ.copy()
    env.update({
        "MOCK_OIX_TOKEN": oix_token,
        "MOCK_SMART_ENABLE": smart_enable,
        "MOCK_CORE_TYPE": core_type,
    })
    wrapper = r'''
uci() {
  if [ "$1" = "-q" ] && [ "$2" = "get" ]; then
    case "$3" in
      openclash.config.oix_token) printf '%s\n' "$MOCK_OIX_TOKEN" ;;
      openclash.config.smart_enable) printf '%s\n' "$MOCK_SMART_ENABLE" ;;
      openclash.config.core_type) printf '%s\n' "$MOCK_CORE_TYPE" ;;
      *) return 1 ;;
    esac
    return 0
  fi
  return 1
}
. "$1" "$2" "$3" "$4" "$5"
'''
    return subprocess.run(
        [shell, "-c", wrapper, "selector", str(SELECTOR), str(config), str(meta), str(smart), str(digest)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
        env=env,
    )


def verify_patched_openclash_shell_syntax() -> None:
    source_root_text = os.environ.get("OPENCLASH_PRE_0014_SOURCE")
    if not source_root_text:
        return

    source_root = Path(source_root_text)
    relative_files = (
        Path("luci-app-openclash/root/etc/init.d/openclash"),
        Path("luci-app-openclash/root/usr/share/openclash/openclash_core.sh"),
    )
    with tempfile.TemporaryDirectory(prefix="openclash-smart-patch-syntax-") as tmp_text:
        patched_root = Path(tmp_text)
        for relative in relative_files:
            source = source_root / relative
            if not source.is_file():
                raise AssertionError(f"pre-0014 OpenClash source is missing {relative}")
            destination = patched_root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

        init_git = subprocess.run(
            ["git", "init", "--quiet"],
            cwd=patched_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if init_git.returncode:
            raise AssertionError(f"could not create disposable OpenClash patch tree:\n{init_git.stdout}")

        apply = subprocess.run(
            ["git", "apply", "--recount", str(SMART_PATCH)],
            cwd=patched_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if apply.returncode:
            raise AssertionError(f"Smart Core patch did not apply to the pinned source:\n{apply.stdout}")

        shell = shutil.which("sh") or shutil.which("bash")
        if not shell and sys.platform == "win32":
            candidates = (
                Path("C:/Program Files/Git/usr/bin/sh.exe"),
                Path("C:/Program Files/Git/bin/bash.exe"),
            )
            shell = next((str(path) for path in candidates if path.is_file()), None)
        if not shell:
            raise AssertionError("POSIX shell is required to parse the patched OpenClash init script")

        init_script = patched_root / relative_files[0]
        parsed = subprocess.run(
            [shell, "-n", str(init_script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if parsed.returncode:
            raise AssertionError(f"patched OpenClash init script has invalid shell syntax:\n{parsed.stdout}")
    print("OPENCLASH_SMART_PATCH_SHELL_SYNTAX=PASS")


def main() -> int:
    verify_patched_openclash_shell_syntax()
    selector_source = SELECTOR.read_text(encoding="utf-8")
    if "tr -d '[:space:]'" in selector_source:
        raise AssertionError(
            "Smart Core SHA pin parsing must not use tr's [:space:] class; "
            "OpenWrt BusyBox tr treats it as a literal delete set"
        )

    patch_stats = subprocess.run(
        ["git", "apply", "--recount", "--stat", str(SMART_PATCH)],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
    )
    if patch_stats.returncode or "clash_smart" not in SMART_PATCH.read_text(encoding="utf-8"):
        raise AssertionError(f"Smart Core OpenClash patch is malformed or lacks dedicated Smart paths:\n{patch_stats.stdout}")
    package_hook = (ROOT / "scripts/add-custom-packages.sh").read_text(encoding="utf-8")
    if "0014-smart-core-bundle-and-runtime-selection.patch" not in package_hook:
        raise AssertionError("Smart Core selection patch is not wired into the reproducible OpenClash source preparation")

    with tempfile.TemporaryDirectory(prefix="openclash-smart-core-") as tmp_text:
        tmp = Path(tmp_text)
        archive = tmp / "smart.tar.gz"
        binary = fake_aarch64_elf()
        with tarfile.open(archive, "w:gz") as bundle:
            member = tarfile.TarInfo("clash")
            member.mode = 0o755
            member.size = len(binary)
            bundle.addfile(member, io.BytesIO(binary))
        archive_bytes = archive.read_bytes()
        lock = tmp / "smart-lock.json"
        lock.write_text(json.dumps({
            "schema_version": 1,
            "source_repository": "vernesong/OpenClash",
            "source_ref": "a" * 40,
            "core_version": "alpha-smart-test",
            "core_type": "Smart",
            "asset_path": "master/smart/clash-linux-arm64.tar.gz",
            "asset_size_bytes": len(archive_bytes),
            "asset_git_blob_sha1": git_blob_sha1(archive_bytes),
            "binary_name": "clash",
            "install_path": "/etc/openclash/core/clash_smart",
            "elf_class": 64,
            "elf_machine": 183,
        }), encoding="utf-8")
        staged = tmp / "package/files/clash_smart"
        report = tmp / "smart-stage.txt"
        stage = subprocess.run(
            [sys.executable, str(STAGER), str(lock), str(archive), str(staged), str(report)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
        )
        if stage.returncode:
            raise AssertionError(f"valid official Smart archive was rejected:\n{stage.stdout}")
        sidecar = staged.with_suffix(".sha256")
        expected = hashlib.sha256(binary).hexdigest()
        if staged.read_bytes() != binary or sidecar.read_text(encoding="ascii").strip() != expected:
            raise AssertionError("Smart Core staging did not preserve bytes and emit its SHA-256 sidecar")
        if "OPENCLASH_SMART_CORE_BUNDLED=PASS" not in report.read_text(encoding="utf-8"):
            raise AssertionError("Smart stage report lacks its bundle PASS marker")

        executable_suffix = ".exe" if sys.platform == "win32" else ""
        meta = tmp / f"clash_meta{executable_suffix}"
        smart = tmp / f"clash_smart{executable_suffix}"
        digest = tmp / "clash_smart.sha256"
        meta.write_bytes(b"meta-core-must-remain-untouched")
        meta.chmod(0o755)
        shutil.copyfile(staged, smart)
        shutil.copyfile(sidecar, digest)
        smart.chmod(0o755)
        config = tmp / "active.yaml"
        config.write_text("proxy-groups:\n  - name: smart\n    type: smart\n", encoding="utf-8")
        selected = run_selector(config, meta, smart, digest)
        if selected.returncode or selected.stdout.strip().splitlines()[-1] != str(smart):
            raise AssertionError(f"active Smart YAML did not select Smart Core:\n{selected.stdout}")
        config.write_text('proxy-groups: [{name: smart-inline, type: "smart"}]\n', encoding="utf-8")
        selected = run_selector(config, meta, smart, digest)
        if selected.returncode or selected.stdout.strip().splitlines()[-1] != str(smart):
            raise AssertionError(f"inline Smart YAML did not select Smart Core:\n{selected.stdout}")
        config.write_text("# type: smart is a comment, not an active group\nproxy-groups:\n  - type: select\n", encoding="utf-8")
        selected = run_selector(config, meta, smart, digest)
        if selected.returncode or selected.stdout.strip().splitlines()[-1] != str(meta):
            raise AssertionError(f"commented Smart text was treated as an active group:\n{selected.stdout}")
        if meta.read_bytes() != b"meta-core-must-remain-untouched":
            raise AssertionError("Smart selection modified or replaced the Meta Core")

        config.write_text("proxy-groups:\n  - name: default\n    type: select\n", encoding="utf-8")
        selected = run_selector(config, meta, smart, digest)
        if selected.returncode or selected.stdout.strip().splitlines()[-1] != str(meta):
            raise AssertionError(f"non-Smart YAML did not select Meta Core:\n{selected.stdout}")

        selected = run_selector_with_uci(config, meta, smart, digest, smart_enable="1")
        if selected.returncode or selected.stdout.strip().splitlines()[-1] != str(smart):
            raise AssertionError(f"smart_enable=1 did not select Smart Core:\n{selected.stdout}")
        selected = run_selector_with_uci(config, meta, smart, digest, core_type="Smart")
        if selected.returncode or selected.stdout.strip().splitlines()[-1] != str(smart):
            raise AssertionError(f"core_type=Smart did not select Smart Core:\n{selected.stdout}")
        selected = run_selector_with_uci(
            config, meta, smart, digest, oix_token="opaque-oix-token", smart_enable="1", core_type="Smart"
        )
        if selected.returncode or selected.stdout.strip().splitlines()[-1] != str(meta):
            raise AssertionError(f"Oix priority did not preserve Meta selection:\n{selected.stdout}")

        smart.write_bytes(binary + b"tampered")
        config.write_text("proxy-groups:\n  - type: smart\n", encoding="utf-8")
        rejected = run_selector(config, meta, smart, digest)
        if rejected.returncode == 0 or "SHA" not in rejected.stdout:
            raise AssertionError(f"tampered Smart Core was not rejected fail-fast:\n{rejected.stdout}")

        smart.write_bytes(binary)
        non_executable = tmp / "clash_smart_noexec"
        non_executable.write_bytes(binary)
        non_executable.chmod(0o644)
        rejected = run_selector(config, meta, non_executable, digest)
        if rejected.returncode == 0 or "executable" not in rejected.stdout.lower():
            raise AssertionError(f"non-executable Smart Core was not rejected fail-fast:\n{rejected.stdout}")

    print("OPENCLASH_SMART_CORE_CONTRACT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
