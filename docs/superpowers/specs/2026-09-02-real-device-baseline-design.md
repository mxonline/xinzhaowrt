# Arthur Real-Device Baseline Design

Date: 2026-09-02
Status: Design approved in chat, pending written-spec review before implementation
Scope: JDCloud RE-SS-01 / Arthur production firmware pipeline

## 1. Decision

All future Arthur firmware development must derive from the currently running real JDCloud RE-SS-01 device state, not from an older historical Candidate, a stale repository default, or chat history.

The currently running device is the bootstrap real-device reference for this transition. Operator-observed evidence supplied on 2026-09-02 shows:

- Product/model: JDCloud RE-SS-01
- Target family: qualcommax/ipq60xx
- Firmware label: XinZhaoWrt 0.1.3
- Build ID: 33368080615
- Git Commit shown by LuCI: 7ee9eec
- Build date shown by LuCI: 2026-08-31
- The operator reports this firmware has been running on the real device for more than 24 hours.

The runtime duration above is user-confirmed evidence, not machine-collected evidence. It is sufficient to choose this device as the bootstrap reference, but not sufficient by itself to promote a new machine-readable Known-Good. Promotion requires automated real-device evidence collection and hash/provenance reconciliation.

## 2. Source-of-truth hierarchy

For Arthur device behavior and future incremental changes, authority is ordered as follows:

1. Live verified real-device evidence from the designated Arthur unit.
2. `production/real-device-baseline.json` after it is created and cryptographically/evidentially bound to that live device.
3. The Candidate provenance, manifest and SHA256 for the firmware that produced the verified device state.
4. `production/known-good.json` for the last formally promoted Stable and rollback chain.
5. Repository configuration and documentation.
6. Historical chat or stale workflow state.

If a lower-priority source conflicts with a higher-priority source, the conflict must be reconciled before a new Candidate is allowed to flash.

## 3. New real-device baseline record

Create `production/real-device-baseline.json` as the machine-readable description of the currently accepted real-device state.

It must contain at least:

- schema version
- device identity: model, board name, target, subtarget, profile, storage identity/layout fingerprint
- device address currently used for management
- firmware identity: displayed version, build ID, build date, project Git commit if available
- candidate/release provenance when known: GitHub run ID, artifact ID/name, source SHA, firmware filename, SHA256
- LAN configuration
- Wi-Fi SSIDs, radios, encryption modes and enabled/disabled state, excluding plaintext secrets from the repository
- LuCI language and active/default theme
- required plugin set and package presence
- iStore/QuickStart presence and expected UI/service state
- AdGuard Home expected default state
- critical service state and port ownership relevant to DNS/routing coexistence
- overlay/storage health summary
- verified sysupgrade method/profile reference
- evidence timestamp and evidence sources
- promotion status

Sensitive credentials must never be committed in plaintext. The baseline may record credential policy or a secret-reference identifier, but not the actual secret beyond intentionally public project defaults already authorized by repository policy.

## 4. Bootstrap procedure for the current 0.1.3 device

The 0.1.3 device becomes the bootstrap `REAL_DEVICE_BASELINE` only after a read-only device snapshot succeeds.

The snapshot must collect, without changing the router:

- `ubus call system board`
- `/etc/openwrt_release` and relevant XinZhaoWrt build metadata
- current LAN address and network identity
- Wi-Fi configuration/state
- installed package list and required-plugin verification
- theme/LuCI defaults
- iStore/QuickStart presence and service/UI availability evidence
- AdGuard Home installed/default-enabled state
- storage/overlay identity and health data sufficient to prevent flashing a mismatched layout
- current boot/system health signals used by the existing real-device gate

The snapshot must distinguish three failure classes that are currently conflated:

- `DEVICE_UNREACHABLE`
- `SSH_AUTH_FAILED`
- `DEVICE_IDENTITY_MISMATCH`

Only an actual identity mismatch is a hard device-identity safety block. Network reachability or SSH authentication failure is a recoverable access problem and must not be mislabeled as an unknown device identity.

## 5. Baseline promotion rule

Do not immediately replace the existing `production/known-good.json` or delete the preserved `v0.1.0` rollback.

Promotion occurs in two phases.

### Phase A: Real-device bootstrap accepted

After the read-only snapshot proves this is the expected Arthur and captures its complete state, mark `production/real-device-baseline.json` as the active development baseline.

At this point, future changes must derive from this baseline even if the historical Known-Good record still points to an older formally promoted artifact.

### Phase B: Formal Known-Good promotion

Promote the 0.1.3 state into `production/known-good.json` only when its firmware provenance and immutable firmware SHA256 can be reconciled to a stored GitHub artifact or release asset and the corresponding real-device verification record is complete.

Until Phase B succeeds, preserve the existing known-good and `v0.1.0` rollback as emergency recovery assets.

## 6. Future development invariant

Every future firmware task must begin with the active real-device baseline.

The required chain becomes:

`REAL_DEVICE_BASELINE -> CHANGE_IMPACT_GATE -> BASELINE_INHERITANCE_GATE -> EXPECTED_DIFF_GATE -> shortest safe build lane -> Candidate -> artifact/config/plugin/theme checks -> AUTO_FLASH_SAFETY_GATE -> standard Arthur sysupgrade -> WAIT_DEVICE -> REAL_DEVICE_VERIFY -> baseline promotion -> PRODUCTION_RELEASED`

This does not add a new user-facing release stage ahead of the existing frozen release model. `REAL_DEVICE_BASELINE` is the authority consumed by the existing gates and recovery logic.

## 7. CHANGE_IMPACT_GATE behavior

The gate must define the exact requested change set before any build.

Examples of change domains include:

- package/plugin addition or removal
- theme change
- Wi-Fi defaults
- LAN defaults
- root credential policy
- AdGuard Home defaults or management integration
- iStore/QuickStart integration
- kernel/target/source changes

Anything not explicitly included in the requested change set is inherited from the real-device baseline and is treated as protected state.

## 8. BASELINE_INHERITANCE_GATE behavior

The Candidate must prove inheritance of all protected state from `production/real-device-baseline.json`.

At minimum, for non-kernel/non-target changes, it must preserve:

- exact Arthur target/subtarget/profile
- storage/layout compatibility
- LAN behavior unless intentionally changed
- Wi-Fi defaults unless intentionally changed
- root credential policy unless intentionally changed
- mandatory plugin set
- theme set and default theme unless intentionally changed
- iStore/QuickStart state unless intentionally changed
- AdGuard Home default state unless intentionally changed
- all other explicitly baselined product settings

A Candidate that silently regresses any protected state is rejected before flashing.

## 9. EXPECTED_DIFF_GATE behavior

Every Candidate must carry a machine-readable expected-diff manifest.

The gate compares:

- baseline state
- requested changes
- Candidate static state

Only declared differences are allowed. Unexpected differences fail the Candidate and return to the smallest repair/build path that can correct them.

This directly prevents the recurring failure mode where adding one theme or plugin accidentally changes LAN, Wi-Fi, credentials, AdGuard Home, iStore, or other already verified product behavior.

## 10. Version and provenance policy

The currently running device identifies itself as XinZhaoWrt 0.1.3, while the current Production Agent configuration references a v0.1.2 Candidate. This version/provenance inconsistency must be resolved before any new automatic flash.

Future Candidate versioning must derive from the active real-device baseline version plus the repository version policy. A Candidate with a numerically older product version than the active real-device baseline must be blocked unless an explicit, separately authorized downgrade/rollback operation is being performed.

Rollback artifacts are exempt from normal forward-version ordering but must be clearly classified as rollback assets and must never be mistaken for the next development Candidate.

## 11. Device identity and SSH recovery design

The Production Agent must stop treating one failed `ssh.exe ... ubus call system board` probe as equivalent to `UNKNOWN_DEVICE_IDENTITY`.

Identity flow:

1. probe expected and recovery addresses for network reachability;
2. attempt SSH with the configured non-interactive credential path;
3. classify authentication failure separately from device mismatch;
4. run `ubus call system board` after authentication succeeds;
5. compare model/board/target evidence to the active real-device baseline;
6. accept the device only on an exact safe match.

No fallback may weaken the device identity requirement. A screenshot or user statement can bootstrap the design transition, but automatic flashing still requires machine-verifiable identity evidence.

## 12. Safety and rollback

The existing safe Arthur standard sysupgrade policy remains in force.

The new baseline model must not authorize:

- MTD/raw partition writes
- bootloader/U-Boot writes
- raw eMMC/SPI/NAND writes
- partition-table changes
- ART/EEPROM/calibration writes
- force flashing with mismatched target/profile/storage layout

The preserved historical rollback remains available until the current 0.1.3 firmware itself has a verified immutable artifact/hash and is formally promoted.

## 13. Documentation reconciliation

`knowledge/DEVICE-PROFILE.md` currently contains an older statement that build agents must not automatically flash the router, while `AGENTS.md` and `production/release-policy.md` define safe standard Arthur sysupgrade as part of the automated release path after `AUTO_FLASH_SAFETY_GATE`.

Implementation must reconcile this stale documentation so there is one consistent policy: standard Arthur sysupgrade is permitted only after the full automatic safety gate passes; raw/boot-critical writes remain prohibited or explicitly human-authorized.

## 14. Required implementation components

Implementation is expected to modify or add narrowly scoped components around the existing release flow:

- `production/real-device-baseline.json`
- a read-only real-device snapshot/verification script
- `scripts/production-agent.ps1` device-access/error classification
- existing change-impact/baseline-inheritance/expected-diff logic so they consume the real-device baseline
- version/provenance downgrade protection
- tests covering baseline inheritance, expected diff, SSH failure classification and version ordering
- `AGENTS.md`, `production/release-policy.md`, `knowledge/DEVICE-PROFILE.md`, project-state/known-good knowledge where necessary

The active release pipeline must not be replaced with a new orchestration framework.

## 15. Testing and acceptance

Implementation is accepted only when tests prove:

- current device identity can be machine-verified without a write operation;
- network unreachable, SSH auth failure and identity mismatch are distinct states;
- a valid current real-device snapshot produces a deterministic baseline record;
- protected settings are inherited by a Candidate;
- an undeclared regression is rejected by EXPECTED_DIFF_GATE;
- an explicitly declared change is accepted;
- a normal Candidate older than the active baseline version is rejected;
- a classified rollback is still allowed when its SHA256 and rollback policy verify;
- no existing raw-write prohibition is weakened;
- the existing Arthur release chain still terminates only at `PRODUCTION_RELEASED`.

## 16. Migration outcome

After migration, the phrase "current Arthur baseline" means the last verified state of the designated real JDCloud RE-SS-01 device represented by `production/real-device-baseline.json`.

All later theme, plugin, Wi-Fi, AdGuard Home, iStore, network, package and firmware changes must be incremental changes from that baseline. A historical build may remain as rollback evidence, but it cannot silently become the development starting point again.