# Arthur Control Plane Promotion Implementation Plan

> **For agentic workers:** Use this plan inline with the existing control-plane branch; do not rebuild or flash.

**Goal:** Promote the frozen Arthur baseline into the v4 control plane and prove no-change routing without creating firmware.

**Architecture:** `production/known-good.json` and `production/v4-state.json` become the authoritative frozen pointer and pipeline state. A local/CI Baseline Integrity Gate verifies the immutable tag, manifest, lock/provenance references, firmware digest, and exact plugin list before the classifier is run.

**Tech Stack:** POSIX shell, Python JSON validation, Git refs, existing `scripts/classify-build-scope.sh` and shell tests.

**Spec:** Arthur automated production pipeline promotion request (2026-08-29).

## Global Constraints

- Frozen tag `arthur-known-good-v1` must remain unchanged and point to `a47d994bbb434dbcfc8036a4acb4379747b65f9f`.
- No FULL_BUILD, SDK_BUILD, ImageBuilder, router connection, or flash is allowed for this dry run.
- Unknown file changes fail closed to `FULL_BUILD`.
- The exact 22 required plugin names remain enabled and must match `config/required-plugins.txt`.

### Task 1: Baseline Integrity Gate

**Files:** Create `scripts/baseline-integrity-gate.sh`; create `tests/test-baseline-integrity-gate.sh`.

- [ ] Write a failing test that checks the frozen tag target, manifest, digest, lock digest, and 22-plugin identity.
- [ ] Run the test and confirm it fails because the gate does not yet exist.
- [ ] Implement fail-closed JSON/ref checks with explicit `PIPELINE BLOCKED` output.
- [ ] Run the test and confirm PASS.

### Task 2: Control-plane promotion

**Files:** Modify `production/known-good.json`, `production/v4-state.json`; add the frozen manifest to main.

- [ ] Preserve v0.1.0 under `previous_known_good` and `rollback` while pointing top-level fields at `arthur-known-good-v1`.
- [ ] Set v4 current stage to `AUTOMATED_BUILD_PIPELINE`, toolchain to `VERIFIED`, and lanes to the requested ready states.
- [ ] Run JSON validation and the integrity gate.

### Task 3: Routing and no-change dry run

**Files:** Modify `scripts/classify-build-scope.sh`, `tests/test-classify-build-scope.sh`; create `scripts/v4-pipeline-dry-run.sh`, `tests/test-v4-pipeline-dry-run.sh`.

- [ ] Add control-plane/baseline manifest paths to `FAST_GATE`.
- [ ] Test docs, rootfs overlay, QuickStart package source, and kernel/target cases.
- [ ] Run the dry run to prove no build, candidate, or router action is requested.

### Task 4: Verify and publish

- [ ] Run all focused tests, JSON checks, diff checks, and secret scan.
- [ ] Commit only control-plane files on the isolated branch.
- [ ] Push fast-forward to `main` without touching the frozen tag.
