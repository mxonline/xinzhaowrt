"""Windows process policy for the headless daemon and Codex SDK bridge."""

import os
import shutil
import subprocess
import sys
from pathlib import Path


CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
CREATE_NEW_PROCESS_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)
CREATE_NEW_CONSOLE = getattr(subprocess, "CREATE_NEW_CONSOLE", 0x00000010)
STARTF_USESHOWWINDOW = getattr(subprocess, "STARTF_USESHOWWINDOW", 0x00000001)
SW_HIDE = 0


def hidden_creation_flags():
    if os.name != "nt":
        return 0
    return CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP


def hidden_startupinfo():
    if os.name != "nt":
        return None
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= STARTF_USESHOWWINDOW
    startup.wShowWindow = SW_HIDE
    return startup


def pythonw_path():
    executable = Path(sys.executable)
    candidate = executable.with_name("pythonw.exe")
    return candidate if candidate.exists() else executable


def runtime_python_path():
    """Choose a supported Python for resumed Runtime processes.

    The system ``python.exe`` on this host is 3.8, while the Codex SDK needs
    3.10+.  Prefer the bundled workspace runtime used by the successful
    preflight, then an explicit override, then the current interpreter.
    """
    override = os.environ.get("XINZHAO_RUNTIME_PYTHON")
    candidates = []
    if override:
        candidates.append(Path(override))
    candidates.append(Path.home() / "AppData" / "Local" / "Programs" / "Python" / "Python314" / "python.exe")
    candidates.append(Path.home() / ".cache" / "codex-runtimes" / "codex-primary-runtime" / "dependencies" / "python" / "python.exe")
    found = shutil.which("python3")
    if found:
        candidates.append(Path(found))
    candidates.append(Path(sys.executable))
    for candidate in candidates:
        try:
            exists = candidate.exists()
        except OSError:
            exists = False
        if exists:
            try:
                if sys.version_info >= (3, 10) and candidate == Path(sys.executable):
                    return candidate
                probe = subprocess.run(
                    [str(candidate), "-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                )
                if probe.returncode == 0:
                    return candidate
            except (OSError, subprocess.SubprocessError):
                continue
    return Path(sys.executable)


def hidden_codex_launch_args():
    """Return SDK ``CodexConfig.launch_args_override`` without a console.

    The SDK owns the outer Popen call and does not expose creation flags.  The
    GUI-subsystem pythonw process is therefore the adapter boundary; it then
    starts codex.exe with CREATE_NO_WINDOW and inherited stdio.
    """
    if os.name == "nt" and pythonw_path().name.lower() != "pythonw.exe":
        raise RuntimeError("pythonw.exe is required for hidden Codex SDK launch")
    launcher = Path(__file__).with_name("codex_hidden_launcher.py")
    return [str(pythonw_path()), str(launcher), "app-server", "--listen", "stdio://"]
