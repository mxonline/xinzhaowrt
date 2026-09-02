import json
import os
from datetime import datetime, timezone
from pathlib import Path

from .models import ActionKind, PipelineState


class ArthurPipeline:
    PREBUILD_PHASE = "PREBUILD_REAL_DEVICE_FEATURES"
    PREBUILD_GATE = "V013_PREBUILD_REAL_DEVICE_FEATURES"
    PREBUILD_GATE_ENV = "ARTHUR_PREBUILD_GATE_PATH"
    PREBUILD_BASELINE_VERSION = "0.1.3"
    PREBUILD_BASELINE_BUILD_ID = "33462873812"
    PREBUILD_REQUIRED_MARKERS = (
        "V013_LIVE_BASELINE=PASS version=0.1.3 build_id=33462873812",
        "ADGUARD_LIVE=PASS final_state=stopped_disabled",
        "QUICKSTART_LIVE=PASS homepage=admin/quickstart",
        "WIFI_LIVE=PASS ssid=xinzhaowrt key=REDACTED",
        "V013_PREBUILD_REAL_DEVICE_FEATURES=PASS",
    )

    phases = (
        "FORENSICS",
        "CHANGE_IMPACT",
        "BASELINE_INHERITANCE",
        "EXPECTED_DIFF",
        "CONFIG",
        "PACKAGE",
        "PLUGIN_BASELINE_22",
        "ARGON_KUCAT",
        "LAN",
        PREBUILD_PHASE,
        "FAST_GATE",
        "BUILD",
        "ARTIFACT",
        "PRE_FLASH",
        "AUTO_FLASH_SAFETY_GATE",
        "FLASH",
        "WAIT_DEVICE",
        "IDENTIFY",
        "LAN_RUNTIME",
        "DHCP",
        "WAN",
        "DNS",
        "SSH",
        "LUCI",
        "PLUGIN_RUNTIME_22",
        "ARGON_KUCAT_RUNTIME",
        "SYSTEM_HEALTH",
        "RELEASE_GATE",
        "RELEASE",
        "PRODUCTION_RELEASED",
    )

    def __init__(self, project_root=None):
        self.project_root = Path(project_root or Path.cwd())

    def initial_state(self, request_id="arthur-production", next_prompt=None):
        return PipelineState(
            request_id=request_id,
            device="jdcloud_re-ss-01",
            phase=self.phases[0],
            next_codex_prompt=next_prompt or self.prompt_for(self.phases[0]),
        )

    def prompt_for(self, phase):
        if phase == "PRODUCTION_RELEASED":
            return None
        if phase == self.PREBUILD_PHASE:
            return (
                "Production phase PREBUILD_REAL_DEVICE_FEATURES for the already-running physical Arthur 0.1.3 "
                "(Build ID 33462873812). Hot-deploy and verify only AdGuard Home management, iStore QuickStart homepage, "
                "and 2.4G/5G Wi-Fi xinzhaowrt on root@192.168.6.1 over the verified Ethernet control path. "
                "Do not build, dispatch a firmware build, upload firmware, sysupgrade, flash, or perform raw writes. "
                "The phase may advance only after durable evidence contains all required live markers, ending with "
                "V013_PREBUILD_REAL_DEVICE_FEATURES=PASS. On any failure, repair the first concrete failure and repeat "
                "this phase automatically."
            )
        return (
            "Production phase %s for Arthur (qualcommax/ipq60xx/jdcloud_re-ss-01). "
            "Execute only this phase, collect durable evidence, do not ask for design/spec/plan/merge/PR approval, "
            "standard sysupgrade is automatic only after AUTO_FLASH_SAFETY_GATE; never perform raw MTD/U-Boot/dd/eMMC writes. "
            "Return a concise result with evidence paths."
        ) % phase

    def prebuild_gate_path(self):
        configured = os.environ.get(self.PREBUILD_GATE_ENV)
        if configured:
            return Path(configured)
        program_data = os.environ.get("ProgramData") or os.environ.get("PROGRAMDATA")
        if os.name == "nt" and program_data:
            return Path(program_data) / "XinZhaoWrt" / "v013-prebuild-real-device-features.json"
        return self.project_root / "output" / "real-device" / "v013-prebuild-real-device-features.json"

    def record_result(self, state, result):
        if state.phase != self.PREBUILD_PHASE:
            return None
        text = "\n".join([result.final_response or ""] + list(result.evidence or []))
        missing = [marker for marker in self.PREBUILD_REQUIRED_MARKERS if marker not in text]
        if missing:
            return None
        payload = {
            "schema_version": "1.0",
            "gate": self.PREBUILD_GATE,
            "status": "PASS",
            "baseline_version": self.PREBUILD_BASELINE_VERSION,
            "baseline_build_id": self.PREBUILD_BASELINE_BUILD_ID,
            "markers": list(self.PREBUILD_REQUIRED_MARKERS),
            "turn_id": result.turn_id,
            "evidence": list(result.evidence or []),
            "validated_at": datetime.now(timezone.utc).isoformat(),
        }
        path = self.prebuild_gate_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(str(temporary), str(path))
        state.observability.setdefault("policy_gates", {})[self.PREBUILD_GATE] = dict(payload)
        return payload

    def prebuild_gate_passed(self, state=None):
        payload = self._read_prebuild_gate()
        if not self._valid_prebuild_gate(payload):
            return False
        if state is not None:
            state.observability.setdefault("policy_gates", {})[self.PREBUILD_GATE] = dict(payload)
        return True

    def enforce_pre_execution_gate(self, state):
        if self.prebuild_gate_passed(state):
            return None
        if state.phase not in self.phases:
            return None
        if self.phases.index(state.phase) < self.phases.index("FAST_GATE"):
            return None
        previous = state.phase
        state.phase = self.PREBUILD_PHASE
        state.next_codex_prompt = self.prompt_for(self.PREBUILD_PHASE)
        state.pending_human_gate = None
        event = {
            "reason_code": "PREBUILD_REAL_DEVICE_FEATURES_REQUIRED",
            "from": previous,
            "to": self.PREBUILD_PHASE,
            "build_allowed": False,
            "gate_path": str(self.prebuild_gate_path()),
        }
        state.observability["prebuild_policy_gate"] = dict(event)
        return event

    def next_phase(self, current_phase, action):
        if action == ActionKind.RECOVERABLE.value or action == ActionKind.RECOVERABLE:
            return current_phase
        if action == ActionKind.SAFE_AUTO.value or action == ActionKind.SAFE_AUTO:
            try:
                index = self.phases.index(current_phase)
            except ValueError:
                raise ValueError("unknown Arthur phase: %s" % current_phase)
            proposed = self.phases[min(index + 1, len(self.phases) - 1)]
            if self.phases.index(proposed) >= self.phases.index("FAST_GATE") and not self.prebuild_gate_passed():
                return self.PREBUILD_PHASE
            return proposed
        return current_phase

    def _read_prebuild_gate(self):
        path = self.prebuild_gate_path()
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return None

    def _valid_prebuild_gate(self, payload):
        if not isinstance(payload, dict):
            return False
        if payload.get("gate") != self.PREBUILD_GATE or payload.get("status") != "PASS":
            return False
        if payload.get("baseline_version") != self.PREBUILD_BASELINE_VERSION:
            return False
        if str(payload.get("baseline_build_id")) != self.PREBUILD_BASELINE_BUILD_ID:
            return False
        markers = payload.get("markers")
        if not isinstance(markers, list):
            return False
        return all(marker in markers for marker in self.PREBUILD_REQUIRED_MARKERS)
