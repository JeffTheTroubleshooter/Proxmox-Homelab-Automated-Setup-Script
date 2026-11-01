# Proxmox Homelab Automated Setup Script

> ⚠️ **Experimental.** This script is still being fixed and tested. Expect bugs, and try it on a test Proxmox host first.

One script, run on a Proxmox VE host, that creates 4 Debian 12 LXC containers, installs a full homelab inside them, and prints every URL at the end. Use [ForgePanel](https://github.com/JeffTheTroubleshooter/ForgePanel-Dashboard) to see them all in one place.

| CT | Name | Services |
|----|------|----------|
| 200 | docker-stack | Immich (2283), Nextcloud (8080), RomM (8081), Nginx Proxy Manager (81) |
| 201 | source-stack | Jellyfin (8096), Navidrome (4533), FileBrowser (8082), AdGuard Home (3000) |
| 202 | light-stack | Vaultwarden (8000), Trilium (8083) |
| 203 | forgepanel | ForgePanel (8084) |

## Usage

On the Proxmox host, as root:

```bash
bash proxmox.sh            # create + install everything
bash proxmox.sh destroy    # remove the 4 containers
```

Defaults: bridge `vmbr0`, storage `local-lvm`, container IDs 200–203.

## Security note

The containers use a default root password (`homelab`) set at the top of the script. Change `PASSWORD` before running, and change any app passwords after setup.
