from .models import ActionKind, PipelineState


class ArthurPipeline:
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
        return (
            "Production phase %s for Arthur (qualcommax/ipq60xx/jdcloud_re-ss-01). "
            "Execute only this phase, collect durable evidence, do not ask for design/spec/plan/merge/PR approval, "
            "standard sysupgrade is automatic only after AUTO_FLASH_SAFETY_GATE; never perform raw MTD/U-Boot/dd/eMMC writes. "
            "Return a concise result with evidence paths."
        ) % phase

    def next_phase(self, current_phase, action):
        if action == ActionKind.RECOVERABLE.value or action == ActionKind.RECOVERABLE:
            return current_phase
        if action == ActionKind.SAFE_AUTO.value or action == ActionKind.SAFE_AUTO:
            try:
                index = self.phases.index(current_phase)
            except ValueError:
                raise ValueError("unknown Arthur phase: %s" % current_phase)
            return self.phases[min(index + 1, len(self.phases) - 1)]
        return current_phase
