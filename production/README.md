# XinZhaoWrt Production Control

This directory is the control plane for 路由固件完整生产 v1.0.

## Source of Truth

Use the production files by responsibility rather than treating one historical state file as the whole truth:

- `ARTHUR_PRODUCT_TARGETS.md` — current Arthur product intent and real-device acceptance targets.
- `release-policy.md` — RELEASE-FIRST policy, flash safety, candidate/stable promotion and release rules.
- `production-agent.json` — machine-readable production target/gate configuration.
- `arthur-known-good-v1.json` and `known-good.json` — frozen verified baseline and rollback evidence.
- `v4-state.json` and current HANDOFF/runtime state — controller persistence and task recovery context; cross-check them against current GitHub workflow/artifact/device evidence before treating them as real-time progress.

## Production principle

The only successful end state is `PRODUCTION_RELEASED`.

Candidate build success does not replace real-device verification. Stable/Latest promotion remains blocked until all applicable product-target and release-policy acceptance items pass on the real Arthur device.

Supporting automation components such as GPT, Codex, Bridge, Runtime, Supervisor or Skills must serve the firmware-release path. They must not become the main task or cause unrelated platform work to block a current Arthur release.

## Change handling

For a requested firmware change:

1. Restore current project/HANDOFF/GitHub/device evidence.
2. Identify the minimal intended diff against the frozen baseline and current product targets.
3. Run the project change-impact and baseline-integrity gates.
4. Choose the smallest reliable build lane that can safely produce the required artifact.
5. Build and verify artifact/provenance/hash requirements.
6. Enter automatic standard sysupgrade only when `AUTO_FLASH_SAFETY_GATE` passes.
7. Run real-device verification against both `release-policy.md` and `ARTHUR_PRODUCT_TARGETS.md`.
8. Promote only after Release Gate passes.

If a newer product target is documented but an older verifier does not enforce it yet, the item remains REQUIRED and unverified. Historical PASS evidence must not be reused to claim the newer requirement passed.
