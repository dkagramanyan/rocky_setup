# NVIDIA driver and CUDA on Rocky Linux 9

Target: working `nvidia-smi`, `nvcc`, and DKMS that survives kernel updates.
Ada and Blackwell cards (RTX 40xx/50xx, GB20x) **require the open kernel
modules**. When in doubt use `open-dkms`, it works on older cards too.

`bin/bootstrap-gpu-node.sh` automates everything below. This page is the
reference for when it goes wrong.

## Order of operations

| # | Step | Command |
|---|---|---|
| 1 | GPU visible on the bus | `lspci \| grep -i nvidia` |
| 2 | Base update | `dnf upgrade --refresh -y && reboot` |
| 3 | Repos | `epel-release`, `crb`, CUDA rhel9 repo |
| 4 | Build deps | `Development Tools`, `kernel-devel-$(uname -r)`, `kernel-headers-$(uname -r)`, `dkms`, `elfutils-libelf-devel`, `libglvnd-devel` |
| 5 | Blacklist nouveau | `grubby --args="rd.driver.blacklist=nouveau nouveau.modeset=0" --update-kernel=ALL` then `dracut --force` and reboot |
| 6 | Driver | `dnf module reset -y nvidia-driver` then `dnf module install -y nvidia-driver:open-dkms`, reboot |
| 7 | CUDA | `dnf install -y cuda-toolkit`, installs to `/usr/local/cuda-<ver>` |
| 8 | Environment | `/etc/profile.d/cuda.sh` with `CUDA_HOME`, `PATH`, `LD_LIBRARY_PATH` |
| 9 | Verify | `modinfo nvidia \| grep license` → `GPL`; then `nvidia-smi`; then `nvcc --version` |
| 10 | Version lock | `dnf versionlock add 'nvidia-driver*' 'cuda*'` |

Step 5 is mandatory. Step 9 must be done in that order, a `GPL` license line
confirms the open modules are the ones actually loaded.

## CUDA repo added on a node that already had ELRepo

ELRepo `kmod-nvidia` conflicts with the CUDA repo module stream. Remove it
first, then reset the module state, otherwise modular filtering hides the
stream:

```bash
rpm -qa | grep -Ei 'nvidia|cuda' | sort
dnf remove -y 'kmod-nvidia*' 'nvidia-x11-drv*'
dnf module reset -y nvidia-driver
dnf clean all && dnf makecache
dnf module enable  -y nvidia-driver:open-dkms
dnf module install -y nvidia-driver:open-dkms
reboot
```

## Troubleshooting

**`nvidia-smi: No devices were found`** — check `dmesg | grep -E "NVRM|nvidia"`.
A line about requiring the open kernel modules means the proprietary driver is
installed on a card that will not accept it. Redo step 6 with `open-dkms`.

**`Driver/library version mismatch`** — the RPMs updated but the old module is
still loaded. Reboot. This is the failure mode that
`MAINT_REBOOT_MODE`/`MAINT_EXCLUDE_PKGS` in the maintenance script exist to
manage.

**Modules do not load at all** — `mokutil --sb-state`. With Secure Boot enabled
you must either disable it in firmware or sign the DKMS modules.

**DKMS did not rebuild after a kernel update** — `dkms status`, and confirm
`kernel-devel` matching the *new* kernel is installed, not only the running one.

## Version locking

Locking prevents a routine `dnf upgrade` from pulling a driver that does not
match the running kernel:

```bash
dnf install -y dnf-plugin-versionlock
dnf versionlock add 'nvidia-driver*' 'cuda*'
```

Mirror the same set in `MAINT_EXCLUDE_PKGS` so the maintenance script and dnf
agree about what is pinned.
