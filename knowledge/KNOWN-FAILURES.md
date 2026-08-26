# XinZhaoWrt Known Failure Patterns

Only record failure patterns that were observed and whose repair was verified by a later gate/build. Do not turn guesses into permanent knowledge.

## Classification

Use one primary class per first real error:

- `SOURCE`
- `FEED`
- `DEPENDENCY`
- `CONFIG`
- `PATCH`
- `TOOLCHAIN`
- `PACKAGE`
- `KERNEL`
- `IMAGE`
- `CI`

Always prefer the first causal error over later cascade messages.

---

## FW-001 — iStore / luci-app-store missing before defconfig

Class: `FEED` / `DEPENDENCY`

Observed symptom:

- package-existence preflight reported missing `istore` feed/source content;
- `luci-app-store` was unavailable;
- build stopped before `make defconfig`.

Correct behavior:

- stop early rather than let `make defconfig` silently drop the package;
- inspect `scripts/add-custom-packages.sh`, source layout and `scripts/check-package-existence.sh`;
- use the pinned iStore source from the Known-Good lock;
- refresh feeds/package indexes before the existence check;
- preserve `luci-app-store` if it remains in the 22 mandatory app list.

Verified recovery condition:

The 2026-08-26 locked v3 Candidate build passed package preparation and later verified all 22/22 mandatory LuCI applications in the final firmware manifest.

Do not repair by removing iStore/luci-app-store from the required list.

---

## FW-002 — Large firmware upload duplicates exhaust tmpfs / OOM

Class: `PATCH` / runtime integration

Observed problem:

Large firmware upload/sysupgrade preparation could create transient duplicate upload copies on tmpfs, creating an OOM risk on Arthur.

Repair strategy implemented by the project:

- apply the large-upload OOM fix during source preparation;
- keep transient duplicate upload copies off `/tmp`/tmpfs while preserving the final sysupgrade image behavior;
- run a static guard;
- verify the fix in the compiled source tree;
- require an acceptance artifact/result before Candidate publication.

Verified recovery:

Workflow run `32943895389` reported the compiled/acceptance OOM guard PASS together with firmware, 22/22 plugins and checksums.

Remaining gate:

A Candidate containing this repair is not Stable until the large-upload path is exercised on a real JDCloud RE-SS-01 and no OOM/regression is observed.

---

## FW-003 — OOM guard rejects already-correct patched source

Class: `PATCH` / `CI`

Observed history:

The OOM verification guard had to be corrected to ignore a removed tmpfs line after the source was intentionally patched. Repository history contains the repair `fix: ignore removed tmpfs line in OOM patch guard` followed by a successful v3 Candidate build.

Rule:

A verifier must test the intended invariant, not require text that the patch itself is expected to remove.

When a guard fails after a patch:

1. inspect the compiled/patched source;
2. distinguish a real regression from a verifier false positive;
3. change the guard only when the desired runtime invariant is still satisfied;
4. rerun the full relevant acceptance gate.

---

## FW-004 — Shell script executable-bit mismatch blocks verification

Class: `CI`

Observed history:

Repository history includes `fix: normalize shell script permissions before v3 verification`, followed by successful v3 execution.

Rule:

Before treating a script invocation failure as an OpenWrt/package failure, check executable permissions and checkout normalization. CI/controller setup may normalize `scripts/*.sh` permissions where appropriate.

Do not rewrite build logic when the actual failure is only an execution-mode mismatch.

---

## General failure loop

For every new failure:

1. preserve the first real error context;
2. classify it;
3. search this file;
4. reproduce with the smallest relevant preflight/package/build step;
5. apply the smallest coherent repair;
6. rerun the failed gate;
7. rerun downstream acceptance gates affected by the change;
8. only after verified recovery, add/update a failure pattern here.

## Anti-patterns

Never:

- rerun a two-hour full build repeatedly without changing or diagnosing anything;
- fix cascade errors before the first causal error;
- remove mandatory packages to obtain a green build;
- move all upstream/feed/plugin refs while debugging one package;
- call a CI failure an OpenWrt failure without inspecting the failing job/step;
- call a Candidate Known-Good Stable without real-device evidence.