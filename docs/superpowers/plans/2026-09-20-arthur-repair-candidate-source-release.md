# Arthur Repair Candidate Source and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Promote the already live-validated Arthur OpenClash/AdGuardHome repair into one new source-identified candidate and release it without touching the existing v0.1.5 release or device.

**Architecture:** Preserve dnsmasq as the LAN DNS frontend and keep the existing mature OpenClash, AdGuardHome and lifecycle implementations. Add only source-parity fixes proven by live evidence: bounded lifecycle locking, native swap persistence, HTTP-only Nginx, compatible AdGuardHome YAML defaults, default-disabled ADH, and authoritative device verifier checks.

**Tech Stack:** ImmortalWrt `qualcommax/ipq60xx`, Arthur profile `jdcloud_re-ss-01`, OpenClash Meta/Mihomo linux-arm64, AdGuardHome v0.107.79, OpenWrt UCI/procd/dnsmasq, Bash/Python/PowerShell gates, GitHub Actions release workflow.

**Spec:** `production/ARTHUR_PRODUCT_TARGETS.md` and `production/openclash-adguardhome-coexistence.json`.

## Global Constraints

- Existing v0.1.5 Release and Known-Good state remain unchanged.
- No sysupgrade, reflash, raw MTD, `dd`, bootloader or device write.
- `POST_RELEASE_DEVICE_TEST` remains an independent post-release acceptance, never a build prerequisite.
- Target remains `qualcommax/ipq60xx/jdcloud_re-ss-01` with 22 mandatory packages.
- LuCI remains HTTP/80 only; TCP/443 disabled and no HTTP-to-HTTPS redirect.
- AdGuardHome defaults to disabled; coexistence is `dnsmasq:53 -> AdGuardHome:1745 -> OpenClash:7874`.

## Review Focus

- Every live repair mutation has a source owner and is not only present in `/overlay` or a test command.
- Native swap is idempotently enabled only when the Arthur swap partition exists and is typed as swap.
- A missing AdGuardHome config receives the same compatible YAML structure as the validated runtime.
- Existing 22-package, Argon, Kucat, LAN, Wi-Fi and management contracts are inherited unchanged.
- Release metadata and artifact hash are derived from the new build identity and are not written back to v0.1.5.

### Task 1: Source parity audit and regression tests

**Files:**
- Create: `tests/test-arthur-source-parity.sh`
- Review: live evidence under `post-release-tests/arthur-v0.1.5-20260919/evidence/`
- Review: `files/usr/libexec/xinzhao-dns-coexist`, `files/etc/uci-defaults/98-xinzhao-web-stack`, `files/etc/config/AdGuardHome`, `files/etc/AdGuardHome.yaml`, `files/usr/share/AdGuardHome/AdGuardHome_template.yaml`, `scripts/real-device-verify.ps1`

- [ ] Map each live mutation to an authoritative source path.
- [ ] Add assertions for bounded lock wait, swap persistence, HTTP-only Nginx, compatible ADH YAML, default-disabled ADH, authoritative UCI namespace, and the required DNS chain.
- [ ] Run the new test and observe RED for the missing swap/template parity.

### Task 2: Minimal source fixes

**Files:**
- Create: `files/etc/uci-defaults/98-xinzhao-native-swap`
- Modify: `files/etc/AdGuardHome.yaml`
- Modify: `files/usr/share/AdGuardHome/AdGuardHome_template.yaml`
- Modify: `tests/test-arthur-source-parity.sh`

- [ ] Add idempotent first-boot UCI creation/enabling of `/dev/mmcblk0p28` only when `block info` reports `TYPE="swap"`.
- [ ] Replace the legacy `edns_client_subnet: false` and `clients: []` forms in both shipped ADH YAML sources with the v0.107.79-compatible mappings.
- [ ] Run the new parity test GREEN and rerun focused lifecycle/web/native-verifier checks.

### Task 3: Baseline inheritance and static/fast verification

**Files:**
- Generated: `output/changeset-manifest.json`, `output/source-parity-evidence.*`
- Review: `production/arthur-known-good-v1.json`, v0.1.3 acceptance evidence, current source diff

- [ ] Execute CHANGE_IMPACT, BASELINE_INHERITANCE, EXPECTED_DIFF, required-plugin, Argon/Kucat, LAN/defaults, web, ADH manager, OpenClash core, lifecycle and package-source gates.
- [ ] Confirm no protected target/profile/DTS/sysupgrade metadata changed.
- [ ] Record the new execution identity and source SHA before build.

### Task 4: New candidate build and artifact verification

**Files:**
- Generated only: `output/logs/build.log`, `output/firmware/*`, `output/build-info.txt`, `output/firmware/SHA256SUMS.local`

- [ ] Use the fastest valid project build lane after every static gate is green.
- [ ] Verify target/profile, 22 packages, bundled core path/architecture, HTTP-only web stack, ADH defaults, DNS chain and artifact SHA.
- [ ] Preserve build run ID and artifact ID; do not flash the device.

### Task 5: Release gate and GitHub Release

**Files:**
- Generated release evidence under `output/` and release metadata

- [ ] Run RELEASE_GATE against the exact candidate artifact and source identity.
- [ ] Publish one new candidate Release without editing v0.1.5.
- [ ] Stop at `PRODUCTION_RELEASED + POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT`.
