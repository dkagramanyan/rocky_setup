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

## Move the docker data root

```bash
systemctl stop docker docker.socket containerd
mkdir -p /home/docker-data
# /etc/docker/daemon.json
# { "data-root": "/home/docker-data" }
rsync -aP /var/lib/docker/ /home/docker-data/
systemctl start docker
docker info | grep "Docker Root Dir"
docker images        # sanity check before deleting anything
rm -rf /var/lib/docker
```

## Move containerd

containerd has no data-root setting in this setup, so use a symlink:

```bash
systemctl stop docker docker.socket containerd
mkdir -p /home/containerd-data
rsync -aP /var/lib/containerd/ /home/containerd-data/
rm -rf /var/lib/containerd
ln -s /home/containerd-data /var/lib/containerd
systemctl start containerd docker
```

## Move /opt/services

```bash
mv /opt/services /home/services
ln -s /home/services /opt/services
```

## nvidia runtime not registered

`docker: Error response from daemon: unknown or invalid runtime name: nvidia`

```bash
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-container-toolkit/$distribution/nvidia-container-toolkit.repo \
  | tee /etc/yum.repos.d/nvidia-container-toolkit.repo
dnf clean expire-cache && dnf install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
docker run --rm --gpus all nvidia/cuda:12.4.0-base-rockylinux9 nvidia-smi
```

Note that `docker system prune` in the maintenance script now frees space on
`/home`, not `/`, once the data root has moved.
