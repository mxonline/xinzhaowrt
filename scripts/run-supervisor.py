"""Windows startup shim for the hidden GPT-Codex bridge supervisor."""

import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from ai_orchestrator.supervisor import main  # noqa: E402


raise SystemExit(main())
