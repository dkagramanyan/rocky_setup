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
    exec > >(tee -a "$LOG") 2>&1

    log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
    sec()  { printf '\n--- %s ---\n' "$*"; }
    warn() { log "WARN: $*"; RC=20; }
    run()  { if ((DRY)); then log "DRY: $*"; else log "+ $*"; "$@" || warn "rc=$? : $*"; fi; }

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

    log "$(hostname -f)  kernel $(uname -r)  $(cat /etc/rocky-release 2>/dev/null)"
    sec "disk before"; df -h / /boot /home 2>/dev/null

    if ((FORCE == 0 && MAINT_SKIP_IF_BUSY == 1)) && node_busy; then
        log "GPU or Slurm work in progress, skipping"
        busy_reason | sed 's/^/  /'
        log "run with --force (menu: 'Force maintenance') to clean anyway;"
        log "with MAINT_REBOOT_MODE=$MAINT_REBOOT_MODE a forced run will not reboot the node"
        exit 10
    fi

    # --- kernels and /boot ---------------------------------------------------
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

    # --- upgrade -------------------------------------------------------------
    if ((UPDATE)); then
        sec "upgrade"
        ARGS=(--refresh); for p in $MAINT_EXCLUDE_PKGS; do ARGS+=("--exclude=$p"); done
        ((MAINT_SECURITY_ONLY)) && ARGS+=(--security)
        dnf check-update "${ARGS[@]}" 2>/dev/null | sed 's/^/  /' || true
        run dnf -y "${ARGS[@]}" upgrade
        dnf autoremove --assumeno 2>&1 | grep -E '^\s+\S+\s+x86_64|Remove' | sed 's/^/  would-remove /' || true
        ((MAINT_AUTOREMOVE)) && run dnf -y autoremove
    fi

    # --- cleanup -------------------------------------------------------------
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
            if is_model_store "$d"; then
                log "SKIP $d — looks like a model store, not touching it"
                continue
            fi
            log "$(du -sh "$d" 2>/dev/null | cut -f1) in $d"
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

        sec "logical volumes"
        lvm_report
        # fstrim frees nothing in df; it tells the SSD which blocks the
        # filesystems stopped using, which is what keeps a thin pool honest.
        if ((MAINT_FSTRIM)); then
            if command -v fstrim >/dev/null; then run fstrim -av
            else log "fstrim not installed (dnf install util-linux), skipping trim"; fi
        fi
    fi

    # --- firewall ------------------------------------------------------------
    if ((MAINT_DISABLE_FIREWALL)); then
        sec "firewalld"
        if systemctl list-unit-files firewalld.service &>/dev/null; then
            run systemctl disable --now firewalld
            run systemctl mask firewalld
        fi
        log "state: $(systemctl is-enabled firewalld 2>&1) / $(systemctl is-active firewalld 2>&1)"
    fi

    # --- GPU and reboot ------------------------------------------------------
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
            if-idle)   node_busy && log "busy, not rebooting" \
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
menu() {
    while true; do
        echo -e "${BLUE}─────────────────────────────────────────────${NC}"
        echo -e "${CYAN}        Rocky 9 GPU node — MENU${NC}"
        echo -e "${BLUE}─────────────────────────────────────────────${NC}"
        echo "1. Bootstrap this node (driver, CUDA, docker)"
        echo "2. Run maintenance now (clean + update)"
        echo "3. Force maintenance (ignore the busy guard)"
        echo "4. Dry run (print, change nothing)"
        echo "5. Install schedule — cron"
        echo "6. Install schedule — systemd timer"
        echo "7. Remove schedule"
        echo "8. Status"
        echo -e "${RED}0. Exit${NC}"
        echo -e "${BLUE}─────────────────────────────────────────────${NC}"
        read -r -p "Choose an action [0-8]: " choice || break
        case $choice in
            1) echo -e "${YELLOW}→  Bootstrap${NC}";        bootstrap ;;
            2) echo -e "${YELLOW}→  Maintenance${NC}";      maintenance; log_info "exit $?" ;;
            3) echo -e "${YELLOW}→  Forced maintenance${NC}"; maintenance --force; log_info "exit $?" ;;
            4) echo -e "${YELLOW}→  Dry run${NC}";          maintenance --dry-run; log_info "exit $?" ;;
            5) echo -e "${YELLOW}→  Install (cron)${NC}";   do_install ;;
            6) echo -e "${YELLOW}→  Install (timer)${NC}";  do_install --timer ;;
            7) echo -e "${YELLOW}→  Remove schedule${NC}";  do_uninstall ;;
            8) do_status ;;
            0) echo -e "${GREEN}Bye.${NC}"; break ;;
            "") ;;
            *) log_error "invalid choice, enter 0-8" ;;
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
    "")          banner; menu ;;
    *)           log_error "unknown command: $1  (try --help)"; exit 2 ;;
esac
