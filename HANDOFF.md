# Arthur First-Boot Handoff

## ARTHUR FAST CANDIDATE ACCEPTED

Release `arthur-fast-candidate-33241309046` is accepted on the real Arthur after explicit clean-flash authorization.

- Firmware: `XinZhaoWrt-Arthur-fast-33241309046-sysupgrade.bin`
- SHA256: `733eeec1375403029f0b08b7307756b2edfd050ca52473891ab340051d3e5612`
- Project commit: `9bc5f471a92048233ff123370830000e124ca32d`
- Toolchain Run: `33196164359`
- QuickStart SDK Build: PASS (`aarch64_cortex-a53`)
- First Boot Runtime Gate: PASS — LAN `192.168.6.1/24`, both markers correct, all required stage log lines present, no `FIRSTBOOT_FAIL`.
- Web Stack Gate: PASS — nginx owns 80/443 and LuCI is reachable; uhttpd is inactive/no listener/no crash loop.
- Functional acceptance: PASS — 22/22 plugins, WAN DHCP, DNS, Internet HTTPS, SSH, storage, memory, logs, overlay, reboot, and persistence.
- Full Build Used: NO. Known-Good tag: NOT CREATED; await Baseline Freeze.

The earlier candidates remain recorded as `REJECTED_FIRST_BOOT`; their failure evidence is preserved below and is not used as the baseline.

Run `33182381566` built the specified candidate successfully, but the clean-flash FIRST BOOT acceptance failed. The candidate is `REJECTED_FIRST_BOOT`; Clean Flash and LAN Default are PASS, while both xinzhaowrt markers are FAIL. Known-Good remains NO.

Root cause is proven on the failed Arthur: real UCI reports `Entry not found` when the xinzhaowrt package file is absent, and `uci -q batch` returns zero despite creating no package. The targeted source fix atomically creates the package and verifies every marker mutation. The isolated real-UCI first-boot and idempotence gates pass.

QuickStart is independent and its root cause is proven: `/usr/sbin/quickstart` is a statically linked `ELF32 ARM EABI5`, while Arthur runs `aarch64` / `aarch64_cortex-a53`; it has no dynamic interpreter or shared-library dependency to repair. procd exits 127 because the executable is the wrong architecture, after which ash misparses ELF bytes as shell. The old feed bootstrap had forcibly selected `quickstart.arm`; source now retains `quickstart.$(PKG_ARCH_quickstart)`. The static source/web-stack gate passes: nginx remains primary and a rootfs uci-defaults overlay stops/disables uhttpd before enabling/restarting nginx. Await bootstrap `33196164359`, SDK-build only QuickStart for the matching aarch64 SDK, then assemble with ImageBuilder. Full Build is prohibited without a target/kernel/ABI/feed proof.

## Arthur FAST CANDIDATE READY

Release `arthur-fast-candidate-33232376176` contains `XinZhaoWrt-Arthur-fast-33232376176-sysupgrade.bin` (`SHA256 1b6028911a2e53f226e24a41d65a825a8b2223c8f7bf41ac434c59a316f8bb0a`) from project commit `528ac620a450d8c450920400fd46b1af604278f8`, built only through the accepted Toolchain Run `33196164359`. SDK_BUILD QuickStart, the isolated first-boot runtime/idempotence gate, ImageBuilder, WEB_STACK_GATE, profile/target/provenance/SHA256 checks, and isolated actual-rootfs `sysupgrade -T` are PASS. Full Build Used: NO. The old candidate remains `REJECTED_FIRST_BOOT`; Clean Flash and LAN Default remain PASS, FIRST BOOT remains FAIL, and Known-Good remains NO. No router was connected or modified. Next action requires explicit authorization for CLEAN FLASH + FIRST BOOT.
