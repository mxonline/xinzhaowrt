# XinZhaoWrt Reuse Gate

## Purpose

Before implementing any new feature, and before changing an upstream source, feed, package source, patch strategy or build component, check the official ecosystem and maintained GitHub implementations first. Prefer a verified existing Arthur/IPQ60xx baseline or a maintained package/source/component over inventing a new implementation.

The default engineering rule is **MATURE-REUSE-FIRST**: reuse a complete maintained solution wherever it satisfies the product requirement. Do not recreate a mature feature as a pile of project-specific LuCI pages, scripts, buttons or partial compatibility glue merely because it is faster to code locally.

This gate is additive only. It does not replace the current build workflow, `production/known-good.json`, `config/arthur-known-good.lock`, the 22-plugin requirement, Candidate/Stable promotion gates, real-device verification or release rules.

## Mandatory new-feature rule

This gate is mandatory for every new Arthur feature, including UI-only and runtime-preview work, even when the feature does not initially appear to require a source change.

Before writing implementation code, record one of `USE / REUSE / FORK / BUILD`.

The executor must first answer:

1. Does OpenWrt/ImmortalWrt already provide the requested feature or package?
2. Does the package's official upstream provide the complete intended management/UI experience?
3. Is there a maintained same-device/same-target implementation with recent successful evidence?
4. Is there a maintained community implementation that can be reused with a small compatibility layer?
5. Only if the above fail, what exact missing requirement justifies a project-specific implementation?

`BUILD` is the last resort, not the default. A `BUILD` decision must include concrete evidence that the checked mature solutions are unavailable, incompatible, abandoned, unsafe, or materially incomplete for the stated requirement.

A local custom implementation must stay as thin as possible: prefer adapters, configuration, packaging or narrowly scoped compatibility patches around the mature upstream implementation. Do not fork or reimplement whole management experiences when selective reuse is possible.

## Progress-preservation rule

- Do not move or regenerate `config/arthur-known-good.lock` merely because this gate was introduced.
- Do not invalidate or restart an already-running/current Candidate build solely to satisfy this documentation gate.
- Do not revert the current `main` branch, current candidate commits, verified fixes or existing known-good evidence.
- Current `production/known-good.json` remains authority for the last promoted Stable.
- Existing locked upstream/feed/plugin refs remain authority until an explicit update/fix task requires a source decision.
- Apply this gate prospectively to new features, new source changes, package substitutions, failure remediation choices and future updates.

## When required

Run the gate before:

- implementing any new user-visible or service-management feature;
- creating a new LuCI page/controller/view for functionality that may already exist upstream;
- changing ImmortalWrt upstream/ref;
- replacing or adding a feed;
- changing a third-party LuCI/package source;
- adopting a different fork for an existing package;
- creating a new compatibility patch where an upstream/maintained fix may exist;
- changing the build framework/controller strategy;
- adding a new package family not already covered by the locked baseline.

A rebuild of the exact current locked known-good/candidate baseline does not require a new gate.

## Search order

1. Official ImmortalWrt/OpenWrt package/feed/device support and upstream commits.
2. Official upstream of the requested application/package, especially its complete LuCI or management implementation.
3. Same-device or same-target recent GitHub Actions baselines, prioritizing `jdcloud_re-ss-01` / `qualcommax/ipq60xx` and successful recent builds.
4. Maintained community fork with clear compatibility evidence.
5. Local/custom patch or custom implementation only after the above are checked.

For management/UI requests, compare the complete intended user experience, not merely package presence or a few endpoint names. A mature source is preferred when it already provides the requested overview, settings, operations, logs, update path, status and backend integration.

## Evaluation criteria

For each serious candidate record:

- exact device/target/kernel/branch match;
- completeness against the user's requested feature, not only package installability;
- most recent successful CI/build evidence;
- maintenance activity and release/commit recency;
- issue/PR maintenance health;
- license compatibility;
- dependency/feed health;
- compatibility with the current ImmortalWrt kernel/toolchain;
- compatibility with all 22 mandatory LuCI applications;
- impact on LuCI Nginx web stack and runtime coexistence constraints;
- security risk;
- source provenance and pinning stability;
- integration effort and long-term maintenance cost.

Star count is supporting evidence only.

## Decision

End every gate with one explicit result:

- `USE` — use the official/known-good source directly.
- `REUSE` — reuse a maintained package/component/patch inside the current build system.
- `FORK` — intentionally maintain a fork only when upstream cannot satisfy the required target and long-term ownership is justified.
- `BUILD` — create/maintain a project-specific patch or component because no suitable maintained solution fits.

Combined decisions such as `USE + REUSE` or `BUILD + SELECTIVE REUSE` are allowed when scoped by package/source family.

No implementation work should begin without this explicit decision for a new feature. If the result is `BUILD`, the evidence rejecting mature alternatives must be preserved with the task.

## Arthur-specific rule

The preferred baseline is always a same-device/same-target known-good build with recent successful Actions and compatible source/feed refs. Never replace a working locked source with a more popular repository solely because it has more stars.

Failure handling still begins with the first causal error. Reuse Gate helps choose the repair source/strategy; it never authorizes removing one of the 22 required plugins to make a build pass.

For Arthur feature development, pair this rule with `knowledge/V013-DEVELOPMENT-LOOP.md`: first choose the mature implementation, then hot/live-deploy the smallest safe integration to the running router for fast validation. Do not use the v0.1.3-style hot loop as an excuse to hand-build a substitute for a mature upstream solution.

## Evidence and writeback

Record the decision with the update/failure task evidence and corresponding project record. If a candidate source is adopted, only update source locks after the existing project tests/build acceptance gates justify that change.
