#!/bin/sh
set -eu
backup=/root/arthur-v016-file-management-backup-20261007
test -f "$backup/world.before"
test -f "$backup/firewall.before"
test -f "$backup/ucitrack.before"
/etc/init.d/linkease stop 2>/dev/null || true
/etc/init.d/linkease disable 2>/dev/null || true
apk --no-scripts --repositories-file /dev/null del luci-app-linkease luci-lib-linkeasefile linkease linkease-common-bin
cp "$backup/ucitrack.before" /etc/config/ucitrack
rm -f /etc/config/linkease /etc/uci-defaults/linkease /etc/uci-defaults/linkease-fw /var/run/linkease.sock
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
if ! cmp -s "$backup/firewall.before" /etc/config/firewall; then echo FIREWALL_CONFIG_DIFF_AFTER_ROLLBACK; exit 1; fi
if ! cmp -s "$backup/world.before" /etc/apk/world; then echo APK_WORLD_DIFF_AFTER_ROLLBACK; exit 1; fi
echo LINKEASE_ROLLBACK_COMPLETE