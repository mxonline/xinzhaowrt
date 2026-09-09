# Arthur #74 real-device verification

Result: **PASS**

- Candidate: `arthur-update-34268801985`
- Project commit: `2f4d9a70e5675955bddaf51eb134131fac61bfc3`
- Device: JDCloud RE-SS-01 / Arthur (`DC-D8-7C-46-91-24`)
- Firmware: `XinZhaoWrt-Arthur-v0.1.3-20260908-sysupgrade.bin`
- SHA-256: `f048a7063c7fa89774f628d252f9709d5cee2801f36066ebefb61cc65ea1b557`
- Build ID: `34268801985`
- Upstream commit: `27e26e324bee0b0c2a4eb58e2e9121fea5d43194`

Executed acceptance evidence: local and router SHA-256 matched; `sysupgrade -T` passed; exactly one `sysupgrade -n` was issued; device rebooted and recovered with LAN `192.168.6.1/24`, DHCP lease `192.168.6.152`, gateway/DNS `192.168.6.1`, and root/password SSH.

HTTP/80 served LuCI without a HTTPS redirect; TCP/443 was unreachable. Chinese LuCI, 2.4 GHz Wi-Fi, 5 GHz Wi-Fi, QuickStart, iStoreX, QuickFile and the AdGuardHome management page passed. AdGuardHome was `enabled=0` and not running. Build-info held concrete #74 values with no placeholders. Candidate plugin verification reported 22/22 PASS.
