# Arthur Known-Good Baseline

## Meaning of Known-Good

For this project, a successful cloud compile is not enough to become Stable Known-Good.

A promoted Known-Good requires:

1. pinned/reproducible source state;
2. target/profile validation;
3. all 22 mandatory LuCI applications present;
4. firmware artifacts and checksums valid;
5. project acceptance guards pass;
6. real JDCloud RE-SS-01 verification recorded;
7. Stable promotion completed by the project workflow.

`production/known-good.json` is the authoritative machine-readable Stable record.

## Stable KG-001

Current real-device-confirmed baseline:

- Stable tag: `v0.1.0`
- Device: `jdcloud_re-ss-01`
- Firmware: `XinZhaoWrt-Arthur-v0.1.0-20260825-sysupgrade.bin`
- Firmware SHA256: `9557593696c7bb07a1f0b259859140b4096ba71c675847aaf5ba5015118a7c2d`
- Upstream ImmortalWrt commit: `27e26e324bee0b0c2a4eb58e2e9121fea5d43194`
- Source-lock SHA256: `1f38f596607346d12097b89f5ab92341172ffbe7a6424c22231b212efbbcc3c1`
- Verification: `real-device-confirmed`
- Verified at: 2026-08-25

This baseline is the safe reference and rollback point for future updates.

## Current Candidate

Candidate lineage created on 2026-08-26:

- Version: `0.1.1`
- Project functional build commit: `256b18667e5b2423cf235303dec5877957d6fd4a`
- Workflow run: `32943895389`
- Candidate tag: `arthur-update-32943895389`
- Mode: `rebuild_known_good`
- Source lock: unchanged from Stable
- Build result: PASS
- Required LuCI applications: 22/22 PASS
- Large-upload OOM acceptance guard: PASS
- Firmware checksums: PASS
- Factory/sysupgrade/initramfs outputs: generated and verified by the workflow

Candidate is intentionally a prerelease. It must not replace KG-001 until real-device verification and Stable promotion pass.

## Baseline evolution rule

Every firmware change must start from a known baseline and produce an explicit delta.

Preferred progression:

`Stable Known-Good -> one scoped change -> Candidate -> automated acceptance -> real-device verification -> Stable promotion`

For source updates, prefer one source family at a time:

- ImmortalWrt core
- standard feeds
- external plugin family
- project overlay/build logic

Broader `update_all` is allowed only when deliberately requested and should be treated as higher risk.

## Never mutate the baseline silently

Do not:

- overwrite `production/known-good.json` before promotion;
- rewrite the source lock merely because upstream moved;
- remove a mandatory plugin to make a Candidate compile;
- call a Candidate Stable based only on GitHub Actions success;
- discard the prior Stable release after a new Candidate appears.

## Promotion evidence

Before promotion, preserve evidence for:

- exact project commit;
- exact source/feed/plugin refs;
- firmware SHA256;
- 22/22 plugin result;
- OOM guard result;
- real-device verification result;
- Stable tag/release created by the promotion path.

If any of these is unavailable, the Candidate remains unpromoted.