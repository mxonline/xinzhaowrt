# Arthur First-Boot Handoff

## Arthur RELEASE-FIRST Candidate 33541575157 — STATIC VALIDATION BLOCKED

- GitHub Run: `33541575157`; source/project commit: `71003e146987aaf41d869a84972d2f4d99908baa`.
- Artifact: `Arthur-v3-Candidate-33541575157` (`9819776930`).
- Candidate prerelease: `arthur-update-33541575157`.
- Firmware: `XinZhaoWrt-Arthur-v0.1.3-20260901-sysupgrade.bin`.
- Size: `98212112` bytes.
- Firmware SHA256: `dc2c92b585feea7087d4e3be50427949c4e9bccc2555439e3e97da17106c8c61`.
- Rollback: `XinZhaoWrt-Arthur-v0.1.0-20260825-sysupgrade.bin`, SHA256 `9557593696c7bb07a1f0b259859140b4096ba71c675847aaf5ba5015118a7c2d`.
- Device identity and current device health were verified: MAC `dc:d8:7c:46:91:24`, model `JDCloud RE-SS-01`, board `jdcloud,re-ss-01`, target `qualcommax/ipq60xx`, LAN `192.168.6.1`.
- Candidate local/manifest/remote SHA256 matched. No sysupgrade, raw write, or Release action was executed.
- Static blocker: exact Candidate SquashFS contains no `argon` or `kucat` resource paths; `full.config` has `CONFIG_PACKAGE_luci-theme-argon` unset. The embedded first-boot root credential remains the project `passwort` hash, not the requested `password`.
- Evidence: `output/headless-production/candidate-33541575157-manifest.json`, `output/headless-production/static-validation-33541575157.json`.
- Current directive forbids a new Build, so the corrected Candidate cannot be produced in this run. Runtime/Supervisor remain stopped under safety block to prevent accidental flash or build dispatch.

## Current Recovery BLOCKED — REAL DEVICE PREBUILD GATE

- Fresh read-only network evidence: `Test-NetConnection 192.168.6.1 -Port 22` and `-Port 80` returned `TcpTestSucceeded=True`; unauthenticated LuCI returned HTTP 200.
- SSH evidence: `ssh -o BatchMode=yes -o ConnectTimeout=8 root@192.168.6.1` was rejected with `REMOTE HOST IDENTIFICATION HAS CHANGED` for `C:\Users\CodexSandboxOffline/.ssh/known_hosts:2`. Host-key verification was not bypassed and `known_hosts` was not modified.
- LuCI evidence: `/cgi-bin/luci/admin/services/adguardhome/` and `/cgi-bin/luci/admin/quickstart/` returned HTTP 403 with `x-luci-login-required: yes`. No `ARTHUR_LUCI_COOKIE_FILE` environment variable or cookie file was available.
- Prebuild evidence: `scripts/check-prebuild-real-device-gate.sh output/real-device/real-device-verification.json` failed closed because `ADGUARD_LIVE`, `QUICKSTART_LIVE`, `WIFI_LIVE`, and `FIRMWARE_BUILD_ALLOWED` were not valid PASS evidence; the existing report also lacks the new Wi-Fi snapshot audit. This report is historical and is not treated as fresh proof.
- Safety state: `PRODUCTION_RELEASED=false`; no production Build/Candidate dispatch, sysupgrade, raw write, or Release action is authorized from this blocked state. The separately authorized non-production Theme Candidate CI is recorded below.
- Next action: an operator must verify the Arthur host key out-of-band and provide an existing authenticated LuCI cookie; then rerun the read-only real-device verifier, confirm Wi-Fi snapshots are comparable and unchanged, and rerun the prebuild gate. Only a gate PASS may authorize the production Candidate path.

## Recovery Theme Candidate CI — PASS, NOT PRODUCTION RELEASE

- PR: `https://github.com/mxonline/xinzhaowrt/pull/57`; branch `codex/arthur-build-20260901-0816-132409c`; no local merge of `main`.
- Recovery commits pushed: `7f6107f` (`fix: harden Arthur recovery and prebuild gates`), `fa91575` (`fix: run clean candidate gates after source setup`), and `c554c50` (`fix: use ImmortalWrt AdGuard manager feed`).
- GitHub Actions Run `33787865737` at head `c554c50525723ce52ba46efdee2ce69e3382773a`: `completed/success` on `2026-09-03T18:19:30Z`. The job output shows Theme static gate, SDK_BUILD frozen themes only, ImageBuilder candidate/rootfs Theme Gate, Candidate Verification, and artifact upload all PASS.
- Artifact: `arthur-theme-candidate-33787865737`, artifact id `9906851806`, `98925407` bytes, digest `sha256:bdc0b8a2ee7e3deb19369f563a3541ff05252b94959af75770f9736513d07f4d`, not expired.
- This is non-production Theme Candidate evidence only. It does not satisfy the real-device prebuild gate and does not authorize firmware download for production, sysupgrade, flash, or Release.
- Closure state remains `PRODUCTION_RELEASED=false` / `BLOCKED`; next action is the host-key out-of-band verification plus authenticated LuCI cookie described in the preceding section, followed by a fresh read-only verifier and prebuild gate.

## ARTHUR FAST CANDIDATE ACCEPTED

Release `arthur-fast-candidate-33241309046` is accepted on the real Arthur after explicit clean-flash authorization.

- Firmware: `XinZhaoWrt-Arthur-fast-33241309046-sysupgrade.bin`
- SHA256: `733eeec1375403029f0b08b7307756b2edfd050ca52473891ab340051d3e5612`
- Project commit: `9bc5f471a92048233ff123370830000e124ca32d`
- Toolchain Run: `33196164359`
- QuickStart SDK Build: PASS (`aarch64_cortex-a53`)
- First Boot Runtime Gate: PASS — LAN `192.168.6.1/24`, both markers correct, all required stage log lines present, no `FIRSTBOOT_FAIL`.
- Web Stack Gate: PASS — nginx owns 80/443 and LuCI is reachable; uhttpd is inactive/no listener/no crash loop.
- Functional acceptance: PASS — 22/22 plugins, WAN DHCP, DNS, Internet HTTPS, SSH, storage, memory, logs, overlay, reboot, and persistence.
- Full Build Used: NO. Known-Good tag: NOT CREATED; await Baseline Freeze.

The earlier candidates remain recorded as `REJECTED_FIRST_BOOT`; their failure evidence is preserved below and is not used as the baseline.

Run `33182381566` built the specified candidate successfully, but the clean-flash FIRST BOOT acceptance failed. The candidate is `REJECTED_FIRST_BOOT`; Clean Flash and LAN Default are PASS, while both xinzhaowrt markers are FAIL. Known-Good remains NO.

Root cause is proven on the failed Arthur: real UCI reports `Entry not found` when the xinzhaowrt package file is absent, and `uci -q batch` returns zero despite creating no package. The targeted source fix atomically creates the package and verifies every marker mutation. The isolated real-UCI first-boot and idempotence gates pass.

QuickStart is independent and its root cause is proven: `/usr/sbin/quickstart` is a statically linked `ELF32 ARM EABI5`, while Arthur runs `aarch64` / `aarch64_cortex-a53`; it has no dynamic interpreter or shared-library dependency to repair. procd exits 127 because the executable is the wrong architecture, after which ash misparses ELF bytes as shell. The old feed bootstrap had forcibly selected `quickstart.arm`; source now retains `quickstart.$(PKG_ARCH_quickstart)`. The static source/web-stack gate passes: nginx remains primary and a rootfs uci-defaults overlay stops/disables uhttpd before enabling/restarting nginx. Await bootstrap `33196164359`, SDK-build only QuickStart for the matching aarch64 SDK, then assemble with ImageBuilder. Full Build is prohibited without a target/kernel/ABI/feed proof.

## Arthur FAST CANDIDATE READY

Release `arthur-fast-candidate-33232376176` contains `XinZhaoWrt-Arthur-fast-33232376176-sysupgrade.bin` (`SHA256 1b6028911a2e53f226e24a41d65a825a8b2223c8f7bf41ac434c59a316f8bb0a`) from project commit `528ac620a450d8c450920400fd46b1af604278f8`, built only through the accepted Toolchain Run `33196164359`. SDK_BUILD QuickStart, the isolated first-boot runtime/idempotence gate, ImageBuilder, WEB_STACK_GATE, profile/target/provenance/SHA256 checks, and isolated actual-rootfs `sysupgrade -T` are PASS. Full Build Used: NO. The old candidate remains `REJECTED_FIRST_BOOT`; Clean Flash and LAN Default remain PASS, FIRST BOOT remains FAIL, and Known-Good remains NO. No router was connected or modified. Next action requires explicit authorization for CLEAN FLASH + FIRST BOOT.
