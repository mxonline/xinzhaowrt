import asyncio
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from enum import Enum

from .models import CodexResult, GPTDecision, PipelineState
from .windows_process import hidden_codex_launch_args


class PreflightStatus(str, Enum):
    READY = "READY"
    CREDENTIAL_REQUIRED = "CREDENTIAL_REQUIRED"
    SDK_REQUIRED = "SDK_REQUIRED"
    RUNTIME_REQUIRED = "RUNTIME_REQUIRED"
    INVALID_ENVIRONMENT = "INVALID_ENVIRONMENT"


@dataclass
class BackendSelection:
    kind: str
    model: str = None
    status: PreflightStatus = PreflightStatus.READY
    evidence: list = field(default_factory=list)


def choose_controller_backend(api_key, sdk_models):
    if api_key:
        return BackendSelection("responses", "gpt-5.6-sol")
    models = set(sdk_models or [])
    for candidate in ("gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4"):
        if candidate in models:
            return BackendSelection("codex_thread", candidate)
    return BackendSelection(
        "none",
        status=PreflightStatus.CREDENTIAL_REQUIRED,
        evidence=[
            "credential_discovery_failed",
            "OPENAI_API_KEY is unset",
            "Codex SDK models() returned no suitable controller model",
        ],
    )


def executor_thread_options(cwd):
    return {
        "approval_mode": "auto_review",
        "sandbox": "workspace_write",
        "cwd": str(cwd),
    }


DECISION_JSON_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": [
        "action",
        "reason_code",
        "summary",
        "next_codex_prompt",
        "human_gate",
        "evidence",
        "terminal_state",
        "auth_resource",
        "provider",
        "verification_error",
        "credential_discovery_failed",
        "metadata",
    ],
    "properties": {
        "action": {"type": "string", "enum": ["SAFE_AUTO", "RECOVERABLE", "HUMAN_GATE", "TERMINAL"]},
        "reason_code": {"type": "string"},
        "summary": {"type": "string"},
        "next_codex_prompt": {"type": ["string", "null"]},
        "human_gate": {
            "type": ["string", "null"],
            "enum": [
                None,
                "NEW_CREDENTIAL_PROVISIONING",
                "UNKNOWN_DEVICE_IDENTITY",
                "NO_SAFE_ROLLBACK",
                "UNRECOVERABLE_IRREVERSIBLE_OPERATION",
            ],
        },
        "evidence": {"type": "array", "items": {"type": "string"}},
        "terminal_state": {"type": ["string", "null"], "enum": [None, "PRODUCTION_RELEASED", "CREDENTIAL_REQUIRED", "SAFETY_BLOCKED"]},
        "auth_resource": {"type": ["string", "null"]},
        "provider": {"type": ["string", "null"]},
        "verification_error": {"type": ["string", "null"]},
        "credential_discovery_failed": {"type": "boolean"},
        "metadata": {
            "type": "object",
            "additionalProperties": False,
            "required": ["candidate", "safety_gate", "next_phase"],
            "properties": {
                "candidate": {
                    "type": ["object", "null"],
                    "additionalProperties": False,
                    "required": [
                        "filename",
                        "sha256",
                        "target",
                        "profile",
                        "build_report",
                        "package_report",
                        "theme_report",
                        "lan_static_report",
                        "rollback_report",
                        "flash_manifest",
                    ],
                    "properties": {
                        "filename": {"type": "string"},
                        "sha256": {"type": "string"},
                        "size_bytes": {"type": "integer"},
                        "target": {"type": "string"},
                        "profile": {"type": "string"},
                        "build_report": {"type": "string"},
                        "package_report": {"type": "string"},
                        "theme_report": {"type": "string"},
                        "lan_static_report": {"type": "string"},
                        "rollback_report": {"type": "string"},
                        "flash_manifest": {"type": "string"},
                    },
                },
                "safety_gate": {
                    "type": ["object", "null"],
                    "additionalProperties": False,
                    "required": [
                        "device_identity",
                        "mac_match",
                        "model_match",
                        "storage_layout_verified",
                        "candidate_complete",
                        "candidate_size_match",
                        "cloud_sha256",
                        "local_sha256",
                        "remote_sha256",
                        "ssh_control_channel",
                        "plugins_22",
                        "argon",
                        "kucat",
                        "known_good_available",
                        "rollback_ready",
                        "rollback_sha256_verified",
                        "current_recovery_address",
                        "recovery_address_classification",
                        "expected_post_flash_lan",
                    ],
                    "properties": {
                        "device_identity": {"type": "boolean"},
                        "mac_match": {"type": "boolean"},
                        "model_match": {"type": "boolean"},
                        "storage_layout_verified": {"type": "boolean"},
                        "candidate_complete": {"type": "boolean"},
                        "candidate_size_match": {"type": "boolean"},
                        "cloud_sha256": {"type": "string"},
                        "local_sha256": {"type": ["string", "null"]},
                        "remote_sha256": {"type": ["string", "null"]},
                        "ssh_control_channel": {"type": "boolean"},
                        "plugins_22": {"type": "boolean"},
                        "argon": {"type": "boolean"},
                        "kucat": {"type": "boolean"},
                        "known_good_available": {"type": "boolean"},
                        "rollback_ready": {"type": "boolean"},
                        "rollback_sha256_verified": {"type": "boolean"},
                        "current_recovery_address": {"type": "string"},
                        "recovery_address_classification": {"type": "string"},
                        "expected_post_flash_lan": {"type": "string"},
                    },
                },
                "next_phase": {"type": ["string", "null"]},
            },
        },
    },
}


class AdapterError(RuntimeError):
    pass


class SDKUnavailable(AdapterError):
    pass


def _import_sdk():
    if sys.version_info < (3, 10):
        raise SDKUnavailable("openai_codex requires Python 3.10 or newer; current=%s" % sys.version.split()[0])
    try:
        import openai_codex
    except ImportError as exc:
        raise SDKUnavailable("openai_codex is not installed: %s" % exc)
    return openai_codex


def _as_dict(value):
    if value is None:
        return None
    if isinstance(value, dict):
        return {key: _as_dict(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_as_dict(item) for item in value]
    if isinstance(value, Enum):
        return value.value
    if hasattr(value, "model_dump"):
        try:
            return _as_dict(value.model_dump(mode="json"))
        except TypeError:
            return _as_dict(value.model_dump())
    if hasattr(value, "dict"):
        return _as_dict(value.dict())
    if hasattr(value, "__dict__"):
        return _as_dict(dict(value.__dict__))
    return {"value": str(value)}


class AsyncCodexExecutor:
    """One durable SDK executor thread; never makes release or gate decisions."""

    def __init__(self, cwd, model=None, codex_factory=None):
        self.cwd = str(cwd)
        self.model = model
        self.codex_factory = codex_factory
        self.codex = None
        self.thread = None

    async def preflight(self):
        module = _import_sdk()
        self.codex = self.codex or self._new_codex(module)
        account = await self.codex.account()
        models = await self.codex.models()
        return {"sdk": "openai_codex", "account": _as_dict(account), "models": _as_dict(models)}

    async def _ensure_thread(self, state):
        module = _import_sdk()
        if self.thread is not None:
            return module
        if self.codex is None:
            self.codex = self._new_codex(module)
        options = {
            "approval_mode": module.ApprovalMode.auto_review,
            "cwd": self.cwd,
            "sandbox": module.Sandbox.workspace_write,
            "model": self.model,
        }
        if state.executor_thread_id:
            try:
                self.thread = await self.codex.thread_resume(state.executor_thread_id, **options)
            except Exception as exc:
                if "no rollout found" not in str(exc).lower():
                    raise
                state.executor_thread_id = None
                self.thread = await self.codex.thread_start(**options)
                state.executor_thread_id = str(getattr(self.thread, "id"))
        else:
            self.thread = await self.codex.thread_start(**options)
            state.executor_thread_id = str(getattr(self.thread, "id"))
        return module

    def _new_codex(self, module):
        if self.codex_factory:
            return self.codex_factory(module)
        config = module.CodexConfig(
            launch_args_override=tuple(hidden_codex_launch_args()),
            cwd=self.cwd,
        )
        return module.AsyncCodex(config=config)

    async def prepare(self, state):
        """Create or resume the executor thread before a turn is started."""
        await self._ensure_thread(state)

    async def run(self, prompt, state):
        module = await self._ensure_thread(state)
        try:
            result = await self.thread.run(
                prompt,
                approval_mode=module.ApprovalMode.auto_review,
                sandbox=module.Sandbox.workspace_write,
            )
        except Exception as exc:
            if "no rollout found" not in str(exc).lower():
                raise
            state.executor_thread_id = None
            self.thread = None
            await self._ensure_thread(state)
            result = await self.thread.run(
                prompt,
                approval_mode=module.ApprovalMode.auto_review,
                sandbox=module.Sandbox.workspace_write,
            )
        return CodexResult(
            turn_id=str(getattr(result, "id", "unknown")),
            final_response=str(getattr(result, "final_response", None) or ""),
            status=str(getattr(getattr(result, "status", None), "value", getattr(result, "status", "completed"))),
            executor_thread_id=state.executor_thread_id,
            items=[_as_dict(item) for item in (getattr(result, "items", None) or [])],
        )

    async def close(self):
        if self.codex is not None and hasattr(self.codex, "close"):
            await self.codex.close()

    def active_process_info(self):
        client = getattr(self.codex, "_client", None)
        sync_client = getattr(client, "_sync", None) or client
        process = getattr(sync_client, "_proc", None)
        if process is None:
            return {"pid": None, "alive": False, "console_visible": False}
        return {
            "pid": getattr(process, "pid", None),
            "alive": process.poll() is None,
            "returncode": process.poll(),
            "console_visible": False,
        }

    async def reset_after_error(self):
        old = self.codex
        self.codex = None
        self.thread = None
        if old is not None and hasattr(old, "close"):
            try:
                await asyncio.wait_for(old.close(), timeout=5)
            except Exception:
                pass


class ControllerAdapter:
    """Read-only decision backend contract used by the production runtime."""

    async def preflight(self):
        raise NotImplementedError

    async def review(self, result, state):
        raise NotImplementedError


class CodexThreadController(ControllerAdapter):
    """Separate read-only controller thread. It only returns structured decisions."""

    def __init__(self, cwd, model, codex_factory=None):
        self.cwd = str(cwd)
        self.model = model
        self.codex_factory = codex_factory
        self.codex = None
        self.thread = None

    async def preflight(self):
        module = _import_sdk()
        self.codex = self.codex or self._new_codex(module)
        account = await self.codex.account()
        models = await self.codex.models()
        return {"sdk": "openai_codex", "account": _as_dict(account), "models": _as_dict(models), "controller_model": self.model}

    async def _ensure_thread(self, state):
        module = _import_sdk()
        if self.thread is not None:
            return module
        if self.codex is None:
            self.codex = self._new_codex(module)
        options = {
            "approval_mode": module.ApprovalMode.auto_review,
            "cwd": self.cwd,
            "sandbox": module.Sandbox.read_only,
            "model": self.model,
            "developer_instructions": (
                "You are a read-only production policy controller. Never execute commands, use tools, modify files, "
                "choose a release result without evidence, or ask the user questions. Return only the JSON schema."
            ),
        }
        if state.controller_thread_id:
            try:
                self.thread = await self.codex.thread_resume(state.controller_thread_id, **options)
            except Exception as exc:
                if "no rollout found" not in str(exc).lower():
                    raise
                state.controller_thread_id = None
                self.thread = await self.codex.thread_start(**options)
                state.controller_thread_id = str(getattr(self.thread, "id"))
        else:
            self.thread = await self.codex.thread_start(**options)
            state.controller_thread_id = str(getattr(self.thread, "id"))
        return module

    def _new_codex(self, module):
        if self.codex_factory:
            return self.codex_factory(module)
        config = module.CodexConfig(
            launch_args_override=tuple(hidden_codex_launch_args()),
            cwd=self.cwd,
        )
        return module.AsyncCodex(config=config)

    async def prepare(self, state):
        await self._ensure_thread(state)

    async def review(self, result, state):
        module = await self._ensure_thread(state)
        prompt = _controller_prompt(result, state)
        try:
            response = await self.thread.run(
                prompt,
                approval_mode=module.ApprovalMode.auto_review,
                sandbox=module.Sandbox.read_only,
                output_schema=DECISION_JSON_SCHEMA,
            )
        except Exception as exc:
            if "no rollout found" not in str(exc).lower():
                raise
            state.controller_thread_id = None
            self.thread = None
            module = await self._ensure_thread(state)
            response = await self.thread.run(
                prompt,
                approval_mode=module.ApprovalMode.auto_review,
                sandbox=module.Sandbox.read_only,
                output_schema=DECISION_JSON_SCHEMA,
            )
        items = getattr(response, "items", None) or []
        if any(_item_is_execution(item) for item in items):
            raise AdapterError("controller attempted command execution")
        text = getattr(response, "final_response", None)
        if not text:
            raise AdapterError("controller returned no structured response")
        return json.loads(text)

    async def close(self):
        if self.codex is not None and hasattr(self.codex, "close"):
            await self.codex.close()

    def active_process_info(self):
        client = getattr(self.codex, "_client", None)
        sync_client = getattr(client, "_sync", None) or client
        process = getattr(sync_client, "_proc", None)
        if process is None:
            return {"pid": None, "alive": False, "console_visible": False}
        return {
            "pid": getattr(process, "pid", None),
            "alive": process.poll() is None,
            "returncode": process.poll(),
            "console_visible": False,
        }

    async def reset_after_error(self):
        old = self.codex
        self.codex = None
        self.thread = None
        if old is not None and hasattr(old, "close"):
            try:
                await asyncio.wait_for(old.close(), timeout=5)
            except Exception:
                pass


class ResponsesController(ControllerAdapter):
    def __init__(self, api_key, model="gpt-5.6-sol", base_url=None):
        self.api_key = api_key
        self.model = model
        self.base_url = (base_url or os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1")).rstrip("/")

    async def preflight(self):
        return {"backend": "responses", "model": self.model, "credential": "OPENAI_API_KEY"}

    async def review(self, result, state):
        body = {
            "model": self.model,
            "input": _controller_prompt(result, state),
            "text": {"format": {"type": "json_schema", "name": "gpt_decision", "strict": True, "schema": DECISION_JSON_SCHEMA}},
        }
        request = urllib.request.Request(
            self.base_url + "/responses",
            data=json.dumps(body).encode("utf-8"),
            headers={"Authorization": "Bearer " + self.api_key, "Content-Type": "application/json"},
            method="POST",
        )
        loop = asyncio.get_event_loop()
        try:
            response = await loop.run_in_executor(None, lambda: urllib.request.urlopen(request, timeout=120))
            payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, OSError, ValueError) as exc:
            raise AdapterError("Responses controller request failed: %s" % exc)
        self.last_conversation_id = payload.get("conversation", {}).get("id") if isinstance(payload.get("conversation"), dict) else None
        text = payload.get("output_text") or _responses_output_text(payload)
        if not text:
            raise AdapterError("Responses controller returned no structured response")
        return json.loads(text)

    async def close(self):
        return None


def _controller_prompt(result, state):
    return json.dumps(
        {
            "instruction": "Review this executor result and pipeline state. Decide the next automatic action under the whitelist.",
            "pipeline_state": state.to_dict(),
            "codex_result": result.to_dict(),
            "constraints": {
                "no_interactive_workflow": True,
                "no_executor_release_decision": True,
                "human_gates": [
                    "NEW_CREDENTIAL_PROVISIONING",
                    "UNKNOWN_DEVICE_IDENTITY",
                    "NO_SAFE_ROLLBACK",
                    "UNRECOVERABLE_IRREVERSIBLE_OPERATION",
                ],
            },
        },
        ensure_ascii=False,
    )


def _item_is_execution(item):
    data = _as_dict(item) or {}
    marker = json.dumps(data).lower()
    return any(token in marker for token in ("command_execution", "shell_command", "terminal_command", "exec_command"))


def _responses_output_text(payload):
    parts = []
    for output in payload.get("output", []) or []:
        for content in output.get("content", []) or []:
            if content.get("type") in ("output_text", "text"):
                parts.append(content.get("text", ""))
    return "".join(parts)
