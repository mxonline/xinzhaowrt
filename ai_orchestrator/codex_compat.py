"""Compatibility guard for the Codex model-catalog refresh failure on headless Windows.

The production bridge uses an explicit Codex model and does not require remote
model discovery to authorize firmware execution.  Current Codex app-server builds
can crash or stall while refreshing a cold/stale models cache on Windows.  Keep
that upstream metadata path off the critical production runtime while preserving
account/authentication checks and explicit model selection.
"""

import os

from . import adapters


DEFAULT_HEADLESS_CODEX_MODEL = "gpt-5.6-terra"
_INSTALLED = False


def configured_headless_codex_model():
    value = str(os.environ.get("HEADLESS_CODEX_MODEL") or "").strip()
    return value or DEFAULT_HEADLESS_CODEX_MODEL


def _explicit_model_probe(model):
    return [
        {
            "id": {"value": model},
            "source": "explicit_headless_config",
        }
    ]


def install_codex_model_cache_workaround():
    global _INSTALLED
    if _INSTALLED:
        return

    original_executor_init = adapters.AsyncCodexExecutor.__init__

    def executor_init(self, cwd, model=None, codex_factory=None):
        original_executor_init(
            self,
            cwd,
            model=model or configured_headless_codex_model(),
            codex_factory=codex_factory,
        )

    async def executor_preflight(self, include_models=False):
        module = adapters._import_sdk()
        self.codex = self.codex or self._new_codex(module)
        account = await self.codex.account()
        model = self.model or configured_headless_codex_model()
        if include_models:
            models = adapters._as_dict(await self.codex.models())
            skipped = False
        else:
            models = _explicit_model_probe(model)
            skipped = True
        return {
            "sdk": "openai_codex",
            "account": adapters._as_dict(account),
            "models": models,
            "executor_model": model,
            "model_catalog_skipped": skipped,
        }

    async def controller_preflight(self, include_models=False):
        module = adapters._import_sdk()
        self.codex = self.codex or self._new_codex(module)
        account = await self.codex.account()
        model = self.model or configured_headless_codex_model()
        if include_models:
            models = adapters._as_dict(await self.codex.models())
            skipped = False
        else:
            models = _explicit_model_probe(model)
            skipped = True
        return {
            "sdk": "openai_codex",
            "account": adapters._as_dict(account),
            "models": models,
            "controller_model": model,
            "model_catalog_skipped": skipped,
        }

    adapters.AsyncCodexExecutor.__init__ = executor_init
    adapters.AsyncCodexExecutor.preflight = executor_preflight
    adapters.CodexThreadController.preflight = controller_preflight
    _INSTALLED = True
