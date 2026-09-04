# rocky9-gpu-node

Provisioning and unattended maintenance for Rocky Linux 9 GPU compute nodes.
Two scripts: one that builds a node from scratch, one that keeps it clean and
current from cron.

## Layout

```
bin/bootstrap-gpu-node.sh    one-shot provisioning: driver, CUDA, docker, firewall
bin/node-maintenance.sh      recurring cleanup and update
config/node-maintenance.env  all tunables, installed to /etc/sysconfig/
cron/                        daily clean, weekly full run
systemd/                     timer alternative to cron
logrotate/                   rotation for the script's own logs
install.sh                   deploys the above
docs/nvidia-cuda.md          driver and CUDA reference, troubleshooting
docs/storage.md              /boot pressure, moving docker and containerd to /home
docs/firewall-and-ports.md   firewalld policy, GPUStack port list
```

## Install

```bash
git clone <this-repo> && cd rocky9-gpu-node
sudo ./install.sh                  # cron
sudo USE_TIMER=1 ./install.sh      # systemd timer instead
sudo node-maintenance.sh --dry-run
```

New node from scratch:

```bash
sudo ./bin/bootstrap-gpu-node.sh   # reboots twice, re-run after each
```

## What the maintenance run does

1. `flock`, so overlapping cron runs cannot collide.
2. Exits 10 if `nvidia-smi` shows compute processes or `squeue` shows jobs here.
3. Prunes kernels to `MAINT_KEEP_KERNELS` and deletes orphaned `initramfs`,
   `vmlinuz`, `System.map`, `config` and BLS loader entries. Before the upgrade,
   because a full `/boot` is what breaks kernel installs on these nodes.
4. Skips the upgrade entirely if `/boot` is still under `MAINT_BOOT_MIN_FREE_MB`.
5. `dnf upgrade` with the configured excludes, `dnf clean all`.
6. Journal vacuum, rotated logs, core dumps, `/tmp` and `/var/tmp` by atime,
   pip/uv/npm caches, `docker`/`podman` prune.
7. Disables and masks `firewalld` when `MAINT_DISABLE_FIREWALL=1`.
8. Reports GPU state, `dkms status`, and the `nvidia` module license.
9. `needs-restarting -r`, then acts on `MAINT_REBOOT_MODE`.

Log: `/var/log/node-maintenance/latest.log`.

## Options and exit codes

```
node-maintenance.sh                clean + update
node-maintenance.sh --clean-only   no package upgrade
node-maintenance.sh --update-only  kernel pruning + upgrade only
node-maintenance.sh --dry-run      print, change nothing
node-maintenance.sh --force        ignore the busy guard
```

| Code | Meaning |
|---|---|
| 0 | success |
| 10 | skipped, node was busy |
| 20 | finished, one or more steps failed |
| 30 | another instance was already running |

## Two decisions to make per cluster

**Driver updates.** The default updates the kernel and driver but never
reboots, which leaves a window where `nvidia-smi` reports a driver/library
mismatch and CUDA jobs cannot start. Either pin the stack with
`MAINT_EXCLUDE_PKGS` plus `dnf versionlock` and handle it in a window, or set
`MAINT_REBOOT_MODE=if-idle`. With Slurm, drain from the controller rather than
trusting the idle check alone.

**Autoremove.** `MAINT_AUTOREMOVE=0` on purpose. With third-party NVIDIA and
CUDA repos, `dnf autoremove` proposes removing packages the driver needs. Every
run logs what it *would* remove as `would-remove` lines. Read a few weeks
before enabling.

## First run on a node with a full /boot

cn-005 style, `/boot` at 904M of 960M. Clear it by hand once, then the script
holds the line:

```bash
sudo dnf -y --setopt=installonly_limit=2 remove --oldinstallonly
df -h /boot
```

Still tight? Set `MAINT_DROP_RESCUE=1` to drop the `0-rescue` image.
