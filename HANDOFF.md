# Arthur Current Handoff

## Current state

- Device: JDCloud RE-SS-01 / Arthur.
- Management LAN: `192.168.6.1`.
- Target/profile: `qualcommax/ipq60xx` / `jdcloud_re-ss-01`.
- Recovery PR: `#57`, branch `codex/arthur-build-20260901-0816-132409c`.
- `WIFI=VERIFIED_FROZEN`; Wi-Fi is inherited from the already accepted real-device baseline and MUST NOT be modified, reloaded, or revalidated during ordinary prebuild/new-feature work.
- `PRODUCTION_RELEASED=false`.
- No production sysupgrade, raw write, or Release is authorized until the normal production gates pass.

The previous HANDOFF text that required an operator to confirm the changed SSH host key and manually provide an authenticated LuCI cookie is superseded by this handoff. Historical detail remains available in Git history before this replacement.

## Unattended recovery implementation

The prebuild control plane now treats the previous SSH/LuCI stop as an automatically recoverable condition, not an ordinary operator prompt.

### SSH host-key recovery

`scripts/ensure-arthur-unattended-access.ps1` is the only approved automatic rebind path. It does **not** disable host-key checking and does **not** blindly delete the old key. A changed/new host key may replace the stored Arthur entry only after all of the following independent evidence agrees:

1. the route to `192.168.6.1` is an active Ethernet path, not Wi-Fi;
2. Windows neighbor discovery reports the frozen Arthur management MAC from `production/arthur-control-plane.json`;
3. the unauthenticated static XinZhaoWrt build-info endpoint identifies the expected firmware/target/profile;
4. authenticated SSH through a disposable `accept-new` trust store identifies the expected Arthur board plus XinZhaoWrt build target/profile.

After those proofs, the existing `known_hosts` file is backed up, only the verified target entry is replaced, and strict SSH is run again. If the runner key no longer authenticates, secured `ARTHUR_ROOT_PASSWORD` may be used only after the independent endpoint proofs to install/repair the controller public key; the password is never persisted by this flow.

True identity/control-path/authentication ambiguity remains fail-closed. It is a legitimate `BLOCKED`, not a reason to bypass SSH security.

### LuCI authentication recovery

`scripts/real-device-verify.ps1` no longer requires an operator-supplied cookie. After verified root SSH is available it creates a short-lived rpcd session, assigns the authenticated root identity and dispatcher token, grants the required session access, writes a temporary local `sysauth_http` cookie, runs the authenticated AdGuard Home and QuickStart acceptance checks, then destroys/removes the temporary session evidence.

An existing `ARTHUR_LUCI_COOKIE_FILE` remains accepted for compatibility but is no longer required for unattended execution.

### Frozen Wi-Fi inheritance

`production/wifi-frozen-baseline.json` pins the accepted source file and Git blob. Prebuild checks the local source blob only. It does not call wireless UCI/iwinfo for fresh Wi-Fi acceptance and does not reload Wi-Fi.

Expected status is:

```text
WIFI_STATE=VERIFIED_FROZEN
WIFI=VERIFIED_FROZEN
wifi_configuration_mutated=false
```

Any change to the pinned Wi-Fi source fails closed and requires explicit user authorization before Wi-Fi work resumes.

## Non-disruptive prebuild and production dispatch

`real-device-verify-v3.ps1` defaults to `Mode=Prebuild`. In this mode it does not create the old persistence test file and does not reboot the router. Formal post-flash reboot/persistence testing remains available only through `Mode=PostFlash` after a real Candidate exists.

`scripts/github-app-auth.ps1 -GhProductionDispatch` now owns the full pre-dispatch closure:

```text
current local HEAD
  -> delete stale real-device report
  -> unattended Arthur access recovery
  -> fresh non-disruptive Prebuild verifier
  -> auto-created authenticated LuCI session
  -> ADGUARD_LIVE / QUICKSTART_LIVE checks
  -> inherit WIFI_STATE=VERIFIED_FROZEN
  -> write fresh real-device report bound to current HEAD
  -> PREBUILD_REAL_DEVICE_GATE
  -> only on PASS: dispatch arthur-update-v3.yml
```

A stale/missing cookie, changed Arthur host key, or old prebuild report is therefore not an operator next_action anymore.

## Verification evidence

Repo-side unattended recovery contract is green:

- Controller Preflight Run `33795326044` on commit `d584b78dd622332dee9df76683367c83676f1526`.
- `Parse PowerShell scripts`: PASS, including the new access helper, real-device verifier, v3 wrapper, and GitHub App dispatcher.
- `Verify v3 hard gates are referenced`: PASS.
- `Verify unattended prebuild recovery contract`: PASS.

Earlier non-production Theme Candidate Run `33790155987` completed successfully. It remains build/static evidence only and is not real-device or release authorization.

## Resume rule — no routine operator confirmation

On the local Windows/Codex runner, first synchronize this branch without discarding uncommitted work, then continue the existing checkpoint. Do not restart the development flow or rebuild merely because the prior Codex response stopped.

For production dispatch, use the existing production dispatcher; it now refreshes prebuild evidence itself. If an automatically recoverable step fails, classify the failure, rollback/repair, and retry without asking the user for routine approval.

Only these classes may stop the unattended loop:

- Arthur is unreachable after bounded retries;
- the management route cannot be proven Ethernet;
- the verified management MAC does not match;
- HTTP or authenticated SSH identifies a different device/firmware/target/profile;
- neither the existing runner key nor the already provisioned secured authentication path can authenticate;
- a required rollback cannot be proven;
- a later Candidate/flash safety gate reports genuine ambiguity or failure.

Do **not** stop merely for:

- `REMOTE HOST IDENTIFICATION HAS CHANGED` when the independent Arthur identity proofs succeed;
- missing/stale LuCI cookie;
- missing/stale prebuild report;
- fresh `WIFI_LIVE` evidence, because Wi-Fi is `VERIFIED_FROZEN` for this work.

## Next checkpoint

The repo-side fix is complete and CI-validated. The next required evidence must come from the real local Arthur control path: execute the refreshed unattended Prebuild path and continue automatically only if it returns `ADGUARD_LIVE=PASS`, `QUICKSTART_LIVE=PASS`, `WIFI_STATE=VERIFIED_FROZEN`, and `FIRMWARE_BUILD_ALLOWED=true`.

Until that real-device evidence exists:

```text
REAL_DEVICE_PREBUILD=NOT_RUN_ON_CURRENT_FIX
PRODUCTION_RELEASED=false
```
