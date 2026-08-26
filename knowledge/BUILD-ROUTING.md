# Arthur Build Routing Policy

## Goal

Avoid paying for a full OpenWrt firmware build when a change cannot affect firmware output, while preserving a fail-closed path for anything uncertain.

The routing authority is `scripts/classify-build-scope.sh`. The CI implementation is `.github/workflows/arthur-fast-preflight.yml`.

## Scope levels

### DOC_ONLY

Use for documentation and knowledge-only changes such as `README.md`, `docs/**` and `knowledge/**`.

Required action:

- no firmware compile;
- no Candidate dispatch;
- no Stable mutation.

### FAST_GATE

Use for CI, verifier, test and control-plane-only changes that do not alter firmware content. Typical examples include `.github/**`, `tests/**`, `scripts/verify-project.sh`, `scripts/analyze-error.sh`, verifier scripts and build request/control files.

Required action:

- run `Arthur Fast Preflight`;
- run classifier tests;
- run static project verification;
- do not start a full firmware build solely to validate the verifier or workflow change.

If a FAST_GATE change reveals a separate firmware defect, fix that defect in a new scoped change and let the classifier route that change independently.

### FULL_BUILD

Use for any firmware-affecting or unknown change. This includes firmware config, mandatory plugin list, source lock, overlay files, patches, build/source preparation logic, package/feed source logic, version changes, Stable Known-Good machine state, and any unclassified path.

Required action:

1. Fast Preflight must pass first.
2. Run `Arthur Known-Good Update v3` with the smallest applicable update mode.
3. Apply the existing Candidate acceptance gates.
4. Keep the result as Candidate until required real-device verification passes.
5. Promote Stable only through the existing Stable promotion path.

## Fail-closed rule

Unknown paths are `FULL_BUILD`.

The classifier must never guess that an unfamiliar path is harmless. When a mixed change contains multiple scopes, the highest-risk scope wins:

`DOC_ONLY < FAST_GATE < FULL_BUILD`

## Active-build isolation

A preflight, documentation or CI-control change must not cancel, restart, rebase or mutate an already-running Candidate build. GitHub Actions runs against its original commit SHA, so improvement work should be done on an isolated branch/PR while the active Candidate completes.

## Failure loop

For a failure:

1. preserve the first causal error;
2. classify the failure;
3. run the smallest relevant test or gate;
4. change one variable;
5. rerun only the failed gate and affected downstream gates;
6. perform a full OpenWrt rebuild only when firmware output can actually change or when the classifier requires `FULL_BUILD`.

Do not use a multi-hour build as a syntax checker, verifier test or workflow parser.

## Relationship to existing workflows

- `Arthur Fast Preflight`: quick routing and static validation; never compiles firmware.
- `Arthur Known-Good Update v3`: full locked Candidate build/update pipeline.
- `Arthur Known-Good Fast Lane v1`: despite its historical name, this is a full firmware build and is not the lightweight preflight lane.
- `promote-stable-v3.yml`: Stable promotion after required real-device evidence.

The new routing layer does not weaken the 22-plugin gate, OOM guard, checksum verification, source lock, real-device verification or Stable promotion requirements.
