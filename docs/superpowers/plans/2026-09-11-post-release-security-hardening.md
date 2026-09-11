# Post-Release Security Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Protect `main` against force-push/deletion, pin every GitHub Action to an immutable official commit, and restore the existing GitHub SSH alias without changing Arthur build/release/resume semantics.

**Architecture:** Add one repository ruleset scoped only to `refs/heads/main`, with deletion and non-fast-forward rules and no pull-request requirement. Replace floating `@v4` references with the commit SHAs resolved from the official `v4` tags. Repair only the local SSH alias/identity mapping, then verify with `ssh -T` and read-only `git ls-remote`.

**Tech Stack:** GitHub repository rulesets API, GitHub Actions YAML, Git worktree, Windows OpenSSH, PowerShell, `gh` CLI.

**Spec:** User request `POST_RELEASE_SECURITY_HARDENING_ONLY` in the current Codex thread.

## Global Constraints

- `NO_BUILD`, `NO_RELEASE`, `NO_FLASH`, `NO_SYSUPGRADE`, and `NO_FIRMWARE_SOURCE_CHANGE`.
- Preserve v0.1.4, its assets, known-good/rollback evidence, production evidence, resume-state, and firmware-events ledger.
- Do not enable Require PR, required reviews, or restricted pushes unless compatibility is proven.
- Do not generate or replace any SSH key; never use the Arthur deploy key for GitHub pushes.

---

### Task 1: Audit main direct writers and create the minimum ruleset

**Files:**
- Read: `.github/workflows/*.yml`, `.github/workflows/*.yaml`, `scripts/**`, `production/**`.
- No repository source files are modified for the ruleset.

**Interfaces:**
- Consumes: current remote `main` SHA and direct writer scan results.
- Produces: repository ruleset scoped to `refs/heads/main` with `deletion` and `non_fast_forward` rules only.

- [ ] **Step 1: Enumerate direct writers**

  Search for `git push ... main`, main-ref API updates, and `contents: write`; record workflow/script path, commit identity, and token source without printing secrets.

- [ ] **Step 2: Create the ruleset**

  Use the GitHub API with `target=branch`, `enforcement=active`, `conditions.ref_name.include=["refs/heads/main"]`, and rules `{type: deletion}` and `{type: non_fast_forward}`. Do not add `pull_request` or review rules.

- [ ] **Step 3: Verify compatibility**

  Confirm the ruleset leaves normal fast-forward pushes possible and that `REQUIRE_PR=DEFERRED_FOR_COMPATIBILITY` remains recorded because state-sync and release workflows write `main` directly.

### Task 2: Pin all Actions to official immutable commits

**Files:**
- Modify: every `.github/workflows/*.yml` and `.github/workflows/*.yaml` containing `uses:`.

**Interfaces:**
- Consumes: official tag resolutions `actions/checkout@v4`, `actions/cache@v4`, and `actions/upload-artifact@v4`.
- Produces: `uses: actions/<name>@<40-hex-commit> # v4` at every current reference.

- [ ] **Step 1: Resolve official tag refs**

  Query the official GitHub repositories and dereference annotated tags; reject any result that is not a 40-character commit SHA.

- [ ] **Step 2: Replace only action references**

  Keep workflow names, triggers, permissions, jobs, commands, and artifact paths unchanged; replace only the floating action ref and add the existing version as a comment.

- [ ] **Step 3: Run static validation**

  Parse all workflow YAML, assert zero floating `uses:` refs, assert zero local/third-party refs were accidentally changed, and run the repository's action-reference regression tests if present. Do not dispatch a workflow.

### Task 3: Restore the existing GitHub SSH path

**Files:**
- Read: `C:/Users/chenz/.ssh/config`, `C:/Users/chenz/.ssh/known_hosts`.
- Modify only the relevant SSH alias/`IdentityFile` mapping if an existing GitHub key is found.

**Interfaces:**
- Consumes: existing GitHub SSH identity and the separate Arthur deploy key path.
- Produces: `ssh -T git@github.com` success and read-only `git ls-remote origin` success.

- [ ] **Step 1: Inspect identities**

  Run `ssh -G github.com`, inspect configured `IdentityFile` and `IdentitiesOnly`, and distinguish `C:/Users/chenz/.ssh/xinzhaowrt_deploy_ed25519` from the GitHub push key.

- [ ] **Step 2: Repair only the alias mapping**

  Update the existing GitHub alias to use the already-authorized GitHub private key; do not generate, copy, or replace keys and do not alter Arthur SSH credentials.

- [ ] **Step 3: Verify read-only SSH**

  Run `ssh -T git@github.com` and `git ls-remote origin`; do not push code. If the GitHub private key or authorization is absent, report the blocker and leave SSH configuration unchanged.

### Task 4: Preserve release and secret invariants

**Files:**
- Read only: v0.1.4 Release metadata/assets, known-good and rollback refs, `production/resume-state.json`, `production/firmware-events.jsonl`, and local secret-bearing paths.

- [ ] **Step 1: Verify invariants**

  Confirm the v0.1.4 target commit and asset digests, unchanged known-good/rollback refs, unchanged production ledger files, and no full secret values in output.

- [ ] **Step 2: Review the security diff**

  Confirm the branch diff contains only the ruleset/API change record, immutable action refs, SSH mapping repair if needed, and this plan; reject firmware, release, state, and credential material changes.

- [ ] **Step 3: Commit, push, review, and merge**

  Commit on `codex/security-hardening-20260911`, push the branch without force, create a PR, review the diff and checks, then merge normally into `main` only after the review is clean.
