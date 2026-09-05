import asyncio
import os
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from ai_orchestrator import adapters, cli


class _FakeCodex:
    def __init__(self):
        self.models_called = 0

    async def account(self):
        return {"type": "chatgpt"}

    async def models(self):
        self.models_called += 1
        raise AssertionError("models() must not be called on the headless production path")


class CodexModelCacheBypassTests(unittest.TestCase):
    def test_executor_preflight_can_skip_remote_model_catalog(self):
        fake = _FakeCodex()
        module = SimpleNamespace()
        executor = adapters.AsyncCodexExecutor(
            Path.cwd(),
            model="gpt-5.6-terra",
            codex_factory=lambda _module: fake,
        )
        with patch.object(adapters, "_import_sdk", return_value=module):
            probe = asyncio.run(executor.preflight(include_models=False))

        self.assertEqual({"type": "chatgpt"}, probe["account"])
        self.assertEqual(0, fake.models_called)

    def test_build_runtime_uses_explicit_chatgpt_model_without_models_list(self):
        executor_calls = []
        controller_calls = []

        class FakeExecutor:
            def __init__(self, cwd, model=None):
                self.cwd = str(cwd)
                self.model = model
                self.preflight_flags = []
                executor_calls.append(self)

            async def preflight(self, include_models=True):
                self.preflight_flags.append(include_models)
                if include_models:
                    raise AssertionError("executor model discovery path was used")
                return {"sdk": "openai_codex", "account": {"type": "chatgpt"}}

        class FakeController:
            def __init__(self, cwd, model, codex_factory=None):
                self.cwd = str(cwd)
                self.model = model
                self.preflight_flags = []
                controller_calls.append(self)

            async def preflight(self, include_models=True):
                self.preflight_flags.append(include_models)
                if include_models:
                    raise AssertionError("controller model discovery path was used")
                return {
                    "sdk": "openai_codex",
                    "account": {"type": "chatgpt"},
                    "controller_model": self.model,
                }

        env = dict(os.environ)
        env.pop("OPENAI_API_KEY", None)
        env["HEADLESS_CODEX_MODEL"] = "gpt-5.6-terra"
        with (
            patch.dict(os.environ, env, clear=True),
            patch.object(cli, "AsyncCodexExecutor", FakeExecutor),
            patch.object(cli, "CodexThreadController", FakeController),
        ):
            executor, controller, report = asyncio.run(cli._build_sdk_runtime(Path.cwd()))

        self.assertEqual("gpt-5.6-terra", executor.model)
        self.assertEqual([False], executor.preflight_flags)
        self.assertEqual("gpt-5.6-terra", controller.model)
        self.assertEqual([False], controller.preflight_flags)
        self.assertEqual("gpt-5.6-terra", report["controller_probe"]["controller_model"])


if __name__ == "__main__":
    unittest.main()
