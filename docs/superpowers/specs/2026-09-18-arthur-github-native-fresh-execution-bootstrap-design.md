# Arthur GitHub-Native Fresh Execution Bootstrap Design

## Goal

Allow an explicitly authorized new Arthur `RELEASE_ONLY` execution to start from a previous terminal `PRODUCTION_RELEASED` snapshot without any Windows CurrentUser / DPAPI / local-worktree push bridge. The bootstrap must run inside GitHub Actions, fail closed, preserve append-only history and known-good authority, and hand control directly back to the existing Arthur Control Plane.

## Problem

The repository already carries a valid fresh operator authorization (`EXECUTE_FIRMWARE`, `FIRMWARE_RELEASE`, `target_release=v0.1.5`, `release_mode=RELEASE_ONLY`, `device_write_authorized=false`), while `production/resume-state.json` is still the terminal v0.1.4 execution with `status=PRODUCTION_RELEASED` and `instruction_allowed=false`.

The current control-plane gate reads the terminal resume snapshot before it considers the fresh operator execution identity, so the Resume Gate fails closed before a new schema-v2 execution snapshot can exist. The previous workaround generated a local commit and tried to move it into `main` through `run-host-main-push.ps1`. That created an unnecessary Windows/DPAPI/worktree dependency and repeatedly failed before GitHub authentication or push.

The host bridge is not part of the firmware-release product path and must not be required for fresh execution startup.

## Architecture

Add one narrowly scoped GitHub-native bootstrap helper, invoked by `scripts/arthur-control-plane-gate.ps1` before the existing Resume Gate.

The helper reads only repository-controlled state:

- `production/operator-intent.json`
- `production/release-mode.json`
- `production/resume-state.json`
- `production/firmware-events.jsonl`
- `production/known-good.json`
- `VERSION`
- current Git HEAD / `origin/main`

It returns one of three outcomes:

1. `NOOP_CURRENT_EXECUTION` — resume state already belongs to the authorized execution.
2. `NOOP_NOT_AUTHORIZED` — no fresh authorized firmware execution exists.
3. `BOOTSTRAP_REQUIRED` — operator intent authorizes a different execution and the current resume state is a terminal prior execution.

For `BOOTSTRAP_REQUIRED`, the helper creates the fresh schema-v2 state and execution evidence index in the workflow checkout, appends exactly one execution-aware bootstrap event, and publishes only the state/evidence/event files to `main` using the GitHub Actions checkout credential. It never uses DPAPI, a PAT, GitHub App private-key material, a user worktree, or `run-host-main-push.ps1`.

After publication, the existing Resume Gate and Arthur Control Plane continue normally.

## Bootstrap Preconditions

Bootstrap is permitted only when all conditions are true:

- `operator-intent.project == Arthur`.
- `intent_type == EXECUTE_FIRMWARE`.
- `authorization_scope == FIRMWARE_RELEASE`.
- `firmware_execution_authorized == true`.
- `execution_id` is valid and differs from the terminal resume execution.
- `target_release` is valid `vMAJOR.MINOR.PATCH`.
- repository `VERSION` exactly equals `target_release` without the leading `v`.
- operator intent `release_mode == RELEASE_ONLY`.
- `production/release-mode.json.mode == RELEASE_ONLY`.
- `unattended_release == true`.
- `automatic_flash == false`.
- `device_write_authorized == false`.
- `sysupgrade_forbidden == true`.
- previous resume state is schema v2 and terminal `PRODUCTION_RELEASED`.
- previous resume execution is different from the new execution.
- `firmware_state.active_source_sha` is a valid 40-hex commit and is an ancestor of current `main`.
- local checkout HEAD equals fetched `origin/main` immediately before publication.

Any ambiguity fails closed without modifying files or remote state.

## Fresh State Semantics

The new snapshot must:

- use the authorized `execution_id`;
- set `status=RESUME_SAFE` and `instruction_allowed=true`;
- set `release` to the authorized target release;
- set `source.repository_head` to the current control-plane repository HEAD;
- set `source.accepted_source_sha` to `firmware_state.active_source_sha` (the product source identity);
- clear production run/artifact/release identities for the new execution;
- start at `CHANGE_IMPACT`;
- leave BUILD / ARTIFACT / RELEASE evidence unproven;
- preserve only explicitly frozen/inheritable baseline gates allowed by `operator-intent.firmware_state.verified_frozen` and existing requirement identity;
- mark pre-production repair-only phases before `CHANGE_IMPACT` as `SKIPPED` for this already-merged release execution;
- leave all other release-relevant gates `PENDING`;
- create `production/evidence/<execution_id>/index.json` with the matching execution identity;
- append an execution-aware `EXECUTION_STARTED` event so the latest execution-aware ledger event matches the new resume state;
- never modify or truncate older `firmware-events.jsonl` rows;
- never modify `production/known-good.json`.

## Publication Semantics

Publication is GitHub-native and at-most-once:

1. fetch `origin/main`;
2. require local HEAD == `origin/main`;
3. write only the fresh resume state, fresh evidence index, and append-only ledger event;
4. commit with `[skip ci]` to prevent recursive state-only workflow loops;
5. normal `git push origin HEAD:main` only;
6. no force push;
7. fetch and verify remote `main` equals the new commit;
8. if remote moved, fail closed and let a fresh workflow retry from the new main.

The workflow that authorizes a fresh execution must be able to wake the existing Arthur Control Plane without user-host scripts. `arthur-control-plane.yml` therefore also watches `production/operator-intent.json` in addition to its own workflow file.

## RELEASE_ONLY Safety Boundary

This change must not add or invoke any device-write path. It must preserve:

- `automatic_flash=false`;
- `device_write_authorized=false`;
- `sysupgrade_forbidden=true`;
- no `PRE_FLASH`, `AUTO_FLASH_SAFETY_GATE`, `FLASH`, `WAIT_DEVICE`, SSH upload, router reboot, MTD/dd, or automatic post-release real-device test;
- `production/known-good.json` unchanged until the independent post-release real-device test passes.

The normal successful terminal remains `PRODUCTION_RELEASED`.

## Permanent Regression Guard

Tests must prevent reintroducing the failed architecture:

- fresh execution bootstrap must not reference `run-host-main-push.ps1`;
- it must not reference `github-app-bridge`;
- it must not require DPAPI, PAT, JWT, GitHub App private-key files, or a user-specific `C:\Users\chenz` path;
- the control-plane gate must invoke bootstrap before the Resume Gate;
- `arthur-control-plane.yml` must wake on `production/operator-intent.json` changes;
- a terminal old execution plus a valid fresh authorization must produce a new `RESUME_SAFE` execution;
- same-execution reruns must be idempotent;
- invalid version/release/source/head/authorization conditions must fail closed;
- known-good and historical event rows must remain unchanged.

## Current v0.1.5 Application

Once this change is merged to `main`, the same merge push must wake `Arthur Control Plane`. The bootstrap must consume the already-authorized execution:

`arthur-v0.1.5-release-e037750-20260918`

with product source:

`e0377509dcc57c415935e9f779fe27117ce591be`

and target release:

`v0.1.5`

Then the existing production flow continues unattended through:

`CHANGE_IMPACT -> BASELINE_INHERITANCE -> EXPECTED_DIFF -> BUILD -> ARTIFACT -> RELEASE_GATE -> RELEASE -> PRODUCTION_RELEASED`

with all flash/device-write stages excluded by `RELEASE_ONLY`.