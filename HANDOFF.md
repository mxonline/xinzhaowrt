# Arthur First-Boot Handoff

Run `33182381566` built the specified candidate successfully, but the clean-flash FIRST BOOT acceptance failed. The candidate is `REJECTED_FIRST_BOOT`; Clean Flash and LAN Default are PASS, while both xinzhaowrt markers are FAIL. Known-Good remains NO.

Root cause is proven on the failed Arthur: real UCI reports `Entry not found` when the xinzhaowrt package file is absent, and `uci -q batch` returns zero despite creating no package. The targeted source fix atomically creates the package and verifies every marker mutation. The isolated real-UCI first-boot and idempotence gates pass.

QuickStart is independent: `/usr/sbin/quickstart` is an ELF that cannot execute on the flashed Arthur aarch64 environment; procd exits 127 and the shell fallback produces syntax errors. Nginx owns 80/443. Await bootstrap `33196164359`, inspect the package source/artifact, then choose ImageBuilder for overlay-only work or SDK QuickStart rebuild plus ImageBuilder if the package artifact must change. Full Build is prohibited without a target/kernel/ABI/feed proof.
