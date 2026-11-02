# Proxmox Homelab Automated Setup Script

> ⚠️ **Experimental.** This script is still being fixed and tested. Expect bugs, and try it on a test Proxmox host first.

One script, run on a Proxmox VE host, that creates 4 Debian LXC containers (Debian 13 on Proxmox 9, Debian 12 on Proxmox 8), installs a full homelab inside them and prints every URL at the end. Use [ForgePanel](https://github.com/JeffTheTroubleshooter/ForgePanel-Dashboard) to see them all in one place.

| CT | Name | CPU | RAM | Disk | Services |
|----|------|-----|-----|------|----------|
| 200 | docker-stack | 2 | 1536 MB | 20 GB | Immich (2283), Nextcloud (8080), RomM (8081), Nginx Proxy Manager (81) |
| 201 | source-stack | 4 | 3072 MB | 16 GB | Jellyfin (8096), Navidrome (4533), FileBrowser (8082), AdGuard Home (3000) |
| 202 | light-stack | 1 | 768 MB | 8 GB | Vaultwarden (8000), Trilium (8083) |
| 203 | forgepanel | 1 | 384 MB | 4 GB | ForgePanel (**https**://<ip>:8084, self-signed cert) |

> **ForgePanel** is served over **HTTPS** by default at `https://<forgepanel-ip>:8084` with a self-signed certificate (your browser warns once). Use `https://`, not `http://`: plain HTTP on port 8084 gets an empty reply. The final summary prints it as HTTPS too. For no warning, put it behind Nginx Proxy Manager with a real certificate.

> **Note:** TrueNAS is set up manually. This script no longer creates a TrueNAS VM or downloads its ISO; create and install TrueNAS yourself in Proxmox if you want it.

The `docker-stack` container is created **privileged** (`nesting=1,keyctl=1,fuse=1`) so Docker can use `overlay2`. In an unprivileged container Docker falls back to `fuse-overlayfs`, which unpacks image layers very slowly. The other three containers are unprivileged.

## App installer repos

`proxmox.sh` downloads each app's installer from its own public repo below and runs it in the app's LXC. A copy of every installer is also embedded in `proxmox.sh` and is used only if GitHub can't be reached. Each repo's script also works on its own.

- **Jellyfin**: [Jellyfin-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Jellyfin-Automated-Setup-Script) (source)
- **Navidrome**: [Navidrome-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Navidrome-Automated-Setup-Script) (source)
- **FileBrowser**: [FileBrowser-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/FileBrowser-Automated-Setup-Script) (source)
- **AdGuard Home**: [AdGuard-Home-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/AdGuard-Home-Automated-Setup-Script) (source)
- **Vaultwarden**: [Vaultwarden-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Vaultwarden-Automated-Setup-Script) (source)
- **Trilium**: [Trilium-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Trilium-Automated-Setup-Script) (prebuilt release tarball)
- **Immich**: [Immich-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Immich-Automated-Setup-Script) (Docker)
- **Nextcloud**: [Nextcloud-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Nextcloud-Automated-Setup-Script) (Docker)
- **RomM**: [RomM-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/RomM-Automated-Setup-Script) (Docker)
- **Nginx Proxy Manager**: [Nginx-Proxy-Manager-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Nginx-Proxy-Manager-Automated-Setup-Script) (Docker)
- **ForgePanel**: [ForgePanel-Dashboard](https://github.com/JeffTheTroubleshooter/ForgePanel-Dashboard) (dashboard; its installer is embedded in `proxmox.sh`)

## Usage

On the Proxmox host, as root:

```bash
bash proxmox.sh               # create + install everything
bash proxmox.sh update        # re-run the installers in existing containers
bash proxmox.sh self-update   # pull the newest version of this script from GitHub
bash proxmox.sh destroy       # remove the containers created by the script
```

Defaults: bridge `vmbr0`, storage `local-lvm`, container IDs 200–203. If a default ID is already in use, the script picks the next free one.

On a normal run the script also checks GitHub for a newer copy of itself and offers to update before doing anything else.

## What happens during a run

1. Downloads the newest Debian LXC template matching the host's Debian release (13 on Proxmox 9, falling back to 12). Host-built binaries need the same glibc as the containers, and the script stops with a clear error if they don't match.
2. Installs build tools on the Proxmox host (Go, Node, Rust, gcc) and builds the source-based services there — Navidrome, FileBrowser, AdGuard Home and Vaultwarden — into `/root/homelab-builds`, using the same steps as each app's installer (FileBrowser's pnpm web UI is built before `go build`, and Vaultwarden gets the web vault release its installer pins). Building on the host uses every core instead of a container's CPU limit. Build logs are in `/root/homelab-builds/logs/`, and finished builds are reused on the next run.
3. Creates each container with its CPU limit, memory, swap and disk settings.
4. Installs the role's base packages (Docker, build tools, Python, etc.). `source-stack` also gets `ffmpeg`, because Jellyfin shuts down at startup when it can't find FFmpeg.
5. Pushes the host-built binaries into their container and installs them as systemd services; anything not built on the host gets its installer script copied in over SSH and run with its prompts on defaults.
6. Removes SSH from the container and stops it once the installs finish.
7. Starts all containers again.
8. Runs health checks: every service must answer on its port (ForgePanel over HTTPS). If one doesn't, the run stops with a red `FAILED: <app> ... health check` line instead of printing `Homelab ready`.

### Progress output

Long steps never go quiet. Every 30 seconds the script prints the step's elapsed time and the last lines of its log, for example while Jellyfin builds from source in `source-stack` (dotnet publish plus the webpack build of jellyfin-web, often 20–30 minutes). Change the interval with `HEARTBEAT_SECS=60 bash proxmox.sh`. During the installs `source-stack` gets every host core, then its normal CPU limit is put back.

## Security note

The containers use a default root password (`admin`) set at the top of the script. Change `PASSWORD` before running, and change any app passwords after setup:

```bash
pct enter <ctid>
passwd
```

Services built on the host are deployed as root with their default app credentials (for example FileBrowser `admin` / `admin12345678`). Change those on first login.

SSH is only enabled inside each container while the installers run, then it is removed and the container's root SSH key is deleted.

Because the Docker container is privileged, services running in it have more access to the host than a normal container. It is the container that faces the most exposure (Immich, Nextcloud, RomM, Nginx Proxy Manager), so keep those services patched and do not expose them to the internet without a reverse proxy and authentication.
