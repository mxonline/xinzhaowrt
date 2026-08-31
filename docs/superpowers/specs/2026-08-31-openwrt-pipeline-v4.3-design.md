# OpenWrt Automated Firmware Pipeline v4.3 Design

## Goal

Make `PRODUCTION_RELEASED` the only success state while preventing partial feature work from producing a flashable Arthur candidate.

The production build system must remain useful even when the local GPT-Codex Bridge, Codex UI, Windows supervisor, or local workstation is stopped. GitHub Actions is the authoritative build plane. GPT/Codex is an optional remediation plane for code/build failures, not a prerequisite for ordinary compilation.

## Core model

The pipeline is release-first and batched:

`RESTORE_STATE -> COLLECT_CHANGESET -> REUSE_GATE -> IMPLEMENT -> STATIC_VERIFY -> IMPLEMENTATION_COMPLETE_GATE -> CHANGESET_FREEZE -> BUILD_ROUTER -> PRODUCTION_BUILD -> ARTIFACT_GATE -> CANDIDATE_GATE -> AUTO_FLASH_SAFETY_GATE -> AUTO_SYSUPGRADE -> WAIT_DEVICE -> FULL_REAL_DEVICE_VERIFY -> RELEASE_GATE -> GITHUB_RELEASE -> PRODUCTION_RELEASED`

A failed real-device verification enters one batch-repair cycle: collect all failures, repair them together, freeze a new repair changeset, rebuild once, reflash once, and fully reverify.

## Build-plane ownership

GitHub Actions owns normal compilation. Its state is authoritative for build progress and artifact availability.

The local GPT-Codex Bridge may create or repair source commits, but a running Bridge process is not required after a frozen source revision reaches GitHub. If the Bridge disappears while a build is queued or running, the GitHub workflow continues to completion. When GPT/Codex later returns, it resumes from GitHub run/artifact state instead of restarting completed work.

The production build state machine is:

`REQUESTED -> IMPACT_CHECKED -> BUILD_QUEUED -> BUILDING -> BUILD_FAILED | ARTIFACT_READY -> CANDIDATE_VERIFIED`

`BUILD_FAILED` branches into either bounded infrastructure retry or code remediation. It must never be treated as a reason to restart an already successful build.

## Build Router

`BUILD_ROUTER` chooses the smallest verified build lane compatible with the frozen changeset:

- `IMAGEBUILDER`: files/defaults/package-selection changes that do not require compiling new packages or changing ABI/kernel/target.
- `SDK_BUILD + IMAGEBUILDER`: new or changed user-space packages/LuCI applications that can be built against the frozen known-good SDK/package repository.
- `FULL_BUILD`: kernel, target, profile, ABI-sensitive, toolchain, driver, partition/storage, or unknown-impact changes.

Unknown or ambiguous impact fails closed to `FULL_BUILD`.

The router decision is recorded with the changeset and artifact provenance. It is deterministic for a given frozen source SHA and known-good baseline.

## Hard-gate invariant

A production candidate is eligible only when all of the following are true in the checked-out source revision:

- every required task in `production/current-changeset.json` is `PASS`;
- `implementation_complete` is `true`;
- `frozen` is `true`;
- workflow input `changeset_id` matches the state file;
- workflow input `source_sha` matches the checked-out `HEAD`;
- `CHANGE_IMPACT_GATE=PASS`;
- `BASELINE_INHERITANCE_GATE=PASS`;
- `EXPECTED_DIFF_GATE=PASS`.

If any condition fails, the workflow must terminate before SDK, ImageBuilder, Full Build, candidate artifact generation, flashing, or release.

## Current Arthur required tasks

- `adguardhome_full_manager`
- `istoreos_original_quickstart`
- `wifi_real_connect_fix`
- `plugin_i18n`
- `argon_compatibility`
- `kucat_compatibility`
- `plugins_menu_cleanup`
- `baseline_regression`

The initial state is intentionally incomplete and unfrozen. Development commits therefore cannot produce a production candidate.

## Automated production-build trigger

A frozen changeset is the trigger boundary. Once a revision passes implementation/freeze gates on GitHub, the cloud build workflow must queue automatically; the user must not have to copy a Codex response, paste a GPT instruction, keep a local terminal open, or manually press a build button.

The trigger must bind immutable values:

- `source_sha`
- `changeset_id`
- known-good baseline identity
- router decision

Duplicate requests for the same tuple are idempotent: an existing queued/running/successful production run is reused instead of creating another build.

Manual `workflow_dispatch` remains an emergency/operator entry point, not the normal path.

## Candidate workflow contract

Every Arthur workflow that can produce a flashable sysupgrade candidate must accept or derive immutable:

- `source_sha`
- `changeset_id`
- `confirm=BUILD_FROZEN_CHANGESET`

It must checkout `source_sha`, run `scripts/implementation-complete-gate.sh`, verify the three v4.3 change gates, and only then enter any firmware build step.

Development/preflight workflows may run without this production gate only when they cannot produce a flashable candidate.

## Artifact Gate

A successful workflow is not sufficient by itself. `ARTIFACT_GATE` must verify and publish machine-readable provenance for the candidate:

- workflow run ID and attempt;
- source SHA and changeset ID;
- known-good baseline identity;
- selected build lane;
- artifact ID/name/size;
- artifact digest/SHA256;
- sysupgrade filename/SHA256;
- target/profile;
- package/plugin report;
- theme/language/default-config report;
- rollback reference.

Incomplete or partially downloaded artifacts are never eligible and are removed from local recovery directories.

## Failure classification and automatic recovery

Failures are classified before deciding whether source code should change.

Infrastructure/transient failures include GitHub 5xx, network/TLS EOF, artifact download interruption, runner provisioning, API rate limiting, and equivalent transport failures. These receive bounded retry/backoff and reuse the same frozen `source_sha`; they do not create a source commit.

Deterministic source/build failures include compiler errors, missing packages, dependency resolution, configuration contradictions, static gate failures, and equivalent reproducible failures. Their logs and failure fingerprint become remediation evidence for GPT/Codex. Codex makes the minimum source repair, tests it, freezes a new source SHA only when required, and the cloud build resumes from the appropriate lane.

Retry loops are bounded. Repeated identical failure fingerprints escalate instead of producing infinite commits/builds.

## GPT/Codex role

GPT/Codex is responsible for requirement interpretation, root-cause analysis, and minimum source repair when a deterministic failure requires code changes.

GPT/Codex is not responsible for keeping a normal GitHub build alive. The following are therefore non-blocking to a queued/running production build:

- local Bridge stopped;
- Codex UI closed;
- Windows supervisor stopped;
- local workstation rebooted;
- local heartbeat unavailable.

After recovery, GPT/Codex reads GitHub run/artifact state first and continues from the first incomplete production gate.

## Runtime and release invariants

- Arthur target/profile remains `qualcommax/ipq60xx` / `jdcloud_re-ss-01`.
- LAN remains `192.168.6.1`, public LuCI HTTP remains port `80`.
- Argon remains the default theme; Kucat remains the second theme.
- Wi-Fi must pass config, runtime, and real-client association gates; config presence alone is insufficient.
- AdGuard Home is installed with the full manager but is disabled and stopped by default and must be disabled again after controlled real-device verification.
- The final artifact identity must satisfy `BUILD_SHA256 = FLASHED_SHA256 = VERIFIED_SHA256 = RELEASE_SHA256`.
- Standard verified Arthur flashing remains PowerShell -> `ssh.exe` -> remote SHA256 -> `/sbin/sysupgrade`; raw MTD/U-Boot/bootloader/dd/eMMC/SPI/NAND writes are outside automatic execution.

## Success criteria for automated compilation

For a normal frozen changeset, the user provides the desired firmware change once. The system automatically reaches either:

`AUTOMATED_BUILD=PASS + CANDIDATE_READY=YES + CANDIDATE_SHA256=<sha256>`

or a bounded, evidence-backed safety/credential block.

No ordinary compilation success criterion depends on a local Runtime PID, Codex PID, Supervisor PID, or local heartbeat.

## Failure behavior

A failed implementation/change gate returns non-zero and prints the specific missing/inconsistent condition. A candidate workflow must not silently downgrade this failure or continue with `|| true`.

A failed build preserves logs, run ID, source SHA, changeset ID, selected lane, and failure fingerprint. A successful build preserves artifact provenance. No automatic recovery is allowed to discard evidence or replace the frozen source with an unrelated branch head.

## Migration rule

Existing intermediate artifacts produced before v4.3 remain non-production. In particular, workflow run `33396664381` is not eligible for flash or release because it predates the implementation-complete/freeze hard gate.

Run `33400519410` is a successful formal build for source `2f1b8883ccdf65a98ef13cac5ad1da12d80155db`; recovery logic must reuse its existing artifact when still valid rather than rebuilding only because a local Bridge process failed.
