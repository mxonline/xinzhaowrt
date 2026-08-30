# XinZhaoWrt Production Control

This directory is the control plane for 路由固件完整生产 v1.0. The production architecture is permanently cloud-first; see `pipeline-policy.json`.

- `request.json`: desired production request. Change `request_id` and set `action` to `produce` to trigger a run.
- `status.json`: stable status protocol for higher-level integrations. GitHub Actions run state remains authoritative in v1.0.
- `known-good.json`: verified firmware baseline. Never mark it verified before real-device validation.
- `pipeline-policy.json`: authoritative execution-plane policy.

## Production architecture

`Windows + GPT/Codex Orchestrator` is the control plane. GitHub Actions Linux runners are the primary build plane, Arthur is the device-validation plane, and GitHub Release is the release plane.

The build lane order is:

1. GitHub-hosted `ubuntu-24.04` runner.
2. Another verified cloud Linux runner.
3. WSL only as an emergency fallback.

Missing local WSL, `make`, Docker, or Podman is reported as `LOCAL_LINUX_EXECUTOR_UNAVAILABLE`; it must never become `BUILD_BLOCKED`.

## Required self-hosted runner labels

The Windows controller machine must be registered to this repository with these labels:

- `self-hosted`
- `windows`
- `x64`
- `xinzhaowrt-controller`

The control-plane machine must provide `git`, GitHub CLI `gh`, and Codex CLI `codex`. GitHub authentication is a deliberate credential gate because the controller must dispatch and monitor the cloud build, then use the same session for Release publication.

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
