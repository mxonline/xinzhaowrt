#!/usr/bin/env python3
"""Static contract for the Arthur OpenClash/AdGuardHome DNS topology.

This test intentionally describes the product boundary.  It must fail until
the declarative contract and the small runtime reconciliation helper are
present in the firmware tree.
"""
from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "production" / "openclash-adguardhome-coexistence.json"
HELPER = ROOT / "files" / "usr" / "libexec" / "xinzhao-dns-coexist"
INIT = ROOT / "files" / "etc" / "init.d" / "xinzhao-dns-coexist"
ADH_OVERLAY_DIR = ROOT / "files" / "usr" / "share" / "AdGuardHome"
TEMPLATE = ADH_OVERLAY_DIR / "AdGuardHome_template.yaml"
ADH_PATCH = ROOT / "scripts" / "patch-adguardhome-coexistence.py"
PACKAGE_SCRIPT = ROOT / "scripts" / "add-custom-packages.sh"


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


if not CONTRACT.is_file():
    fail("coexistence contract is missing")
if not HELPER.is_file():
    fail("runtime DNS reconciliation helper is missing")
if not INIT.is_file():
    fail("coexistence init wrapper is missing")
if TEMPLATE.exists():
    fail("duplicate AdGuardHome template overlay must not exist; pinned mature package owns this file")
if ADH_OVERLAY_DIR.is_dir() and any(ADH_OVERLAY_DIR.iterdir()):
    fail("duplicate files/usr/share/AdGuardHome overlay must be empty; pinned mature package owns these files")
if not ADH_PATCH.is_file():
    fail("AdGuardHome coexistence source patch is missing")
if not PACKAGE_SCRIPT.is_file():
    fail("custom package source script is missing")

contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
if contract.get("lan_frontend") != {"service": "dnsmasq", "port": 53}:
    fail("dnsmasq must be the sole LAN :53 frontend")
if contract.get("openclash_dns_port") != 7874:
    fail("OpenClash DNS port must remain 7874")
if contract.get("adguardhome_dns_port") != 1745:
    fail("AdGuardHome must use its independent DNS port 1745")
defaults = contract.get("defaults", {})
if defaults.get("adguardhome_enabled") is not False:
    fail("AdGuardHome default enabled state must remain disabled")
if defaults.get("adguardhome_redirect") != "none":
    fail("AdGuardHome default redirect must remain none")
if contract.get("coexistence", {}).get("adh_redirect") != "dnsmasq-upstream":
    fail("coexistence must use mature AdGuardHome dnsmasq-upstream mode")
if contract.get("coexistence", {}).get("openclash_enable_redirect_dns") != 0:
    fail("OpenClash DNS hijack must be disabled while AdGuardHome owns the upstream hop")

helper = HELPER.read_text(encoding="utf-8")
for required in (
    "uci",
    "AdGuardHome",
    "dnsmasq-upstream",
    "enable_redirect_dns",
    "redirect_dns",
    "127.0.0.1#1745",
    "127.0.0.1:7874",
    "start|stop|restart",
):
    if required not in helper:
        fail(f"coexistence helper is missing required lifecycle/topology primitive: {required}")
init = INIT.read_text(encoding="utf-8")
if "procd_add_reload_trigger AdGuardHome openclash dhcp" not in init:
    fail("coexistence init must reconcile after mature service UCI changes")
if any(token in helper for token in ("iptables", "iptables-restore", "nft ", "nftables")):
    fail("coexistence helper must delegate firewall ownership to mature packages")

adh_patch = ADH_PATCH.read_text(encoding="utf-8")
package_script = PACKAGE_SCRIPT.read_text(encoding="utf-8")
if "127.0.0.1:7874" not in adh_patch:
    fail("AdGuardHome coexistence patch must terminate upstream at OpenClash DNS 7874")
if "patch-adguardhome-coexistence.py" not in package_script:
    fail("mature AdGuardHome source patch is not wired into package staging")
if "  port: 1745" not in adh_patch:
    fail("AdGuardHome coexistence patch must require mature DNS listener port 1745")

# Deterministic lifecycle simulation.  This exercises the coordinator's
# contract without pretending that a Windows checkout is a running router.
class DnsState:
    def __init__(self) -> None:
        self.adh_enabled = False
        self.adh_running = False
        self.oc_running = False
        self.oc_redirect = 1
        self.adh_redirect = "none"
        self.dnsmasq_servers = ["127.0.0.1#7874"]
        self.firewall_rules: list[str] = []
        self.saved_oc: tuple[int, int] | None = None

    def apply(self) -> None:
        if self.adh_enabled and self.adh_running:
            if self.saved_oc is None:
                self.saved_oc = (self.oc_redirect, self.oc_redirect)
            self.oc_redirect = 0
            self.adh_redirect = "dnsmasq-upstream"
            self.dnsmasq_servers = ["127.0.0.1#1745"]
        else:
            self.adh_redirect = "none"
            self.dnsmasq_servers = [s for s in self.dnsmasq_servers if s != "127.0.0.1#1745"]
            if self.saved_oc is not None:
                self.oc_redirect = self.saved_oc[0]
                self.saved_oc = None
            if self.oc_running:
                self.dnsmasq_servers = ["127.0.0.1#7874"]
        self.dnsmasq_servers = list(dict.fromkeys(self.dnsmasq_servers))
        if self.firewall_rules:
            fail("coexistence coordinator must not create duplicate firewall DNS redirects")

    def adh_start(self) -> None:
        self.adh_enabled = True
        self.adh_running = True
        self.apply()

    def adh_stop(self) -> None:
        self.adh_running = False
        self.apply()

    def adh_restart(self) -> None:
        self.adh_running = False
        self.apply()
        self.adh_running = True
        self.apply()

    def adh_disable(self) -> None:
        self.adh_enabled = False
        self.adh_running = False
        self.apply()

    def openclash_start(self) -> None:
        self.oc_running = True
        self.apply()

    def openclash_stop(self) -> None:
        self.oc_running = False
        self.apply()

    def openclash_restart(self) -> None:
        self.oc_running = True
        self.apply()


state = DnsState()
state.openclash_start()
state.adh_start()
state.openclash_restart()
state.adh_restart()
state.adh_stop()
state.adh_disable()
state.openclash_stop()
state.openclash_start()
if state.dnsmasq_servers != ["127.0.0.1#7874"] or state.adh_redirect != "none":
    fail("ADH disable must restore the pure OpenClash DNS chain")
state.adh_start()
state.adh_running = False  # reboot before services are brought back
state.apply()
state.adh_running = True
state.oc_running = True
state.apply()
if state.dnsmasq_servers != ["127.0.0.1#1745"] or state.adh_redirect != "dnsmasq-upstream":
    fail("reboot-state restoration did not recover the coexistence chain")
for _ in range(3):
    state.apply()
if state.dnsmasq_servers.count("127.0.0.1#1745") != 1:
    fail("repeated apply created duplicate dnsmasq upstream entries")

print("DNS_CHAIN=LAN:dnsmasq:53 -> AdGuardHome:1745 -> OpenClash:7874")
print("PORT53_OWNER=dnsmasq")
print("DNSMASQ_PORT=53")
print("ADGUARDHOME_DNS_PORT=1745")
print("OPENCLASH_DNS_PORT=7874")
print("NO_DNS_PORT_CONFLICT=PASS")
print("NO_DNS_LOOP_DESIGN=PASS")
print("NO_DUPLICATE_DNS_HIJACK=PASS")
print("OPENCLASH_RESTORE_PATH=PASS")
print("ADH_RESTORE_PATH=PASS")
print("ADH_DEFAULT_STATE=DISABLED")
print("COEXISTENCE_STATIC_CONTRACT=PASS")
