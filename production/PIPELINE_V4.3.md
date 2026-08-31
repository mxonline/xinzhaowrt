# OpenWrt Automated Firmware Pipeline v4.3

## Fixed production order

`RESTORE_STATE → COLLECT_CHANGESET → REUSE_GATE → IMPLEMENT → STATIC_VERIFY → IMPLEMENTATION_COMPLETE_GATE → CHANGESET_FREEZE → PRODUCTION_BUILD → CANDIDATE_GATE → AUTO_FLASH_SAFETY_GATE → AUTO_SYSUPGRADE → WAIT_DEVICE → FULL_REAL_DEVICE_VERIFY → RELEASE_GATE → GITHUB_RELEASE → PRODUCTION_RELEASED`

## Hard rule

No production candidate may enter SDK, ImageBuilder or Full Build until `production/current-changeset.json` is committed with every required task `PASS`, `implementation_complete=true`, `frozen=true`, and `candidate_policy.allow_candidate_build=true`.

Freeze uses two commits:

1. The final implementation commit contains all code/config changes and is recorded as `frozen_source_sha`.
2. The immediately following **state-only freeze commit** may modify only `production/current-changeset.json` and becomes the Candidate checkout HEAD.

The hard gate verifies that the Candidate HEAD parent equals `frozen_source_sha`. Any additional commit after freeze invalidates Candidate eligibility automatically.

The code-level authority is `scripts/implementation-complete-gate.sh`. Natural-language claims from GPT/Codex are not sufficient.

## Batched changeset

A normal cycle is:

1. Collect all pending changes.
2. Implement and statically verify all of them.
3. Commit the final implementation source.
4. Create one state-only freeze commit.
5. Build one production candidate.
6. Perform one standard automatic sysupgrade.
7. Run one full real-device verification.

If real-device verification fails, collect every failure first, then create one batch repair changeset. Do not rebuild/reflash once per individual failure.

## Intermediate artifacts

Builds created before the hard gate existed or while the changeset is not frozen are `INTERMEDIATE_NON_PRODUCTION` and are never eligible for flashing or release. Run `33396664381` is explicitly in this class.

## Arthur release invariants

- `qualcommmax/ipq60xx` / `jdcloud_re-ss-01`
- LAN `192.168.6.1`
- LuCI HTTP `80`
- Simplified Chinese `zh_cn`
- Argon default, Kucat selectable
- 22 baseline LuCI plugins
- AdGuard Home installed but default/final state disabled
- Wi-Fi requires config + runtime + real client connection verification
- Standard flash transport: PowerShell → OpenSSH `ssh.exe` → remote SHA256 → `/sbin/sysupgrade`
- No automatic raw MTD/U-Boot/bootloader/dd/raw eMMC/SPI/NAND writes

## Final identity invariant

`BUILD_SHA256 = FLASHED_SHA256 = VERIFIED_SHA256 = RELEASE_SHA256`

Only `PRODUCTION_RELEASED` is a completed production run.
