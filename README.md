<h1 align="center">rocky_setup</h1>

## Provisioning and maintenance for Rocky Linux 9 GPU nodes

One self-contained script. It builds a node from scratch, keeps it clean and
current on a schedule, and gives you a menu when you run it with no arguments.

## What it does

- **Bootstrap** a fresh node: NVIDIA driver (open DKMS modules), CUDA toolkit,
  docker relocated to `/home`, nvidia-container-toolkit, firewalld off,
  versionlock on the NVIDIA stack.
- **Maintenance**, unattended: kernel pruning before the upgrade so `/boot` has
  room for the new initramfs, `dnf upgrade` with your excludes, journal vacuum,
  rotated logs, core dumps, `/tmp` and `/var/tmp` by atime, pip/uv/npm caches,
  `docker`/`podman` prune, GPU and `dkms` report, reboot policy.
- **Guards**: `flock` against overlapping runs, a busy check on `nvidia-smi`
  compute processes and `squeue`, a `/boot` free-space floor, and per-node
  start jitter so a cluster does not hit the mirrors at once.
- **Schedule**: installs itself as a cron job or a systemd timer, running
  **every 2 weeks, Saturday 08:00 MSK (GMT+3)**.

## Requirements

- Rocky Linux 9 (or a RHEL 9 rebuild), root or sudo.
- For the GPU stages: an NVIDIA card on the PCI bus, Secure Boot off.

## Install

1. Clone the repository

    ```bash
    git clone https://github.com/dkagramanyan/rocky_setup.git && cd rocky_setup
    ```

2. Make it executable

    ```bash
    chmod +x node-setup.sh
    ```

3. Run it

    ```bash
    sudo ./node-setup.sh
    ```

4. Or in one command (needs sudo)

    ```bash
    sudo bash <(curl -fsSL https://raw.githubusercontent.com/dkagramanyan/rocky_setup/main/node-setup.sh)
    ```

Non-interactive, for a fleet:

```bash
sudo ./node-setup.sh bootstrap             # new node, reboots twice, re-run after each
sudo ./node-setup.sh install               # cron, every 2 weeks Sat 08:00 MSK
sudo ./node-setup.sh install --timer       # systemd timer instead
sudo ./node-setup.sh maintenance --dry-run # verify, change nothing
```

## Schedule

The cron job and the timer both fire **every Saturday at 08:00 Europe/Moscow**;
`--scheduled` makes the script exit early on odd ISO weeks, so a run actually
lands every 2 weeks. `MAINT_JITTER_SEC=1800` then spreads the cluster over the
following half hour.

| | |
|---|---|
| cron | `CRON_TZ=Europe/Moscow` + `0 8 * * 6` in `/etc/cron.d/node-maintenance` |
| timer | `OnCalendar=Sat *-*-* 08:00:00 Europe/Moscow`, falls back to `05:00 UTC` if systemd rejects the timezone |
| every 2 weeks | `MAINT_BIWEEKLY=1` — run only when the ISO week number is even |

Set `MAINT_BIWEEKLY=0` in `/etc/sysconfig/node-maintenance` for a weekly run.
The gap is exactly 14 days except once across a 53-week year boundary.

## What the maintenance run does

1. `flock`, so overlapping runs cannot collide.
2. Exits 0 if this is an odd ISO week and `MAINT_BIWEEKLY=1`.
3. Exits 10 if `nvidia-smi` shows compute processes or `squeue` shows jobs here.
4. Prunes kernels to `MAINT_KEEP_KERNELS` and deletes orphaned `initramfs`,
   `vmlinuz`, `System.map`, `config` and BLS loader entries. Before the upgrade,
   because a full `/boot` is what breaks kernel installs on these nodes.
5. Skips the upgrade entirely if `/boot` is still under `MAINT_BOOT_MIN_FREE_MB`.
6. `dnf upgrade` with the configured excludes, `dnf clean all`.
7. Journal vacuum, rotated logs, core dumps, `/tmp` and `/var/tmp` by atime,
   pip/uv/npm caches, `docker`/`podman` prune.
8. Disables and masks `firewalld` when `MAINT_DISABLE_FIREWALL=1`.
9. Reports GPU state, `dkms status`, and the `nvidia` module license.
10. `needs-restarting -r`, then acts on `MAINT_REBOOT_MODE`.

Log: `/var/log/node-maintenance/latest.log`.

## Commands and exit codes

```
node-setup.sh                       interactive menu
node-setup.sh bootstrap [stages]    base repos nouveau driver cuda toolkit docker firewall lock
node-setup.sh maintenance           clean + update now
node-setup.sh install [--timer]     deploy the script, config and schedule
node-setup.sh uninstall             remove the schedule, keep script, config, logs
node-setup.sh status                what is installed, when it next runs
```

Maintenance options: `--clean-only`, `--update-only`, `--dry-run`, `--force`
(ignore the busy guard), `--scheduled` (honour `MAINT_BIWEEKLY`).

| Code | Meaning |
|---|---|
| 0 | success, or skipped on an odd week |
| 10 | skipped, node was busy |
| 20 | finished, one or more steps failed |
| 30 | another instance was already running |

## Installed layout

```
/usr/local/sbin/node-setup.sh        the script
/etc/sysconfig/node-maintenance      all tunables
/etc/cron.d/node-maintenance         or /etc/systemd/system/node-maintenance.{service,timer}
/etc/logrotate.d/node-maintenance    rotation for the script's own logs
/var/log/node-maintenance/           logs, latest.log is a symlink to the newest
docs/nvidia-cuda.md                  driver and CUDA reference, troubleshooting
docs/storage.md                      /boot pressure, moving docker and containerd to /home
docs/firewall-and-ports.md           firewalld policy, GPUStack port list
```

`install` keeps an existing config and drops the new defaults next to it as
`/etc/sysconfig/node-maintenance.new`.

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

## How it looks

```
┌────────────────────────────────────────────┐
│ ██████╗  ██████╗  ██████╗██╗  ██╗██╗   ██╗ │
│ ██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝╚██╗ ██╔╝ │
│ ██████╔╝██║   ██║██║     █████╔╝  ╚████╔╝  │
│ ██╔══██╗██║   ██║██║     ██╔═██╗   ╚██╔╝   │
│ ██║  ██║╚██████╔╝╚██████╗██║  ██╗   ██║    │
│ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝   ╚═╝    │
└────────────────────────────────────────────┘
rocky9-gpu-node — provisioning and maintenance for Rocky Linux 9 GPU nodes
Version: 2.0
Schedule: every 2 weeks, Saturday 08:00 MSK (even ISO weeks)

─────────────────────────────────────────────
        Rocky 9 GPU node — MENU
─────────────────────────────────────────────
1. Bootstrap this node (driver, CUDA, docker)
2. Run maintenance now (clean + update)
3. Dry run (print, change nothing)
4. Install schedule — cron
5. Install schedule — systemd timer
6. Remove schedule
7. Status
0. Exit
─────────────────────────────────────────────
Choose an action [0-7]:
```

## Upgrading from v1

v1 shipped `install.sh`, `bin/`, `config/`, `cron/`, `systemd/` and
`logrotate/`; all of it is now inside `node-setup.sh`. `sudo ./node-setup.sh
install` overwrites `/etc/cron.d/node-maintenance` with the new biweekly entry
and keeps your `/etc/sysconfig/node-maintenance`. The old
`/usr/local/sbin/node-maintenance.sh` and `bootstrap-gpu-node.sh` are left in
place and no longer referenced — remove them by hand once the new schedule has
run.
