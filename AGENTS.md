# 新肇网络Wrt-京东云亚瑟固件 — Codex project rules

## Project identity

- Official Chinese name: 新肇网络Wrt-京东云亚瑟固件
- Internal firmware ID: XinZhaoWrt
- Device: JDCloud RE-SS-01 / Arthur
- SoC: Qualcomm IPQ6000
- OpenWrt target: qualcommax/ipq60xx
- Device profile: jdcloud_re-ss-01
- 64G means eMMC capacity only. Never create a fake `jdcloud_re-ss-01-64g` target.
- Upstream: VIKINGYFY/immortalwrt
- Default branch: main

Read `build.env` before changing build logic.

## Agent Knowledge Layer

For every non-trivial firmware task, do not begin by re-deriving the project from old chat context or loading every repository document.

Required startup sequence:

1. read `knowledge/PROJECT-STATE.md`;
2. verify live Git branch/HEAD and relevant GitHub workflow/release state;
3. read `knowledge/INDEX.md` and route the task to only the relevant knowledge/documents;
4. for device/target work, read `knowledge/DEVICE-PROFILE.md`;
5. for baseline/update work, read `knowledge/KNOWN-GOOD.md` and `knowledge/SOURCE-LOCK.md`;
6. on a failure, classify the first causal error and consult `knowledge/KNOWN-FAILURES.md` before inventing a repair;
7. before changing an upstream/feed/package source, adopting a fork, or creating a new compatibility patch/build component, execute `knowledge/REUSE-GATE.md` and record `USE / REUSE / FORK / BUILD`.

Live GitHub/build/device evidence overrides stale documentation. `production/known-good.json` remains the machine-readable authority for the last promoted real-device-confirmed Stable. `config/arthur-known-good.lock` remains the authority for pinned source/feed/plugin refs.

After a new failure is genuinely fixed and verified, update `knowledge/KNOWN-FAILURES.md`. After a Candidate is promoted, update the project state/known-good knowledge to match the new machine-readable Stable record.

## Reuse Gate hard rule

`knowledge/REUSE-GATE.md` is a prospective source/implementation decision gate. It does not create a new firmware workflow and does not supersede the current Known-Good/Candidate/Stable gates.

- Do not move `config/arthur-known-good.lock`, invalidate `production/known-good.json`, restart an active Candidate, or revert current `main` progress merely because this rule was introduced.
- Rebuilding the exact current locked baseline does not require a new Reuse Gate.
- Apply the gate when a task changes upstream, feeds, third-party package sources, forks, patch strategy or build-system components.
- Search official OpenWrt/ImmortalWrt sources first, then same-device/same-target recent successful GitHub Actions baselines, then maintained package upstreams/forks.
- Evaluate actual target/kernel/branch compatibility, recent CI/build status, license, maintenance, dependency health, security, source provenance, 22-plugin compatibility and long-term maintenance cost.
- Star count is supporting evidence only.
- No explicit `USE / REUSE / FORK / BUILD` decision means no new source/fork/custom compatibility implementation should be adopted.
- The gate never authorizes dropping a mandatory plugin or weakening acceptance criteria to get a green build.

## Mandatory plugins

`config/required-plugins.txt` is the authoritative list. It contains exactly 22 required LuCI applications. Every one must remain `=y` after `make defconfig`.

Never fix a build by silently deleting, disabling, renaming or commenting out a requested plugin. If a plugin fails:

1. identify the first real compiler/package error;
2. verify source layout and dependencies;
3. check current ImmortalWrt/kernel API compatibility;
4. run the Reuse Gate when the repair would change package source/fork/patch strategy;
5. patch or update the package source only after that decision;
6. rerun `make defconfig` and `scripts/check-config.sh`;
7. rebuild.

## Required first-boot defaults

- LAN IP: 192.168.6.1
- administrator: root
- initial password: passwort

These defaults are implemented in `files/etc/uci-defaults/99-xinzhao-defaults` and checked by `scripts/check-defaults.sh`.
Do not change them unless the user explicitly requests a change.

The password is intentionally a known initial password. Documentation must tell users to change it immediately after first login.

## Source rules

Use standard ImmortalWrt feeds where the requested package exists. External packages are added by `scripts/add-custom-packages.sh`.
Avoid adding broad duplicate feeds just to make one package appear.

Current external source families:

- iStoreX / Store / QuickStart / QuickFile / Lucky: selected kenzok8 packages
- DiskMan: sbwml/luci-app-diskman
- EasyTier: EasyTier/luci-app-easytier
- MosDNS: sbwml/luci-app-mosdns v5 plus geodata dependency
- OpenClash: vernesong/OpenClash
- OAF: destan19/OpenAppFilter

Before replacing any of these source families, use `knowledge/REUSE-GATE.md`. Existing pinned refs remain authoritative until the normal update/fix acceptance path justifies a lock change.

## Build procedure

Before a long build:

```bash
./scripts/verify-project.sh
```

Before `make defconfig`, external sources must pass:

```bash
./scripts/check-package-sources.sh work/immortalwrt
```

Cloud build entrypoint:

```bash
./scripts/codex-cloud-build.sh
```

Do not stream a full OpenWrt build log into the conversation. The cloud build writes `output/logs/build.log`. On failure, use:

```bash
./scripts/extract-build-error.sh output/logs/build.log
```

Read only the relevant error area before deciding on a fix.

## Build success criteria

A build is not successful merely because `make` exits zero. Verify all of these:

- target remains `qualcommax/ipq60xx/jdcloud_re-ss-01`;
- all 22 mandatory plugin symbols remain enabled in `output/full.config`;
- at least one Arthur firmware image is present in `output/firmware/`;
- `output/build-info.txt` exists;
- `output/firmware/SHA256SUMS.local` exists;
- first-boot defaults file is included in the source `files/` overlay.

## Web server stack

QuickFile requires `luci-nginx`. This project therefore uses LuCI on Nginx as the primary web stack. Do not add the `luci` or `luci-ssl` meta collections unless there is a verified reason, because those select the default uhttpd stack and may create port conflicts with Nginx.

## Runtime coexistence notes

AdGuard Home, MosDNS, SmartDNS and OpenClash may all be compiled, but do not configure multiple services to bind the same DNS port 53 by default.
OpenClash and PBR may coexist as packages, but should not both be configured to own the same policy-routing flows.
OAF is kernel-facing and should be one of the first packages investigated after a major upstream kernel change.

## Safety

Never execute a router flashing command, write a bootloader, alter eMMC partitions, ART/EEPROM/calibration data or U-Boot automatically. Build and validation are allowed. Flashing instructions must remain human-reviewed.

## Git discipline

Before editing: `git status`.
After editing: `git diff`.
Never commit `work/`, `output/`, `build_dir/`, `staging_dir/`, `dl/`, `tmp/` or full build logs.
Use focused commit messages such as `fix: resolve OAF build compatibility` or `feat: add Arthur first-boot defaults`.
