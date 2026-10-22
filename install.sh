#!/bin/sh
# MIT. Stages package files only. Does not change live network or start services.
set -eu
mode=${1:---plan}
case "$mode" in --plan|--apply) ;; *) printf '%s\n' 'Usage: sh install.sh [--plan|--apply]'; exit 2;; esac
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for name in IptvConfig.pm iptv_dhcp.pl iptv_access.pl iptv_gateway.pl iptv-homelab.init iptv.conf.example channels.example.m3u; do
    [ -f "$base/$name" ] || { printf '%s\n' 'Package incomplete.' >&2; exit 1; }
done
printf '%s\n' 'Target: /opt/iptv-homelab (code), /etc/iptv-homelab (examples), /etc/init.d/iptv-homelab (service).'
[ "$mode" = '--apply' ] || { printf '%s\n' 'Plan only; no changes. --apply installs files but does not enable/start services.'; exit 0; }
[ "$(id -u)" = 0 ] || { printf '%s\n' 'Installation requires root.' >&2; exit 1; }
[ -r /etc/openwrt_release ] || { printf '%s\n' 'Installer requires OpenWrt/iStoreOS. Other systems: use manual instructions.' >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { printf '%s\n' 'Perl required.' >&2; exit 1; }
for dir in /opt/iptv-homelab /etc/iptv-homelab; do
    [ ! -L "$dir" ] || { printf '%s\n' 'Refusing symlink installation directory.' >&2; exit 1; }
done
perl -MIO::Socket::INET -MIO::Select -MPOSIX -MFcntl -MSocket -e 1
for name in iptv_gateway.pl iptv_dhcp.pl iptv_access.pl; do perl -c "$base/$name" >/dev/null; done
# Keep file-only rollback material; don't copy subscriber configuration into it.
stamp=$(date +%Y-%m-%d_%H-%M-%S)
umask 077
mkdir -p /opt/iptv-homelab /etc/iptv-homelab
backup=/etc/iptv-homelab/package-backup-$stamp
mkdir "$backup"
for name in IptvConfig.pm iptv_gateway.pl iptv_dhcp.pl iptv_access.pl; do
    [ ! -L "/opt/iptv-homelab/$name" ] || exit 1
    if [ -f "/opt/iptv-homelab/$name" ]; then cp -p "/opt/iptv-homelab/$name" "$backup/$name"; fi
    cp "$base/$name" "/opt/iptv-homelab/$name"
    chmod 644 "/opt/iptv-homelab/$name"
done
[ ! -L /etc/init.d/iptv-homelab ] || exit 1
[ ! -f /etc/init.d/iptv-homelab ] || cp -p /etc/init.d/iptv-homelab "$backup/iptv-homelab.init"
cp "$base/iptv-homelab.init" /etc/init.d/iptv-homelab
chmod 755 /etc/init.d/iptv-homelab
cp "$base/iptv.conf.example" /etc/iptv-homelab/iptv.conf.example
cp "$base/channels.example.m3u" /etc/iptv-homelab/channels.example.m3u
printf '%s\n' 'Files installed. Existing private config unchanged; service NOT started or enabled. Read RUNTIME.md.'
