#!/usr/bin/env bash
# install.sh - deploy node-maintenance on a Rocky 9 node. Run as root from the repo root.
#   sudo ./install.sh                 cron
#   sudo USE_TIMER=1 ./install.sh     systemd timer instead of cron
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
: "${USE_TIMER:=0}"

dnf -y install dnf-utils util-linux >/dev/null

install -D -m 0755 "$SRC/bin/node-maintenance.sh"    /usr/local/sbin/node-maintenance.sh
install -D -m 0755 "$SRC/bin/bootstrap-gpu-node.sh"  /usr/local/sbin/bootstrap-gpu-node.sh
install -D -m 0644 "$SRC/logrotate/node-maintenance" /etc/logrotate.d/node-maintenance
install -d -m 0750 /var/log/node-maintenance

if [[ -e /etc/sysconfig/node-maintenance ]]; then
    install -D -m 0644 "$SRC/config/node-maintenance.env" /etc/sysconfig/node-maintenance.new
    echo "kept existing config, new version at /etc/sysconfig/node-maintenance.new"
else
    install -D -m 0644 "$SRC/config/node-maintenance.env" /etc/sysconfig/node-maintenance
fi

if [[ $USE_TIMER -eq 1 ]]; then
    install -D -m 0644 "$SRC/systemd/node-maintenance.service" /etc/systemd/system/node-maintenance.service
    install -D -m 0644 "$SRC/systemd/node-maintenance.timer"   /etc/systemd/system/node-maintenance.timer
    rm -f /etc/cron.d/node-maintenance
    systemctl daemon-reload
    systemctl enable --now node-maintenance.timer
    systemctl list-timers node-maintenance.timer --no-pager
else
    install -D -m 0644 "$SRC/cron/node-maintenance" /etc/cron.d/node-maintenance
    systemctl enable --now crond
fi

echo "installed. verify: sudo node-maintenance.sh --dry-run"
