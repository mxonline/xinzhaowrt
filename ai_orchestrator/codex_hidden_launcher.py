"""Console-free bridge used as the official SDK's launch_args_override."""

import json
import os
import subprocess
import sys
from pathlib import Path

try:
    import ctypes
    from ctypes import wintypes
except ImportError:  # pythonw on the bundled runtime may omit _ctypes loading
    ctypes = None
    wintypes = None

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from ai_orchestrator.windows_process import hidden_creation_flags, hidden_startupinfo


def _codex_binary():
    override = os.environ.get("XINZHAO_CODEX_BIN")
    if override:
        return override
    from codex_cli_bin import bundled_codex_path

    return str(bundled_codex_path())


def _startupinfo_with_inherited_stdio():
    startup = hidden_startupinfo()
    if os.name != "nt" or ctypes is None:
        return startup
    # pythonw does not populate Python-level sys.std* streams, but the SDK's
    # inherited pipe handles are still available through GetStdHandle.
    kernel32 = ctypes.windll.kernel32
    startup.dwFlags |= 0x00000100  # STARTF_USESTDHANDLES
    startup.hStdInput = kernel32.GetStdHandle(-10)   # STD_INPUT_HANDLE
    startup.hStdOutput = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
    startup.hStdError = kernel32.GetStdHandle(-12)   # STD_ERROR_HANDLE
    return startup


class _Job:
    def __init__(self, process):
        self.handle = None
        if os.name != "nt" or ctypes is None:
            return
        kernel32 = ctypes.windll.kernel32
        self.handle = kernel32.CreateJobObjectW(None, None)
        if not self.handle:
            return

        class BasicLimitInformation(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_longlong),
                ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD),
            ]

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount",
            )]

        class ExtendedLimitInformation(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", BasicLimitInformation),
                ("IoInfo", IoCounters),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        info = ExtendedLimitInformation()
        info.BasicLimitInformation.LimitFlags = 0x2000  # KILL_ON_JOB_CLOSE
        kernel32.SetInformationJobObject(self.handle, 9, ctypes.byref(info), ctypes.sizeof(info))
        if not kernel32.AssignProcessToJobObject(self.handle, wintypes.HANDLE(process._handle)):
            kernel32.CloseHandle(self.handle)
            self.handle = None

    def close(self):
        if self.handle:
            ctypes.windll.kernel32.CloseHandle(self.handle)
            self.handle = None


def main():
    command = [_codex_binary(), *sys.argv[1:]]
    # Test/diagnostic override only; normal SDK launches use the exact
    # app-server arguments passed by CodexConfig.launch_args_override.
    extra = os.environ.get("XINZHAO_CODEX_EXTRA_ARGS_JSON")
    if extra:
        command = [_codex_binary(), *json.loads(extra)]
    # The Runtime is a standalone durable Arthur workflow.  When it is
    # launched from the Codex desktop, these inherited variables identify the
    # desktop conversation and its private MCP pipe, not this workflow.  They
    # can make a fresh app-server attach to the wrong writer/session and then
    # remain alive while every turn waits indefinitely.  Keep CODEX_HOME and
    # credentials, but remove only desktop ownership markers.
    child_env = os.environ.copy()
    for key in ("CODEX_SESSION_ID", "CODEX_THREAD_ID", "CODEX_APP_TOOLS_PIPE_PATH", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"):
        child_env.pop(key, None)
    child = subprocess.Popen(
        command,
        env=child_env,
        stdin=None,
        stdout=None,
        stderr=None,
        close_fds=False,
        creationflags=hidden_creation_flags(),
        startupinfo=_startupinfo_with_inherited_stdio(),
        bufsize=0,
    )
    job = _Job(child)
    try:
        return child.wait()
    finally:
        job.close()


if __name__ == "__main__":
    raise SystemExit(main())
