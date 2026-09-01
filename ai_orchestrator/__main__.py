import os
import shutil
import subprocess
import sys


def _reexec_on_supported_python():
    if sys.version_info >= (3, 10) or len(sys.argv) < 2 or sys.argv[1] not in ("run-production", "resume"):
        return False
    launcher = shutil.which("py")
    if not launcher:
        return False
    try:
        probe = subprocess.run(
            [launcher, "-3", "-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if probe.returncode != 0:
        return False
    os.execvp(launcher, [launcher, "-3", "-m", "ai_orchestrator"] + sys.argv[1:])
    return True


_reexec_on_supported_python()

from .cli import main


if __name__ == "__main__":
    raise SystemExit(main())
