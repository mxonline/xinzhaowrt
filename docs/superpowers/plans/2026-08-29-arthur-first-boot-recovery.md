# Arthur First-Boot Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the Arthur first-boot transaction, prove it with a real runtime gate, and isolate QuickStart/Nginx web-stack compatibility before producing a replacement candidate.

**Architecture:** The uci-defaults script is treated as a staged, fail-closed transaction. A disposable real-UCI harness verifies first execution and idempotence before build work. QuickStart receives a separate source/runtime inspection and a web-stack preflight gate so its service behavior cannot be mistaken for marker behavior.

**Tech Stack:** POSIX shell, OpenWrt UCI, OpenWrt package metadata/init scripts, Bash test harnesses.

**Spec:** `docs/superpowers/specs/2026-08-29-arthur-first-boot-recovery-design.md`

## Global Constraints

- Preserve the failed Arthur evidence; never modify its marker, password, configuration, or firmware.
- Keep all 22 required LuCI applications enabled; QuickStart must not be deleted.
- Nginx remains the primary LuCI web stack; do not select `luci` or `luci-ssl` meta collections.
- Do not trigger bootstrap, full build, or a replacement flash in this work.
- Do not mark any candidate known-good until a new artifact passes clean-flash FIRST BOOT acceptance.

---

### Task 1: Create a failing real-UCI first-boot test

**Files:**
- Create: `tests/test-first-boot-runtime.sh`
- Test: `tests/test-first-boot-runtime.sh`

**Interfaces:**
- Consumes: `files/etc/uci-defaults/99-xinzhao-defaults`
- Produces: a disposable configuration root and assertions for first-run markers, LAN state, root branch, and idempotence.

- [ ] **Step 1: Write the failing test**

Create a fixture with an empty UCI configuration directory and run the defaults script through a wrapper that exposes real `uci`, `logger`, and shadow paths. Assert literal values `192.168.6.1/24`, `1`, and `XinZhaoWrt-Arthur`; assert the first run exits zero and creates the package.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-first-boot-runtime.sh`

Expected: failure because the current `uci -q batch` cannot create the missing package and produces no marker file.

- [ ] **Step 3: Extend the failing test for idempotence**

Rerun the same fixture after inserting a non-default LAN and a non-empty root hash. Assert the script exits zero without replacing those values and leaves both markers intact.

- [ ] **Step 4: Run the test to verify the idempotence assertion fails**

Run: `bash tests/test-first-boot-runtime.sh`

Expected: failure until the transaction has explicit stage handling and observable checks.

### Task 2: Make the first-boot transaction fail closed

**Files:**
- Modify: `files/etc/uci-defaults/99-xinzhao-defaults`
- Modify: `scripts/check-defaults.sh`
- Test: `tests/test-first-boot-runtime.sh`

**Interfaces:**
- Consumes: `build.env` defaults and real `uci` behavior.
- Produces: stage-tagged logs, an explicit xinzhaowrt package, committed verified markers, and nonzero failures.

- [ ] **Step 1: Implement the minimal package-creation and checked-UCI changes**

Create `/etc/config/xinzhaowrt` with secure permissions before UCI mutation; use non-quiet UCI commands; check each mutation and marker readback. Route failures through `FIRSTBOOT_FAIL stage=<stage>`.

- [ ] **Step 2: Add stage logs and transaction checks**

Emit `FIRSTBOOT_START`, `LAN_CONFIG_PASS`, `ROOT_CREDENTIAL_PASS`, `MARKER_CONFIG_PASS`, and `FIRSTBOOT_COMPLETE` only at their respective completed boundaries.

- [ ] **Step 3: Run the runtime test and static check**

Run: `bash tests/test-first-boot-runtime.sh && bash scripts/check-defaults.sh`

Expected: both pass; runtime output reports `FIRST_BOOT_RUNTIME_GATE: PASS` and `FIRST_BOOT_IDEMPOTENCE: PASS`.

### Task 3: Diagnose and gate QuickStart with Nginx

**Files:**
- Create: `scripts/check-web-stack.sh`
- Create: `tests/test-web-stack-gate.sh`
- Modify: `scripts/add-custom-packages.sh` only if package source inspection proves an invocation/packaging correction is needed.

**Interfaces:**
- Consumes: extracted QuickStart package source plus Arthur Nginx configuration.
- Produces: `WEB_STACK_GATE` proving Nginx ownership, no uhttpd listener conflict, and a non-shell-misinterpreted QuickStart launch path.

- [ ] **Step 1: Write the failing web-stack characterization test**

Assert that the QuickStart executable's file header and the `S93startdhns` invocation agree on an executable interpreter, and assert the gate rejects a uhttpd listener on ports owned by nginx.

- [ ] **Step 2: Run it to verify the current source/runtime characterization fails**

Run: `bash tests/test-web-stack-gate.sh`

Expected: failure until the package source is available and its actual QuickStart init/invocation is classified.

- [ ] **Step 3: Implement only the proven compatibility adjustment**

Adapt the QuickStart launch path or configuration according to its actual shebang/file format. Keep the package and Nginx; do not use a blind `uhttpd` removal.

- [ ] **Step 4: Run the web-stack gate**

Run: `bash scripts/check-web-stack.sh`

Expected: `WEB_STACK_GATE: PASS` with nginx active, uhttpd non-conflicting, QuickStart non-crashing, and LuCI route present.

### Task 4: Record the rejected candidate and select the minimal lane

**Files:**
- Modify: `verification/status.json`
- Modify: `verification/arthur-real-device-verification.md`
- Create: `HANDOFF.md`

**Interfaces:**
- Consumes: failure evidence and completed gates.
- Produces: a handoff stating `REJECTED_FIRST_BOOT` and the conditional ImageBuilder/SDK lane.

- [ ] **Step 1: Record the immutable observed results**

Set candidate state to `REJECTED_FIRST_BOOT`; retain Clean Flash and LAN Default as PASS; mark markers/FIRST BOOT as FAIL and Known-Good as NO.

- [ ] **Step 2: Record the post-fix gates and lane condition**

State that ImageBuilder is the only permitted lane for overlay/service-only changes, while an SDK QuickStart rebuild is required only if package artifacts change. Explicitly prohibit Full Build without an ABI/target/feed proof.

- [ ] **Step 3: Verify the status vocabulary**

Run: `rg -n 'REJECTED_FIRST_BOOT|FIRST_BOOT_ROOT_CAUSE|ROOT CAUSE|TARGETED FIX|RUNTIME PREFLIGHT|NEW CANDIDATE' verification/status.json verification/arthur-real-device-verification.md HANDOFF.md`

Expected: every required state and next-stage term is present.
