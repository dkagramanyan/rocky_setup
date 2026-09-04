#!/usr/bin/env bash
#>usage: node-maintenance.sh [--clean-only|--update-only] [--dry-run] [--force]
#>  Cleanup and update for Rocky Linux 9 GPU nodes. Kernels are pruned BEFORE
#>  the upgrade so /boot has room for the new initramfs.
#>  Exit: 0 ok | 10 node busy | 20 partial failure | 30 already running
set -uo pipefail

# shellcheck source=/dev/null
[[ -r ${MAINT_CONF:=/etc/sysconfig/node-maintenance} ]] && . "$MAINT_CONF"

: "${MAINT_LOG_DIR:=/var/log/node-maintenance}" "${MAINT_JITTER_SEC:=0}"
: "${MAINT_KEEP_KERNELS:=2}" "${MAINT_DROP_RESCUE:=0}" "${MAINT_BOOT_MIN_FREE_MB:=250}"
: "${MAINT_EXCLUDE_PKGS:=}" "${MAINT_SECURITY_ONLY:=0}" "${MAINT_AUTOREMOVE:=0}"
: "${MAINT_JOURNAL_AGE:=14d}" "${MAINT_JOURNAL_SIZE:=1G}" "${MAINT_LOG_AGE_DAYS:=30}"
: "${MAINT_TMP_AGE_DAYS:=10}" "${MAINT_CACHE_DIRS:=}" "${MAINT_PRUNE_CONTAINERS:=1}"
: "${MAINT_DISABLE_FIREWALL:=1}" "${MAINT_SKIP_IF_BUSY:=1}"
: "${MAINT_REBOOT_MODE:=never}" "${MAINT_REBOOT_DELAY_MIN:=5}" "${MAINT_MAIL_TO:=}"

CLEAN=1 UPDATE=1 DRY=0 FORCE=0 RC=0
while [[ $# -gt 0 ]]; do case $1 in
    --clean-only)  UPDATE=0 ;;
    --update-only) CLEAN=0 ;;
    --dry-run)     DRY=1 ;;
    --force)       FORCE=1 ;;
    -h|--help)     sed -n 's/^#>//p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac; shift; done

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 2; }

mkdir -p "$MAINT_LOG_DIR"
LOG="$MAINT_LOG_DIR/maintenance-$(date +%Y%m%d-%H%M%S).log"
ln -sfn "$LOG" "$MAINT_LOG_DIR/latest.log"
exec > >(tee -a "$LOG") 2>&1

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
sec()  { printf '\n--- %s ---\n' "$*"; }
warn() { log "WARN: $*"; RC=20; }
run()  { if ((DRY)); then log "DRY: $*"; else log "+ $*"; "$@" || warn "rc=$? : $*"; fi; }
busy() {
    nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -q . && return 0
    squeue -h -w "$(hostname -s)" -t RUNNING 2>/dev/null | grep -q . && return 0
    return 1
}

exec 9>/var/lock/node-maintenance.lock
flock -n 9 || { log "another instance is running"; exit 30; }
trap 'log interrupted; exit 20' INT TERM

((MAINT_JITTER_SEC > 0 && DRY == 0)) && sleep $((RANDOM % MAINT_JITTER_SEC))

log "$(hostname -f)  kernel $(uname -r)  $(cat /etc/rocky-release 2>/dev/null)"
sec "disk before"; df -h / /boot /home 2>/dev/null

if ((FORCE == 0 && MAINT_SKIP_IF_BUSY == 1)) && busy; then
    log "GPU or Slurm work in progress, skipping"; exit 10
fi

# --- kernels and /boot -------------------------------------------------------
sec "kernel pruning"
rpm -q kernel-core --qf '  %{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V
if grep -q '^installonly_limit' /etc/dnf/dnf.conf 2>/dev/null; then
    run sed -i "s/^installonly_limit=.*/installonly_limit=$MAINT_KEEP_KERNELS/" /etc/dnf/dnf.conf
elif ((DRY)); then
    log "DRY: append installonly_limit=$MAINT_KEEP_KERNELS to /etc/dnf/dnf.conf"
else
    echo "installonly_limit=$MAINT_KEEP_KERNELS" >> /etc/dnf/dnf.conf
fi
run dnf -y --setopt="installonly_limit=$MAINT_KEEP_KERNELS" remove --oldinstallonly

shopt -s nullglob
for img in /boot/initramfs-*.img; do
    v=${img#/boot/initramfs-}; v=${v%.img}; v=${v%kdump}; v=${v%.}
    [[ $v == *rescue* || -d /lib/modules/$v ]] && continue
    log "orphan artifacts for absent kernel $v"
    run rm -f "/boot/initramfs-$v.img" "/boot/initramfs-${v}kdump.img" \
              "/boot/vmlinuz-$v" "/boot/System.map-$v" "/boot/config-$v" \
              "/boot/symvers-$v.xz" /boot/loader/entries/*"$v".conf
done
((MAINT_DROP_RESCUE)) && run rm -f /boot/*0-rescue* /boot/loader/entries/*0-rescue*.conf
shopt -u nullglob

FREE=$(df -Pm /boot | awk 'NR==2{print $4}')
log "/boot free: ${FREE}MB"
((FREE < MAINT_BOOT_MIN_FREE_MB)) && { warn "/boot below ${MAINT_BOOT_MIN_FREE_MB}MB, upgrade skipped"; UPDATE=0; }

# --- upgrade -----------------------------------------------------------------
if ((UPDATE)); then
    sec "upgrade"
    ARGS=(--refresh); for p in $MAINT_EXCLUDE_PKGS; do ARGS+=("--exclude=$p"); done
    ((MAINT_SECURITY_ONLY)) && ARGS+=(--security)
    dnf check-update "${ARGS[@]}" 2>/dev/null | sed 's/^/  /' || true
    run dnf -y "${ARGS[@]}" upgrade
    dnf autoremove --assumeno 2>&1 | grep -E '^\s+\S+\s+x86_64|Remove' | sed 's/^/  would-remove /' || true
    ((MAINT_AUTOREMOVE)) && run dnf -y autoremove
fi

# --- cleanup -----------------------------------------------------------------
if ((CLEAN)); then
    sec "caches, logs, tmp"
    run dnf clean all
    run journalctl --vacuum-time="$MAINT_JOURNAL_AGE"
    run journalctl --vacuum-size="$MAINT_JOURNAL_SIZE"
    ACT=(-delete); ((DRY)) && ACT=(-printf 'DRY: rm %p\n')
    find /var/log -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.old' \
         -o -name '*.[0-9]' -o -name '*-20[0-9][0-9][0-9][0-9][0-9][0-9]' \) \
         -mtime "+$MAINT_LOG_AGE_DAYS" "${ACT[@]}" 2>/dev/null
    [[ -d /var/lib/systemd/coredump ]] && \
        find /var/lib/systemd/coredump -type f -mtime +7 "${ACT[@]}" 2>/dev/null
    run systemd-tmpfiles --clean
    for d in /tmp /var/tmp /root/.cache/pip /root/.cache/uv /root/.npm/_cacache $MAINT_CACHE_DIRS; do
        [[ -d $d ]] || continue
        log "$(du -sh "$d" 2>/dev/null | cut -f1) in $d"
        ((DRY)) || { find "$d" -xdev -mindepth 1 -type f -atime "+$MAINT_TMP_AGE_DAYS" -delete 2>/dev/null
                     find "$d" -xdev -mindepth 1 -type d -empty -atime "+$MAINT_TMP_AGE_DAYS" -delete 2>/dev/null; }
    done
    if ((MAINT_PRUNE_CONTAINERS)); then
        systemctl is-active --quiet docker && run docker system prune -af --filter until=168h
        command -v podman >/dev/null && run podman system prune -af --filter until=168h
    fi
fi

# --- firewall ----------------------------------------------------------------
if ((MAINT_DISABLE_FIREWALL)); then
    sec "firewalld"
    if systemctl list-unit-files firewalld.service &>/dev/null; then
        run systemctl disable --now firewalld
        run systemctl mask firewalld
    fi
    log "state: $(systemctl is-enabled firewalld 2>&1) / $(systemctl is-active firewalld 2>&1)"
fi

# --- GPU and reboot ----------------------------------------------------------
sec "GPU"
if command -v nvidia-smi >/dev/null; then
    nvidia-smi --query-gpu=index,name,driver_version,memory.used,memory.total,temperature.gpu \
        --format=csv 2>&1 | sed 's/^/  /' \
        || warn "nvidia-smi failed, driver and loaded module likely mismatched, reboot needed"
    command -v dkms >/dev/null && dkms status 2>&1 | sed 's/^/  /'
    modinfo nvidia 2>/dev/null | awk '/^license:/{print "  module license: "$2}'
fi

sec "reboot"
NEED=0
if command -v needs-restarting >/dev/null; then
    needs-restarting -r >/dev/null 2>&1 || NEED=1
else
    [[ $(uname -r) != "$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)" ]] && NEED=1
fi
if ((NEED)); then
    log "reboot required (mode=$MAINT_REBOOT_MODE)"
    case $MAINT_REBOOT_MODE in
        if-needed) run shutdown -r "+$MAINT_REBOOT_DELAY_MIN" "maintenance reboot" ;;
        if-idle)   busy && log "busy, not rebooting" \
                        || run shutdown -r "+$MAINT_REBOOT_DELAY_MIN" "maintenance reboot" ;;
        *)         log "not rebooting, do it manually" ;;
    esac
else
    log "no reboot required"
fi

sec "disk after"; df -h / /boot /home 2>/dev/null
log "exit $RC"
[[ -n $MAINT_MAIL_TO ]] && command -v mail >/dev/null && \
    mail -s "[maint] $(hostname -s) rc=$RC$( ((NEED)) && echo ' REBOOT-NEEDED')" "$MAINT_MAIL_TO" < "$LOG"
exit $RC
