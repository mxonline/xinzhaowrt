# Arthur Real-Device Theme and Language Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce a new Arthur candidate whose first boot contains zh_cn, defaults to Argon, registers Kucat, preserves all 22 baseline plugins, and passes real-device verification before release.

**Architecture:** Reuse the existing frozen-theme GitHub Actions lane and pinned upstream revisions. Add source/package/rootfs gates for the Chinese LuCI package, Argon/Kucat registration and defaults, then reuse the existing PowerShell → ssh.exe → sysupgrade path for the new candidate.

**Tech Stack:** ImmortalWrt SDK/ImageBuilder, GitHub Actions, shell gates, LuCI UCI configuration, OpenSSH PowerShell dispatch.

**Spec:** User-provided REAL_DEVICE_VERIFY failure report (2026-08-31).

## Global Constraints

- Target remains `qualcommax/ipq60xx/jdcloud_re-ss-01`.
- Fixed ImmortalWrt source revision remains `27e26e324bee0b0c2a4eb58e2e9121fea5d43194`.
- Preserve all 22 required LuCI applications.
- Default LAN remains `192.168.6.1`.
- Do not change cgi-io/OOM fixes, flash architecture, or sysupgrade policy.
- Reject any candidate missing zh_cn, Argon default, Kucat registration, or expected package/theme set.

### Task 1: Apply the prepared source and gate fixes

**Files:**
- Modify: `.github/workflows/arthur-theme-candidate.yml`
- Modify: `config/arthur-theme.lock`
- Modify: `files/etc/config/luci`
- Modify: `tests/test-arthur-theme-candidate-workflow.sh`
- Create: `tests/test-argon-default-theme.sh`

- [ ] Verify the prepared branch changes only the theme/language candidate lane and gates.
- [ ] Run the workflow/static tests and confirm they fail closed on missing package/rootfs/theme defaults.
- [ ] Preserve pinned Argon/Kucat revisions and add locked LuCI feed/package provenance.

### Task 2: Build and verify a new candidate

**Files:**
- Create: `output/` candidate artifacts and provenance logs only.

- [ ] Run project verification and the theme candidate workflow using the fixed source revision.
- [ ] Verify rootfs contains `luci-i18n-base-zh-cn`, Argon, Kucat, 22 plugins, and `option mediaurlbase '/luci-static/argon'`.
- [ ] Verify no unplanned theme is selected as default and record SHA256.

### Task 3: Flash and verify the new candidate

- [ ] Confirm local/cloud/remote SHA256 and device identity.
- [ ] Upload with the historical OpenSSH identity and legacy SCP where required.
- [ ] Dispatch `sysupgrade -n`, tolerate expected SSH exit 246, and wait for `192.168.6.1`.
- [ ] Verify firmware identity, zh_cn selector/default, Argon/Kucat runtime registration and switching, all 22 plugins, LAN/WAN/DHCP/DNS/services/storage/overlay/boot log.

### Task 4: Release only after complete real-device PASS

- [ ] Require `REAL_DEVICE_VERIFY=PASS` and `RELEASE_GATE=PASS`.
- [ ] Upload release assets and final SHA256 only with valid GitHub authentication.

