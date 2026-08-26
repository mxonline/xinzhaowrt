# XinZhaoWrt Reuse Gate

## Purpose

Before changing an upstream source, feed, package source, patch strategy or build component, check the official ecosystem and maintained GitHub implementations first. Prefer a verified existing Arthur/IPQ60xx baseline or a maintained package source over inventing a new build path.

This gate is additive only. It does not replace the current build workflow, `production/known-good.json`, `config/arthur-known-good.lock`, the 22-plugin requirement, Candidate/Stable promotion gates, real-device verification or release rules.

## Progress-preservation rule

- Do not move or regenerate `config/arthur-known-good.lock` merely because this gate was introduced.
- Do not invalidate or restart an already-running/current Candidate build solely to satisfy this documentation gate.
- Do not revert the current `main` branch, current candidate commits, verified fixes or existing known-good evidence.
- Current `production/known-good.json` remains authority for the last promoted Stable.
- Existing locked upstream/feed/plugin refs remain authority until an explicit update/fix task requires a source decision.
- Apply this gate prospectively to new source changes, package substitutions, failure remediation choices and future updates.

## When required

Run the gate before:

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
2. Same-device or same-target recent GitHub Actions baselines, prioritizing `jdcloud_re-ss-01` / `qualcommax/ipq60xx` and successful recent builds.
3. Maintained upstream repository for the affected package.
4. Maintained community fork with clear compatibility evidence.
5. Local/custom patch or custom implementation only after the above are checked.

## Evaluation criteria

For each serious candidate record:

- exact device/target/kernel/branch match;
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

## Arthur-specific rule

The preferred baseline is always a same-device/same-target known-good build with recent successful Actions and compatible source/feed refs. Never replace a working locked source with a more popular repository solely because it has more stars.

Failure handling still begins with the first causal error. Reuse Gate helps choose the repair source/strategy; it never authorizes removing one of the 22 required plugins to make a build pass.

## Evidence and writeback

Record the decision with the update/failure task evidence and corresponding Notion project record. If a candidate source is adopted, only update source locks after the existing project tests/build acceptance gates justify that change.
