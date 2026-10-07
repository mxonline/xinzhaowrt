# Arthur Real Device Verification

## Current result — Arthur FAST Candidate accepted

- Release: `arthur-fast-candidate-33241309046`
- Firmware: `XinZhaoWrt-Arthur-fast-33241309046-sysupgrade.bin`
- SHA256: `733eeec1375403029f0b08b7307756b2edfd050ca52473891ab340051d3e5612`
- Project commit: `9bc5f471a92048233ff123370830000e124ca32d`
- Toolchain run: `33196164359`
- Clean Flash: PASS — executed only after explicit authorization.
- Device identity: PASS — JDCloud RE-SS-01 / `jdcloud,re-ss-01` / `qualcommax/ipq60xx`.
- FIRST BOOT: PASS — LAN `192.168.6.1/24`, `initialized=1`, `firmware=XinZhaoWrt-Arthur`; `/tmp/xinzhaowrt-firstboot.log` contains `FIRSTBOOT_START`, `LAN_CONFIG_PASS`, `ROOT_CREDENTIAL_PASS`, `MARKER_CONFIG_PASS`, and `FIRSTBOOT_COMPLETE`, with no `FIRSTBOOT_FAIL`.
- QuickStart: PASS — actual binary is `ELF 64-bit LSB ARM aarch64`, statically linked; service running and stable across reboot.
- Web Stack: PASS — nginx 1.30.3 owns 80/443, HTTP redirects to HTTPS, LuCI returns expected unauthenticated 403, uhttpd is inactive with no listener or crash loop.
- Functional gates: PASS — 22/22 plugins, WAN DHCP, DNS, HTTPS Internet egress, SSH, storage, memory, logs, overlay, reboot, and persistence.
- Full Build Used: NO. Known-Good tag: NOT CREATED (await Baseline Freeze).

## Run 33182381566 — rejected FIRST BOOT candidate

- Candidate: `XinZhaoWrt-Arthur-v0.1.3-20260828-sysupgrade.bin`
- Build / artifact identity / SHA256 / profile / target / source commit / 22-plugin manifest: PASS
- Clean Flash: PASS
- LAN Default: PASS — `192.168.6.1/24`
- FIRST BOOT: FAIL — `xinzhaowrt.system.initialized` and `xinzhaowrt.system.firmware` were absent.
- Known-Good: NO
- Root cause: an absent `/etc/config/xinzhaowrt` makes UCI report `Entry not found`; `uci -q batch` suppresses that error and returns zero, so the old defaults script was removed without committing markers.
- Targeted fix: explicit atomic package creation, fail-closed UCI transaction, stage evidence, and real-UCI runtime/idempotence gate.
- Runtime preflight: PASS on isolated real UCI (`FIRST_BOOT_RUNTIME_GATE`, `FIRST_BOOT_IDEMPOTENCE`).
- QuickStart runtime: FAIL / ROOT CAUSE CONFIRMED — extracted `/usr/sbin/quickstart` is a statically linked `ELF32 ARM EABI5` executable (no dynamic interpreter or shared-library dependencies), while Arthur runs `aarch64` / `aarch64_cortex-a53`. procd exit 127 is therefore a wrong-architecture exec failure; ash then misparses the ELF as a script.
- QuickStart source correction: PASS (static) — the Kenzok8 feed bootstrap had replaced `quickstart.$(PKG_ARCH_quickstart)` with `quickstart.arm`; the correction preserves the target-architecture artifact selection. SDK rebuild remains pending bootstrap acceptance.
- Web stack: static gate PASS — nginx remains primary and the new overlay stops/disables uhttpd before enabling/restarting nginx. Runtime gate is pending the rebuilt aarch64 QuickStart package.
- Next: wait for bootstrap `33196164359` → SDK_BUILD QuickStart → ImageBuilder → runtime WEB_STACK_GATE → replacement candidate. Do not full-build or flash this rejected candidate.

## Arthur FAST CANDIDATE — ready, not flashed

- Release: `arthur-fast-candidate-33232376176`
- Firmware: `XinZhaoWrt-Arthur-fast-33232376176-sysupgrade.bin`
- SHA256: `1b6028911a2e53f226e24a41d65a825a8b2223c8f7bf41ac434c59a316f8bb0a`
- Project commit: `528ac620a450d8c450920400fd46b1af604278f8`
- Toolchain run: `33196164359` (accepted SDK, ImageBuilder, repository, SHA256, provenance, and lock)
- SDK_BUILD QuickStart: PASS — matching `aarch64_cortex-a53` package was built and executed through the SDK gate.
- FIRST_BOOT_RUNTIME_GATE / idempotence: PASS — isolated real UCI gate; rootfs defaults are now executable.
- WEB_STACK_GATE: PASS — nginx primary, uhttpd disabled, QuickStart architecture/runtime probe passed.
- ImageBuilder: PASS — 22 required LuCI applications asserted; the missing non-required `luci-i18n-base-zh-cn` is explicitly recorded as unavailable from the accepted package set.
- `sysupgrade -T`: PASS — executed in an isolated rootfs extracted from this candidate with Arthur board identity `jdcloud,re-ss-01`.
- Full Build Used: NO. No router connection, configuration modification, or flash occurred after the old failure evidence was preserved.
- Next: await authorization for CLEAN FLASH + FIRST BOOT.

- Started: 2026-08-28 15:58 +08:00
- Scope: resumed from an already-flashed, booted firmware. No build, download, flash, factory reset, or configuration rewrite is permitted.

## Stage 1 — Windows network discovery

- Status: PASS
- Active physical adapter: Intel(R) Ethernet Connection (16) I219-V
- Host IPv4: `192.168.1.152/24`
- DHCP server / IPv4 default gateway / DNS: `192.168.1.1`
- Router candidate: `192.168.1.1` (ARP MAC `dc-d8-7c-46-91-24`)
- Other discovered local networks are VMware-only (`192.168.127.0/24`, `192.168.169.0/24`); no broader scan is required while the active LAN identifies the router candidate.

Historical validation records under `output/real-device/` were found and left untouched. This directory is the resumable record for the current verification run.

## Stage 2 — Live reachability

- Status: IN_PROGRESS
- ICMP: PASS — 3/3 replies from `192.168.1.1`, 0% loss, 0–2 ms.
- TCP/22: PASS — port open.
- HTTP: PASS — nginx 1.30.3 responds and redirects HTTP to HTTPS.
- SSH authentication: IN_PROGRESS — client trust-state mismatch must be investigated before a safe known-host update.
- HTTPS/LuCI: IN_PROGRESS — TCP service is behind nginx; direct Windows curl TLS setup failed locally before connecting, so a second local HTTPS client will be used.

## Stage 3 — Live system acceptance

- Status: PASS
- Device / target: `JDCloud RE-SS-01` / `jdcloud,re-ss-01`, `qualcommax/ipq60xx`.
- OpenWrt: `ImmortalWRT SNAPSHOT r0+1-27e26e324`; kernel `6.18.44`.
- Uptime / clock: 5 h 55 min at collection; router UTC time exactly matched the Windows host UTC time.
- Memory: 404,996 KiB total, 148,424 KiB available, no swap; no OOM evidence.
- Storage: f2fs overlay is mounted read-write with 1.8 GiB free (5% used); the 50.9 GiB data volume is healthy.
- LAN/WAN/DHCP: `br-lan` is up at `192.168.1.1/24`; WAN is DHCP-up at `192.168.2.208/24` with default gateway `192.168.2.1`; the verification PC has an active DHCP lease.
- DNS / Internet: DNS resolves `openwrt.org`; HTTPS egress succeeds. ICMP to `1.1.1.1` is filtered, but this does not affect working Internet access.
- SSH: Dropbear listens on TCP/22 and root authentication succeeded using an ephemeral session. No local SSH trust file was modified.
- LuCI: nginx listens on TCP/80 and TCP/443, HTTP redirects to HTTPS, and a Node.js TLS probe received `HTTP 403` from `/cgi-bin/luci/` — the expected unauthenticated LuCI response.
- Plugins: all 22 mandatory APK packages are installed. LuCI menu definitions, legacy controllers/views where applicable, and RPC ACLs were found. Feature-specific services that are intentionally unconfigured were not force-started, avoiding unsafe DNS or policy-routing conflicts.
- Logs: no kernel panic, OOM, segfault, filesystem/overlay/mount failure, RPC error, dependency error, or restart loop. One nginx `favicon.ico` 404 is cosmetic. `uhttpd` is inactive by design because LuCI runs on nginx.

## Stage 4 — Persistence and controlled reboot

- Status: PASS
- A read-write overlay marker and baseline hashes of `/etc/config/*` were created without changing existing configuration.
- One normal reboot was issued. The uptime reset from approximately 5 h 55 min to 10 min, confirming a real reboot.
- Post-reboot: 3/3 LAN ICMP replies; TCP/22 and TCP/443 open; nginx returned HTTP→HTTPS redirect and LuCI HTTPS returned the expected unauthenticated `403`; LAN/WAN DHCP, DNS, HTTPS egress, overlay, memory, services, 22/22 plugins, and logs all passed.
- Persistence: the marker remained present, every current `/etc/config/*` hash was found in its baseline, and `/overlay` remained writable.

## Final acceptance

| Check | Result |
| --- | --- |
| Boot | PASS |
| LAN | PASS |
| WAN | PASS |
| DHCP | PASS |
| DNS | PASS |
| Internet | PASS |
| SSH | PASS |
| LuCI | PASS |
| Plugins | PASS (22/22) |
| Storage | PASS |
| Memory | PASS |
| Logs | PASS |
| Reboot | PASS |
| Persistence | PASS |

**Runtime acceptance: PASS**

**Known-Good firmware baseline: NO** — the running-image provenance was later
resolved to the rejected v0.1.3 candidate, so this evidence is retained but is
not eligible to establish a firmware baseline.

Warnings retained: upstream ICMP filtering to `1.1.1.1`; local Windows Schannel incompatibility with the self-signed HTTPS endpoint (Node.js verified the endpoint); nginx `favicon.ico` 404; uhttpd inactive by design.

## Fixed-candidate continuation

- Status: BLOCKED before build dispatch.
- Repair source: `a735e34cc5b787a9c62f4138741abe55affe960a` (`fix: enforce Arthur first-boot identity`).
- Repair checks: PASS — the first-boot test replaces the CIDR-form upstream LAN value with `192.168.6.1/24`, persists the `xinzhaowrt` marker, and the version-identity test injects `XinZhaoWrt v0.1.3`.
- GitHub authentication: PASS — an in-memory `GH_TOKEN` authenticated `gh api user` as `mxonline`.
- Build dispatch blocker: GitHub REST requests to `mxonline/xinzhaowrt` and its Actions endpoints terminate with EOF from this host. No new GitHub Actions run was dispatched and no existing artifact was reused.

## Defconfig identity gate repair

- Previous failed run: `33152832160` (`Arthur Known-Good Fast Lane v1`).
- Root cause: `CONFIG_VERSIONOPT` is conditional on `CONFIG_IMAGEOPT`; the build seed omitted `CONFIG_IMAGEOPT=y`, so `make defconfig` removed the injected version identity option.
- Repair: the Arthur seed and identity injector now both select `CONFIG_IMAGEOPT=y`. A real-source normalization test runs `arthur.config` → identity injection → `make defconfig` and requires `IMAGEOPT`, all version symbols, and all 22 plugins before source downloads or compilation.
- Static checks: PASS. The actual normalization gate will run in the next push-triggered GitHub Actions build. Local Actions monitoring is `REMOTE_ACTIONS_MONITORING_EXTERNAL` because repository/Actions REST requests end in EOF; this does not block a normal push trigger.
