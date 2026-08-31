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
        "CHANGESET_IMPLEMENTATION",
        "CHANGESET_FREEZE",
        "IMPLEMENTATION_COMPLETE_GATE",
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

        phase_instruction = {
            "CHANGESET_IMPLEMENTATION": (
                "Read production/current-changeset.json and finish every still-pending required task for the active v4.3 "
                "changeset. Use the smallest deterministic edits and targeted tests. Do not build, flash, freeze, or release. "
                "Do not mark a task PASS without concrete test/source evidence. Keep working inside this phase until the "
                "implementation is actually ready to freeze."
            ),
            "CHANGESET_FREEZE": (
                "Freeze the completed v4.3 changeset exactly as specified by the repository policy: the implementation "
                "commit must already contain all code changes; create only the state-only freeze commit that updates "
                "production/current-changeset.json, records the implementation parent SHA, marks every required task PASS, "
                "sets implementation_complete=true, state=FROZEN, frozen=true and allow_candidate_build=true. Do not include "
                "any other file in the freeze commit and do not start a build in this phase."
            ),
            "IMPLEMENTATION_COMPLETE_GATE": (
                "Run scripts/implementation-complete-gate.sh and scripts/check-changeset-complete.sh against the exact frozen "
                "HEAD. Treat any failure as recoverable: repair the underlying implementation/freeze defect, create a fresh "
                "valid state-only freeze if required, and rerun the gates. Do not advance to BUILD until "
                "IMPLEMENTATION_COMPLETE_GATE=PASS, CHANGESET_FREEZE=PASS and CANDIDATE_ELIGIBLE=YES are proven."
            ),
            "BUILD": (
                "Build the single production candidate for the exact frozen changeset on GitHub Actions using the repository's "
                "validated routing/build path. Intermediate theme/test artifacts are not production candidates. Require full "
                "production provenance, target/profile manifest, 22/22 baseline-plugin evidence, rootfs manifest and SHA256 "
                "before advancing."
            ),
            "ARTIFACT": (
                "Fetch and verify the production candidate produced for the exact frozen changeset. Reject an artifact from a "
                "different run, branch, source SHA, or intermediate workflow. Preserve cloud/local artifact digest and firmware "
                "SHA256 evidence."
            ),
            "PRE_FLASH": (
                "Assemble the complete pre-flash evidence for the exact production candidate. If provenance is incomplete, do "
                "not stop the production request and do not reuse an intermediate candidate; classify the failure recoverable "
                "and automatically return to the smallest build/artifact repair needed for the same frozen changeset."
            ),
        }.get(phase)

        common = (
            "Production phase %s for Arthur (qualcommax/ipq60xx/jdcloud_re-ss-01). "
            "Execute only this phase, collect durable evidence, do not ask for design/spec/plan/merge/PR approval, "
            "standard sysupgrade is automatic only after AUTO_FLASH_SAFETY_GATE; never perform raw MTD/U-Boot/dd/eMMC writes. "
            "Ordinary build, dependency, source, configuration, artifact, LAN, plugin, theme and gate failures are recoverable "
            "and must continue automatically. Return a concise result with evidence paths."
        ) % phase
        return common if not phase_instruction else common + " " + phase_instruction

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
