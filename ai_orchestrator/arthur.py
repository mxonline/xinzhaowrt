import json
from pathlib import Path

from .models import ActionKind, PipelineState


class ArthurPipeline:
    default_request_id = "arthur-adh-quickstart"
    production_candidate_workflow = ".github/workflows/arthur-update-v3.yml"
    non_production_candidate_workflows = frozenset(
        {
            ".github/workflows/arthur-theme-candidate.yml",
            ".github/workflows/arthur-fast-candidate.yml",
        }
    )
    production_candidate_evidence = (
        "plugin-verification.txt",
        "update-metadata.json",
        "arthur-known-good.lock",
        "build-info.txt",
        "SHA256SUMS.local",
    )
    supported_release_modes = frozenset({"RELEASE_ONLY", "FLASH_AND_VERIFY"})
    legacy_phases = (
        "FORENSICS",
        "ADH_MANAGEMENT",
        "ADH_CHINESE",
        "CHANGE_IMPACT",
        "BASELINE_INHERITANCE",
        "EXPECTED_DIFF",
        "CONFIG",
        "PACKAGE",
        "PLUGIN_BASELINE_22",
        "ARGON_KUCAT",
        "LAN",
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
    release_only_skipped_phases = frozenset(
        {
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
        }
    )
    release_only_phases = tuple(
        phase for phase in legacy_phases if phase not in release_only_skipped_phases
    )
    # Compatibility alias for readers that use the historical registry directly.
    phases = legacy_phases

    def __init__(self, release_mode=None):
        self.release_mode = release_mode or self._load_default_release_mode()
        if self.release_mode not in self.supported_release_modes:
            raise ValueError("unsupported Arthur release mode: %s" % self.release_mode)
        self.effective_phases = (
            self.release_only_phases
            if self.release_mode == "RELEASE_ONLY"
            else self.legacy_phases
        )

    @classmethod
    def _load_default_release_mode(cls):
        policy_path = Path(__file__).resolve().parents[1] / "production" / "release-mode.json"
        try:
            with policy_path.open("r", encoding="utf-8") as handle:
                policy = json.load(handle)
        except (OSError, ValueError) as exc:
            raise ValueError("Arthur release mode policy unavailable: %s" % exc)
        mode = policy.get("mode")
        if not isinstance(mode, str) or not mode.strip():
            raise ValueError("Arthur release mode policy missing mode")
        return mode.strip()

    def initial_state(self, request_id=None, next_prompt=None):
        return PipelineState(
            request_id=request_id or self.default_request_id,
            device="jdcloud_re-ss-01",
            phase=self.effective_phases[0],
            next_codex_prompt=next_prompt or self.prompt_for(self.effective_phases[0]),
        )

    def prompt_for(self, phase):
        if phase == "PRODUCTION_RELEASED":
            return None
        if phase not in self.legacy_phases:
            raise ValueError("unknown Arthur phase: %s" % phase)

        release_behavior = (
            "This execution is RELEASE_ONLY: never flash or sysupgrade the router; after ARTIFACT continue through RELEASE_GATE and GitHub Release. "
            if self.release_mode == "RELEASE_ONLY"
            else "Standard sysupgrade is automatic only after AUTO_FLASH_SAFETY_GATE; never perform raw MTD/U-Boot/dd/eMMC writes. "
        )
        prompt = (
            "Production phase %s for Arthur (qualcommax/ipq60xx/jdcloud_re-ss-01). "
            "Execute only this phase, collect durable evidence, do not ask for design/spec/plan/merge/PR approval, "
            "%sReturn a concise result with evidence paths."
        ) % (phase, release_behavior)
        if phase == "ADH_MANAGEMENT":
            prompt += (
                " Resume the accepted arthur-adh-quickstart work on the running XinZhaoWrt 0.1.3 device. "
                "Reuse the mature luci-app-adguardhome implementation first and permit only minimal compatibility patches; "
                "do not rebuild the manager from scratch. Preserve WIFI=VERIFIED_FROZEN and the accepted iStore/QuickStart state."
            )
        elif phase == "ADH_CHINESE":
            prompt += (
                " Complete and verify Chinese localization for the accepted ADH management implementation without replacing "
                "the mature upstream management structure. Preserve all previously verified firmware behavior."
            )
        if phase in {"BUILD", "ARTIFACT", "PRE_FLASH"}:
            prompt += (
                " Production candidates must come from .github/workflows/arthur-update-v3.yml and include the complete "
                "production evidence set. Theme/SDK/ImageBuilder-only workflows are non-production evidence and must be "
                "classified RECOVERABLE_ROUTE_MISMATCH and routed to the formal production workflow; never flash or release them."
            )
        return prompt

    @classmethod
    def classify_candidate_route(cls, workflow, evidence_names, release_mode="RELEASE_ONLY"):
        """Return the durable route decision for a completed candidate artifact."""
        if release_mode not in cls.supported_release_modes:
            return {
                "route": "SAFETY_BLOCKED_UNKNOWN_RELEASE_MODE",
                "workflow": cls.production_candidate_workflow,
                "missing_evidence": [],
                "flash_allowed": False,
                "release_allowed": False,
            }

        names = set(evidence_names or ())
        missing = [item for item in cls.production_candidate_evidence if item not in names]
        if workflow != cls.production_candidate_workflow or missing:
            return {
                "route": "RECOVERABLE_ROUTE_MISMATCH",
                "workflow": cls.production_candidate_workflow,
                "missing_evidence": missing,
                "flash_allowed": False,
                "release_allowed": False,
            }
        return {
            "route": "PRODUCTION_CANDIDATE",
            "workflow": cls.production_candidate_workflow,
            "missing_evidence": [],
            "flash_allowed": release_mode == "FLASH_AND_VERIFY",
            "release_allowed": True,
        }

    def next_phase(self, current_phase, action):
        if action == ActionKind.RECOVERABLE.value or action == ActionKind.RECOVERABLE:
            return current_phase
        if action == ActionKind.SAFE_AUTO.value or action == ActionKind.SAFE_AUTO:
            try:
                index = self.effective_phases.index(current_phase)
            except ValueError:
                if current_phase in self.legacy_phases:
                    raise ValueError(
                        "Arthur phase %s is not actionable in %s mode"
                        % (current_phase, self.release_mode)
                    )
                raise ValueError("unknown Arthur phase: %s" % current_phase)
            return self.effective_phases[min(index + 1, len(self.effective_phases) - 1)]
        return current_phase
