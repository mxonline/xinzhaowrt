# Arthur First-Boot and Web-Stack Runtime Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make FIRSTBOOT stage evidence durable across early boot and prevent uhttpd from ever starting in the Nginx-based Arthur image.

**Architecture:** The first-boot defaults script writes a mode-0600 stage log under `/tmp` before attempting UCI changes and mirrors each line to `logread` when available. The fast ImageBuilder lane removes the default uhttpd packages at image assembly time; the existing overlay remains a defensive stop/disable check. Runtime gates inspect the actual image and service state rather than only grepping source.

**Tech Stack:** POSIX `ash`, OpenWrt UCI/procd, Bash gate scripts, GitHub Actions ImageBuilder, PowerShell SSH acceptance checks.

**Spec:** Arthur FAST Candidate real-device acceptance requirements in the active user request.

## Global Constraints

- Keep target `qualcommax/ipq60xx`, profile `jdcloud_re-ss-01`, and all 22 required LuCI plugins.
- Never use FULL_BUILD, rerun Toolchain Bootstrap, or modify the router during implementation validation.
- Nginx remains the primary LuCI web stack; uhttpd must not bind 80/443 or enter a crash loop.
- Only an explicitly approved later clean flash may alter the router.

---

### Task 1: Add failing observability and web-stack regression gates

**Files:**
- Create: `scripts/check-firstboot-observability.sh`
- Create: `scripts/check-web-stack-imagebuilder.sh`

**Interfaces:**
- Consumes: `files/etc/uci-defaults/99-xinzhao-defaults`, `.github/workflows/arthur-fast-candidate.yml`.
- Produces: exit-code gates that fail against the current implementation and pass only when durable first-boot logging and ImageBuilder uhttpd removal are present.

- [ ] **Step 1: Write the failing tests**

  `check-firstboot-observability.sh` must assert that the defaults script defines `XINZHAO_FIRSTBOOT_LOG`, creates it with an explicit checked operation, appends `FIRSTBOOT_START`, and checks each required `log` call. `check-web-stack-imagebuilder.sh` must assert the fast workflow passes `-uhttpd` and `-uhttpd-mod-ubus` removals and keeps the Nginx enable/restart overlay.

- [ ] **Step 2: Run the tests to verify RED**

  Run `bash scripts/check-firstboot-observability.sh` and `bash scripts/check-web-stack-imagebuilder.sh`; both must fail because the current script has no durable log and the workflow does not remove uhttpd packages.

- [ ] **Step 3: Commit tests**

  `git add scripts/check-firstboot-observability.sh scripts/check-web-stack-imagebuilder.sh` then `git commit -m "test: gate Arthur runtime observability and web stack"`.

### Task 2: Make FIRSTBOOT stage logs durable and fail-closed

**Files:**
- Modify: `files/etc/uci-defaults/99-xinzhao-defaults`
- Modify: `scripts/check-defaults.sh`

**Interfaces:**
- Consumes: existing UCI transaction and marker behavior.
- Produces: `/tmp/xinzhaowrt-firstboot.log` containing all required stage lines on a fresh boot, while retaining `logger` mirroring and marker idempotence.

- [ ] **Step 1: Implement the minimal logging change**

  Define `log_file="${XINZHAO_FIRSTBOOT_LOG:-/tmp/xinzhaowrt-firstboot.log}"`, atomically create it with `umask 077`, make `log()` append to it and mirror to `logger`, and route `FIRSTBOOT_FAIL stage=<stage>` through the same file. Check every stage log call without making logger availability a transaction failure.

- [ ] **Step 2: Run existing and new static/runtime gates**

  Run `bash scripts/check-defaults.sh`, `bash scripts/check-firstboot-observability.sh`, and the isolated first-boot runtime gate with a fresh UCI directory. Expected result: all PASS, including idempotent second execution and preserved existing configuration.

- [ ] **Step 3: Commit the fix**

  `git add files/etc/uci-defaults/99-xinzhao-defaults scripts/check-defaults.sh` then `git commit -m "fix: persist Arthur first-boot stage evidence"`.

### Task 3: Remove uhttpd from the Nginx fast-image package set

**Files:**
- Modify: `.github/workflows/arthur-fast-candidate.yml`
- Modify: `files/etc/uci-defaults/98-xinzhao-web-stack`
- Modify: `scripts/check-web-stack-imagebuilder.sh`

**Interfaces:**
- Consumes: accepted SDK/ImageBuilder and the existing Nginx overlay.
- Produces: an image with no uhttpd startup unit or listener, with a defensive overlay that succeeds whether uhttpd is absent or present.

- [ ] **Step 1: Add package removals to ImageBuilder invocation**

  Add `-uhttpd -uhttpd-mod-ubus -uhttpd-mod-lua -uhttpd-mod-tls` to the `PACKAGES` list before `make image`; retain all 22 required plugin packages and `luci-nginx`.

- [ ] **Step 2: Keep overlay fail-closed for Nginx**

  Make the overlay record `WEBSTACK_FAIL stage=<stage>` and exit on Nginx errors, while treating absent uhttpd as the desired state and stopping/disabling it when a package remains.

- [ ] **Step 3: Run the image/static web gate**

  Run `bash scripts/check-web-stack-imagebuilder.sh` and the workflow's package/provenance gate. Expected result: PASS with uhttpd removals and Nginx as the sole 80/443 owner.

- [ ] **Step 4: Commit the fix**

  `git add .github/workflows/arthur-fast-candidate.yml files/etc/uci-defaults/98-xinzhao-web-stack scripts/check-web-stack-imagebuilder.sh` then `git commit -m "fix: remove uhttpd from Arthur Nginx image"`.

### Task 4: Rebuild and validate the smallest candidate lane

**Files:**
- Modify: `verification/status.json`
- Modify: `verification/arthur-real-device-verification.md`
- Modify: `HANDOFF.md`

**Interfaces:**
- Consumes: the accepted Toolchain Run `33196164359`, SDK-only QuickStart lane, and ImageBuilder workflow.
- Produces: a new prerelease sysupgrade candidate with provenance, SHA256, profile/target, isolated `sysupgrade -T`, durable FIRSTBOOT log evidence, and Web Stack Gate evidence.

- [ ] **Step 1: Run source gates and the existing SDK/ImageBuilder workflow**

  Use the matching SDK to rebuild only QuickStart; do not run FULL_BUILD or bootstrap. Assemble with ImageBuilder and the four uhttpd package removals.

- [ ] **Step 2: Verify artifacts**

  Verify QuickStart ELF is aarch64 with the expected ABI/interpreter, candidate SHA256, target/profile, provenance, and isolated `sysupgrade -T` exit 0.

- [ ] **Step 3: Run runtime gates on the new candidate**

  Clean-flash only after explicit user approval; then verify UCI markers, `/tmp/xinzhaowrt-firstboot.log`, QuickStart service, Nginx 80/443, no uhttpd process/listener/crash loop, and LuCI HTTP/HTTPS reachability. Preserve the current failed candidate evidence until all gates pass.

- [ ] **Step 4: Record status without creating a Known-Good tag**

  Update verification status and handoff with exact run, firmware, SHA256, and gate results. Pause only at `ARTHUR FAST CANDIDATE READY` before the next explicitly approved flash.

