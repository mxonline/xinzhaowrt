import asyncio
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from enum import Enum

from .models import CodexResult, GPTDecision, PipelineState
from .windows_process import hidden_codex_launch_args, terminate_process_tree


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


def validate_strict_json_schema(schema):
    """Return provider-facing errors for every nested strict object schema."""
    errors = []

    def visit(node, path):
        if not isinstance(node, dict):
            return
        schema_type = node.get("type")
        object_schema = schema_type == "object" or (
            isinstance(schema_type, list) and "object" in schema_type
        )
        if object_schema and node.get("additionalProperties") is False:
            properties = node.get("properties")
            required = node.get("required")
            if not isinstance(properties, dict):
                properties = {}
            if not isinstance(required, list):
                errors.append("%s: required must be supplied as an array" % (path or "<root>"))
            else:
                missing = [name for name in properties if name not in required]
                extra = [name for name in required if name not in properties]
                if missing:
                    errors.append(
                        "%s: required must include every declared property; missing %s"
                        % (path or "<root>", ", ".join(missing))
                    )
                if extra:
                    errors.append(
                        "%s: required contains undeclared properties; extra %s"
                        % (path or "<root>", ", ".join(extra))
                    )

        properties = node.get("properties")
        if isinstance(properties, dict):
            for name, child in properties.items():
                child_path = "%s.%s" % (path, name) if path else name
                visit(child, child_path)
        for key in ("items", "additionalProperties", "not", "if", "then", "else"):
            child = node.get(key)
            if isinstance(child, dict):
                visit(child, "%s.%s" % (path, key) if path else key)
        for key in ("anyOf", "oneOf", "allOf", "prefixItems"):
            children = node.get(key)
            if isinstance(children, list):
                for index, child in enumerate(children):
                    visit(child, "%s.%s[%d]" % (path, key, index) if path else "%s[%d]" % (key, index))

    visit(schema, "")
    return errors


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
                        "size_bytes",
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


_DECISION_SCHEMA_ERRORS = validate_strict_json_schema(DECISION_JSON_SCHEMA)
if _DECISION_SCHEMA_ERRORS:
    raise ValueError("invalid codex_output_schema: %s" % "; ".join(_DECISION_SCHEMA_ERRORS))


class AdapterError(RuntimeError):
    pass


class TransportAmbiguityError(AdapterError):
    """The executor stream ended after dispatch; replay could duplicate side effects."""


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

    def __init__(self, cwd, model=None, codex_factory=None, sleep_fn=None, backoff_base=2.0, backoff_max=30.0, max_recovery_attempts=2):
        self.cwd = str(cwd)
        self.model = model
        self.codex_factory = codex_factory
        self.codex = None
        self.thread = None
        self.last_error = ""
        self.launch_args = []
        self.sleep_fn = sleep_fn or asyncio.sleep
        self.backoff_base = max(0.0, float(backoff_base))
        self.backoff_max = max(self.backoff_base, float(backoff_max))
        self.max_recovery_attempts = max(1, int(max_recovery_attempts))
        self.last_recovery = None

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
                error_text = str(exc).lower()
                if "active writer" in error_text:
                    # The local Codex child has already been replaced, but
                    # the old persisted writer can remain registered briefly.
                    # Preserve the Arthur pipeline HANDOFF and start a fresh
                    # writer for the same durable task context.
                    self.last_error = str(exc)
                    state.executor_thread_id = None
                    self.thread = await self.codex.thread_start(**options)
                    state.executor_thread_id = str(getattr(self.thread, "id"))
                    return module
                if "no rollout found" not in error_text:
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
        self.launch_args = list(hidden_codex_launch_args())
        config = module.CodexConfig(
            launch_args_override=tuple(self.launch_args),
            cwd=self.cwd,
        )
        return module.AsyncCodex(config=config)

    async def prepare(self, state):
        """Create or resume the executor thread before a turn is started."""
        try:
            await self._ensure_thread(state)
        except Exception as exc:
            self.last_error = str(exc)
            raise

    async def run(self, prompt, state):
        self.last_recovery = None
        module = await self._ensure_thread(state)
        try:
            result = await self.thread.run(
                prompt,
                approval_mode=module.ApprovalMode.auto_review,
                sandbox=module.Sandbox.workspace_write,
            )
        except Exception as exc:
            self.last_error = str(exc)
            if "no rollout found" in str(exc).lower():
                result, module = await self._recover_missing_thread(state, prompt, module)
            elif _is_transport_disconnect(exc):
                result, module = await self._recover_stream(state, prompt, module, exc)
            else:
                raise
        return CodexResult(
            turn_id=str(getattr(result, "id", "unknown")),
            final_response=str(getattr(result, "final_response", None) or ""),
            status=str(getattr(getattr(result, "status", None), "value", getattr(result, "status", "completed"))),
            executor_thread_id=state.executor_thread_id,
            items=[_as_dict(item) for item in (getattr(result, "items", None) or [])],
        )

    async def _run_turn(self, module, prompt):
        return await self.thread.run(
            prompt,
            approval_mode=module.ApprovalMode.auto_review,
            sandbox=module.Sandbox.workspace_write,
        )

    async def _recover_missing_thread(self, state, prompt, module):
        state.executor_thread_id = None
        self.thread = await self.codex.thread_start(
            approval_mode=module.ApprovalMode.auto_review,
            cwd=self.cwd,
            sandbox=module.Sandbox.workspace_write,
            model=self.model,
        )
        state.executor_thread_id = str(getattr(self.thread, "id"))
        result = await self._run_turn(module, prompt)
        self.last_recovery = {"mode": "recreate_missing_thread", "thread_id": state.executor_thread_id}
        return result, module

    async def _recover_stream(self, state, prompt, module, initial_error):
        await self.reset_after_error()
        raise TransportAmbiguityError(
            "executor stream disconnected after request dispatch; outcome is ambiguous and automatic replay is forbidden: %s"
            % initial_error
        )

    async def close(self):
        await self._close_codex(self.codex)

    def active_process_info(self):
        client = getattr(self.codex, "_client", None)
        sync_client = getattr(client, "_sync", None) or client
        process = getattr(sync_client, "_proc", None)
        if process is None:
            return {"pid": None, "alive": False, "returncode": None, "stderr_tail": self.last_error, "console_visible": False}
        return {
            "pid": getattr(process, "pid", None),
            "alive": process.poll() is None,
            "returncode": process.poll(),
            "stderr_tail": self.last_error if process.poll() is not None else "",
            "console_visible": False,
        }

    async def reset_after_error(self):
        old = self.codex
        self.codex = None
        self.thread = None
        await self._close_codex(old)

    async def _close_codex(self, codex):
        if codex is None:
            return
        process = getattr(getattr(getattr(codex, "_client", None), "_sync", None), "_proc", None)
        pid = getattr(process, "pid", None)
        if pid:
            # Do this before SDK close: once the wrapper disappears, its
            # descendants may otherwise become orphaned and keep the durable
            # Codex writer lock alive for the next resume.
            terminate_process_tree(pid)
        if hasattr(codex, "close"):
            try:
                await asyncio.wait_for(codex.close(), timeout=5)
            except Exception:
                pass

    def launch_diagnostics(self):
        return {
            "command": list(self.launch_args),
            "cwd": self.cwd,
            "python": sys.executable,
            "path_present": bool(os.environ.get("PATH")),
        }


class ControllerAdapter:
    """Read-only decision backend contract used by the production runtime."""

    async def preflight(self):
        raise NotImplementedError

    async def review(self, result, state):
        raise NotImplementedError


def _is_transport_disconnect(error):
    text = str(error).lower()
    return any(marker in text for marker in (
        "stream disconnected before completion",
        "transportclosederror",
        "codex process is not running",
        "codex process closed stdout",
        "no rollout found",
        "connection reset",
        "connection aborted",
    ))


def _is_controller_stream_disconnect(error):
    return _is_transport_disconnect(error)


class CodexThreadController(ControllerAdapter):
    """Separate read-only controller thread. It only returns structured decisions."""

    def __init__(self, cwd, model, codex_factory=None, sleep_fn=None, backoff_base=2.0, backoff_max=30.0, max_recovery_attempts=2):
        self.cwd = str(cwd)
        self.model = model
        self.codex_factory = codex_factory
        self.codex = None
        self.thread = None
        self.sleep_fn = sleep_fn or asyncio.sleep
        self.backoff_base = max(0.0, float(backoff_base))
        self.backoff_max = max(self.backoff_base, float(backoff_max))
        self.max_recovery_attempts = max(1, int(max_recovery_attempts))
        self.last_recovery = None

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

    def _thread_options(self, module):
        return {
            "approval_mode": module.ApprovalMode.auto_review,
            "cwd": self.cwd,
            "sandbox": module.Sandbox.read_only,
            "model": self.model,
            "developer_instructions": (
                "You are a read-only production policy controller. Never execute commands, use tools, modify files, "
                "choose a release result without evidence, or ask the user questions. Return only the JSON schema."
            ),
        }

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

    async def close(self):
        await self._close_codex(self.codex)

    async def reset_after_error(self):
        old = self.codex
        self.codex = None
        self.thread = None
        await self._close_codex(old)

    async def _close_codex(self, codex):
        if codex is None:
            return
        process = getattr(getattr(getattr(codex, "_client", None), "_sync", None), "_proc", None)
        pid = getattr(process, "pid", None)
        if pid:
            terminate_process_tree(pid)
        if hasattr(codex, "close"):
            try:
                await asyncio.wait_for(codex.close(), timeout=5)
            except Exception:
                pass

    async def review(self, result, state):
        self.last_recovery = None
        module = await self._ensure_thread(state)
        prompt = _controller_prompt(result, state)
        try:
            response = await self._run_review(module, prompt)
        except Exception as exc:
            if not _is_controller_stream_disconnect(exc):
                raise
            response, module = await self._recover_stream(result, state, prompt, module, exc)
        items = getattr(response, "items", None) or []
        if any(_item_is_execution(item) for item in items):
            raise AdapterError("controller attempted command execution")
        text = getattr(response, "final_response", None)
        if not text:
            raise AdapterError("controller returned no structured response")
        return json.loads(text)

    async def _run_review(self, module, prompt):
        return await self.thread.run(
            prompt,
            approval_mode=module.ApprovalMode.auto_review,
            sandbox=module.Sandbox.read_only,
            output_schema=DECISION_JSON_SCHEMA,
        )

    async def _recover_stream(self, result, state, prompt, module, initial_error):
        original_thread_id = state.controller_thread_id
        original_transport = self.codex
        last_error = initial_error
        for attempt in range(self.max_recovery_attempts):
            delay = min(self.backoff_max, self.backoff_base * (2 ** attempt))
            await self.sleep_fn(delay)
            try:
                if original_thread_id:
                    self.thread = await self.codex.thread_resume(
                        original_thread_id,
                        **self._thread_options(module),
                    )
                    state.controller_thread_id = original_thread_id
                response = await self._run_review(module, prompt)
                self.last_recovery = {"mode": "resume", "attempt": attempt + 1, "thread_id": original_thread_id}
                return response, module
            except Exception as resume_error:
                last_error = resume_error
                await self.reset_after_error()
                state.controller_thread_id = None
                try:
                    module = _import_sdk()
                    if self.codex_factory is None and not hasattr(module, "CodexConfig"):
                        self.codex = original_transport
                    else:
                        self.codex = self._new_codex(module)
                    self.thread = await self.codex.thread_start(**self._thread_options(module))
                    state.controller_thread_id = str(getattr(self.thread, "id"))
                    response = await self._run_review(module, prompt)
                    self.last_recovery = {
                        "mode": "recreate",
                        "attempt": attempt + 1,
                        "previous_thread_id": original_thread_id,
                        "thread_id": state.controller_thread_id,
                    }
                    return response, module
                except Exception as recreate_error:
                    last_error = recreate_error
                    await self.reset_after_error()
                    state.controller_thread_id = original_thread_id
        raise AdapterError("controller stream recovery exhausted: %s" % last_error)

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
    controller_state = state.to_dict()
    controller_result = _compact_controller_result(result.to_dict())
    controller_state["last_result"] = controller_result
    probe_id = state.observability.get("e2e_probe_id")
    probe_contract = None
    if probe_id:
        probe_contract = {
            "purpose": "temporary_existing_bridge_e2e_verify_only",
            "do_not_modify_firmware_or_pipeline": True,
            "probe_id": probe_id,
            "routing": {
                "BRIDGE_PROBE_STAGE_1": {
                    "match": "final_response exactly contains BRIDGE_PROBE_STAGE_1 with this probe_id and value=37",
                    "action": "RECOVERABLE",
                    "next_codex_prompt": "Return exactly BRIDGE_PROBE_STAGE_2 probe_id=%s value=42, then stop." % probe_id,
                    "reason_code": "BRIDGE_PROBE_STAGE_1_CONFIRMED",
                },
                "BRIDGE_PROBE_STAGE_2": {
                    "match": "final_response exactly contains BRIDGE_PROBE_STAGE_2 with this probe_id and value=42",
                    "action": "RECOVERABLE",
                    "next_codex_prompt": "Return exactly BRIDGE_PROBE_STAGE_3 probe_id=%s value=100, then stop." % probe_id,
                    "reason_code": "BRIDGE_PROBE_NORMAL_PASS",
                    "summary_marker": "BRIDGE_PROBE_NORMAL=PASS",
                },
                "BRIDGE_PROBE_STAGE_3": {
                    "match": "final_response exactly contains BRIDGE_PROBE_STAGE_3 with this probe_id and value=100",
                    "action": "RECOVERABLE",
                    "next_codex_prompt": "Return exactly BRIDGE_PROBE_STAGE_4 probe_id=%s value=200, then stop." % probe_id,
                    "reason_code": "BRIDGE_PROBE_RECOVERY_CONTINUE",
                },
                "BRIDGE_PROBE_STAGE_4": {
                    "match": "final_response exactly contains BRIDGE_PROBE_STAGE_4 with this probe_id and value=200",
                    "action": "RECOVERABLE",
                    "next_codex_prompt": "Resume the existing Arthur FORENSICS task from HANDOFF and existing evidence; do not run another probe.",
                    "reason_code": "BRIDGE_PROBE_RECOVERY_PASS",
                    "summary_marker": "BRIDGE_PROBE_RECOVERY=PASS",
                },
            },
        }
    return json.dumps(
        {
            "instruction": "Review this executor result and pipeline state. Decide the next automatic action under the whitelist.",
            "pipeline_state": controller_state,
            "codex_result": controller_result,
            "temporary_probe_contract": probe_contract,
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


_CONTROLLER_ITEM_TEXT_LIMIT = 4096


def _compact_controller_result(result):
    """Keep controller input bounded while raw results remain in durable evidence."""
    if not isinstance(result, dict):
        return {"status": "invalid", "final_response": str(result)[:_CONTROLLER_ITEM_TEXT_LIMIT]}
    compact = dict(result)
    items = result.get("items")
    if isinstance(items, list):
        compact["items"] = [_compact_controller_item(item) for item in items]
    return compact


def _compact_controller_item(item):
    if not isinstance(item, dict):
        return str(item)[:_CONTROLLER_ITEM_TEXT_LIMIT]
    keep = (
        "type",
        "id",
        "status",
        "command",
        "exit_code",
        "duration_ms",
        "source",
        "plugin_id",
        "summary",
        "content",
        "aggregated_output",
        "error",
        "query",
    )
    compact = {}
    for key in keep:
        if key not in item:
            continue
        value = item[key]
        if isinstance(value, str):
            compact[key] = value[:_CONTROLLER_ITEM_TEXT_LIMIT]
        elif isinstance(value, (int, float, bool)) or value is None:
            compact[key] = value
        elif key in ("content", "query"):
            compact[key] = str(value)[:_CONTROLLER_ITEM_TEXT_LIMIT]
    omitted = sorted(set(item) - set(compact))
    if omitted:
        compact["omitted_fields"] = omitted
    return compact


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
