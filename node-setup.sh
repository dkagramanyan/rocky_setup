#!/usr/bin/env bash
#>usage: node-setup.sh [command] [options]
#>
#>  Rocky Linux 9 GPU node: one-shot provisioning and unattended maintenance.
#>  Run with no arguments for the interactive menu.
#>
#>Commands
#>  bootstrap [stages]  provisioning: driver, CUDA, docker, firewall, versionlock
#>  maintenance         clean + update now
#>  install             deploy this script and the schedule (default: cron)
#>  uninstall           remove the schedule, keep script, config and logs
#>  status              what is installed, when it next runs
#>  --check             read-only report of this node: version locks, driver,
#>                      DKMS, kdump, crash dumps, GPUStack. Exit 1 on any problem
#>  --update [--dry-run]
#>                      guarded interactive update of this node: lock menu,
#>                      drain, upgrade, pre-reboot gate, reboot. Run it again
#>                      after the reboot to verify, start GPUStack and watch
#>
#>Maintenance options
#>  --clean-only        no package upgrade
#>  --update-only       kernel pruning + upgrade only
#>  --dry-run           print, change nothing
#>  --force             ignore the busy guard
#>  --scheduled         honour MAINT_BIWEEKLY; used by the cron job and the timer
#>
#>Install options
#>  --timer             systemd timer instead of cron
#>
#>Exit: 0 ok | 10 node busy | 20 partial failure | 30 already running
set -uo pipefail

VERSION="2.0"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"
SETUP_URL="${SETUP_URL:-https://raw.githubusercontent.com/dkagramanyan/rocky_setup/main/node-setup.sh}"

BIN=/usr/local/sbin/node-setup.sh
CONF=/etc/sysconfig/node-maintenance
CRON=/etc/cron.d/node-maintenance
UNIT=/etc/systemd/system/node-maintenance.service
TIMER=/etc/systemd/system/node-maintenance.timer
LOGROTATE=/etc/logrotate.d/node-maintenance

# --check / --update
REPORT_DIR=./reports                       # run logs and summary-<host>.env
STATE_DIR=/var/lib/node-setup              # last-check time, unfinished update
CRASH_DIR=/var/crash
VLOCK=/etc/dnf/plugins/versionlock.list
CRASHDEBUG_CONF=/etc/sysctl.d/90-crashdebug.conf
TIMER_SIG='__run_timers|enqueue_timer|timer.c:1686|vector_cleanup'
WATCH_MIN=15

# schedule: every second ISO week, Saturday 08:00 Europe/Moscow (GMT+3).
# The "every second week" half is MAINT_BIWEEKLY inside the script, so cron and
# the timer stay a plain weekly expression and both get the same behaviour.
SCHED_CRON='0 8 * * 6'
SCHED_CRON_TZ='Europe/Moscow'
SCHED_ONCALENDAR='Sat *-*-* 08:00:00 Europe/Moscow'
SCHED_ONCALENDAR_FALLBACK='Sat *-*-* 05:00:00 UTC'
SCHED_SHORT='every 2 weeks, Saturday 08:00 MSK'
SCHED_HUMAN="$SCHED_SHORT (even ISO weeks)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[1;36m'; NC='\033[0m'

banner() {
    echo -e "${CYAN}"
    echo "┌────────────────────────────────────────────┐"
    echo "│ ██████╗  ██████╗  ██████╗██╗  ██╗██╗   ██╗ │"
    echo "│ ██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝╚██╗ ██╔╝ │"
    echo "│ ██████╔╝██║   ██║██║     █████╔╝  ╚████╔╝  │"
    echo "│ ██╔══██╗██║   ██║██║     ██╔═██╗   ╚██╔╝   │"
    echo "│ ██║  ██║╚██████╔╝╚██████╗██║  ██╗   ██║    │"
    echo "│ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝   ╚═╝    │"
    echo "└────────────────────────────────────────────┘"
    echo "rocky9-gpu-node — provisioning and maintenance for Rocky Linux 9 GPU nodes"
    echo "Version: $VERSION"
    echo "Schedule: $SCHED_HUMAN"
    echo -e "${NC}"
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
require_root() { [[ $EUID -eq 0 ]] || { log_error "run as root (sudo $0)"; return 1; }; }

# --- configuration -----------------------------------------------------------
# shellcheck source=/dev/null
[[ -r ${MAINT_CONF:=$CONF} ]] && . "$MAINT_CONF"

: "${MAINT_LOG_DIR:=/var/log/node-maintenance}" "${MAINT_JITTER_SEC:=0}"
: "${MAINT_BIWEEKLY:=1}"
: "${MAINT_KEEP_KERNELS:=2}" "${MAINT_DROP_RESCUE:=0}" "${MAINT_BOOT_MIN_FREE_MB:=250}"
: "${MAINT_EXCLUDE_PKGS:=}" "${MAINT_SECURITY_ONLY:=0}" "${MAINT_AUTOREMOVE:=0}"
: "${MAINT_JOURNAL_AGE:=14d}" "${MAINT_JOURNAL_SIZE:=1G}" "${MAINT_LOG_AGE_DAYS:=30}"
: "${MAINT_TMP_AGE_DAYS:=10}" "${MAINT_CACHE_DIRS:=}" "${MAINT_PRUNE_CONTAINERS:=1}"
: "${MAINT_FSTRIM:=1}"
: "${MAINT_DISABLE_FIREWALL:=1}" "${MAINT_SKIP_IF_BUSY:=1}"
: "${MAINT_REBOOT_MODE:=never}" "${MAINT_REBOOT_DELAY_MIN:=5}" "${MAINT_MAIL_TO:=}"

: "${DRIVER_STREAM:=nvidia-driver:open-dkms}"   # open modules, required for Ada/Blackwell
: "${DOCKER_DATA_ROOT:=/home/docker-data}"      # / is only 70G on these nodes
: "${CONTAINERD_DATA_ROOT:=/home/containerd-data}"

# =============================================================================
# maintenance — recurring cleanup and update. Runs in a subshell so its log
# redirection and traps do not leak back into the menu.
# =============================================================================
maintenance() (
    CLEAN=1 UPDATE=1 DRY=0 FORCE=0 SCHEDULED=0 RC=0
    while [[ $# -gt 0 ]]; do case $1 in
        --clean-only)  UPDATE=0 ;;
        --update-only) CLEAN=0 ;;
        --dry-run)     DRY=1 ;;
        --force)       FORCE=1 ;;
        --scheduled)   SCHEDULED=1 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac; shift; done

    [[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 2; }

    # every second week: run only on even ISO weeks
    if ((SCHEDULED && MAINT_BIWEEKLY)); then
        WEEK=$((10#$(date +%V)))
        ((WEEK % 2 == 0)) || { echo "biweekly: ISO week $WEEK is odd, nothing to do"; exit 0; }
    fi

    mkdir -p "$MAINT_LOG_DIR"
    LOG="$MAINT_LOG_DIR/maintenance-$(date +%Y%m%d-%H%M%S).log"
    ln -sfn "$LOG" "$MAINT_LOG_DIR/latest.log"
    exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG")) 2>&1

    # One line per step on screen; command output goes to the log only.
    log()  { printf '  %s\n' "$*"; }
    ok()   { ((DRY)) || printf '  %b✓%b %s\n' "$GREEN" "$NC" "$*"; }
    sec()  { printf '%b%s%b\n' "$CYAN" "$*" "$NC"; }
    warn() { printf '  %b!!%b %s\n' "$YELLOW" "$NC" "$*"; RC=20; }
    quiet() { { printf '%s  + %s\n' "$(date '+%F %T')" "$*"; "$@"; } >> "$LOG" 2>&1; }
    run()  { if ((DRY)); then log "DRY: $*"; else quiet "$@" || warn "failed (exit $?): $*  (see $LOG)"; fi; }
    disk() { df -P / /boot /home 2>/dev/null | awk 'NR > 1 { printf "%s%s %s", (NR > 2 ? "  " : ""), $6, $5 } END { print "" }'; }

    exec 9>/var/lock/node-maintenance.lock
    flock -n 9 || { log "another instance is running"; exit 30; }
    trap 'log interrupted; exit 20' INT TERM

    # Jitter spreads a cluster out when cron fires every node at 08:00. An
    # interactive run must start now, so only --scheduled runs wait, and the
    # wait is announced rather than looking like a hang.
    if ((SCHEDULED && MAINT_JITTER_SEC > 0 && DRY == 0)); then
        JITTER=$((RANDOM % MAINT_JITTER_SEC))
        log "jitter: sleeping ${JITTER}s of MAINT_JITTER_SEC=$MAINT_JITTER_SEC before starting"
        sleep "$JITTER"
    fi

    sec "$(hostname -f)  $(date '+%F %T')"
    log "kernel $(uname -r), $(cat /etc/rocky-release 2>/dev/null)"
    log "disk: $(disk)"
    df -h / /boot /home >> "$LOG" 2>&1

    if ((FORCE == 0 && MAINT_SKIP_IF_BUSY == 1)) && node_busy; then
        log "GPU or Slurm work in progress, skipping"
        busy_reason | sed 's/^/  /'
        log "run with --force (menu: 'Clean up') to clean anyway;"
        log "with MAINT_REBOOT_MODE=$MAINT_REBOOT_MODE a forced run will not reboot the node"
        exit 10
    fi

    # --- kernels and /boot ---------------------------------------------------
    sec "kernels"
    KBEFORE=$(kernels_installed)
    if grep -q '^installonly_limit' /etc/dnf/dnf.conf 2>/dev/null; then
        run sed -i "s/^installonly_limit=.*/installonly_limit=$MAINT_KEEP_KERNELS/" /etc/dnf/dnf.conf
    elif ((DRY)); then
        log "DRY: append installonly_limit=$MAINT_KEEP_KERNELS to /etc/dnf/dnf.conf"
    else
        echo "installonly_limit=$MAINT_KEEP_KERNELS" >> /etc/dnf/dnf.conf
    fi
    if (( $(grep -c . <<<"$KBEFORE") > MAINT_KEEP_KERNELS )); then
        run dnf -y --setopt="installonly_limit=$MAINT_KEEP_KERNELS" remove --oldinstallonly
    fi
    GONE=$(comm -23 <(sort <<<"$KBEFORE") <(kernels_installed | sort) | tr '\n' ' ')
    if [[ -n $GONE ]]; then ok "removed old kernel $GONE"
    else ok "$(grep -c . <<<"$KBEFORE") kernels installed, nothing to remove"; fi

    shopt -s nullglob
    for img in /boot/initramfs-*.img; do
        v=${img#/boot/initramfs-}; v=${v%.img}; v=${v%kdump}; v=${v%.}
        [[ $v == *rescue* || -d /lib/modules/$v ]] && continue
        log "orphan files of absent kernel $v removed"
        run rm -f "/boot/initramfs-$v.img" "/boot/initramfs-${v}kdump.img" \
                  "/boot/vmlinuz-$v" "/boot/System.map-$v" "/boot/config-$v" \
                  "/boot/symvers-$v.xz" /boot/loader/entries/*"$v".conf
    done
    ((MAINT_DROP_RESCUE)) && run rm -f /boot/*0-rescue* /boot/loader/entries/*0-rescue*.conf
    shopt -u nullglob

    FREE=$(df -Pm /boot | awk 'NR==2{print $4}')
    log "/boot free: ${FREE}MB"
    ((FREE < MAINT_BOOT_MIN_FREE_MB)) && { warn "/boot below ${MAINT_BOOT_MIN_FREE_MB}MB, upgrade skipped"; UPDATE=0; }

    # --- upgrade -------------------------------------------------------------
    if ((UPDATE)); then
        # A lock makes dnf skip a package without a word. Say so.
        sec "packages"
        LOCKS=$(locks_now) || warn "repoquery failed, cannot tell whether the locks hold anything back"
        if [[ -n $LOCKS ]]; then
            lock_detail <<<"$LOCKS" >> "$LOG"
            lock_block "$(hostname -s)" <<<"$LOCKS" | sed 's/^/  /' \
                && warn "these locks are skipped by this upgrade (to update them: sudo $BIN --update)"
        fi

        ARGS=(--refresh); for p in $MAINT_EXCLUDE_PKGS; do ARGS+=("--exclude=$p"); done
        ((MAINT_SECURITY_ONLY)) && ARGS+=(--security)
        PBEFORE=$(rpm -qa | sort)
        run dnf -y "${ARGS[@]}" upgrade
        if ((DRY)); then
            log "DRY: $(dnf -q "${ARGS[@]}" repoquery --upgrades --latest-limit=1 2>/dev/null | grep -c .) packages would be upgraded"
        else
            ok "upgrade: $(comm -13 <(echo "$PBEFORE") <(rpm -qa | sort) | grep -c .) packages installed or updated"
        fi
        AUTO=$(dnf autoremove --assumeno 2>&1 | grep -E '^\s+\S+\s+(x86_64|noarch)' || true)
        if [[ -n $AUTO ]]; then
            { echo "autoremove would remove:"; echo "$AUTO"; } >> "$LOG"
            log "autoremove would remove $(grep -c . <<<"$AUTO") packages (MAINT_AUTOREMOVE=$MAINT_AUTOREMOVE, list in the log)"
        fi
        ((MAINT_AUTOREMOVE)) && run dnf -y autoremove
    fi

    # --- cleanup -------------------------------------------------------------
    if ((CLEAN)); then
        sec "cleanup"
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
            if is_model_store "$d"; then
                log "SKIP $d — looks like a model store, not touching it"
                continue
            fi
            echo "$(du -sh "$d" 2>/dev/null | cut -f1) in $d" >> "$LOG"
            ((DRY)) || { find "$d" -xdev -mindepth 1 -type f -atime "+$MAINT_TMP_AGE_DAYS" -delete 2>/dev/null
                         find "$d" -xdev -mindepth 1 -type d -empty -atime "+$MAINT_TMP_AGE_DAYS" -delete 2>/dev/null; }
        done
        if ((MAINT_PRUNE_CONTAINERS)); then
            # No -a. `prune -a` deletes every image that is not currently in a
            # running container, which on these nodes means the images people
            # actually work with. Without it only stopped containers, unused
            # networks, dangling (untagged) layers and build cache go.
            systemctl is-active --quiet docker && run docker system prune -f --filter until=168h
            command -v podman >/dev/null && run podman system prune -f --filter until=168h
        fi
        ok "dnf cache, journal, old logs, tmp, unused containers"

        lvm_report >> "$LOG"
        # fstrim frees nothing in df; it tells the SSD which blocks the
        # filesystems stopped using, which is what keeps a thin pool honest.
        if ((MAINT_FSTRIM)); then
            if command -v fstrim >/dev/null; then run fstrim -av; ok "fstrim"
            else log "fstrim not installed (dnf install util-linux), skipping trim"; fi
        fi
    fi

    # --- firewall ------------------------------------------------------------
    if ((MAINT_DISABLE_FIREWALL)) && [[ $(systemctl is-enabled firewalld 2>/dev/null) != masked ]]; then
        if systemctl list-unit-files firewalld.service &>/dev/null; then
            run systemctl disable --now firewalld
            run systemctl mask firewalld
            log "firewalld: $(systemctl is-enabled firewalld 2>&1) / $(systemctl is-active firewalld 2>&1)"
        fi
    fi

    # --- GPU and reboot ------------------------------------------------------
    sec "GPU"
    if command -v nvidia-smi >/dev/null; then
        if GPU=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1); then
            log "$GPU, module license $(modinfo -F license nvidia 2>/dev/null)"
        else
            warn "nvidia-smi failed, driver and loaded module likely mismatched, reboot needed"
        fi
        command -v dkms >/dev/null && dkms status >> "$LOG" 2>&1
    fi

    NEED=0
    if command -v needs-restarting >/dev/null; then
        needs-restarting -r >/dev/null 2>&1 || NEED=1
    else
        [[ $(uname -r) != "$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)" ]] && NEED=1
    fi
    if ((NEED)); then
        case $MAINT_REBOOT_MODE in
            if-needed) log "reboot required, rebooting in $MAINT_REBOOT_DELAY_MIN min"
                       run shutdown -r "+$MAINT_REBOOT_DELAY_MIN" "maintenance reboot" ;;
            if-idle)   if node_busy; then log "reboot required, node busy, not rebooting"
                       else log "reboot required, rebooting in $MAINT_REBOOT_DELAY_MIN min"
                            run shutdown -r "+$MAINT_REBOOT_DELAY_MIN" "maintenance reboot"; fi ;;
            *)         log "reboot required, do it manually (or menu: Update)" ;;
        esac
    else
        log "no reboot required"
    fi

    sec "done"
    log "disk: $(disk)"
    log "exit $RC, full log: $LOG"
    [[ -n $MAINT_MAIL_TO ]] && command -v mail >/dev/null && \
        mail -s "[maint] $(hostname -s) rc=$RC$( ((NEED)) && echo ' REBOOT-NEEDED')" "$MAINT_MAIL_TO" < "$LOG"
    exit $RC
)

# Model weights are expensive to re-download and are read rarely, so atime
# ageing would delete exactly the wrong files. Anything matching this is never
# cleaned, however it got into MAINT_CACHE_DIRS.
is_model_store() {
    local d
    d=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case $d in
        *gpustack*|*huggingface*|*"/hub"|*"/models"|*"/model"|*ollama*|*torch/hub*|*.cache/modelscope*) return 0 ;;
        *) return 1 ;;
    esac
}

# volume groups and logical volumes. Read-only; snapshots show an origin.
lvm_report() {
    command -v vgs >/dev/null || { echo "  no LVM tools installed"; return 0; }
    # --separator keeps empty columns, so origin cannot be confused with data_percent
    vgs --noheadings --separator '|' --units g -o vg_name,vg_size,vg_free 2>/dev/null \
        | sed -e 's/^ *//' -e 's/ *$//' | awk -F'|' '{printf "  vg %-8s size %-10s free %s\n", $1, $2, $3}'
    lvs --noheadings --separator '|' --units g -o lv_name,vg_name,lv_size,origin,data_percent 2>/dev/null \
        | sed -e 's/^ *//' -e 's/ *$//' | awk -F'|' '{
              extra = ($4 != "") ? "  snapshot of " $4 : ""
              if ($5 != "") extra = extra "  data " $5 "%"
              printf "  lv %-8s vg %-6s size %-10s%s\n", $1, $2, $3, extra
          }'
    return 0
}

# what exactly is holding the node, printed when the guard trips
# shellcheck disable=SC2001
busy_reason() {
    local gpu slurm
    gpu=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null)
    [[ -n $gpu ]] && { echo "GPU compute processes (pid, name, memory):"; sed 's/^/  /' <<<"$gpu"; }
    slurm=$(squeue -h -w "$(hostname -s)" -t RUNNING -o '%i %u %j' 2>/dev/null)
    [[ -n $slurm ]] && { echo "Slurm jobs on this host (id, user, name):"; sed 's/^/  /' <<<"$slurm"; }
    return 0
}

node_busy() {
    nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -q . && return 0
    squeue -h -w "$(hostname -s)" -t RUNNING 2>/dev/null | grep -q . && return 0
    return 1
}

# =============================================================================
# bootstrap — one-shot provisioning of a fresh node. Reboots twice: after the
# nouveau blacklist and after the driver install. Re-run after each reboot, it
# skips completed stages.
# =============================================================================
bootstrap() (
    set -e
    require_root
    stages="${*:-base repos nouveau driver cuda toolkit docker firewall lock}"
    say()  { printf '\n=== %s ===\n' "$*"; }
    have() { [[ " $stages " == *" $1 "* ]]; }

    have base && { say "base packages"
        dnf upgrade --refresh -y
        dnf install -y epel-release dnf-utils dnf-plugin-versionlock rsync
        dnf groupinstall -y "Development Tools"
        dnf install -y "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)" \
                       dkms elfutils-libelf-devel libglvnd-devel
    }

    have repos && { say "repositories"
        dnf config-manager --set-enabled crb
        dnf config-manager --add-repo \
            https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
        dnf clean all && dnf makecache
    }

    have nouveau && { say "nouveau blacklist"
        lspci | grep -i nvidia || { log_error "no NVIDIA device on the PCI bus"; exit 1; }
        if lsmod | grep -q '^nouveau'; then
            grubby --args="rd.driver.blacklist=nouveau nouveau.modeset=0" --update-kernel=ALL
            dracut --force
            log_warning "REBOOT NOW, then run bootstrap again"; exit 0
        fi
        log_success "nouveau not loaded"
    }

    have driver && { say "NVIDIA driver ($DRIVER_STREAM)"
        # ELRepo packages conflict with the CUDA-repo module stream
        dnf remove -y 'kmod-nvidia*' 'nvidia-x11-drv*' 2>/dev/null || true
        dnf module reset  -y nvidia-driver
        dnf module enable -y "$DRIVER_STREAM"
        dnf module install -y "$DRIVER_STREAM"
        mokutil --sb-state 2>/dev/null | grep -qi enabled \
            && log_warning "Secure Boot is on, unsigned modules will not load"
        log_warning "REBOOT NOW, then run bootstrap again"
    }

    have cuda && { say "CUDA toolkit"
        dnf install -y cuda-toolkit
        cat > /etc/profile.d/cuda.sh <<'EOF'
export CUDA_HOME=/usr/local/cuda
export PATH=$CUDA_HOME/bin:$PATH
export LD_LIBRARY_PATH=$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}
EOF
        chmod 0644 /etc/profile.d/cuda.sh
    }

    have toolkit && { say "verification"
        modinfo nvidia | awk '/^license:/{print "module license: "$2"  (expect GPL for open modules)"}'
        nvidia-smi || log_error "nvidia-smi failed, check: dmesg | grep -E 'NVRM|nvidia'"
        /usr/local/cuda/bin/nvcc --version || true
    }

    have docker && { say "docker on /home"
        if command -v docker >/dev/null; then
            if [[ $(docker info -f '{{.DockerRootDir}}' 2>/dev/null) != "$DOCKER_DATA_ROOT" ]]; then
                systemctl stop docker docker.socket containerd || true
                mkdir -p "$DOCKER_DATA_ROOT" "$CONTAINERD_DATA_ROOT"
                rsync -a /var/lib/docker/ "$DOCKER_DATA_ROOT/"
                rsync -a /var/lib/containerd/ "$CONTAINERD_DATA_ROOT/"
                mkdir -p /etc/docker
                python3 - "$DOCKER_DATA_ROOT" <<'EOF'
import json, sys, pathlib
p = pathlib.Path("/etc/docker/daemon.json")
d = json.loads(p.read_text()) if p.exists() and p.read_text().strip() else {}
d["data-root"] = sys.argv[1]
p.write_text(json.dumps(d, indent=2) + "\n")
EOF
                rm -rf /var/lib/containerd && ln -sfn "$CONTAINERD_DATA_ROOT" /var/lib/containerd
                systemctl start containerd docker
                log_warning "old data left in /var/lib/docker, remove it once 'docker images' looks right"
            fi
            # shellcheck source=/dev/null
            distribution=$(. /etc/os-release; echo "$ID$VERSION_ID")
            curl -fsSL "https://nvidia.github.io/nvidia-container-toolkit/$distribution/nvidia-container-toolkit.repo" \
                -o /etc/yum.repos.d/nvidia-container-toolkit.repo
            dnf clean expire-cache && dnf install -y nvidia-container-toolkit
            nvidia-ctk runtime configure --runtime=docker
            systemctl restart docker
            docker run --rm --gpus all nvidia/cuda:12.4.0-base-rockylinux9 nvidia-smi || true
        else
            log_warning "docker not installed, skipping"
        fi
    }

    have firewall && { say "firewalld off"
        systemctl disable --now firewalld 2>/dev/null || true
        systemctl mask firewalld 2>/dev/null || true
        log_info "firewalld: $(systemctl is-enabled firewalld 2>&1) / $(systemctl is-active firewalld 2>&1)"
    }

    have lock && { say "versionlock"
        dnf versionlock add 'nvidia-driver*' 'cuda*' 'kmod-nvidia*' || true
        dnf versionlock list
        log_info "mirror this in MAINT_EXCLUDE_PKGS in $CONF"
    }

    say "done"
)

# =============================================================================
# --check / --update — run on each node with sudo. Version locks are made
# visible, the update drains GPUStack, gates the reboot on a built nvidia
# module and keeps gpustack-worker from auto-starting until the node has
# survived a watch window. Background: cn-002 crash-looped on a versionlocked
# 610.57.04 driver that the routine dnf upgrade skipped for two months.
# =============================================================================

# key=value summary of one node, written by probe, read by everything after it
kv()  { printf '%s=%s\n' "$1" "$2" >> "$KV"; }
kvg() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }      # kvg file key

evr_ver() {     # 3:615.71.09-1.el9 -> 615.71.09
    [[ -z $1 || $1 == - ]] && { echo -; return 0; }
    local v=${1#*:}; echo "${v%-*}"
}
evr_newer() {   # true if EVR $1 is newer than EVR $2
    local a=$1 b=$2
    [[ $a == *:* ]] || a="0:$a"
    [[ $b == *:* ]] || b="0:$b"
    [[ $a != "$b" && $(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1) == "$a" ]]
}
rpm_evr() {     # installed EVR of a package, - when absent
    rpm -q --qf '%{EVR}\n' "$1" 2>/dev/null | grep -v 'not installed' | sort -V | tail -n 1 | grep . || echo -
}
kernels_installed() { rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V; }
boot_id() { cat /proc/sys/kernel/random/boot_id; }
irq_state() { echo "$(systemctl is-active irqbalance 2>/dev/null)/$(systemctl is-enabled irqbalance 2>/dev/null || true)"; }
unit_state() { echo "$(systemctl is-enabled "$1" 2>/dev/null || true)/$(systemctl is-active "$1" 2>/dev/null)"; }

# --- version locks -----------------------------------------------------------
lock_group() {
    case $1 in
        nvidia-container*|libnvidia-container*)             echo other ;;
        nvidia-*|kmod-nvidia*|libnvidia-*|xorg-x11-nvidia*) echo nvidia ;;
        cuda*|libcu*|libnpp*|libnv*|nsight*|gds-tools*)     echo cuda ;;
        *)                                                  echo other ;;
    esac
}
lock_entries() { dnf -q versionlock list 2>/dev/null | sed 's/[[:space:]]*$//' | grep -vE '^(#|!|$)'; }
lock_spec() { local s=${1%.\*}; s=${s%.x86_64}; s=${s%.noarch}; echo "${s%.i686}"; }
lock_name() { local s; s=$(lock_spec "$1"); echo "${s%-*-*}"; }
lock_evr()  { local s n; s=$(lock_spec "$1"); n=$(lock_name "$1"); echo "${s#"$n"-}"; }
# entry|comment: the comment dnf writes above each entry ("Added lock on <date>")
lock_dates() {
    awk '/^#/ { c = $0; sub(/^#[[:space:]]*/, "", c); gsub(/\|/, "/", c); next } NF { print $1 "|" c }' "$VLOCK" 2>/dev/null
}
# name|evr of the newest version in the enabled repos, the lock ignored
repo_newest() {
    dnf -q --refresh --disableplugin=versionlock repoquery --latest-limit=1 \
        --qf '%{name}|%{evr}\n' "$@" | sort -t'|' -k1,1 -k2,2V
}
newest_of() { awk -F'|' -v n="$1" '$1 == n { v = $2 } END { print (v == "" ? "-" : v) }' <<<"$2"; }

# One line per lock: status|group|name|locked-evr|newest-evr|since|comment.
# BEHIND: the repos carry a newer version than the lock allows.
# CURRENT: the locked version is the newest. UNKNOWN: repoquery failed.
lock_scan() {   # $1 entries, $2 repo_newest output, $3 lock_dates output, $4 1 if repoquery worked
    local e name evr newest st c since
    while read -r e; do
        [[ -n $e ]] || continue
        name=$(lock_name "$e"); evr=$(lock_evr "$e"); newest=$(newest_of "$name" "$2")
        if (($4 == 0)); then st=UNKNOWN
        elif [[ $newest != - ]] && evr_newer "$newest" "$evr"; then st=BEHIND
        else st=CURRENT; fi
        c=$(awk -F'|' -v e="$e" '$1 == e { print $2; exit }' <<<"$3")
        if [[ $c =~ ^Added\ lock\ on\ (.*)$ ]]; then
            since=$(date -d "${BASH_REMATCH[1]}" +%F 2>/dev/null || echo "${BASH_REMATCH[1]}"); c=
        elif [[ $c =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then since=${BASH_REMATCH[1]}
        else since='?'; fi
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$st" "$(lock_group "$name")" "$name" "$evr" "$newest" "$since" "$c"
    done <<<"$1"
}
locks_now() {   # lock_scan for this node; fails if repoquery failed
    local e entries avail ok=1 names=()
    entries=$(lock_entries)
    [[ -n $entries ]] || return 0
    while read -r e; do names+=("$(lock_name "$e")"); done <<<"$entries"
    avail=$(repo_newest "${names[@]}") || ok=0
    lock_scan "$entries" "$avail" "$(lock_dates)" "$ok"
    ((ok))
}
lock_detail() {
    awk -F'|' '{ printf "    %-14s %-6s %-34s %-22s %-22s since %s%s\n", "LOCKED-" $1, $2, $3, $4,
                 ($5 == "-" ? "(not in repos)" : $5), $6, ($7 == "" ? "" : "  # " $7) }'
}
# The warning block. Succeeds only if something is held back.
lock_block() {   # stdin: lock_scan lines, $1 node name
    awk -F'|' -v node="$1" '
        function ver(e) { sub(/^[0-9]+:/, "", e); sub(/-[^-]*$/, "", e); return e }
        $1 == "BEHIND" {
            n++; cnt[$2]++
            rep = ($3 ~ /^(nvidia-open|kmod-nvidia-open-dkms|cuda-toolkit)/)
            if (!($2 in from) || (rep && !isrep[$2])) {
                from[$2] = ver($4); to[$2] = ver($5); since[$2] = $6; isrep[$2] = rep
            }
        }
        END {
            if (!n) exit 1
            printf "!! %s: %d packages version-locked behind available updates\n", node, n
            lbl["nvidia"] = "NVIDIA driver"; lbl["cuda"] = "CUDA toolkit"; lbl["other"] = "other"
            split("nvidia cuda other", order, " ")
            for (i = 1; i <= 3; i++) {
                g = order[i]
                if (!(g in from)) { printf "   %-15s none\n", lbl[g]; continue }
                printf "   %-15s %s -> %s available   (locked since %s)%s\n", lbl[g], from[g], to[g], since[g],
                       (cnt[g] > 1 ? "   [" cnt[g] " packages]" : "")
            }
        }'
}

# group|label|summary per lock group, for the update menu
lock_groups() {
    awk -F'|' '
        function ver(e) { sub(/^[0-9]+:/, "", e); sub(/-[^-]*$/, "", e); return e }
        { n[$2]++; if (!($2 in since)) since[$2] = $6
          if ($1 == "BEHIND") { b[$2]++; rep = ($3 ~ /^(nvidia-open|kmod-nvidia-open-dkms|cuda-toolkit)/)
              if (!($2 in from) || (rep && !isrep[$2])) { from[$2] = ver($4); to[$2] = ver($5); isrep[$2] = rep } } }
        END {
            lbl["nvidia"] = "NVIDIA driver"; lbl["cuda"] = "CUDA toolkit"; lbl["other"] = "other"
            split("nvidia cuda other", order, " ")
            for (i = 1; i <= 3; i++) {
                g = order[i]; if (!n[g]) continue
                if (b[g]) printf "%s|%s|%s -> %s available   (%d locked, %d behind, since %s)\n", g, lbl[g], from[g], to[g], n[g], b[g], since[g]
                else      printf "%s|%s|%d locked, already newest\n", g, lbl[g], n[g]
            }
        }'
}

# --- crash dumps -------------------------------------------------------------
# A dump is a kdump directory in /var/crash or a file in /var/crash/logs.
dump_units() {   # "mtime path"
    [[ -d $CRASH_DIR ]] || return 0
    {
        find "$CRASH_DIR" -mindepth 1 -maxdepth 1 -type d ! -name logs -printf '%T@ %p\n'
        [[ ! -d $CRASH_DIR/logs ]] || find "$CRASH_DIR/logs" -type f -printf '%T@ %p\n'
    } 2>/dev/null | sed 's/\.[0-9]*//'
}
dumps_since() { dump_units | awk -v s="$1" '$1 > s' | grep -c . || true; }
# -I skips binary files, so the vmcores are not read
timer_units() {   # dumps with a text file matching the timer signature
    [[ -d $CRASH_DIR ]] || return 0
    grep -rlIE "$TIMER_SIG" --exclude=vmcore --exclude=vmcore.flat "$CRASH_DIR" 2>/dev/null \
        | awk -v root="$CRASH_DIR" '{ rel = substr($0, length(root) + 2)
              if (rel ~ /^logs\//) print; else { split(rel, p, "/"); print root "/" p[1] } }' | sort -u
}
cpu_hist() {     # CPU12:190 CPU3:4
    [[ -d $CRASH_DIR ]] || return 0
    grep -rhoIE 'CPU: [0-9]+ PID: [0-9]+ (at|Comm)' --exclude=vmcore --exclude=vmcore.flat "$CRASH_DIR" 2>/dev/null \
        | awk '{ print $2 }' | sort | uniq -c | sort -rn \
        | awk '{ printf "%sCPU%s:%s", (NR > 1 ? " " : ""), $2, $1 } END { print "" }'
}
# what crash-cleanup.service runs, and the lines in its scripts that delete
cleanup_info() {
    local f
    systemctl cat crash-cleanup.service >/dev/null 2>&1 || { echo "no crash-cleanup.service"; return 0; }
    echo "timer $(unit_state crash-cleanup.timer)"
    systemctl cat crash-cleanup.service crash-cleanup.timer 2>/dev/null | grep -E '^(Exec|OnCalendar|OnBootSec|OnUnitActiveSec)'
    for f in $(systemctl show -p ExecStart --value crash-cleanup.service | tr -s ' ;' '\n' \
               | sed -E 's/^(path|argv\[\])=//' | grep '^/' | sort -u); do
        [[ -f $f ]] || continue
        grep -nIE '(^|[^[:alnum:]_-])(rm|shred|truncate|unlink)([^[:alnum:]_-]|$)|-delete|find ' "$f" | sed "s|^|deletes? $f:|"
    done
    return 0
}
timer_watch_info() {
    local u w=/usr/local/sbin/kernel-timer-watch found=0
    [[ -e $w ]] || { echo "$w not present"; return 0; }
    for u in $(grep -lrs "$w" /etc/systemd/system --include='*.service' --include='*.timer' | xargs -r -n1 basename | sort -u); do
        echo "$u $(unit_state "$u")"; found=1
        [[ $u == *.service && -e /etc/systemd/system/${u%.service}.timer ]] \
            && echo "${u%.service}.timer $(unit_state "${u%.service}.timer")"
    done
    grep -ls "$w" /etc/crontab /etc/cron.d/* /var/spool/cron/* 2>/dev/null | sed 's/^/cron: /' && found=1
    ((found)) || echo "present, but no systemd unit or cron entry runs it"
    return 0
}

# --- GPUStack ----------------------------------------------------------------
worker_state() {   # status|restart-policy of the gpustack-worker container
    docker inspect -f '{{.State.Status}}|{{.HostConfig.RestartPolicy.Name}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}}' \
        gpustack-worker 2>/dev/null | sed -E 's/:0$//; s/\|:?$/|no/' || echo 'absent|-'
}
model_containers() { docker ps --format '{{.Names}}' 2>/dev/null | grep -E -- '-run-|-pause$'; }

# --- probe and report --------------------------------------------------------
probe() {   # $1 crash baseline (epoch, 0 = none yet), $2 summary file to write
    local since=$1 k st ok l w wp locks avail repo_ok=1 units timer newest
    KV=$2; : > "$KV"
    kv host "$(hostname -s)"; kv fqdn "$(hostname -f)"
    kv now "$(date +%s)"; kv date "$(date '+%F %T')"; kv boot_id "$(boot_id)"
    kv uptime_s "$(cut -d. -f1 /proc/uptime)"
    kv disk "$(df -P / /boot /home 2>/dev/null | awk 'NR > 1 { printf "%s%s %s", (NR > 2 ? "  " : ""), $6, $5 }')"
    kv schedule "$(sched_state)"
    kv kernel_run "$(uname -r)"; kv kernel_new "$(kernels_installed | tail -n 1)"
    kv bios "$(dmidecode -s bios-version 2>/dev/null || cat /sys/class/dmi/id/bios_version 2>/dev/null)"
    kv driver "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1)"
    kv license "$(modinfo -F license nvidia 2>/dev/null)"

    locks=$(locks_now) || repo_ok=0
    avail=$(repo_newest nvidia-open kmod-nvidia-open-dkms) || repo_ok=0
    kv repo_ok "$repo_ok"
    kv nvopen_inst "$(rpm_evr nvidia-open)";           kv nvopen_avail "$(newest_of nvidia-open "$avail")"
    kv kmod_inst "$(rpm_evr kmod-nvidia-open-dkms)";   kv kmod_avail "$(newest_of kmod-nvidia-open-dkms "$avail")"
    while read -r l; do [[ -z $l ]] || kv lock "$l"; done <<<"$locks"

    while read -r k; do
        [[ -n $k ]] || continue
        st=$(dkms status -k "$k" 2>/dev/null | grep -E '^nvidia[/,]' | head -n 1)
        ok=MISSING
        [[ $st == *": installed"* && -e /lib/modules/$k/extra/nvidia.ko.xz ]] && ok=ok
        kv dkms "$k|$ok|${st:-no nvidia dkms entry}"
    done < <(kernels_installed)

    kv irq "$(irq_state)"
    kv kdump_status "$(kdumpctl status 2>&1 | grep -m1 -i 'kdump is' || kdumpctl status 2>&1 | tail -n 1)"
    kv kdump_loaded "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null || echo 0)"

    units=$(dump_units); timer=$(timer_units)
    kv baseline "$((since > 0))"
    kv dumps_total "$(grep -c . <<<"$units")"
    kv dumps_new "$( ((since > 0)) && dumps_since "$since" || echo 0)"
    newest=$(sort -n <<<"$units" | tail -n 1 | cut -d' ' -f1)
    if [[ -n $newest ]]; then kv dumps_newest "$(date -d "@$newest" '+%F %H:%M')"; else kv dumps_newest -; fi
    kv timer_total "$(grep -c . <<<"$timer")"
    kv timer_new "$(awk -v s="$since" 'NR == FNR { t = $1; sub(/^[^ ]+ /, ""); m[$0] = t; next }
                                       s > 0 && ($0 in m) && m[$0] > s' <(echo "$units") <(echo "$timer") | grep -c .)"
    kv cpu_hist "$(cpu_hist)"
    while read -r l; do kv cleanup "$l"; done < <(cleanup_info)
    while read -r l; do kv timer_watch "$l"; done < <(timer_watch_info)

    IFS='|' read -r w wp <<<"$(worker_state)"
    kv worker "$w"; kv worker_policy "$wp"
    kv models "$(model_containers | tr '\n' ' ' | sed 's/ $//')"
    if grep -qxF 'kernel.ftrace_dump_on_oops = 1' "$CRASHDEBUG_CONF" 2>/dev/null; then kv crashdebug yes; else kv crashdebug no; fi
    print_node "$KV"
}

print_node() {   # $1 summary file. Short report on screen, full detail in the run log.
    local f=$1 n k bad nk drv av lic
    pl() { printf '  %-12s %s\n' "$1" "$2"; }
    echo; echo -e "${CYAN}== $(kvg "$f" fqdn)   $(kvg "$f" date)${NC}"

    k=$(kvg "$f" kernel_run)
    if [[ $k == "$(kvg "$f" kernel_new)" ]]; then pl Kernel "$k"
    else pl Kernel "$k running, $(kvg "$f" kernel_new) installed (reboot to use it)"; fi
    drv=$(kvg "$f" driver); av=$(evr_ver "$(kvg "$f" kmod_avail)"); lic=$(kvg "$f" license)
    case $lic in *GPL*|*MIT*) lic="open module" ;; "") lic="no module" ;; *) lic="proprietary module" ;; esac
    if [[ -z $drv ]]; then pl Driver "NONE loaded ($lic)"
    elif [[ $av != - && $av != "$drv" ]]; then pl Driver "$drv ($lic), $av available"
    else pl Driver "$drv ($lic), newest"; fi
    nk=$(grep -c '^dkms=' "$f"); bad=$(sed -n 's/^dkms=//p' "$f" | awk -F'|' '$2 != "ok" { printf "%s ", $1 }')
    if [[ -n $bad ]]; then pl DKMS "nvidia module MISSING for $bad"; else pl DKMS "nvidia module built for all $nk kernels"; fi
    pl BIOS "$(kvg "$f" bios)"
    pl Disk "$(kvg "$f" disk)"
    pl irqbalance "$(kvg "$f" irq)"
    if [[ $(kvg "$f" kdump_loaded) == 1 ]]; then pl kdump armed; else pl kdump "NOT armed ($(kvg "$f" kdump_status))"; fi
    if [[ $(kvg "$f" baseline) == 1 ]]; then n="$(kvg "$f" dumps_new) new"; else n="first check"; fi
    pl Crashes "$(kvg "$f" dumps_total) dumps ($n), newest $(kvg "$f" dumps_newest)"
    (( $(kvg "$f" timer_total) > 0 )) && pl "" "$(kvg "$f" timer_total) match the timer bug; by CPU: $(kvg "$f" cpu_hist)"
    pl Cleanup "$(sed -n 's/^cleanup=//p' "$f" | grep -v '^Exec' | sed 's/^deletes? [^:]*:[0-9]*: *//' | paste -sd ';' | sed 's/;/; /g')"
    pl "Timer watch" "$(sed -n 's/^timer_watch=//p' "$f" | paste -sd ';' | sed 's/;/; /g')"
    n=$(kvg "$f" models | wc -w)
    pl GPUStack "worker $(kvg "$f" worker) (restart=$(kvg "$f" worker_policy)), $n model containers"
    pl Schedule "$(kvg "$f" schedule)"
    [[ $(kvg "$f" repo_ok) == 1 ]] || pl Repos "repoquery FAILED, newest versions unknown"
    pl Locks "$(grep -c '^lock=' "$f") locks, $(grep -c '^lock=BEHIND|' "$f") behind available updates"
    unset -f pl
    [[ -z ${RUN_LOG:-} ]] || {
        echo "--- detail"
        sed -n 's/^dkms=//p' "$f" | awk -F'|' '{ printf "  dkms  %-34s %-8s %s\n", $1, $2, $3 }'
        sed -n 's/^cleanup=//p' "$f" | sed 's/^/  crash-cleanup  /'
        echo "  models: $(kvg "$f" models)"
        sed -n 's/^lock=//p' "$f" | lock_detail
    } >> "$RUN_LOG"
}

node_flags() {   # $1 summary file, $2 newest driver in the fleet. One line per problem.
    local f=$1 d n
    n=$(grep -c '^lock=BEHIND|' "$f"); ((n)) && echo "$n packages locked behind available updates"
    [[ $(kvg "$f" repo_ok) == 1 ]] || echo "repoquery failed, available versions unknown"
    d=$(kvg "$f" driver)
    if [[ -z $d ]]; then echo "no NVIDIA driver loaded"
    elif [[ $d != "$2" ]]; then echo "driver $d differs from $2 elsewhere in the fleet"; fi
    sed -n 's/^dkms=//p' "$f" | awk -F'|' '$2 != "ok" { print "no nvidia module built for kernel " $1 }'
    n=$(kvg "$f" dumps_new); ((n)) && echo "$n new crash dumps"
    n=$(kvg "$f" timer_new); ((n)) && echo "$n new dumps with the timer signature"
    [[ $(kvg "$f" kdump_loaded) == 1 ]] || echo "kdump not armed"
    return 0
}

table_row() {    # one row per summary file, or the header with no argument
    row() { printf '%-8s %-7s %-9s %-9s %-11s %-10s %-4s %-20s %-20s %-14s %-17s %-6s %-23s %-6s %-16s %s\n' "$@"; }
    kab() { local k=${1#*-}; echo "${k%.el*}"; }
    ia()  { local i a; i=$(evr_ver "$1"); a=$(evr_ver "$2")
            if [[ $i == - || $a == - || $i == "$a" ]]; then echo "$i"; else echo "$i>$a"; fi; }
    if (($# == 0)); then
        row NODE UP KERNEL NEWEST BIOS DRIVER FLAV NVIDIA-OPEN KMOD-DKMS DKMS IRQBALANCE KDUMP "DUMPS tot/new/newest" TIMER WORKER LOCKS
        return 0
    fi
    local f=$1 up lic flav dk dumps nl nb
    up=$(kvg "$f" uptime_s); up="$((up / 86400))d$(( up % 86400 / 3600 ))h"
    lic=$(kvg "$f" license)
    case $lic in *GPL*|*MIT*) flav=open ;; "") flav=- ;; *) flav=prop ;; esac
    dk=$(sed -n 's/^dkms=//p' "$f" | awk -F'|' '$2 != "ok" { print $1; exit }')
    if [[ -n $dk ]]; then dk="MISS:$(kab "$dk")"; else dk=ok; fi
    dumps="$(kvg "$f" dumps_total)/$( [[ $(kvg "$f" baseline) == 1 ]] && kvg "$f" dumps_new || echo -)/$(kvg "$f" dumps_newest | cut -d' ' -f1)"
    nl=$(grep -c '^lock=' "$f"); nb=$(grep -c '^lock=BEHIND|' "$f")
    row "$(kvg "$f" host)" "$up" "$(kab "$(kvg "$f" kernel_run)")" "$(kab "$(kvg "$f" kernel_new)")" \
        "$(kvg "$f" bios)" "$(kvg "$f" driver | grep . || echo NONE)" "$flav" \
        "$(ia "$(kvg "$f" nvopen_inst)" "$(kvg "$f" nvopen_avail)")" "$(ia "$(kvg "$f" kmod_inst)" "$(kvg "$f" kmod_avail)")" \
        "$dk" "$(kvg "$f" irq)" "$( [[ $(kvg "$f" kdump_loaded) == 1 ]] && echo armed || echo NOT)" "$dumps" \
        "$(kvg "$f" timer_total)" "$(kvg "$f" worker)/$(kvg "$f" worker_policy)" \
        "$( ((nl)) && echo "$nb/$nl behind" || echo -)"
}

# The table holds this node plus every other node's last --check found in
# ./reports (collect the summary-*.env files there to compare the fleet).
fleet_report() {   # $1 this node's summary. Returns 1 if this node has a problem.
    local own=$1 f l host newest flags files=("$1")
    shopt -s nullglob
    for f in "$REPORT_DIR"/summary-*.env; do [[ $f -ef $own ]] || files+=("$f"); done
    shopt -u nullglob

    if ((${#files[@]} > 1)); then
        echo; table_row
        for f in "${files[@]}"; do table_row "$f"; done
        echo "(other rows: last --check of those nodes, from $REPORT_DIR/summary-*.env)"
        for f in "${files[@]:1}"; do echo "   $(kvg "$f" host) as of $(kvg "$f" date)"; done
    fi

    echo
    for f in "${files[@]}"; do
        sed -n 's/^lock=//p' "$f" | lock_block "$(kvg "$f" host)"
    done
    newest=$(for f in "${files[@]}"; do kvg "$f" driver; done | grep . | sort -V | tail -n 1)
    for f in "${files[@]}"; do
        [[ $(kvg "$f" driver) == "$newest" ]] \
            || echo "!! $(kvg "$f" host): loaded driver $(kvg "$f" driver | grep . || echo NONE), newest in the fleet $newest"
    done

    host=$(kvg "$own" host)
    flags=$(node_flags "$own" "$newest")
    if [[ -n $flags ]]; then
        echo; log_error "$host: check failed"; while read -r l; do echo "   $l"; done <<<"$flags"; return 1
    fi
    echo; log_success "$host: all checks passed"; return 0
}

start_log() {   # $1 mode. From here on everything also goes to ./reports/
    mkdir -p "$REPORT_DIR" "$STATE_DIR" || exit 2
    RUN_LOG="$REPORT_DIR/$(date +%Y%m%d-%H%M%S)-$1-$(hostname -s).log"
    exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$RUN_LOG")) 2>&1
    log_info "log: $RUN_LOG"
}

do_check() (
    require_root || exit 2
    start_log check
    SUM="$REPORT_DIR/summary-$(hostname -s).env"
    probe "$(cat "$STATE_DIR/last-check" 2>/dev/null || echo 0)" "$SUM"
    fleet_report "$SUM"; rc=$?
    kvg "$SUM" now > "$STATE_DIR/last-check"
    exit $rc
)

# --- update ------------------------------------------------------------------
# Steps 1-9 run in one go and end with the reboot. Their record goes to
# $STATE_DIR/update.state; while it exists the node is drained with
# gpustack-worker restart=no, and the next --update resumes at step 10.
do_update() (
    DRY=0
    for a in "$@"; do case $a in
        --update) ;;
        --dry-run) DRY=1 ;;
        *) log_error "unknown option: $a"; exit 2 ;;
    esac; done
    require_root || exit 2
    start_log "update$( ((DRY)) && echo -dry)"
    exec 9>/var/lock/node-maintenance.lock
    flock -n 9 || { log_error "maintenance or another update is running"; exit 30; }

    HOST=$(hostname -s) ST=$STATE_DIR/update.state SUM="$REPORT_DIR/summary-$(hostname -s).env"
    # one line per command on screen, its output in the log; the tail on failure
    run()  { if ((DRY)); then echo "  DRY: $*"; return 0; fi
             echo "  + $*"
             { echo "+ $*"; "$@"; } >> "$RUN_LOG" 2>&1 && return 0
             local rc=$?
             echo -e "  ${RED}failed (exit $rc)${NC}, end of $RUN_LOG:"; tail -n 15 "$RUN_LOG" | sed 's/^/    /'
             return "$rc"; }
    ask()  { local a; read -r -p "$1 [Y/n] " a || return 1; [[ $a != [nN]* ]]; }   # Enter = yes
    die()  { log_error "$HOST: $*"; exit 1; }
    save() { ((DRY)) || printf '%s=%s\n' "$1" "$2" >> "$ST"; }
    chk()  { local msg=$1; shift     # chk "message" test-command...
             if "$@"; then echo -e "  ${GREEN}ok${NC}    $msg"; else echo -e "  ${RED}FAIL${NC}  $msg"; return 1; fi; }
    backup_vlock() { b="$VLOCK.bak-$(date +%Y%m%d-%H%M%S)"   # sets $b
                     [[ ! -e $b ]] || b+="-$$-$RANDOM"         # never overwrite an earlier backup
                     run cp -p "$VLOCK" "$b"; }
    driver_inst() { evr_ver "$(rpm_evr kmod-nvidia-open-dkms)"; }

    # steps 10-12
    update_finish() {
        local k nv smi irq n fails=0 models left t
        if [[ $(kvg "$ST" phase) == watch && $(kvg "$ST" boot_watch) != "$(boot_id)" ]]; then
            die "$HOST rebooted during the watch window (crash?). gpustack-worker restart policy is still 'no'. Look at $CRASH_DIR; remove $ST once resolved."
        fi

        echo -e "\n${CYAN}== after reboot: verify${NC}"
        k=$(kernels_installed | tail -n 1); nv=$(driver_inst)
        chk "running kernel $(uname -r), newest installed $k" test "$(uname -r)" = "$k" || fails=1
        smi=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1 | head -n 1)
        chk "nvidia-smi: $smi, installed driver $nv" test "$smi" = "$nv" || fails=1
        irq=$(irq_state)
        chk "irqbalance $irq, before the update $(kvg "$ST" irq_before)" test "$irq" = "$(kvg "$ST" irq_before)" || fails=1
        for _ in $(seq 36); do [[ $(cat /sys/kernel/kexec_crash_loaded 2>/dev/null) == 1 ]] && break; sleep 5; done
        chk "kdump armed" test "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" = 1 || fails=1
        n=$(dumps_since "$(kvg "$ST" since)")
        chk "$n new crash dumps since the update started" test "$n" -eq 0 || fails=1
        ((fails == 0)) || die "verification failed. Node stays drained, gpustack-worker restart=no. Fix it and run --update again."

        echo -e "\n${CYAN}== start GPUStack${NC}"
        if [[ $(kvg "$ST" worker) == running ]]; then
            run docker start gpustack-worker || die "cannot start gpustack-worker"
            models=$(kvg "$ST" models); left=$models
            for _ in $(seq 60); do
                left=$(for m in $models; do [[ $(docker inspect -f '{{.State.Running}}' "$m" 2>/dev/null) == true ]] || echo "$m"; done)
                [[ -z $left ]] && break
                sleep 10
            done
            chk "model containers back: ${models:-none}${left:+; missing: $(tr '\n' ' ' <<<"$left")}" test -z "$left" \
                || die "model containers did not return within 10 min"
        else
            echo "  gpustack-worker was '$(kvg "$ST" worker)' before the update, not starting it"
        fi

        # restart=no stays until the node has survived the window, so a crash
        # in it cannot turn into a boot loop
        echo -e "\n${CYAN}== watch $WATCH_MIN min for crashes${NC}"
        save phase watch; save boot_watch "$(boot_id)"; t=$(date +%s)
        for ((n = WATCH_MIN; n > 0; n -= 5)); do
            echo "  $n min left"; sleep $(( (n < 5 ? n : 5) * 60 ))
        done
        n=$(dumps_since "$t")
        chk "$n new crash dumps during the watch" test "$n" -eq 0 || die "crash dump during the watch window, restart policy stays 'no'"
        chk "kdump still armed" test "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" = 1 || die "kdump disarmed during the watch"

        [[ $(kvg "$ST" worker) == absent ]] || run docker update --restart="$(kvg "$ST" worker_policy)" gpustack-worker \
            || die "cannot restore restart=$(kvg "$ST" worker_policy)"
        date +%s > "$STATE_DIR/last-check"
        rm -f "$ST"
        log_success "$HOST done: kernel $k, driver $nv. Next node."
    }


    if [[ -e $ST ]]; then
        log_info "unfinished update from $(kvg "$ST" started), resuming at verification"
        ((DRY)) && { sed 's/^/  /' "$ST"; exit 0; }
        update_finish; exit $?
    fi
    # dumps newer than the last --check count as new; without one, the last 7 days
    since=$(cat "$STATE_DIR/last-check" 2>/dev/null || echo $(( $(date +%s) - 7 * 86400 )))

    echo -e "\n${CYAN}== checks${NC}"
    probe "$since" "$SUM"
    sed -n 's/^lock=//p' "$SUM" | lock_block "$HOST"
    n=$(kvg "$SUM" dumps_new)
    if [[ -e $STATE_DIR/last-check ]]; then when="since the last check"; else when="in the last 7 days"; fi
    ((n == 0)) || die "$n new crash dump(s) $when, newest $(kvg "$SUM" dumps_newest). Not updating a crashing node. Look at $CRASH_DIR; once they are understood, run --check (marks them as seen) and --update again."

    # Every lock is removed unless the operator picks a group to keep.
    echo -e "\n${CYAN}== version locks${NC}"
    keep=() gid=()
    groups=$(sed -n 's/^lock=//p' "$SUM" | lock_groups)
    if [[ -n $groups ]]; then
        echo "These version locks will be removed so everything updates:"
        while IFS='|' read -r g label text; do
            gid+=("$g"); printf '  %d) %-14s %s\n' "${#gid[@]}" "$label" "$text"
        done <<<"$groups"
        read -r -p "Keep any of them locked? Enter = none, or numbers (e.g. 1): " ans || ans=
        for x in $ans; do
            if [[ $x =~ ^[0-9]+$ ]] && ((x >= 1 && x <= ${#gid[@]})); then keep+=("${gid[x - 1]}")
            else log_warning "ignoring '$x'"; fi
        done
        drop=$(sed -n 's/^lock=//p' "$SUM" | awk -F'|' -v keep=" ${keep[*]} " 'index(keep, " " $2 " ") == 0 { print $3 }' | sort -u)
        if ((${#keep[@]})); then echo "  keeping: ${keep[*]}"; else echo "  keeping: nothing, all locks go"; fi
        if [[ -n $drop ]]; then
            backup_vlock || die "cannot back up $VLOCK"
            bak=$b
            if ((${#keep[@]})); then
                mapfile -t dn <<<"$drop"; run dnf versionlock delete "${dn[@]}" || die "dnf versionlock delete failed"
            else
                run dnf versionlock clear || die "dnf versionlock clear failed"
            fi
        fi
    fi

    echo -e "\n${CYAN}== what will be upgraded${NC}"
    pv=(--refresh)
    ((DRY && ${#keep[@]} == 0)) && pv+=(--disableplugin=versionlock)   # dry run: locks still in place
    up=$(dnf -q "${pv[@]}" repoquery --upgrades --latest-limit=1 --qf '%{name} %{evr}' 2>>"$RUN_LOG" | sort -u)
    { echo "--- dnf upgrade --assumeno"; LC_ALL=C dnf "${pv[@]}" upgrade --assumeno; } >> "$RUN_LOG" 2>&1
    if [[ -z $up ]]; then
        echo "  nothing to upgrade"
    else
        echo "  $(grep -c . <<<"$up") packages, the ones that matter:"
        grep -E '^(kernel|nvidia-open|kmod-nvidia-open-dkms|nvidia-driver|cuda-toolkit|docker-ce) ' <<<"$up" \
            | awk -v hi="$YELLOW" -v n="$NC" '{ printf "    %s%-24s %s%s\n", hi, $1, $2, n }'
        echo "  (full transaction in $RUN_LOG)"
    fi
    if ! ask "Proceed?"; then
        [[ -z ${bak:-} ]] || run cp -p "$bak" "$VLOCK"      # put the locks back as they were
        log_info "$HOST: nothing changed"; exit 0
    fi

    echo -e "\n${CYAN}== stop GPUStack${NC}"
    IFS='|' read -r ws wp <<<"$(worker_state)"
    models=$(model_containers | tr '\n' ' '); models=${models% }
    echo "  gpustack-worker $ws, restart=$wp; model containers running: ${models:-none}"
    for m in $models; do
        [[ $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$m" 2>/dev/null) == always ]] \
            && log_warning "$m has restart=always and will start on boot by itself"
    done
    save started "$(date '+%F %T')"; save phase drained; save irq_before "$(irq_state)"
    save worker "$ws"; save worker_policy "$wp"; save models "$models"
    [[ $ws != running ]] || run docker stop gpustack-worker || die "cannot stop gpustack-worker"
    for m in $models; do run docker stop "$m" || die "cannot stop $m"; done
    [[ $ws == absent ]] || run docker update --restart=no gpustack-worker || die "cannot set restart=no"

    if grep -qxF 'kernel.ftrace_dump_on_oops = 1' "$CRASHDEBUG_CONF" 2>/dev/null; then
        echo "  $CRASHDEBUG_CONF already set"
    elif ask "Set kernel.ftrace_dump_on_oops = 1 in $CRASHDEBUG_CONF?"; then
        if ((DRY)); then echo "  DRY: echo 'kernel.ftrace_dump_on_oops = 1' > $CRASHDEBUG_CONF"
        else echo 'kernel.ftrace_dump_on_oops = 1' > "$CRASHDEBUG_CONF"; fi
        run sysctl -p "$CRASHDEBUG_CONF"
    fi

    echo -e "\n${CYAN}== upgrade${NC}"
    run dnf -y --refresh upgrade || die "dnf upgrade failed, node left drained"
    run dnf -y --setopt=installonly_limit=2 remove --oldinstallonly || echo "  no old kernels removed"

    nv=$(driver_inst)

    echo -e "\n${CYAN}== before reboot: is the nvidia module ready?${NC}"
    k=$(kernels_installed | tail -n 1); gate=0
    ((DRY)) && echo "  (dry run: nothing was upgraded, this is the state as it is now)"
    st=$(dkms status -k "$k" 2>/dev/null | grep -E '^nvidia[/,]' | head -n 1)
    chk "dkms status -k $k: ${st:-no nvidia entry}" grep -q ': installed' <<<"$st" || gate=1
    chk "/lib/modules/$k/extra/nvidia.ko.xz" test -e "/lib/modules/$k/extra/nvidia.ko.xz" || gate=1
    mv=$(modinfo -k "$k" -F version nvidia 2>/dev/null)
    chk "module version ${mv:-none}, installed driver $nv" test "$mv" = "$nv" || gate=1
    dk=$(grubby --default-kernel 2>/dev/null)
    chk "grubby --default-kernel: $dk" test "$dk" = "/boot/vmlinuz-$k" || gate=1
    ((gate == 0 || DRY)) || die "pre-reboot gate failed. Node stays drained, gpustack-worker restart=no. Fix it, reboot, then run --update again to verify and restore."

    need=0; why=()
    needs-restarting -r >/dev/null 2>&1 || { need=1; why+=("updated kernel or core libraries"); }
    loaded=$(cat /sys/module/nvidia/version 2>/dev/null)
    [[ $loaded == "$nv" ]] || { need=1; why+=("driver ${loaded:-none} -> $nv"); }
    save kernel "$k"; save driver "$nv"; save since "$(date +%s)"; save boot_before "$(boot_id)"
    if ((need)); then
        echo "  reboot needed: ${why[*]}"
        ((DRY)) && { echo "  DRY: ask 'Reboot $HOST now?', systemctl reboot; after it, Update again verifies, starts GPUStack, watches $WATCH_MIN min"; exit 0; }
        ask "Reboot $HOST now?" || die "reboot declined. Node stays drained, gpustack-worker restart=no. Reboot later, then run --update again."
        save phase rebooting
        log_info "when $HOST is back: sudo $SELF, choose Update (or: sudo $SELF --update) to finish"
        run systemctl reboot
        exit 0
    fi
    ((DRY)) && { echo "DRY: no reboot needed now; next: verify, start gpustack-worker, watch $WATCH_MIN min, restore restart policy"; exit 0; }
    update_finish
)


# =============================================================================
# install / uninstall / status
# =============================================================================
write_config() {
    cat <<'EOF'
# node-maintenance configuration, read by /usr/local/sbin/node-setup.sh

# schedule. The cron job and the timer fire every Saturday 08:00 Europe/Moscow;
# MAINT_BIWEEKLY makes the script skip odd ISO weeks, so the run lands every
# 2 weeks. Set to 0 for weekly.
MAINT_BIWEEKLY=1

MAINT_JITTER_SEC=1800          # random start delay, keeps a cluster off the mirrors at once

# kernels and /boot. /boot is 960M on these nodes and the NVIDIA initramfs is
# large, so 2 is the practical maximum. 3 is the dnf default and overflows it.
MAINT_KEEP_KERNELS=2
MAINT_DROP_RESCUE=0            # 1 removes the 0-rescue image, frees 100-200M
MAINT_BOOT_MIN_FREE_MB=250     # below this the upgrade is skipped, not attempted

# upgrade. Mirror your dnf versionlock set here so dnf does not fight itself.
#MAINT_EXCLUDE_PKGS="kernel* nvidia-driver* nvidia-dkms* cuda* libnvidia*"
MAINT_SECURITY_ONLY=0
MAINT_AUTOREMOVE=0             # off: autoremove eats NVIDIA repo deps. Logged as would-remove.

# cleanup
MAINT_JOURNAL_AGE=14d
MAINT_JOURNAL_SIZE=1G
MAINT_LOG_AGE_DAYS=30
MAINT_TMP_AGE_DAYS=10          # /tmp and /var/tmp aged by atime

# Extra directories to age by atime. Never point this at model weights: a
# GPUStack, HuggingFace, Ollama or torch cache is read rarely and would be
# deleted first. Such paths are skipped by name even if listed here.
MAINT_PRUNE_CONTAINERS=1        # stopped containers, dangling layers, build cache.
                               # Tagged images are never removed.
MAINT_FSTRIM=1                 # fstrim -av on the LVM filesystems each run
#MAINT_CACHE_DIRS="/home/shared/.cache/pip /home/shared/.cache/uv"

# firewalld stays off. Re-asserted every run because a dnf upgrade can
# re-enable the unit. Only sane if the nodes sit behind a perimeter firewall.
MAINT_DISABLE_FIREWALL=1

# guards
MAINT_SKIP_IF_BUSY=1           # nvidia-smi compute apps or squeue on this host
MAINT_REBOOT_MODE=never        # never | if-idle | if-needed
MAINT_REBOOT_DELAY_MIN=5

#MAINT_MAIL_TO=david@example.org

# bootstrap
#DRIVER_STREAM=nvidia-driver:open-dkms
#DOCKER_DATA_ROOT=/home/docker-data
#CONTAINERD_DATA_ROOT=/home/containerd-data
EOF
}

install_self() {
    if [[ -f $SELF ]]; then
        install -D -m 0755 "$SELF" "$BIN"
    else
        # piped in with bash <(curl ...): $0 is not a readable file, refetch
        log_info "fetching $SETUP_URL"
        curl -fsSL "$SETUP_URL" -o "$BIN" || { log_error "cannot fetch the script, clone the repo and run ./node-setup.sh install"; return 1; }
        chmod 0755 "$BIN"
    fi
}

do_install() {
    require_root || return 1
    local use_timer=0
    [[ ${1:-} == --timer ]] && use_timer=1

    dnf -y install dnf-utils util-linux >/dev/null

    install_self || return 1
    install -d -m 0750 "$MAINT_LOG_DIR"
    mkdir -p "$(dirname "$CONF")" "$(dirname "$CRON")" "$(dirname "$UNIT")" "$(dirname "$LOGROTATE")"

    if [[ -e $CONF ]]; then
        write_config > "$CONF.new"; chmod 0644 "$CONF.new"
        log_warning "kept existing config, new version at $CONF.new"
    else
        write_config > "$CONF"; chmod 0644 "$CONF"
    fi

    cat > "$LOGROTATE" <<'EOF'
/var/log/node-maintenance/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    su root root
}
EOF
    chmod 0644 "$LOGROTATE"

    if ((use_timer)); then
        local oncal="$SCHED_ONCALENDAR"
        systemd-analyze calendar "$oncal" >/dev/null 2>&1 || {
            log_warning "systemd here does not accept a timezone in OnCalendar, using $SCHED_ONCALENDAR_FALLBACK"
            oncal="$SCHED_ONCALENDAR_FALLBACK"
        }
        cat > "$UNIT" <<EOF
[Unit]
Description=Node cleanup and package update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN maintenance --scheduled
TimeoutStartSec=2h
Nice=10
IOSchedulingClass=idle
EOF
        cat > "$TIMER" <<EOF
[Unit]
Description=Node cleanup and package update, $SCHED_SHORT

[Timer]
OnCalendar=$oncal
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
        chmod 0644 "$UNIT" "$TIMER"
        rm -f "$CRON"
        systemctl daemon-reload
        systemctl enable --now node-maintenance.timer
        systemctl list-timers node-maintenance.timer --no-pager
    else
        cat > "$CRON" <<EOF
# $CRON
# Fires weekly; --scheduled makes the script skip odd ISO weeks, so the run
# lands $SCHED_SHORT. MAINT_JITTER_SEC spreads the cluster out, so every
# node can share this file. cron reads % as a newline, escape it as \\% if
# you add date formats here.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=$SCHED_CRON_TZ
MAILTO=""

$SCHED_CRON   root  $BIN maintenance --scheduled
EOF
        chmod 0644 "$CRON"
        rm -f "$UNIT" "$TIMER"
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now crond
    fi

    log_success "installed: $BIN, $CONF, schedule = $SCHED_HUMAN"
    log_info "verify: sudo $BIN maintenance --dry-run"
}

do_uninstall() {
    require_root || return 1
    systemctl disable --now node-maintenance.timer 2>/dev/null || true
    rm -f "$UNIT" "$TIMER" "$CRON"
    systemctl daemon-reload 2>/dev/null || true
    log_success "schedule removed. $BIN, $CONF and $MAINT_LOG_DIR were kept"
}

do_status() {
    echo
    printf '%-22s %s\n' "host" "$(hostname -f)  $(cat /etc/rocky-release 2>/dev/null)"
    printf '%-22s %s\n' "kernel" "$(uname -r)"
    printf '%-22s %s\n' "script" "$([[ -x $BIN ]] && echo "$BIN" || echo 'NOT INSTALLED')"
    printf '%-22s %s\n' "config" "$([[ -e $CONF ]] && echo "$CONF" || echo 'not installed')"
    printf '%-22s %s\n' "biweekly" "MAINT_BIWEEKLY=$MAINT_BIWEEKLY  (ISO week now: $((10#$(date +%V))))"

    if [[ -e $CRON ]]; then
        printf '%-22s %s\n' "schedule" "cron $CRON — $SCHED_HUMAN"
    elif [[ -e $TIMER ]]; then
        printf '%-22s %s\n' "schedule" "systemd timer — $SCHED_HUMAN"
        systemctl list-timers node-maintenance.timer --no-pager 2>/dev/null | sed -n '1,2p'
    else
        printf '%-22s %s\n' "schedule" "not installed"
    fi

    if [[ ( -e $CRON || -e $TIMER ) && ! -x $BIN ]]; then
        log_warning "a schedule is installed but $BIN is missing — the scheduled run does nothing."
        log_warning "fix it with: sudo ./node-setup.sh install"
    fi

    if node_busy; then
        echo; log_warning "node is busy, plain maintenance will exit 10:"
        busy_reason | sed 's/^/  /'
    fi

    echo; df -h / /boot /home 2>/dev/null
    echo; lvm_report
    if command -v nvidia-smi >/dev/null; then
        echo; nvidia-smi --query-gpu=index,name,driver_version,memory.used,memory.total,temperature.gpu \
            --format=csv 2>&1 | sed 's/^/  /'
    fi
    if [[ -e $MAINT_LOG_DIR/latest.log ]]; then
        echo; log_info "last run: $(readlink -f "$MAINT_LOG_DIR/latest.log")"
        tail -n 3 "$MAINT_LOG_DIR/latest.log" | sed 's/^/  /'
    fi
    echo
}

# =============================================================================
# menu
# =============================================================================
sched_state() {
    if [[ -e $CRON ]]; then echo "on, $SCHED_SHORT (cron)"
    elif [[ -e $TIMER ]]; then echo "on, $SCHED_SHORT (systemd timer)"
    else echo off; fi
}

menu() {
    local c a upd
    while true; do
        upd="remove version locks, drain GPUStack, upgrade, reboot"
        echo
        echo -e "${BLUE}─────────────────────────────────────────────${NC}"
        echo -e "${CYAN}  $(hostname -s) — MENU${NC}"
        echo -e "${BLUE}─────────────────────────────────────────────${NC}"
        if [[ -e $STATE_DIR/update.state ]]; then
            echo -e "${YELLOW}  An update is unfinished, the node is drained. Choose 2 to finish it.${NC}"
            upd="finish: verify, start GPUStack, watch $WATCH_MIN min"
        fi
        echo "  1) Check       health report, changes nothing"
        echo "  2) Update      $upd"
        echo "  3) Clean up    old kernels, caches, logs, unused containers"
        echo "  4) Schedule    automatic maintenance: $(sched_state)"
        echo "  5) Bootstrap   set up a new node (driver, CUDA, docker)"
        echo -e "${RED}  0) Exit${NC}"
        read -r -p "Choose [0-5]: " c || break
        case $c in
            1) do_check ;;
            2) do_update ;;
            3) maintenance --clean-only --force ;;
            4) if [[ $(sched_state) == off ]]; then
                   read -r -p "Turn on automatic maintenance ($SCHED_SHORT, includes dnf upgrade)? [Y/n] " a
                   [[ $a == [nN]* ]] || do_install
               else
                   read -r -p "Turn off automatic maintenance? [Y/n] " a
                   [[ $a == [nN]* ]] || do_uninstall
               fi ;;
            5) bootstrap ;;
            0|q) echo -e "${GREEN}Bye.${NC}"; break ;;
            "") ;;
            *) log_error "enter 0-5" ;;
        esac
    done
}

# =============================================================================
# dispatch
# =============================================================================
case "${1:-}" in
    -h|--help)   sed -n 's/^#>//p' "$SELF" 2>/dev/null || sed -n 's/^#>//p' "$0"; exit 0 ;;
    bootstrap)   shift; banner; bootstrap "$@" ;;
    maintenance) shift; maintenance "$@"; exit $? ;;
    install)     shift; banner; do_install "$@" ;;
    uninstall)   shift; do_uninstall ;;
    status)      shift; banner; do_status ;;
    --check)     shift; [[ $# -eq 0 ]] || { log_error "--check takes no arguments, it checks this node"; exit 2; }
                 do_check; exit $? ;;
    --update|--dry-run) do_update "$@"; exit $? ;;
    "")          banner; menu ;;
    *)           log_error "unknown command: $1  (try --help)"; exit 2 ;;
esac
