# XinZhaoWrt Production Control

This directory is the control plane for 路由固件完整生产 v1.0.

- `request.json`: desired production request. Change `request_id` and set `action` to `produce` to trigger a run.
- `status.json`: stable status protocol for higher-level integrations. GitHub Actions run state remains authoritative in v1.0.
- `known-good.json`: verified firmware baseline. Never mark it verified before real-device validation.

## Required self-hosted runner labels

The Windows controller machine must be registered to this repository with these labels:

- `self-hosted`
- `windows`
- `x64`
- `xinzhaowrt-controller`

The machine must provide `git`, GitHub CLI `gh`, and Codex CLI `codex`, and `gh auth status --hostname github.com` must succeed.

## Trigger example

Update `request.json`:

```json
{
  "schema_version": "1.0",
  "request_id": "arthur-20260825-001",
  "action": "produce",
  "device": "jdcloud_re-ss-01",
  "mode": "UpdateBuild",
  "source_ref": "main",
  "max_repair_rounds": 3,
  "poll_seconds": 60,
  "notes": "Produce Arthur firmware from the current protected configuration."
}
```

A push that changes this file triggers `.github/workflows/produce.yml`.
