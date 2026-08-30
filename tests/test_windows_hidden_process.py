import os
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ai_orchestrator.windows_process import (
    CREATE_NEW_CONSOLE,
    hidden_creation_flags,
    hidden_startupinfo,
    pythonw_path,
)


class WindowsHiddenProcessTests(unittest.TestCase):
    def test_hidden_flags_never_request_a_new_console(self):
        flags = hidden_creation_flags()
        self.assertEqual(0, flags & CREATE_NEW_CONSOLE)
        if os.name == "nt":
            self.assertNotEqual(0, flags)
            self.assertIsNotNone(hidden_startupinfo())

    @unittest.skipUnless(os.name == "nt", "Windows child-process integration test")
    def test_pythonw_is_available_for_sdk_override(self):
        self.assertTrue(pythonw_path().exists())
        self.assertEqual("pythonw.exe", pythonw_path().name.lower())

    @unittest.skipUnless(os.name == "nt", "Windows child-process integration test")
    def test_hidden_launcher_preserves_stdio_and_exit_code_without_console(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "fake_codex.py"
            helper.write_text(
                "import ctypes, sys\n"
                "print('STDOUT:%s' % (ctypes.windll.kernel32.GetConsoleWindow(),), flush=True)\n"
                "print('STDERR', file=sys.stderr, flush=True)\n"
                "raise SystemExit(7)\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment["XINZHAO_CODEX_BIN"] = sys.executable
            environment["XINZHAO_CODEX_EXTRA_ARGS_JSON"] = json.dumps([str(helper)])
            launcher = Path(__file__).parents[1] / "ai_orchestrator" / "codex_hidden_launcher.py"
            completed = subprocess.run(
                [str(pythonw_path()), str(launcher), "app-server", "--listen", "stdio://"],
                cwd=str(Path(__file__).parents[1]),
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(7, completed.returncode, "stdout=%r stderr=%r" % (completed.stdout, completed.stderr))
            self.assertIn("STDOUT:0", completed.stdout)
            self.assertIn("STDERR", completed.stderr)


if __name__ == "__main__":
    unittest.main()
