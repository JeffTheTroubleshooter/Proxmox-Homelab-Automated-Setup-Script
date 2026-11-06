# Proxmox Homelab Automated Setup Script

> ✅ **Tested and working** on Proxmox VE with Debian 13 containers. Nothing is installed on the Proxmox host itself: Docker and every app run only inside the LXC containers, set up with `pct exec` (no SSH). Change the default passwords after the first run.

One script, run on a Proxmox VE host, that creates 4 Debian LXC containers (Debian 13 template, Debian 12 if 13 isn't available), installs Docker + the Compose plugin in each, runs every app from its **official Docker image**, health-checks them and prints every URL at the end. Nothing is compiled on the host or in the containers (except ForgePanel's small Python image, built from its own Dockerfile). Use [ForgePanel](https://github.com/JeffTheTroubleshooter/ForgePanel-Dashboard) to see them all in one place.

| Preferred CT | Name | CPU | RAM | Disk | Apps (port) |
|--------------|------|-----|-----|------|-------------|
| 200 | docker-stack | 2–4 (auto) | 2–6 GB (auto) | 40 GB | Immich (2283), Nextcloud (8080), RomM (8081), Nginx Proxy Manager (81, plus 80/443) |
| 201 | source-stack | 4 | 3072 MB | 24 GB | Jellyfin (8096), Navidrome (4533), FileBrowser (8082), AdGuard Home (3000, DNS 53) |
| 202 | light-stack | 1 | 1024 MB | 8 GB | Vaultwarden (8000), Trilium (8083) |
| 203 | forgepanel | 1 | 768 MB | 6 GB | ForgePanel (**https**://<ip>:8084, self-signed cert) |

### Images

| App | Image |
|-----|-------|
| Immich | Immich's release `docker-compose.yml` (`ghcr.io/immich-app/immich-server`, `immich-machine-learning`, valkey, postgres) |
| Nextcloud | `nextcloud:apache` + `mariadb:11` + `redis:7-alpine` |
| RomM | `rommapp/romm:latest` + `mariadb:11` |
| Nginx Proxy Manager | `jc21/nginx-proxy-manager:latest` |
| Jellyfin | `jellyfin/jellyfin:latest` (includes jellyfin-ffmpeg) |
| Navidrome | `deluan/navidrome:latest` (music from `/mnt/music` in source-stack) |
| FileBrowser | `filebrowser/filebrowser:latest` (serves `/srv/files` in source-stack) |
| AdGuard Home | `adguard/adguardhome:latest` |
| Vaultwarden | `vaultwarden/server:latest` |
| Trilium | `triliumnext/trilium:latest` |
| ForgePanel | built from [ForgePanel-Dashboard](https://github.com/JeffTheTroubleshooter/ForgePanel-Dashboard)'s Dockerfile, run with `--https` |

Pin a version with an environment variable, e.g. `JELLYFIN_IMAGE=jellyfin/jellyfin:10.11.5 bash Proxmox_Homelab-Setup.sh`.

Each app lives in `/opt/homelab/<app>/` inside its container (`docker-compose.yml`, `.env`, data folders). Every container uses `restart: always`.

> **ForgePanel** is served over **HTTPS** at `https://<forgepanel-ip>:8084` with a self-signed certificate (your browser warns once). Use `https://`, not `http://`.

> **Note:** TrueNAS is set up manually; this script does not create it.

All four containers are **privileged** with `nesting=1,keyctl=1` so Docker can use `overlay2` (in an unprivileged container Docker falls back to very slow `fuse-overlayfs`/`vfs`).

## Standalone app installer repos

The per-app repos below are **native installers** (from source or release tarballs, no Docker) for running an app directly on a machine. `Proxmox_Homelab-Setup.sh` no longer uses or embeds them.

- [Jellyfin](https://github.com/JeffTheTroubleshooter/Jellyfin-Automated-Setup-Script) · [Navidrome](https://github.com/JeffTheTroubleshooter/Navidrome-Automated-Setup-Script) · [FileBrowser](https://github.com/JeffTheTroubleshooter/FileBrowser-Automated-Setup-Script) · [AdGuard Home](https://github.com/JeffTheTroubleshooter/AdGuard-Home-Automated-Setup-Script) · [Vaultwarden](https://github.com/JeffTheTroubleshooter/Vaultwarden-Automated-Setup-Script) · [Trilium](https://github.com/JeffTheTroubleshooter/Trilium-Automated-Setup-Script) · [Immich](https://github.com/JeffTheTroubleshooter/Immich-Automated-Setup-Script) · [Nextcloud](https://github.com/JeffTheTroubleshooter/Nextcloud-Automated-Setup-Script) · [RomM](https://github.com/JeffTheTroubleshooter/RomM-Automated-Setup-Script) · [Nginx Proxy Manager](https://github.com/JeffTheTroubleshooter/Nginx-Proxy-Manager-Automated-Setup-Script)

## Usage

On the Proxmox host, as root:

| Command | What it does |
|---------|--------------|
| `bash Proxmox_Homelab-Setup.sh` | Create the four containers and install every app (default mode) |
| `bash Proxmox_Homelab-Setup.sh update` | Pull newer images and recreate the apps in the existing containers |
| `bash Proxmox_Homelab-Setup.sh reset-logins` | Reset default logins and redeploy Vaultwarden with HTTPS; keeps data |
| `bash Proxmox_Homelab-Setup.sh self-update` | Pull the newest version of this script from GitHub |
| `bash Proxmox_Homelab-Setup.sh destroy` | Remove only the containers this script created (alias: `remove`) |

### Defaults

| Setting | Value |
|---------|-------|
| Bridge | `vmbr0` |
| Storage | `local-lvm` |
| Saved IDs file | `/root/.homelab-script/ids` |

### Containers

| Container | Apps | Default ID | Override variable |
|-----------|------|------------|-------------------|
| `docker-stack` | Immich, Nextcloud, RomM, Nginx Proxy Manager | 200 | `CT_ID_DOCKER` |
| `source-stack` | Jellyfin, Navidrome, FileBrowser, AdGuard Home | 201 | `CT_ID_SOURCE` |
| `light-stack` | Vaultwarden, Trilium | 202 | `CT_ID_LIGHT` |
| `forgepanel` | ForgePanel | 203 | `CT_ID_FORGE` |

Example override:

```bash
CT_ID_DOCKER=205 CT_ID_SOURCE=206 bash Proxmox_Homelab-Setup.sh
```

### How container IDs are picked

- Reuses IDs it created itself (listed in `/root/.homelab-script/ids`, or whose hostname matches the slot / `ct-map`).
- Never modifies a CT or VM that belongs to you; if a preferred ID is taken it warns, e.g. `CT 200 is in use by otherbox; using 205 for docker-stack`, and takes the next free ID from `pvesh get /cluster/nextid`.
- Reruns keep existing `.env` files and data.
- `destroy` / `remove` only deletes this script's own containers, and only after you type `yes`.

## What happens during a run

1. Downloads the newest Debian standard LXC template (13, falling back to 12).
2. Creates each container (privileged, `nesting=1,keyctl=1`, DHCP on `vmbr0`, tag `homelab-script`).
3. Installs Docker CE + the Compose plugin from Docker's official apt repo and checks Docker uses `overlay2`.
4. For each app: writes `docker-compose.yml` (and a `.env` with generated passwords on first run), runs `docker compose pull` and `up -d`, then checks none of its containers exited or is restarting.
5. Health checks: every app must answer on its port (ForgePanel over HTTPS). If one doesn't, the run stops with a red `FAILED: <app> ... health check` line instead of printing `Homelab ready`.

Logs of each step are in `/var/log/homelab-script/` on the host.

### Progress output and failure detection

Every 30 seconds a long step prints its elapsed time and the last lines of its log (`HEARTBEAT_SECS=60` changes the interval). The wait never hangs:

- if the step's process exits, its exit code is checked right away (non-zero → red `FAILED` line plus the log tail);
- if the kernel OOM-kills anything in the container's memory cgroup (`oom_memcg=/lxc/<ctid>` in `dmesg`), the step is stopped and reported as `FAILED` with an out-of-memory message; a container that Docker reports as OOM-killed is reported the same way;
- each app install has an overall timeout, `APP_TIMEOUT_SECS` (default 1800; `0` disables it).

## Logins

> ⚠️ **Every app gets the same default login. Change it right after the first login**, or set your own
> before running: `HOMELAB_ADMIN_USER=me HOMELAB_ADMIN_PASS='At-Least-12-Chars' bash Proxmox_Homelab-Setup.sh`
> (12+ characters, letters/digits/`._@+=-`).

| App | URL | User | Password |
|---|---|---|---|
| Immich | http://IP:2283 | admin@example.com | Homelab-Admin-2026 |
| Nextcloud | http://IP:8080 | admin | Homelab-Admin-2026 |
| RomM | http://IP:8081 | setup wizard on first open | |
| Nginx Proxy Manager | http://IP:81 | admin@example.com | Homelab-Admin-2026 (older installs: changeme) |
| Jellyfin | http://IP:8096 | admin | Homelab-Admin-2026 |
| Navidrome | http://IP:4533 | admin | Homelab-Admin-2026 |
| FileBrowser | http://IP:8082 | admin | Homelab-Admin-2026 |
| AdGuard Home | http://IP:3000 | setup wizard (keep admin port 3000) | |
| Vaultwarden | **https**://IP:8000 | create an account; `/admin` token | Homelab-Admin-2026 |
| Trilium | http://IP:8083 | set a password on first open | |
| ForgePanel | https://IP:8084 | admin | forgepanel |

Vaultwarden uses a self-signed certificate (the web vault refuses to run without HTTPS), so accept the browser warning once.
The script prints this table with real IPs at the end of every run.

Fix logins on an existing install (keeps data): `bash Proxmox_Homelab-Setup.sh reset-logins`. It resets the FileBrowser and Nextcloud
admin passwords, redeploys Vaultwarden with HTTPS, and creates the Immich/Navidrome/Jellyfin admin if none exists yet.

## Security note

The containers use a default root password (`admin`) set at the top of the script. Change `PASSWORD` before running, or change it afterwards:

```bash
pct enter <ctid>
passwd
```

The containers are privileged so Docker runs at normal speed, which gives their services more access to the host than an unprivileged container. Keep the images updated (`bash Proxmox_Homelab-Setup.sh update`) and do not expose the apps to the internet without a reverse proxy and authentication.
