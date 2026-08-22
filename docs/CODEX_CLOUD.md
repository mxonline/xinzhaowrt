# Codex Cloud full-build workflow

## Environment setup

Connect this repository to a Codex Cloud environment. Configure internet access for the build task because ImmortalWrt feeds, source archives and third-party package repositories must be downloaded.

Use this repository setup command:

```bash
./scripts/codex-setup.sh
```

Codex Cloud tasks run in isolated environments tied to the connected GitHub repository. Keep `AGENTS.md` in the repository so each task receives the same build requirements.

## Full build task

Use this as the normal Codex task:

```text
Read AGENTS.md and build.env. Run scripts/verify-project.sh, then perform a full JDCloud Arthur firmware build with scripts/codex-cloud-build.sh. All 22 plugins in config/required-plugins.txt are mandatory. Do not remove plugins to make the build pass. If the build fails, inspect only the concise diagnostics and the relevant section of output/logs/build.log, fix the first real package/compiler error, rerun validation, and continue until the firmware succeeds or there is a concrete upstream incompatibility that cannot safely be patched. Do not execute any router flashing operation.
```

## Outputs

Successful builds produce:

- `output/firmware/XinZhaoWrt-Arthur-v0.1.0-YYYYMMDD-sysupgrade.bin` when a sysupgrade image is produced
- `output/firmware/XinZhaoWrt-Arthur-v0.1.0-YYYYMMDD-factory.bin` when a factory image is produced
- `output/firmware/SHA256SUMS.local`
- `output/full.config`
- `output/build-info.txt`
- `output/required-plugins.txt`

## Initial login

- Router IP: `192.168.6.1`
- User: `root`
- Initial password: `passwort`

Change the password immediately after first login.


## External package source validation

The build assembles selected third-party repositories into a local OpenWrt feed named `xinzhao`. Before configuration it verifies that each selected package has a real `Makefile` under `package/feeds/xinzhao/`. This prevents nested-repository layouts from silently hiding LuCI packages.
