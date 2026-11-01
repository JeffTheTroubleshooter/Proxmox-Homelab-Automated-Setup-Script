# Proxmox Homelab Automated Setup Script

> ⚠️ **Experimental.** This script is still being fixed and tested. Expect bugs, and try it on a test Proxmox host first.

One script, run on a Proxmox VE host, that creates 4 Debian 12 LXC containers, installs a full homelab inside them, creates a TrueNAS SCALE VM, and prints every URL at the end. Use [ForgePanel](https://github.com/JeffTheTroubleshooter/ForgePanel-Dashboard) to see them all in one place.

| CT | Name | CPU | RAM | Disk | Services |
|----|------|-----|-----|------|----------|
| 200 | docker-stack | 2 | 1536 MB | 20 GB | Immich (2283), Nextcloud (8080), RomM (8081), Nginx Proxy Manager (81) |
| 201 | source-stack | 4 | 3072 MB | 16 GB | Jellyfin (8096), Navidrome (4533), FileBrowser (8082), AdGuard Home (3000) |
| 202 | light-stack | 1 | 768 MB | 8 GB | Vaultwarden (8000), Trilium (8083) |
| 203 | forgepanel | 1 | 384 MB | 4 GB | ForgePanel (8084) |

A **TrueNAS SCALE VM** (ID 100, 4 GB RAM, 2 cores) is also created with the installer ISO attached. The script does not install TrueNAS for you: start the VM and walk through the installer in the Proxmox console.

## Usage

On the Proxmox host, as root:

```bash
bash proxmox.sh               # create + install everything
bash proxmox.sh update        # re-run the installers in existing containers
bash proxmox.sh self-update   # pull the newest version of this script from GitHub
bash proxmox.sh destroy       # remove the containers and the TrueNAS VM
```

Defaults: bridge `vmbr0`, storage `local-lvm`, container IDs 200–203, TrueNAS VM ID 100. If a default ID is already in use, the script picks the next free one.

On a normal run the script also checks GitHub for a newer copy of itself and offers to update before doing anything else.

## What happens during a run

1. Downloads the newest Debian 12 LXC template.
2. Installs build tools on the Proxmox host (Go, Node, Rust, gcc) and builds the source-based services there — Navidrome, FileBrowser, AdGuard Home and Vaultwarden — into `/root/homelab-builds`. Building on the host uses every core instead of a container's CPU limit.
3. Creates each container with its CPU limit, memory, swap and disk settings.
4. Installs the role's base packages (Docker, build tools, Python, etc.).
5. Pushes the host-built binaries into their container and installs them as systemd services; anything not built on the host gets its installer script copied in over SSH and run with its prompts on defaults.
6. Removes SSH from the container and stops it once the installs finish.
7. Creates the TrueNAS VM, then starts all containers again.

## Security note

The containers use a default root password (`admin`) set at the top of the script. Change `PASSWORD` before running, and change any app passwords after setup:

```bash
pct enter <ctid>
passwd
```

Services built on the host are deployed as root with their default app credentials (for example FileBrowser `admin` / `admin12345678`). Change those on first login.

SSH is only enabled inside each container while the installers run, then it is removed and the container's root SSH key is deleted.
