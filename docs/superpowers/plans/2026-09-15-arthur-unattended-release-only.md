# Arthur Unattended Release-Only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make new Arthur production executions automatically build, verify and publish a GitHub Release without automatically flashing the router, while preserving legacy flash history and keeping known-good promotion gated by an independent post-release device test.

**Architecture:** Add a machine-readable `RELEASE_ONLY` policy, then teach both the Python orchestrator and PowerShell resume resolver to select an effective production route from that policy. Keep legacy flash phases parseable for old state, but exclude them from new `RELEASE_ONLY` phase/gate traversal. Align durable policy text and authorization rules only after executable tests prove the route.

**Tech Stack:** Python 3 standard library, PowerShell 7, JSON policy, GitHub Actions, existing Arthur state-contract/resume machinery.

**Spec:** `docs/superpowers/specs/2026-09-15-arthur-unattended-release-only-design.md`

## Global Constraints

- `PRODUCTION_RELEASED` remains the production success terminal.
- New default mode is exactly `RELEASE_ONLY`.
- `automatic_flash=false` in `RELEASE_ONLY`.
- `POST_RELEASE_DEVICE_TEST` remains independent and non-blocking for Release.
- `production/known-good.json` may advance only after the exact released firmware/hash passes the independent post-release device test.
- Preserve historical flash phases for state/event compatibility.
- Unknown/missing release mode fails closed and never authorizes router writes.
- Never add MTD/U-Boot/dd/raw partition automation.
- Do not reuse the completed v0.1.4 execution ID for a new production task.

---

### Task 1: Add failing release-mode contract tests and PR CI

**Files:**
- Create: `tests/test_arthur_release_mode.py`
- Create: `tests/arthur-release-mode.tests.ps1`
- Create: `.github/workflows/arthur-release-mode.yml`

**Interfaces:**
- Consumes: current `ai_orchestrator.arthur.ArthurPipeline` and `scripts/arthur-resume-state.ps1`.
- Produces: executable contract for `RELEASE_ONLY`, including `Get-ArthurEffectivePhaseOrder` and release-mode-aware `ArthurPipeline.next_phase`/Candidate classification.

- [ ] **Step 1: Write Python tests before production code**

Create `tests/test_arthur_release_mode.py` with assertions that:

```python
import unittest

from ai_orchestrator.arthur import ArthurPipeline
from ai_orchestrator.models import ActionKind


class ArthurReleaseModeTests(unittest.TestCase):
    def test_release_only_routes_artifact_directly_to_release_gate(self):
        pipeline = ArthurPipeline(release_mode="RELEASE_ONLY")
        self.assertEqual(
            pipeline.next_phase("ARTIFACT", ActionKind.SAFE_AUTO),
            "RELEASE_GATE",
        )

    def test_release_only_candidate_can_release_but_never_flash(self):
        result = ArthurPipeline.classify_candidate_route(
            ArthurPipeline.production_candidate_workflow,
            ArthurPipeline.production_candidate_evidence,
            release_mode="RELEASE_ONLY",
        )
        self.assertEqual(result["route"], "PRODUCTION_CANDIDATE")
        self.assertTrue(result["release_allowed"])
        self.assertFalse(result["flash_allowed"])

    def test_unknown_release_mode_fails_closed(self):
        result = ArthurPipeline.classify_candidate_route(
            ArthurPipeline.production_candidate_workflow,
            ArthurPipeline.production_candidate_evidence,
            release_mode="UNKNOWN",
        )
        self.assertEqual(result["route"], "SAFETY_BLOCKED_UNKNOWN_RELEASE_MODE")
        self.assertFalse(result["release_allowed"])
        self.assertFalse(result["flash_allowed"])

    def test_legacy_mode_keeps_historical_flash_route_parseable(self):
        pipeline = ArthurPipeline(release_mode="FLASH_AND_VERIFY")
        self.assertEqual(
            pipeline.next_phase("ARTIFACT", ActionKind.SAFE_AUTO),
            "PRE_FLASH",
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Write PowerShell tests before production code**

Create `tests/arthur-release-mode.tests.ps1` that dot-sources `scripts/arthur-resume-state.ps1`, verifies `production/release-mode.json`, and asserts:

```powershell
$order = @(Get-ArthurEffectivePhaseOrder -ReleaseMode 'RELEASE_ONLY')
Assert-True ($order -contains 'ARTIFACT') 'release-only order must include ARTIFACT'
Assert-True ($order -contains 'RELEASE_GATE') 'release-only order must include RELEASE_GATE'
Assert-True ($order -contains 'RELEASE') 'release-only order must include RELEASE'
Assert-True ($order -contains 'PRODUCTION_RELEASED') 'release-only order must include terminal'
Assert-True ($order -notcontains 'PRE_FLASH') 'release-only order must skip PRE_FLASH'
Assert-True ($order -notcontains 'AUTO_FLASH_SAFETY_GATE') 'release-only order must skip automatic flash safety gate'
Assert-True ($order -notcontains 'FLASH') 'release-only order must skip FLASH'
Assert-True ($order -notcontains 'WAIT_DEVICE') 'release-only order must skip WAIT_DEVICE'
Assert-Throws { Get-ArthurEffectivePhaseOrder -ReleaseMode 'UNKNOWN' } 'unknown mode must fail closed'
```

Also assert the JSON policy says `mode=RELEASE_ONLY`, `unattended_release=true`, `automatic_flash=false`, `post_release_device_test=INDEPENDENT`, and `known_good_promotion_requires_post_release_device_test_pass=true`.

- [ ] **Step 3: Add a narrow PR workflow**

Create `.github/workflows/arthur-release-mode.yml` triggered on pull requests to `main` when the release-mode policy, route implementation, tests, or durable policy files change. Run:

```yaml
- run: python -m unittest tests.test_arthur_release_mode -v
- shell: pwsh
  run: ./tests/arthur-release-mode.tests.ps1
```

- [ ] **Step 4: Open a draft PR and verify RED**

Expected: CI fails because `ArthurPipeline` does not yet accept `release_mode`, `Get-ArthurEffectivePhaseOrder` does not yet exist, and `production/release-mode.json` does not yet exist.

- [ ] **Step 5: Commit**

Commit message: `test: define Arthur release-only safety contract`.

### Task 2: Add the machine-readable release policy and Python route selector

**Files:**
- Create: `production/release-mode.json`
- Modify: `ai_orchestrator/arthur.py`

**Interfaces:**
- Consumes: `release_mode` string (`RELEASE_ONLY` or compatibility `FLASH_AND_VERIFY`).
- Produces: `effective_phases`, release-mode-aware `next_phase`, and Candidate permissions.

- [ ] **Step 1: Add exact policy JSON**

```json
{
  "schema_version": "1.0",
  "mode": "RELEASE_ONLY",
  "unattended_release": true,
  "automatic_flash": false,
  "post_release_device_test": "INDEPENDENT",
  "known_good_promotion_requires_post_release_device_test_pass": true,
  "fail_closed_on_unknown": true
}
```

- [ ] **Step 2: Implement release-mode selection minimally**

In `ai_orchestrator/arthur.py`:

- add `legacy_phases` equal to the current phase tuple;
- add `release_only_phases` equal to the same pre-artifact phases followed by `RELEASE_GATE`, `RELEASE`, `PRODUCTION_RELEASED`;
- make `__init__(release_mode=None)` use explicit input or load `production/release-mode.json` relative to repository/module location;
- reject unsupported modes for active traversal;
- have `next_phase` traverse `self.effective_phases`;
- preserve compatibility by allowing explicit `FLASH_AND_VERIFY` to use `legacy_phases`;
- make `classify_candidate_route(..., release_mode="RELEASE_ONLY")` return `flash_allowed=false` for `RELEASE_ONLY`, `flash_allowed=true` only for explicit `FLASH_AND_VERIFY`, and fail closed for unknown modes.

- [ ] **Step 3: Run Python test**

Expected: `python -m unittest tests.test_arthur_release_mode -v` PASS.

- [ ] **Step 4: Commit**

Commit message: `feat: add release-only Arthur route policy`.

### Task 3: Make Resume Gate use the effective release route

**Files:**
- Modify: `scripts/arthur-resume-state.ps1`
- Modify: `tests/arthur-release-mode.tests.ps1` only if a test fixture needs exact existing function signatures, never to weaken assertions.

**Interfaces:**
- Produces: `Get-ArthurEffectivePhaseOrder -ReleaseMode <string>` and release-mode-aware Gate selection.

- [ ] **Step 1: Implement `Get-ArthurEffectivePhaseOrder`**

Keep `$script:ArthurResumePhaseOrder` as the legacy recognition list. Add a release-only skip set:

```powershell
@(
  'PRE_FLASH','AUTO_FLASH_SAFETY_GATE','FLASH','WAIT_DEVICE','IDENTIFY',
  'LAN_RUNTIME','DHCP','WAN','DNS','SSH','LUCI','PLUGIN_RUNTIME_22',
  'ARGON_KUCAT_RUNTIME','SYSTEM_HEALTH'
)
```

For `RELEASE_ONLY`, return the legacy order excluding that set. For `FLASH_AND_VERIFY`, return the legacy order unchanged. Unknown mode throws `ARTHUR_RELEASE_MODE_INVALID=<mode>`.

- [ ] **Step 2: Use effective order for `Get-ArthurNextRequiredGate`**

Add a `ReleaseMode` parameter to `Resolve-ArthurResumeState` defaulting from `production/release-mode.json`; pass the effective order into `Get-ArthurNextRequiredGate`. Historical Gate records stay in the state object but are not actionable in `RELEASE_ONLY`.

- [ ] **Step 3: Run PowerShell tests**

Expected: `./tests/arthur-release-mode.tests.ps1` PASS and existing `./tests/arthur-resume-state-v2.tests.ps1` PASS.

- [ ] **Step 4: Commit**

Commit message: `feat: route resume gate around flash in release-only mode`.

### Task 4: Align durable Source of Truth and authorization rules

**Files:**
- Modify: `production/release-policy.md`
- Modify: `production/GPT-FIRMWARE-EXECUTION-RULES.md`
- Modify: `AGENTS.md`
- Modify: `production/ARTHUR_PRODUCT_TARGETS.md`
- Modify: `knowledge/PROJECT-STATE.md`
- Modify: `knowledge/LIVE-PREVIEW.md`

**Interfaces:**
- Produces: one non-contradictory human-readable contract matching executable policy.

- [ ] **Step 1: Replace the legacy mandatory flash-before-release wording**

State exactly that the default production mode is `RELEASE_ONLY`, with production success at GitHub Release, and that `POST_RELEASE_DEVICE_TEST` is independent.

- [ ] **Step 2: Preserve legacy/history wording explicitly**

Document `FLASH_AND_VERIFY` as compatibility-only and never implicitly selected. Authorization for `FIRMWARE_RELEASE` does not imply authorization for router writes.

- [ ] **Step 3: State known-good promotion rule**

A Release may be `PRODUCTION_RELEASED` before device testing; `known-good.json` cannot advance until the exact released hash passes independent post-release device testing.

- [ ] **Step 4: Run grep/contract checks**

Confirm no current Source of Truth still claims the default mandatory chain is `ARTIFACT -> PRE_FLASH -> ... -> REAL_DEVICE_VERIFY -> Release`.

- [ ] **Step 5: Commit**

Commit message: `docs: align Arthur release-only production contract`.

### Task 5: Validate the migration on the PR before any firmware execution

**Files:**
- No production file changes unless CI exposes a defect.

**Interfaces:**
- Consumes: PR workflow results and existing CI.
- Produces: evidence that governance/control-plane migration is safe to merge.

- [ ] **Step 1: Verify release-mode CI GREEN**

Required: Python and PowerShell release-mode tests PASS.

- [ ] **Step 2: Verify existing relevant CI GREEN**

Required: `Arthur Resume State V2` and `Arthur Production Agent CI` pass when triggered by changed paths/PR.

- [ ] **Step 3: Review PR diff**

Confirm no firmware payload, package list, target/profile, first-boot defaults, plugin list, source lock or router write command changed.

- [ ] **Step 4: Merge only after verification**

Use expected head SHA to prevent merging a moved branch.

### Task 6: Start a fresh unattended RELEASE_ONLY execution after merge

**Files:**
- Modify: `production/operator-intent.json`
- Modify/Create: current execution request/state files only through the repository's existing authorized state-init path.
- Modify: `production/expected-diff.json` only for the new execution's explicit declared change set.

**Interfaces:**
- Consumes: merged release-only control plane, current `main`, current verified known-good, latest GitHub Release.
- Produces: a new execution ID authorized for `FIRMWARE_RELEASE`, with no flash authorization.

- [ ] **Step 1: Re-read live main, latest Release, known-good and resume state**

Do not reuse `arthur-final-release-5f41c4e-20260908` or its terminal checkpoint.

- [ ] **Step 2: Resolve version/source identity from live evidence**

Because repository `VERSION` currently says `0.1.3` while the published stable is `v0.1.4`, treat that as a version-metadata conflict to reconcile before build dispatch. Do not guess the next tag.

- [ ] **Step 3: Create a fresh execution identity and intent**

Set durable intent to:

```json
{
  "intent_type": "EXECUTE_FIRMWARE",
  "authorization_scope": "FIRMWARE_RELEASE",
  "firmware_execution_authorized": true,
  "release_mode": "RELEASE_ONLY",
  "automatic_flash_authorized": false
}
```

Keep the exact schema fields already required by `operator-intent.json` and add only compatible fields needed by the implementation.

- [ ] **Step 4: Generate execution-specific expected diff**

Allowed changes must match the actual new release task. Protected domains include device identity, target/profile, storage layout, LAN defaults, root credential policy, required plugins, themes, web stack and all undeclared product state.

- [ ] **Step 5: Run Resume Gate and preflight**

Required: new execution reports safe/authorized release-only traversal, with `ARTIFACT -> RELEASE_GATE` and no flash phase selected.

- [ ] **Step 6: Dispatch the existing production Candidate workflow only after all pre-build Gates pass**

Use the existing build lane selected by `CHANGE_IMPACT_GATE`; do not dispatch duplicate builds.

- [ ] **Step 7: Continue unattended to `PRODUCTION_RELEASED`**

A Candidate may publish only after artifact/hash/provenance/Release Gate PASS. No `sysupgrade` is permitted.

- [ ] **Step 8: Record post-release test state**

Set `POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT`; do not update known-good until that test later passes for the exact released hash.
