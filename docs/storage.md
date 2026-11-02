# Storage layout

On these nodes `/` is a 70 GB LVM volume and `/home` is 374 GB to 1.5 TB.
Container images and service data must not live on `/`.

Current usage for reference:

| Node | `/` | `/boot` | `/home` |
|---|---|---|---|
| cn-004 | 34G / 70G | 700M / 960M | 525G / 1.5T |
| cn-005 | 18G / 70G | 904M / 960M | 232G / 374G |

`/boot` is the pressure point. 960 MB with an NVIDIA initramfs holds two
kernels, not the dnf default of three. See `MAINT_KEEP_KERNELS`.

## Automatic mounting and Docker relocation

Run `sudo ./node-setup.sh setup` for new-node provisioning, or
`sudo ./node-setup.sh bootstrap disks docker` for the storage stages on an
existing node (requires base packages). Completed stages have checkpoints under
`/var/lib/node-setup/bootstrap`; remove the relevant checkpoint to repeat one.

Existing local filesystems are mounted using their fstab destination or
`/mnt/disks/<UUID>`. Blank disks are reported without formatting. See the README
for exclusions. `/home` must be mounted separately before Docker migration.

Docker is installed from its RPM repository, including Compose and Buildx.
Services stop before `rsync -aHAXS --numeric-ids` copies data. The script preserves
existing daemon JSON settings and sets `data-root` to `/home/docker-data`.
Containerd data is copied to `/home/containerd-data`; its original directory is
renamed to `/var/lib/containerd.backup-<timestamp>` before creating the symlink.
SELinux labels and systemd mount dependencies are configured before startup.
Originals are retained; inspect `docker info`, `docker images`, and `docker ps -a`
before manually removing them. Migration failures stop setup for a retry and
never delete the original store. Custom containerd roots require manual migration.

## Move /opt/services

```bash
mv /opt/services /home/services
ln -s /home/services /opt/services
```

## nvidia runtime not registered

`docker: Error response from daemon: unknown or invalid runtime name: nvidia`

```bash
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  | tee /etc/yum.repos.d/nvidia-container-toolkit.repo
dnf clean expire-cache && dnf install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
docker run --rm --gpus all nvidia/cuda:12.4.0-base-rockylinux9 nvidia-smi
```

Note that `docker system prune` in the maintenance script now frees space on
`/home`, not `/`, once the data root has moved.
