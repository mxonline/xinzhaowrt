#!/usr/bin/env python3
"""Apply Arthur's DNS upstream setting to the pinned mature ADH template."""
from pathlib import Path
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch-adguardhome-coexistence.py <AdGuardHome_template.yaml>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    old = "  upstream_dns:\n  - 223.5.5.5"
    new = "  upstream_dns:\n  - 127.0.0.1:7874"
    if new not in text:
        if old not in text:
            raise SystemExit("AdGuardHome upstream template anchor missing")
        text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())