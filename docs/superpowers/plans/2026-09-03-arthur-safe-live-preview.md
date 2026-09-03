# Arthur Safe LIVE_PREVIEW Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the fast 0.1.3-style real-router preview loop as a strictly scoped `LIVE_PREVIEW` control-plane tool while preserving the existing Candidate → build → sysupgrade → REAL_DEVICE_VERIFY → Release production path.

**Architecture:** Add one PowerShell preview executor that reads a machine-readable policy, derives or accepts explicit safe local→remote file mappings, verifies Arthur identity and an Ethernet control path, backs up every remote target before mutation, hot-deploys only allowlisted LuCI/ACL/static files, clears/reloads only the required LuCI/rpcd state, runs authenticated AdGuard/QuickStart preview checks, and automatically rolls back on failure. `LIVE_PREVIEW` stays outside the frozen production stage order and can never set `REAL_DEVICE_VERIFY=PASS` or `RELEASE_ALLOWED=true`.

**Tech Stack:** Windows PowerShell 7 / OpenSSH `ssh.exe` + `scp.exe`, Bash static contract tests, GitHub Actions Ubuntu `pwsh`, existing Arthur Fast Preflight classifier.

**Spec:** `docs/superpowers/specs/2026-09-03-arthur-live-preview-release-flow-design.md`

## Global Constraints

- Device remains JDCloud RE-SS-01 / Arthur, target `qualcommax/ipq60xx`, profile `jdcloud_re-ss-01`, management LAN `192.168.6.1`.
- `WIFI=VERIFIED_FROZEN`; LIVE_PREVIEW must not modify or reload Wi-Fi.
- LIVE_PREVIEW must not modify LAN/WAN, firewall core config, kernel, packages/binaries, bootloader, partitions, raw storage, Known-Good, Stable or Latest pointers.
- Every remote file mutation must be preceded by a timestamped router-side backup and missing-file record.
- Any failure after mutation begins must restore the backup, clear LuCI caches, restore rpcd state as needed, and emit `LIVE_PREVIEW=FAIL_ROLLED_BACK`.
- A successful preview must emit `REAL_DEVICE_VERIFY=NOT_RUN` and `RELEASE_ALLOWED=false`.
- AdGuard preview must end with AdGuard Home stopped and disabled.
- QuickStart preview must check the authenticated complete homepage, not package/socket presence alone.
- Existing production release order after source freeze remains unchanged.

---

### Task 1: Lock the preview safety contract with failing tests

**Files:**
- Create: `tests/test-live-preview-contract.sh`
- Modify: `tests/test-classify-build-scope.sh`

**Interfaces:**
- Consumes: repository text only.
- Produces: a static contract that requires a policy file, scope deny rules, backup/rollback markers, authenticated feature checks, frozen Wi-Fi status, and non-release preview status.

- [ ] **Step 1: Write the failing live-preview contract test**

Create `tests/test-live-preview-contract.sh` with checks that require:

```bash
policy="$ROOT/production/live-preview-policy.json"
script="$ROOT/scripts/live-preview.ps1"
[[ -s "$policy" ]] || fail 'live preview policy missing'
[[ -s "$script" ]] || fail 'live preview executor missing'

grep -Fq 'WIFI=VERIFIED_FROZEN' "$script" || fail 'Wi-Fi frozen marker missing'
grep -Fq 'REAL_DEVICE_VERIFY=NOT_RUN' "$script" || fail 'preview must not claim formal real-device verification'
grep -Fq 'RELEASE_ALLOWED=false' "$script" || fail 'preview must never allow release'
grep -Fq 'LIVE_PREVIEW=FAIL_ROLLED_BACK' "$script" || fail 'automatic rollback marker missing'
grep -Fq 'xinzhaowrt-live-preview' "$script" || fail 'router-side backup root missing'
grep -Fq 'Invoke-AuthenticatedLuciPage' "$script" || fail 'authenticated LuCI check missing'
grep -Fq 'Test-AdGuardPreview' "$script" || fail 'AdGuard preview check missing'
grep -Fq 'Test-QuickStartPreview' "$script" || fail 'QuickStart preview check missing'

! grep -Eq 'uci[[:space:]]+(set|delete|rename)[[:space:]]+wireless|wifi[[:space:]]+(reload|down|up)' "$script" || fail 'preview script contains Wi-Fi mutation'
! grep -Eq '/sbin/sysupgrade|(^|[^[:alnum:]_])mtd([^[:alnum:]_]|$)|dd[[:space:]].*of=/dev/' "$script" || fail 'preview script contains flash/raw-write operation'

python3 - "$policy" <<'PY'
import json, sys
p=json.load(open(sys.argv[1], encoding='utf-8'))
assert p['device']['management_ip'] == '192.168.6.1'
assert '/etc/config/wireless' in p['forbidden_remote_prefixes']
assert '/etc/config/network' in p['forbidden_remote_prefixes']
assert '/www/' in p['allowed_remote_prefixes']
assert '/usr/share/rpcd/acl.d/' in p['allowed_remote_prefixes']
PY
```

- [ ] **Step 2: Run the new test and verify RED**

Run:

```bash
bash tests/test-live-preview-contract.sh
```

Expected: FAIL because `production/live-preview-policy.json` and `scripts/live-preview.ps1` do not exist yet.

- [ ] **Step 3: Extend the build-scope classifier test first**

Add this case to `tests/test-classify-build-scope.sh`:

```bash
run_case FAST_GATE \
  scripts/live-preview.ps1 \
  production/live-preview-policy.json \
  tests/test-live-preview-contract.sh
```

- [ ] **Step 4: Run classifier test and verify RED**

Run:

```bash
bash tests/test-classify-build-scope.sh
```

Expected: FAIL with `FULL_BUILD` because the new control-plane paths are not yet classified.

### Task 2: Add the machine-readable preview policy and classifier routing

**Files:**
- Create: `production/live-preview-policy.json`
- Modify: `scripts/classify-build-scope.sh`

**Interfaces:**
- Consumes: repo-relative source paths and remote destination paths.
- Produces: `schema_version`, Arthur identity, safe source mappings, allowed remote prefixes, forbidden repository/remote prefixes, backup root, cache paths, and feature routes consumed by `scripts/live-preview.ps1`.

- [ ] **Step 1: Create the minimal policy**

Create `production/live-preview-policy.json` with:

```json
{
  "schema_version": 1,
  "device": {
    "board_pattern": "jdcloud,re-ss-01|RE-SS-01",
    "management_ip": "192.168.6.1"
  },
  "backup_root": "/root/xinzhaowrt-live-preview",
  "source_mappings": [
    {"repo_prefix": "files/www/", "remote_prefix": "/www/"},
    {"repo_prefix": "files/usr/share/rpcd/acl.d/", "remote_prefix": "/usr/share/rpcd/acl.d/"},
    {"repo_prefix": "sources/kenzok8/quickstart/htdocs/", "remote_prefix": "/www/"},
    {"repo_prefix": "sources/kenzok8/quickstart/root/usr/share/rpcd/acl.d/", "remote_prefix": "/usr/share/rpcd/acl.d/"},
    {"repo_prefix": "sources/kenzok8/quickstart/root/usr/share/luci/menu.d/", "remote_prefix": "/usr/share/luci/menu.d/"}
  ],
  "allowed_remote_prefixes": [
    "/www/",
    "/usr/share/rpcd/acl.d/",
    "/usr/share/luci/menu.d/"
  ],
  "forbidden_repo_prefixes": [
    "config/",
    "files/etc/config/network",
    "files/etc/config/wireless",
    "files/etc/uci-defaults/",
    "files/etc/init.d/",
    "patches/",
    "package/",
    "packages/",
    "feeds/",
    "target/",
    "VERSION",
    "build.env"
  ],
  "forbidden_remote_prefixes": [
    "/etc/config/wireless",
    "/etc/config/network",
    "/etc/config/firewall",
    "/etc/init.d/",
    "/lib/",
    "/usr/bin/",
    "/usr/sbin/",
    "/sbin/",
    "/boot/",
    "/dev/",
    "/sys/",
    "/proc/"
  ],
  "luci_cache_paths": [
    "/tmp/luci-indexcache",
    "/tmp/luci-modulecache/*"
  ],
  "adguard_route": "admin/services/adguardhome",
  "quickstart_route": "admin/quickstart/"
}
```

- [ ] **Step 2: Route the preview control plane to FAST_GATE**

Add `scripts/live-preview.ps1` and `production/live-preview-policy.json` to the explicit FAST_GATE path list in `scripts/classify-build-scope.sh`.

- [ ] **Step 3: Run classifier test and verify GREEN**

Run:

```bash
bash tests/test-classify-build-scope.sh
```

Expected: PASS.

### Task 3: Implement the safe PowerShell LIVE_PREVIEW executor

**Files:**
- Create: `scripts/live-preview.ps1`
- Test: `tests/test-live-preview-contract.sh`

**Interfaces:**
- Consumes: `-Target`, `-Feature AdGuard|QuickStart|Both|Generic`, optional `-ManifestPath`, optional `-ValidateOnly`, `production/live-preview-policy.json`, `ARTHUR_ROOT_PASSWORD`, current git changed files.
- Produces: preview status lines, router-side backup path, deployed file hashes, authenticated feature preview result; never produces release eligibility.

- [ ] **Step 1: Add parameter and policy validation skeleton**

Implement parameters:

```powershell
param(
    [string]$Target = 'root@192.168.6.1',
    [ValidateSet('AdGuard','QuickStart','Both','Generic')][string]$Feature = 'Generic',
    [string]$ManifestPath,
    [switch]$ValidateOnly
)
```

Load `production/live-preview-policy.json`; reject missing/invalid schema and reject a target host different from `device.management_ip`.

- [ ] **Step 2: Implement safe source→remote mapping**

Provide:

```powershell
function Resolve-PreviewEntries
function Test-RepoPathAllowed
function Test-RemotePathAllowed
```

Rules:

- explicit manifest entries are `{ "source": "repo/relative/file", "remote": "/absolute/remote/file" }`;
- auto mode derives entries from current git changed files using `source_mappings`;
- deleted files are rejected from preview;
- every source must exist and be a regular file;
- every remote path must start with an allowed prefix and with no forbidden prefix;
- any changed firmware-affecting path that is forbidden or unmapped fails closed;
- control-plane/docs/test changes may coexist without deployment.

- [ ] **Step 3: Implement read-only Arthur preflight**

Provide:

```powershell
function Invoke-Remote
function Copy-ToRemote
function Assert-RemoteOutput
function Assert-ArthurIdentity
function Assert-EthernetControlPath
```

Require:

- SSH BatchMode connectivity;
- `ubus call system board` matches the policy board pattern;
- `uci -q get network.lan.ipaddr` is `192.168.6.1`;
- Windows route to Arthur resolves through a non-wireless adapter;
- no router mutation occurs before all preflight checks pass.

- [ ] **Step 4: Implement backup, deploy and rollback**

Before copying each entry into its final destination:

- create `${backup_root}/yyyyMMdd-HHmmss-<pid>`;
- record destination path, existence and SHA256;
- copy existing remote file into the backup tree;
- SCP the local file into a temporary router directory;
- copy temporary file into final destination with mode `0644`;
- record deployed SHA256.

On any exception after the first mutation, `Restore-LivePreviewBackup` must restore or remove each destination according to its original existence, restart rpcd if ACL/menu files were touched, clear LuCI caches, emit `LIVE_PREVIEW=FAIL_ROLLED_BACK`, and rethrow.

- [ ] **Step 5: Implement authenticated LuCI checks**

Provide `Invoke-AuthenticatedLuciPage` using the existing root password environment variable and a temporary cookie file. It must fail closed when `ARTHUR_ROOT_PASSWORD` is absent for `AdGuard`, `QuickStart` or `Both` preview modes.

- [ ] **Step 6: Implement AdGuard preview check**

`Test-AdGuardPreview` must:

- fetch the authenticated configured AdGuard LuCI route and reject login redirects/empty pages;
- verify AdGuard core version command works;
- verify rpcd session access includes service status/action and AdGuard config read/write permissions;
- temporarily start AdGuard Home without enabling it, verify the process and local Web endpoint, then stop it;
- end with init disabled and process stopped;
- emit `ADGUARD_PREVIEW=PASS`.

- [ ] **Step 7: Implement QuickStart preview check**

`Test-QuickStartPreview` must fetch the authenticated configured QuickStart route and require the complete app markers already used by formal verification: `luci-static/quickstart/index.js`, an `id="app"` mount point, and `QuickStart`, with no login-page marker. Emit `QUICKSTART_PREVIEW=PASS`.

- [ ] **Step 8: Emit unambiguous preview-only state**

On success emit exactly the conceptual state:

```text
STATIC_VALIDATION=PASS
LIVE_PREVIEW=PASS
WIFI=VERIFIED_FROZEN
REAL_DEVICE_VERIFY=NOT_RUN
RELEASE_ALLOWED=false
```

Feature-specific modes additionally emit their `*_PREVIEW=PASS` lines. Never emit `ADGUARD_REAL_DEVICE=PASS`, `QUICKSTART_REAL_DEVICE=PASS` or `REAL_DEVICE_VERIFY=PASS`.

- [ ] **Step 9: Run contract test and verify GREEN**

Run:

```bash
bash tests/test-live-preview-contract.sh
```

Expected: PASS.

### Task 4: Add CI execution and future-agent routing

**Files:**
- Modify: `.github/workflows/arthur-fast-preflight.yml`
- Modify: `scripts/verify-project.sh`
- Modify: `AGENTS.md`
- Modify: `knowledge/INDEX.md`
- Modify: `knowledge/BUILD-ROUTING.md`

**Interfaces:**
- Consumes: the new test and executor.
- Produces: automatic parser/static-gate enforcement on every relevant PR and durable routing instructions for future Codex/GPT work.

- [ ] **Step 1: Add preview contract and PowerShell parser checks to Fast Preflight**

Add steps after classifier testing:

```yaml
- name: Test LIVE_PREVIEW safety contract
  run: ./tests/test-live-preview-contract.sh

- name: Parse LIVE_PREVIEW PowerShell
  shell: pwsh
  run: |
    $tokens=$null; $errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile('scripts/live-preview.ps1',[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { $errors | Format-List | Out-String | Write-Error; exit 1 }
```

- [ ] **Step 2: Make project verification run the contract test**

Add:

```bash
bash tests/test-live-preview-contract.sh
```

to `scripts/verify-project.sh` beside existing functional acceptance tests.

- [ ] **Step 3: Document the two-channel rule in AGENTS.md**

Add an explicit section stating that `LIVE_PREVIEW` is an approved pre-Candidate development aid outside the frozen production stage order, is preferred for preview-safe UI/ACL/static changes, must preserve `WIFI=VERIFIED_FROZEN`, and never substitutes for Candidate build/flash/REAL_DEVICE_VERIFY.

- [ ] **Step 4: Add knowledge routing**

Update `knowledge/INDEX.md` and `knowledge/BUILD-ROUTING.md` so future agents route UI/ACL/static preview-safe work through `scripts/live-preview.ps1`, while firmware-affecting or unknown changes still follow the normal classifier-selected build lane.

- [ ] **Step 5: Run all affected static tests**

Run:

```bash
bash tests/test-live-preview-contract.sh
bash tests/test-classify-build-scope.sh
bash -n scripts/classify-build-scope.sh
bash -n scripts/verify-project.sh
python3 -m json.tool production/live-preview-policy.json >/dev/null
```

Expected: all PASS.

### Task 5: Verify branch-level integration and hand off to the real Arthur runner

**Files:** No production file changes unless verification finds a defect.

**Interfaces:**
- Consumes: all Task 1–4 outputs.
- Produces: a branch/PR ready for the user's Windows/Codex Arthur runner to execute `LIVE_PREVIEW` against the real router.

- [ ] **Step 1: Confirm the change remains control-plane only**

Run the classifier over all implementation paths and require `FAST_GATE`.

- [ ] **Step 2: Run Fast Preflight on the implementation branch/PR**

Require the GitHub Actions `Arthur Fast Preflight` check to pass; do not start a firmware build solely for this control-plane implementation.

- [ ] **Step 3: Real-device use command after merge/checkout on the authorized Windows runner**

For automatically mappable overlay changes:

```powershell
pwsh -NoProfile -File .\scripts\live-preview.ps1 -Feature Both
```

For a package-source file that needs an explicit runtime destination, generate a temporary JSON manifest with `source`/`remote` pairs and run:

```powershell
pwsh -NoProfile -File .\scripts\live-preview.ps1 -Feature QuickStart -ManifestPath .\tmp\live-preview-manifest.json
```

Expected success state contains `LIVE_PREVIEW=PASS`, feature preview PASS lines, `WIFI=VERIFIED_FROZEN`, `REAL_DEVICE_VERIFY=NOT_RUN`, and `RELEASE_ALLOWED=false`.

- [ ] **Step 4: Preserve production semantics**

After the user visually/functional confirms the preview, source is frozen and the existing release pipeline resumes at its normal pre-Candidate gates. No preview result is reused as formal post-flash `REAL_DEVICE_VERIFY` evidence.
