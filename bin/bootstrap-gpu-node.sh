#!/usr/bin/env bash
# bootstrap-gpu-node.sh - one-shot provisioning of a fresh Rocky 9 GPU node.
# Derived from docs/nvidia-cuda.md. Reboots twice: after nouveau blacklist and
# after the driver install. Re-run after each reboot, it skips completed stages.
#
#   ./bootstrap-gpu-node.sh            all stages
#   ./bootstrap-gpu-node.sh repos      single stage
#   STAGES="repos driver cuda" ./bootstrap-gpu-node.sh
#
# Stages: base repos nouveau driver cuda toolkit docker firewall lock
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

: "${DRIVER_STREAM:=nvidia-driver:open-dkms}"   # open modules, required for Ada/Blackwell
: "${DOCKER_DATA_ROOT:=/home/docker-data}"      # / is only 70G on these nodes
: "${CONTAINERD_DATA_ROOT:=/home/containerd-data}"
: "${STAGES:=base repos nouveau driver cuda toolkit docker firewall lock}"
[[ $# -gt 0 ]] && STAGES="$*"

say()  { printf '\n=== %s ===\n' "$*"; }
have() { [[ " $STAGES " == *" $1 "* ]]; }

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
    lspci | grep -i nvidia || { echo "no NVIDIA device on the PCI bus" >&2; exit 1; }
    if lsmod | grep -q '^nouveau'; then
        grubby --args="rd.driver.blacklist=nouveau nouveau.modeset=0" --update-kernel=ALL
        dracut --force
        echo "REBOOT NOW, then re-run this script"; exit 0
    fi
    echo "nouveau not loaded, ok"
}

have driver && { say "NVIDIA driver ($DRIVER_STREAM)"
    # ELRepo packages conflict with the CUDA-repo module stream
    dnf remove -y 'kmod-nvidia*' 'nvidia-x11-drv*' 2>/dev/null || true
    dnf module reset  -y nvidia-driver
    dnf module enable -y "$DRIVER_STREAM"
    dnf module install -y "$DRIVER_STREAM"
    mokutil --sb-state 2>/dev/null | grep -qi enabled \
        && echo "WARNING: Secure Boot is on, unsigned modules will not load"
    echo "REBOOT NOW, then re-run this script"
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
    nvidia-smi || echo "nvidia-smi failed, check: dmesg | grep -E 'NVRM|nvidia'"
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
            echo "old data left in /var/lib/docker, remove it once docker images looks right"
        fi
        distribution=$(. /etc/os-release; echo "$ID$VERSION_ID")
        curl -fsSL "https://nvidia.github.io/nvidia-container-toolkit/$distribution/nvidia-container-toolkit.repo" \
            -o /etc/yum.repos.d/nvidia-container-toolkit.repo
        dnf clean expire-cache && dnf install -y nvidia-container-toolkit
        nvidia-ctk runtime configure --runtime=docker
        systemctl restart docker
        docker run --rm --gpus all nvidia/cuda:12.4.0-base-rockylinux9 nvidia-smi || true
    else
        echo "docker not installed, skipping"
    fi
}

have firewall && { say "firewalld off"
    systemctl disable --now firewalld 2>/dev/null || true
    systemctl mask firewalld 2>/dev/null || true
    echo "firewalld: $(systemctl is-enabled firewalld 2>&1) / $(systemctl is-active firewalld 2>&1)"
}

have lock && { say "versionlock"
    dnf versionlock add 'nvidia-driver*' 'cuda*' 'kmod-nvidia*' || true
    dnf versionlock list
    echo "mirror this in MAINT_EXCLUDE_PKGS in config/node-maintenance.env"
}

say "done"
