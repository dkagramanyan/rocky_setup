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
- **What it never deletes**: tagged container images, and anything that looks
  like a model store — see below.
- **Logical volumes**: reports the volume groups, logical volumes, snapshots
  and free extents, and runs `fstrim -av` so the SSD learns which blocks the
  filesystems no longer use. It never resizes or removes a volume.
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
following half hour — **only for `--scheduled` runs**. An interactive run from
the menu never waits, and when a scheduled run does wait it logs
`jitter: sleeping 1725s ...` first, so it can never be mistaken for a hang.

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
   pip/uv/npm caches, `docker`/`podman` prune (see below).
8. Logs `vgs`/`lvs` and runs `fstrim -av` when `MAINT_FSTRIM=1`.
9. Disables and masks `firewalld` when `MAINT_DISABLE_FIREWALL=1`.
10. Reports GPU state, `dkms status`, and the `nvidia` module license.
11. `needs-restarting -r`, then acts on `MAINT_REBOOT_MODE`.

Log: `/var/log/node-maintenance/latest.log`.

## What the cleanup will not touch

**Container images.** The prune is `docker system prune -f`, deliberately
without `-a`. It removes stopped containers, unused networks, dangling
(untagged) layers and build cache. Every tagged image stays, whether or not a
container is currently running it. `prune -a` would delete the images people
actually work with, which is not something a cron job should decide.

**Model weights.** Weights are read rarely, so ageing a cache by atime would
delete exactly the wrong files. Any directory whose path contains `gpustack`,
`huggingface`, `ollama`, `modelscope`, `torch/hub`, or ends in `/hub`, `/model`
or `/models` is skipped by name, even if it is listed in `MAINT_CACHE_DIRS`:

```
SKIP /var/lib/gpustack — looks like a model store, not touching it
```

`MAINT_CACHE_DIRS` should point at rebuildable caches — pip, uv, npm — and
never at a model store.

## When the node is busy

A run exits 10 without touching anything if `nvidia-smi` reports compute
processes or `squeue` shows jobs on this host. That is the guard doing its job,
not a failure — the log then names the processes holding the node:

```
GPU or Slurm work in progress, skipping
  GPU compute processes (pid, name, memory):
    3412, python3, 1646 MiB
```

To clean anyway, use `--force` (menu entry 3). With the default
`MAINT_REBOOT_MODE=never` a forced run will not reboot the node, and kernel
pruning — the part that rescues a full `/boot` — is safe while jobs run.

`status` prints the same list up front, and warns if a schedule is installed
while `/usr/local/sbin/node-setup.sh` is missing, which means the cron job or
timer is firing into nothing.

## Check and update a GPU node (`--check`, `--update`)

Run these on each node, from the repository clone, with sudo. One node at a
time: finish a node (including its watch window) before starting the next.

```bash
sudo ./node-setup.sh --update             # update everything, press Enter at each question
sudo ./node-setup.sh --update             # again after the reboot: verify, start GPUStack, watch
sudo ./node-setup.sh --check              # read-only report, exit 1 on any problem
sudo ./node-setup.sh --update --dry-run   # print every change, make none
```

By default `--update` removes **every** version lock and updates everything.
To keep a lock, for example the NVIDIA driver, type its number at the lock
question. Every question defaults to Yes, so Enter goes ahead.

A crash dump that is new stops the update. New means newer than the last
`--check`, or from the last 7 days if there has been no check yet. Every run
writes `./reports/<time>-<mode>-<host>.log`. `--check` also writes
`./reports/summary-<host>.env`.

Run `--update` inside `tmux` or `screen` when you are on SSH. A dropped
connection kills `dnf` in the middle of a kernel or DKMS install.

### What `--check` reports

The detail block, then one table row per node:

```
NODE     UP      KERNEL    NEWEST    BIOS   DRIVER     FLAV NVIDIA-OPEN          KMOD-DKMS            DKMS  IRQBALANCE       KDUMP  DUMPS tot/new/newest  TIMER  WORKER          LOCKS
cn-002   14d6h   687.51.1  687.51.1  1403   610.57.04  open 610.57.04>615.71.09  610.57.04>615.71.09  ok    inactive/masked  armed  208/0/2026-10-04      201    running/always  15/22 behind
```

It covers: kernel running and newest installed, BIOS, loaded driver and
module license, installed and newest available `nvidia-open` and
`kmod-nvidia-open-dkms`, and `dkms status` for every installed kernel. It also
shows irqbalance (reported only, never changed), kdump, and the crash dumps in
`/var/crash` and `/var/crash/logs`: total, new since the last check, newest,
how many match the timer signature, and which CPUs crashed. Finally it shows
what `crash-cleanup.service` deletes, whether
`/usr/local/sbin/kernel-timer-watch` is enabled, the `gpustack-worker` state
and restart policy, and whether `90-crashdebug.conf` is in place.

The table also lists every other `summary-*.env` found in `./reports`. Copy
the other nodes' files there to get a fleet view, and the loaded driver is
compared across them.

Exit 1 if this node has any of these:

- a lock behind an available update
- a driver different from the newest one in the fleet
- a kernel without a built nvidia module
- a new crash dump, or a new timer-signature dump
- kdump not armed
- a failed `repoquery`

The counts of old dumps are reported, but they do not fail the check.

### Version locks

`dnf versionlock` makes `dnf upgrade` skip a package without saying so. That
is how cn-002 stayed on the crashing 610.57.04 for two months. Each lock is
compared with the newest version in the enabled repos, with the lock
disabled:

| Status | Meaning |
|---|---|
| `LOCKED-BEHIND` | a newer version is available, the lock is holding it back |
| `LOCKED-CURRENT` | the locked version is the newest available |
| `LOCKED-UNKNOWN` | `repoquery` failed, nothing can be said |

The locks are grouped into NVIDIA driver, CUDA toolkit and other. The date
comes from the `# Added lock on …` comment in
`/etc/dnf/plugins/versionlock.list`:

```
!! cn-002: 15 packages version-locked behind available updates
   NVIDIA driver   610.57.04 -> 615.71.09 available   (locked since 2026-08-17)   [11 packages]
   CUDA toolkit    13.3.0 -> 13.3.1 available   (locked since 2026-08-17)   [4 packages]
   other           none
```

The scheduled `maintenance` run prints the same block and exits 20 when locks
hold something back, so the drift shows up in its log and mail.

### What `--update` does, in order

1. Runs the checks above. If a crash dump appeared since the last check, it
   stops. A crashing node is not updated blindly.
2. If the node has locks, it lists them by group and removes them all
   unless you pick some to keep:
   ```
   These version locks will be removed so everything updates:
     1) NVIDIA driver  610.57.04 -> 615.71.09 available   (11 locked, 11 behind, since 2026-08-17)
     2) CUDA toolkit   13.3.0 -> 13.3.1 available   (4 locked, 4 behind, since 2026-08-17)
   Keep any of them locked? Enter = none, or numbers (e.g. 1):
   ```
   `versionlock.list` is first copied to `versionlock.list.bak-<time>`.
   Then `dnf versionlock clear` runs, or `dnf versionlock delete` for the
   groups you did not keep. Next it shows the full transaction with the
   NVIDIA and kernel lines highlighted and asks `Proceed? [Y/n]`. Answering
   `n` puts the backup back, so the locks are exactly as they were.
3. Stops `gpustack-worker`, then the model containers (`*-run-*`, `*-pause`),
   and records what was running.
4. Sets `gpustack-worker` to `--restart=no` and records the old policy.
   Asks once whether to add `kernel.ftrace_dump_on_oops = 1` in
   `/etc/sysctl.d/90-crashdebug.conf`, if it is not there yet.
5. `dnf -y --refresh upgrade`
6. `dnf -y --setopt=installonly_limit=2 remove --oldinstallonly`
7. (Locks you chose to keep stay as they are. Nothing is re-locked.)
8. **Pre-reboot gate** for the newest kernel: `dkms status -k` says
   `installed`, `extra/nvidia.ko.xz` exists, its version is the installed
   driver, and `grubby --default-kernel` points at it. If anything fails, it
   does not reboot and leaves the node drained.
9. If `needs-restarting -r` or the driver change requires it, asks
   `Reboot <node> now? [Y/n]`.

The state of the update is kept in `/var/lib/node-setup/update.state`. While
that file exists the node stays drained with `restart=no`, and the next
`sudo ./node-setup.sh --update` resumes here:

10. Verifies: the running kernel is the newest one, `nvidia-smi` reports the
    installed driver, irqbalance is unchanged, kdump is armed, and there is no
    new crash dump.
11. Starts `gpustack-worker` and waits up to 10 min for the model containers.
12. Watches for 15 min, then checks for new crash dumps and kdump again.
    Only then does it restore the old restart policy. A crash in the window
    therefore cannot turn into a boot loop. If the node rebooted during the
    window, the next `--update` says so and leaves the policy at `no`.

Any failed step stops the update with the node drained. Fix the cause, then
run `--update` again. To abandon an unfinished update, remove
`/var/lib/node-setup/update.state` and restore the restart policy by hand
(`docker update --restart=<policy> gpustack-worker`).

Never touched: crash dumps, irqbalance, BIOS and firmware, `crash-cleanup.*`,
`kernel-timer-watch`.

## Commands and exit codes

```
node-setup.sh                       interactive menu
node-setup.sh --check               read-only report of this node (exit 1 on problems)
node-setup.sh --update [--dry-run]  guarded update; run again after the reboot
node-setup.sh bootstrap [stages]    base repos nouveau driver cuda toolkit docker firewall lock
node-setup.sh maintenance           clean + update now
node-setup.sh install [--timer]     deploy the script, config and schedule
node-setup.sh uninstall             remove the schedule, keep script, config, logs
node-setup.sh status                what is installed, when it next runs
```

Maintenance options: `--clean-only`, `--update-only`, `--dry-run`, `--force`
(ignore the busy guard), `--scheduled` (honour `MAINT_BIWEEKLY`).

Cleanup knobs in `/etc/sysconfig/node-maintenance`: `MAINT_JOURNAL_AGE`,
`MAINT_JOURNAL_SIZE`, `MAINT_LOG_AGE_DAYS`, `MAINT_TMP_AGE_DAYS`,
`MAINT_CACHE_DIRS`, `MAINT_PRUNE_CONTAINERS`, `MAINT_FSTRIM`.

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
3. Force maintenance (ignore the busy guard)
4. Dry run (print, change nothing)
5. Install schedule — cron
6. Install schedule — systemd timer
7. Remove schedule
8. Status
0. Exit
─────────────────────────────────────────────
Choose an action [0-8]:
```

## Upgrading from v1

v1 shipped `install.sh`, `bin/`, `config/`, `cron/`, `systemd/` and
`logrotate/`; all of it is now inside `node-setup.sh`. `sudo ./node-setup.sh
install` overwrites `/etc/cron.d/node-maintenance` with the new biweekly entry
and keeps your `/etc/sysconfig/node-maintenance`. The old
`/usr/local/sbin/node-maintenance.sh` and `bootstrap-gpu-node.sh` are left in
place and no longer referenced — remove them by hand once the new schedule has
run.
