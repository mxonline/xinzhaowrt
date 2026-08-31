# AdGuard Home Full Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the minimal AdGuard Home LuCI view with a modern JS manager exposing basic service controls, logs, manual YAML editing, validation, backup/restore, and complete Simplified Chinese labels.

**Architecture:** Keep the pinned ImmortalWrt AdGuard Home daemon and UCI service intact. Override only the LuCI view through the project files overlay, using LuCI `rpc`, `fs`, `form`, and `poll`; preserve dnsmasq ownership of port 53 and use the existing service init script for lifecycle operations.

**Tech Stack:** LuCI JavaScript view, LuCI rpc/fs APIs, ucode/procd service calls, POSIX shell validation helpers, Bash static tests.

**Spec:** Current user request: AdGuard Home full manager with 基础设置/日志/手动设置 tabs, zh_cn, service controls, port 3000, YAML validation/rollback, and DNS compatibility.

## Global Constraints

- Keep dnsmasq-full/OpenClash/MosDNS/SmartDNS DNS topology unchanged.
- Keep AdGuard Home v0.107.79 and existing service UCI paths.
- Never hardcode LAN IP; derive the current LAN address at runtime.
- Do not change board, target, profile, partitions, branding, password, Wi-Fi, or already VERIFIED gates.

### Task 1: Add failing static coverage

**Files:** Create `tests/test-adguard-manager.sh`; modify `.github/workflows/arthur-theme-candidate.yml` to run it.

- [ ] Assert the overlay view exists and contains the three tab labels, service actions, log actions, YAML actions, rollback wording, and `luci-i18n` source.
- [ ] Run the test and confirm it fails against the current 16-line upstream view.

### Task 2: Implement the LuCI manager view

**Files:** Create `files/www/luci-static/resources/view/adguardhome/config.js`.

- [ ] Use `view.extend` with `rpc.declare` for `service.list`, `service.action`, and `file`/`fs` operations already exposed by LuCI.
- [ ] Render tabs `basic`, `logs`, and `manual`; include status/version/port, start/stop/restart, Web UI link derived from `network.interface.lan`, update controls, log polling/order/pause/clear/download, YAML read/edit/validate/save/backup/restore.
- [ ] Validate YAML before save, keep a backup, restore it and restart safely when validation or restart fails.
- [ ] Use `_()` for every visible string so the existing AdGuard zh-cn LMO applies; avoid English-only labels.

### Task 3: Run local gates and freeze

- [ ] Run `tests/test-adguard-manager.sh`, existing Wi-Fi/theme/default tests, shell syntax checks, and `git diff` review.
- [ ] Commit only the AdGuard view/test/workflow changes; leave unrelated dirty files untouched.

### Task 4: Build, flash, and verify

- [ ] Push and trigger the existing workflow once.
- [ ] Verify candidate manifest/rootfs, then use the historical PowerShell→ssh.exe→`sysupgrade -n` path once.
- [ ] Verify all existing regression gates plus the AdGuard full-manager UI, three tabs, zh_cn, service controls, :3000, DNS compatibility, YAML rollback.

