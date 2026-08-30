"""Windows process policy for the headless daemon and Codex SDK bridge."""

import os
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
