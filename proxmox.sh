#!/usr/bin/env bash
#
# Proxmox homelab — one script
# Creates 4 LXC containers, installs every service inside the right one,
# then prints all the URLs. Use ForgePanel to see them in one place.
#
# Usage (on the Proxmox host):
#   bash proxmox.sh            # create + install everything
#   bash proxmox.sh destroy    # remove the 4 containers
#
# Containers:
#   200 docker-stack   Immich, Nextcloud, RomM, Nginx Proxy Manager
#   201 source-stack   Jellyfin, Navidrome, FileBrowser, AdGuard Home
#   202 light-stack    Vaultwarden, Trilium
#   203 forgepanel     ForgePanel dashboard
#

set -euo pipefail

START_TIME=$(date +%s)
PASSWORD="admin"
TRUENAS_ISO_URL="https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.7/TrueNAS-SCALE-25.10.7.iso"
TRUENAS_ISO="TrueNAS-SCALE-25.10.7.iso"
TRUENAS_VMID=100

# Return the first free ID at or above $1.
next_free_id() {
  local id="$1"
  while pct status "$id" >/dev/null 2>&1 || qm status "$id" >/dev/null 2>&1; do
    id=$((id + 1))
  done
  printf '%s' "$id"
}
BRIDGE="vmbr0"
STORAGE="local-lvm"
TEMPLATE=""

CONTAINERS=(
  "200|docker-stack|2|1536|20|docker|2"
  "201|source-stack|4|3072|16|source|4"
  "202|light-stack|1|768|8|light|1"
  "203|forgepanel|1|384|4|forge|1"
)

# role -> "script_name|Service Name|port" entries
declare -A ROLE_SCRIPTS=(
  [docker]="immich-install.sh|Immich|2283 nextcloud-install.sh|Nextcloud|8080 romm-install.sh|RomM|8081 npm-install.sh|NginxProxyManager|81"
  [source]="jellyfin-install.sh|Jellyfin|8096 navidrome-install.sh|Navidrome|4533 filebrowser-install.sh|FileBrowser|8082 adguard-install.sh|AdGuardHome|3000"
  [light]="vaultwarden-install.sh|Vaultwarden|8000 trilium-install.sh|Trilium|8083"
  [forge]="forgepanel-install.sh|ForgePanel|8084"
)

# Raw URL of this script on GitHub. Override with UPDATE_URL=... if the repo path differs.
UPDATE_URL="${UPDATE_URL:-https://raw.githubusercontent.com/JeffTheTroubleshooter/Proxmox-Homelab-Automated-Setup-Script/main/proxmox.sh}"

die()  { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok()   { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
elapsed() { local e=$(date +%s); printf '%dm %ds' $(((e-START_TIME)/60)) $(((e-START_TIME)%60)); }

check_host() {
  command -v pct >/dev/null 2>&1 || die "pct not found. Run this on a Proxmox host."
  [[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
  ok "Proxmox host detected."
}

ensure_template() {
  pveam update >/dev/null || true
  local name
  name=$(pveam available 2>/dev/null | awk '/debian-12-standard/ && /amd64/ {print $2}' | sort -V | tail -1)
  [[ -n "$name" ]] || die "No Debian 12 template found. Run 'pveam available'."
  TEMPLATE="local:vztmpl/$name"
  if ! pveam list local 2>/dev/null | grep -q "$name"; then
    info "Downloading $name ..."
    pveam download local "$name" || die "Failed to download $name"
  fi
  ok "Template ready: $name"
}

create_ct() {
  local ctid="$1" hostname="$2" cores="$3" memory="$4" disk="$5" cpulimit="$6" privileged="${7:-0}"
  if pct status "$ctid" >/dev/null 2>&1; then
    warn "CT $ctid already exists — updating limits."
    pct set "$ctid" --cores "$cores" --memory "$memory" --cpulimit "$cpulimit" || true
    return 0
  fi
  # Docker in an unprivileged container falls back to fuse-overlayfs and
  # extracts layers a few hundred bytes at a time. The docker container
  # is privileged so Docker can use overlay2 at normal speed.
  local unpriv=1 features="nesting=1"
  if [[ "$privileged" == "1" ]]; then
    unpriv=0
    features="nesting=1,keyctl=1,fuse=1"
    info "Creating privileged CT $ctid ($hostname) for Docker"
  else
    info "Creating CT $ctid ($hostname) — ${cores} cores, ${memory}MB"
  fi
  pct create "$ctid" "$TEMPLATE" \
    --hostname "$hostname" \
    --cores "$cores" \
    --memory "$memory" \
    --swap 256 \
    --cpulimit "$cpulimit" \
    --cpuunits 1024 \
    --rootfs "${STORAGE}:${disk}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --password "$PASSWORD" \
    --unprivileged "$unpriv" \
    --features "$features" \
    --onboot 1
  ok "CT $ctid created."
}

setup_ct() {
  local ctid="$1" role="$2"
  info "Starting CT $ctid..."
  pct start "$ctid" || true
  sleep 5

  case "$role" in
    docker)
      info "Installing Docker in CT $ctid..."
      pct exec "$ctid" -- bash -c '
        apt-get update -qq
        apt-get install -y sudo ca-certificates curl openssh-server
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable --now docker
        systemctl enable --now ssh
      '
      ok "Docker ready in CT $ctid"
      ;;
    source)
      info "Installing build tools in CT $ctid..."
      pct exec "$ctid" -- bash -c '
        apt-get update -qq
        apt-get install -y sudo git curl ca-certificates tar gcc g++ make nodejs npm golang openssh-server
        systemctl enable --now ssh
      '
      ok "Build tools ready in CT $ctid"
      ;;
    light)
      info "Installing base tools in CT $ctid..."
      pct exec "$ctid" -- bash -c '
        apt-get update -qq
        apt-get install -y sudo git curl ca-certificates tar xz-utils openssh-server
        systemctl enable --now ssh
      '
      ok "Base tools ready in CT $ctid"
      ;;
    forge)
      info "Installing base tools in CT $ctid..."
      pct exec "$ctid" -- bash -c '
        apt-get update -qq
        apt-get install -y sudo python3 git openssh-server
        systemctl enable --now ssh
      '
      ok "Base tools ready in CT $ctid"
      ;;
  esac
}

prepare_ssh() {
  local ctid="$1"
  info "Enabling SSH in CT $ctid..."
  pct exec "$ctid" -- bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'
  local key="/root/.ssh/homelab_key"
  if [[ ! -f "$key" ]]; then
    ssh-keygen -t ed25519 -f "$key" -N "" -q
  fi
  pct push "$ctid" "${key}.pub" /root/.ssh/authorized_keys
  pct exec "$ctid" -- chmod 600 /root/.ssh/authorized_keys
  ok "SSH ready in CT $ctid"
}

container_ip() {
  local ctid="$1" ip=""
  for _ in 1 2 3 4 5 6; do
    ip=$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
    [[ -n "$ip" ]] && break
    sleep 2
  done
  printf '%s' "$ip"
}

# Extract an embedded script from this file into a temp dir.
extract_script() {
  local name="$1" dest="$2"
  awk -v name="$name" '
    $0 == "###BEGIN " name {p=1; next}
    $0 == "###END " name {p=0}
    p {print}
  ' "$0" > "$dest"
  [[ -s "$dest" ]] || die "Embedded script missing: $name"
  chmod +x "$dest"
}


# Build from-source services on the Proxmox host (all cores), then deploy.
BUILD_ROOT="/root/homelab-builds"

host_deps() {
  info "Installing host build tools..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl ca-certificates tar gcc g++ make pkg-config \
    nodejs npm golang build-essential libssl-dev libsqlite3-dev || true
  if ! command -v cargo >/dev/null 2>&1; then
    info "Installing Rust on the host..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  fi
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
  ok "Host build tools ready."
}

build_on_host() {
  host_deps
  mkdir -p "$BUILD_ROOT"

  # Navidrome
  if [[ ! -x "$BUILD_ROOT/navidrome/navidrome" ]]; then
    info "Building Navidrome on the host..."
    rm -rf "$BUILD_ROOT/navidrome-src"
    git clone --depth 1 https://github.com/navidrome/navidrome.git "$BUILD_ROOT/navidrome-src"
    (cd "$BUILD_ROOT/navidrome-src" && make setup && make build) || warn "Navidrome host build failed"
    mkdir -p "$BUILD_ROOT/navidrome"
    cp "$BUILD_ROOT/navidrome-src/navidrome" "$BUILD_ROOT/navidrome/" 2>/dev/null || true
  fi

  # FileBrowser
  if [[ ! -x "$BUILD_ROOT/filebrowser/filebrowser" ]]; then
    info "Building FileBrowser on the host..."
    rm -rf "$BUILD_ROOT/filebrowser-src"
    git clone --depth 1 https://github.com/filebrowser/filebrowser.git "$BUILD_ROOT/filebrowser-src"
    (cd "$BUILD_ROOT/filebrowser-src" && go build -o filebrowser .) || warn "FileBrowser host build failed"
    mkdir -p "$BUILD_ROOT/filebrowser"
    cp "$BUILD_ROOT/filebrowser-src/filebrowser" "$BUILD_ROOT/filebrowser/" 2>/dev/null || true
  fi

  # AdGuard
  if [[ ! -x "$BUILD_ROOT/adguard/AdGuardHome" ]]; then
    info "Building AdGuard Home on the host..."
    rm -rf "$BUILD_ROOT/adguard-src"
    git clone https://github.com/AdguardTeam/AdGuardHome.git "$BUILD_ROOT/adguard-src"
    (cd "$BUILD_ROOT/adguard-src" && make) || warn "AdGuard host build failed"
    mkdir -p "$BUILD_ROOT/adguard"
    cp "$BUILD_ROOT/adguard-src/AdGuardHome" "$BUILD_ROOT/adguard/" 2>/dev/null || true
  fi

  # Vaultwarden
  if [[ ! -x "$BUILD_ROOT/vaultwarden/vaultwarden" ]]; then
    info "Building Vaultwarden on the host..."
    # shellcheck disable=SC1091
    [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
    rm -rf "$BUILD_ROOT/vaultwarden-src"
    git clone --depth 1 https://github.com/dani-garcia/vaultwarden.git "$BUILD_ROOT/vaultwarden-src"
    (cd "$BUILD_ROOT/vaultwarden-src" && cargo build --features sqlite --release) || warn "Vaultwarden host build failed"
    mkdir -p "$BUILD_ROOT/vaultwarden"
    cp "$BUILD_ROOT/vaultwarden-src/target/release/vaultwarden" "$BUILD_ROOT/vaultwarden/" 2>/dev/null || true
  fi

  ok "Host builds finished."
}

# Deploy a host-built binary into a container and start it. Returns 0 if handled.
deploy_built() {
  local ctid="$1" script="$2"
  case "$script" in
    navidrome-install.sh)
      [[ -x "$BUILD_ROOT/navidrome/navidrome" ]] || return 1
      info "Deploying Navidrome into CT $ctid"
      pct exec "$ctid" -- mkdir -p /opt/navidrome /mnt/music
      pct push "$ctid" "$BUILD_ROOT/navidrome/navidrome" /opt/navidrome/navidrome
      pct exec "$ctid" -- bash -c '
        chmod +x /opt/navidrome/navidrome
        cat >/opt/navidrome/navidrome.toml <<C
MusicFolder = "/mnt/music"
DataFolder = "/opt/navidrome/data"
Port = 4533
Address = "0.0.0.0"
C
        cat >/etc/systemd/system/navidrome.service <<U
[Unit]
Description=Navidrome
After=network.target
[Service]
Type=simple
ExecStart=/opt/navidrome/navidrome --configfile /opt/navidrome/navidrome.toml
Restart=on-failure
[Install]
WantedBy=multi-user.target
U
        systemctl daemon-reload
        systemctl enable --now navidrome
      '
      ok "Navidrome deployed"
      return 0
      ;;
    filebrowser-install.sh)
      [[ -x "$BUILD_ROOT/filebrowser/filebrowser" ]] || return 1
      info "Deploying FileBrowser into CT $ctid"
      pct exec "$ctid" -- mkdir -p /opt/filebrowser /srv/files
      pct push "$ctid" "$BUILD_ROOT/filebrowser/filebrowser" /usr/local/bin/filebrowser
      pct exec "$ctid" -- bash -c '
        chmod +x /usr/local/bin/filebrowser
        (cd /opt/filebrowser && /usr/local/bin/filebrowser config init || true)
        (cd /opt/filebrowser && /usr/local/bin/filebrowser users add admin admin12345678 --perm.admin || true)
        cat >/etc/systemd/system/filebrowser.service <<U
[Unit]
Description=FileBrowser
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/filebrowser
ExecStart=/usr/local/bin/filebrowser -d /opt/filebrowser/filebrowser.db -r /srv/files -a 0.0.0.0 -p 8082
Restart=on-failure
[Install]
WantedBy=multi-user.target
U
        systemctl daemon-reload
        systemctl enable --now filebrowser
      '
      ok "FileBrowser deployed"
      return 0
      ;;
    adguard-install.sh)
      [[ -x "$BUILD_ROOT/adguard/AdGuardHome" ]] || return 1
      info "Deploying AdGuard Home into CT $ctid"
      pct exec "$ctid" -- mkdir -p /opt/adguardhome
      pct push "$ctid" "$BUILD_ROOT/adguard/AdGuardHome" /usr/local/bin/AdGuardHome
      pct exec "$ctid" -- bash -c '
        chmod +x /usr/local/bin/AdGuardHome
        cat >/etc/systemd/system/adguardhome.service <<U
[Unit]
Description=AdGuard Home
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/adguardhome
ExecStart=/usr/local/bin/AdGuardHome -w /opt/adguardhome --no-check-update
Restart=on-failure
[Install]
WantedBy=multi-user.target
U
        systemctl daemon-reload
        systemctl enable --now adguardhome
      '
      ok "AdGuard deployed"
      return 0
      ;;
    vaultwarden-install.sh)
      [[ -x "$BUILD_ROOT/vaultwarden/vaultwarden" ]] || return 1
      info "Deploying Vaultwarden into CT $ctid"
      pct exec "$ctid" -- mkdir -p /opt/vaultwarden/data
      pct push "$ctid" "$BUILD_ROOT/vaultwarden/vaultwarden" /opt/vaultwarden/vaultwarden
      pct exec "$ctid" -- bash -c '
        chmod +x /opt/vaultwarden/vaultwarden
        cat >/opt/vaultwarden/vaultwarden.env <<E
DATA_FOLDER=/opt/vaultwarden/data
ROCKET_ADDRESS=0.0.0.0
ROCKET_PORT=8000
SIGNUPS_ALLOWED=true
E
        cat >/etc/systemd/system/vaultwarden.service <<U
[Unit]
Description=Vaultwarden
After=network.target
[Service]
Type=simple
EnvironmentFile=/opt/vaultwarden/vaultwarden.env
ExecStart=/opt/vaultwarden/vaultwarden
Restart=on-failure
[Install]
WantedBy=multi-user.target
U
        systemctl daemon-reload
        systemctl enable --now vaultwarden
      '
      ok "Vaultwarden deployed"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

lock_down() {
  local ctid="$1"
  info "Removing SSH from CT $ctid..."
  pct exec "$ctid" -- bash -c '
    systemctl disable --now ssh 2>/dev/null || true
    systemctl disable --now sshd 2>/dev/null || true
    rm -rf /root/.ssh
    apt-get remove -y openssh-server 2>/dev/null || true
  ' || true
  ok "SSH removed from CT $ctid"
  info "Stopping CT $ctid..."
  pct stop "$ctid" || true
  ok "CT $ctid stopped."
}

copy_and_run_scripts() {
  local ctid="$1" role="$2"
  local dest="/root/scripts"
  prepare_ssh "$ctid"
  local ip
  ip=$(container_ip "$ctid")
  [[ -n "$ip" ]] || { warn "No IP for CT $ctid — skipping installs"; return 0; }
  info "Connecting to CT $ctid at $ip via SSH..."
  ssh -i /root/.ssh/homelab_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@$ip" "mkdir -p $dest"

  local tmpdir
  tmpdir=$(mktemp -d)
  local entry script svc port
  for entry in ${ROLE_SCRIPTS[$role]}; do
    IFS='|' read -r script svc port <<< "$entry"
    local src="$tmpdir/$script"
    extract_script "$script" "$src"
    scp -i /root/.ssh/homelab_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$src" "root@$ip:$dest/$script" || { warn "Failed to copy $script"; continue; }
    if deploy_built "$ctid" "$script"; then
      continue
    fi
    info "Running $script on $ip ..."
    # Feed a fixed set of newlines so prompts take defaults.
    # Stream output live so it does not look stuck.
    printf '\n%.0s' {1..30} | ssh -i /root/.ssh/homelab_key \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@$ip" "chmod +x $dest/$script && cd $dest && ./$script" || \
      warn "$script exited with an error on $ip"
  done
  rm -rf "$tmpdir"
  ok "Services installed on CT $ctid ($ip)"
}

setup_truenas() {
  info "Downloading TrueNAS SCALE ISO..."
  local iso_dir="/var/lib/vz/template/iso"
  mkdir -p "$iso_dir"
  if [[ ! -f "$iso_dir/$TRUENAS_ISO" ]]; then
    curl -fL --progress-bar -o "$iso_dir/$TRUENAS_ISO" "$TRUENAS_ISO_URL" || die "TrueNAS ISO download failed"
  fi
  ok "ISO ready: $iso_dir/$TRUENAS_ISO"

  if qm status "$TRUENAS_VMID" >/dev/null 2>&1 || pct status "$TRUENAS_VMID" >/dev/null 2>&1; then
    local free
    free=$(next_free_id "$TRUENAS_VMID")
    warn "VM ID $TRUENAS_VMID is taken — using $free for TrueNAS"
    TRUENAS_VMID="$free"
  fi

  info "Creating TrueNAS VM $TRUENAS_VMID..."
  qm create "$TRUENAS_VMID" --name truenas --memory 4096 --cores 2 --cpu host \
    --net0 virtio,bridge="$BRIDGE" --scsihw virtio-scsi-pci --ostype l26
  qm set "$TRUENAS_VMID" --scsi0 "${STORAGE}:32"
  qm set "$TRUENAS_VMID" --ide2 "local:iso/${TRUENAS_ISO},media=cdrom"
  qm set "$TRUENAS_VMID" --boot order=ide2
  qm set "$TRUENAS_VMID" --serial0 socket --vga serial0
  ok "TrueNAS VM created. Start it from the Proxmox console to install."
}

print_summary() {
  echo
  echo "========================================"
  echo "  Homelab ready"
  echo "========================================"
  echo
  echo "Open ForgePanel to see every service in one place:"
  echo
  local entry ctid hostname role ip
  local forge_ip=""
  # collect IPs first
  declare -A CT_IP
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r ctid hostname _ _ _ role <<< "$entry"
    ip=$(container_ip "$ctid")
    CT_IP[$ctid]="$ip"
    [[ "$role" == "forge" ]] && forge_ip="$ip"
  done

  if [[ -n "$forge_ip" ]]; then
    echo "  ForgePanel:  http://${forge_ip}:8084"
    echo
  fi

  echo "Services by container:"
  echo
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r ctid hostname _ _ _ role <<< "$entry"
    ip="${CT_IP[$ctid]:-}"
    echo "  $hostname (CT $ctid)  ${ip:-no-ip}"
    for item in ${ROLE_SCRIPTS[$role]}; do
      IFS='|' read -r script svc port <<< "$item"
      if [[ -n "$ip" ]]; then
        printf '    %-22s http://%s:%s\n' "$svc" "$ip" "$port"
      else
        printf '    %-22s (container has no IP)\n' "$svc"
      fi
    done
    echo
  done

  echo "TrueNAS VM:  $TRUENAS_VMID (ISO attached, start it to install)"
  echo "  qm start $TRUENAS_VMID"
  echo
  echo "Default password for every container: $PASSWORD"
  echo "CHANGE THIS PASSWORD on each container once the script is done."
  echo "  pct enter <ctid>"
  echo "  passwd"
  echo
  echo "Add these URLs to ForgePanel so you can click through to each service."
  echo
  ok "Done in $(elapsed)"
}

self_update() {
  local force="${1:-}"
  info "Checking GitHub for a newer script..."
  local tmp
  tmp=$(mktemp)
  if ! curl -fsSL -o "$tmp" "$UPDATE_URL" 2>/dev/null; then
    warn "Could not reach GitHub. Continuing with the current script."
    rm -f "$tmp"
    return 0
  fi
  if cmp -s "$tmp" "$0"; then
    ok "Script is up to date."
    rm -f "$tmp"
    return 0
  fi
  echo
  warn "A newer version of this script is available on GitHub."
  echo "  $UPDATE_URL"
  echo
  if [[ "$force" == "--yes" ]]; then
    local ans="y"
  else
    read -rp "Update the script now? [y/N]: " ans
    ans="${ans:-n}"
  fi
  if [[ "$ans" =~ ^[Yy] ]]; then
    cp "$0" "${0}.bak"
    cp "$tmp" "$0"
    chmod +x "$0"
    rm -f "$tmp"
    ok "Updated. Backup saved as ${0}.bak"
    ok "Re-run the script to use the new version."
    exit 0
  fi
  rm -f "$tmp"
  info "Skipped update. Continuing with the current script."
}

service_update() {
  echo "Updating services in existing containers"
  echo "========================================"
  check_host
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r ctid hostname _ _ _ role <<< "$entry"
    if ! pct status "$ctid" >/dev/null 2>&1; then
      warn "CT $ctid ($hostname) not found — skipping."
      continue
    fi
    pct start "$ctid" >/dev/null 2>&1 || true
    sleep 3
    info "Updating services in CT $ctid ($hostname)..."
    copy_and_run_scripts "$ctid" "$role"
  done
  print_summary
}

remove_packages_in_ct() {
  local ctid="$1" role="$2"
  local pkgs=""
  case "$role" in
    docker) pkgs="sudo docker-ce docker-ce-cli containerd.io docker-compose-plugin openssh-server" ;;
    source) pkgs="sudo git gcc g++ make nodejs npm golang openssh-server" ;;
    light)  pkgs="sudo git xz-utils openssh-server" ;;
    forge)  pkgs="sudo python3 git openssh-server" ;;
  esac
  info "Removing packages in CT $ctid ($role)..."
  pct exec "$ctid" -- bash -c "apt-get remove -y $pkgs" >/dev/null 2>&1 || true
  ok "Packages removed in CT $ctid"
}

destroy_all() {
  echo "Destroying homelab containers"
  echo "============================="
  check_host
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r ctid hostname _ _ _ role <<< "$entry"
    if pct status "$ctid" >/dev/null 2>&1; then
      # clear a stuck lock before doing anything
      info "Unlocking CT $ctid if locked..."
      pct unlock "$ctid" 2>/dev/null || true
      rm -f "/run/lock/lxc/pve-config-${ctid}.lock" "/var/lock/lxc/pve-config-${ctid}.lock" 2>/dev/null || true
      # make sure it is running so we can remove packages
      pct start "$ctid" >/dev/null 2>&1 || true
      sleep 2
      remove_packages_in_ct "$ctid" "$role"
      info "Removing CT $ctid ($hostname)..."
      pct unlock "$ctid" 2>/dev/null || true
      pct stop "$ctid" --skiplock 2>/dev/null || pct stop "$ctid" 2>/dev/null || true
      pct destroy "$ctid" --force 2>/dev/null || pct destroy "$ctid" || true
      ok "CT $ctid removed."
    else
      warn "CT $ctid not found."
    fi
  done

  if qm status "$TRUENAS_VMID" >/dev/null 2>&1; then
    info "Removing TrueNAS VM $TRUENAS_VMID..."
    qm stop "$TRUENAS_VMID" 2>/dev/null || true
    qm destroy "$TRUENAS_VMID" || true
    ok "TrueNAS VM removed."
  fi

  # host-side leftovers
  if [[ -f /root/.ssh/homelab_key ]]; then
    rm -f /root/.ssh/homelab_key /root/.ssh/homelab_key.pub
    ok "Removed host SSH key."
  fi

  ok "Done. Containers and installed packages removed."
}

main() {
  local mode="${1:-create}"
  case "$mode" in
    destroy|remove)
      destroy_all
      ;;
    update)
      service_update
      ;;
    self-update)
      self_update --yes
      ;;
    create|"")
      self_update
      echo "Proxmox homelab — full install"
      echo "=============================="
      check_host
      ensure_template

      # Assign free IDs if the defaults are taken
      local -a assigned=()
      local new_list=()
      for entry in "${CONTAINERS[@]}"; do
        IFS='|' read -r ctid hostname cores memory disk role cpulimit <<< "$entry"
        if pct status "$ctid" >/dev/null 2>&1 || qm status "$ctid" >/dev/null 2>&1; then
          local free
          free=$(next_free_id "$ctid")
          # also skip IDs we just assigned in this run
          while printf '%s\n' "${assigned[@]}" | grep -qx "$free"; do
            free=$((free + 1))
            free=$(next_free_id "$free")
          done
          warn "ID $ctid is taken — using $free for $hostname"
          ctid="$free"
        fi
        assigned+=("$ctid")
        new_list+=("$ctid|$hostname|$cores|$memory|$disk|$role|$cpulimit")
      done
      CONTAINERS=("${new_list[@]}")

      build_on_host

      for entry in "${CONTAINERS[@]}"; do
        IFS='|' read -r ctid hostname cores memory disk role cpulimit <<< "$entry"
        local privileged=0
        [[ "$role" == "docker" ]] && privileged=1
        create_ct "$ctid" "$hostname" "$cores" "$memory" "$disk" "$cpulimit" "$privileged"
        setup_ct "$ctid" "$role"
        copy_and_run_scripts "$ctid" "$role"
        lock_down "$ctid"
      done
      setup_truenas
      info "Starting all containers (SSH stays off)..."
      for entry in "${CONTAINERS[@]}"; do
        IFS='|' read -r ctid hostname _ _ _ _ _ <<< "$entry"
        pct start "$ctid" || true
      done
      sleep 5
      print_summary
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [create|update|self-update|destroy]"
      ;;
  esac
}

main "$@"
exit 0

# ── embedded install scripts ───────────────────────────────────────────────
###BEGIN immich-install.sh
#!/usr/bin/env bash
#
# Immich installer / uninstaller (Docker Compose)
# Detects distro, ensures Docker + Compose, downloads official compose + .env,
# prompts for custom values, starts the stack, and prints the URL.
#
# Usage:
#   bash immich-install.sh            # install
#   bash immich-install.sh uninstall  # stop and optionally remove data
#

set -euo pipefail

START_TIME=$(date +%s)
DEFAULT_DIR="/opt/immich"
SERVICE_PORT=2283
COMPOSE_URL="https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml"
ENV_URL="https://github.com/immich-app/immich/releases/latest/download/example.env"

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── docker ─────────────────────────────────────────────────────────────────
install_docker() {
  info "Checking Docker..."

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + Compose already available"
  else
    info "Installing Docker..."
    case "$PKG" in
      apt)
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 curl ca-certificates
        ;;
      dnf)
        if ! command -v docker >/dev/null 2>&1; then
          sudo dnf install -y docker docker-compose curl ca-certificates || \
          sudo dnf install -y moby-engine docker-compose curl ca-certificates
        else
          sudo dnf install -y docker-compose curl ca-certificates || true
        fi
        ;;
      pacman)
        sudo pacman -Sy --noconfirm docker docker-compose curl ca-certificates
        ;;
      zypper)
        sudo zypper --non-interactive install docker docker-compose curl ca-certificates
        ;;
      apk)
        sudo apk add --no-cache docker docker-cli-compose curl ca-certificates
        ;;
    esac
  fi

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    sudo rc-update add docker default 2>/dev/null || true
    sudo rc-service docker start 2>/dev/null || true
  fi

  # ensure compose plugin works
  if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose plugin not available. Install docker-compose-v2 / docker-compose and re-run."
  fi
  ok "Docker ready."
}

# ── prompts ────────────────────────────────────────────────────────────────
ask_config() {
  echo
  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
  prompt UPLOAD_LOCATION "Photo upload location" "$INSTALL_DIR/library"
  prompt DB_DATA_LOCATION "Database location" "$INSTALL_DIR/postgres"
  prompt TZ "Timezone (e.g. America/New_York, leave blank for UTC)" "Etc/UTC"
  prompt IMMICH_VERSION "Immich version" "v3"
  prompt DB_PASSWORD "Postgres password (A-Za-z0-9 only)" "postgres"

  # basic password check
  if [[ ! "$DB_PASSWORD" =~ ^[A-Za-z0-9]+$ ]]; then
    die "DB_PASSWORD must contain only A-Za-z0-9 (no spaces or special characters)."
  fi
}

# ── install ────────────────────────────────────────────────────────────────
setup_files() {
  info "Setting up $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR" "$UPLOAD_LOCATION" "$DB_DATA_LOCATION"
  sudo chown -R "$USER:$USER" "$INSTALL_DIR" "$UPLOAD_LOCATION" "$DB_DATA_LOCATION" 2>/dev/null || true

  info "Downloading docker-compose.yml..."
  curl -fsSL -o "$INSTALL_DIR/docker-compose.yml" "$COMPOSE_URL"

  info "Creating .env..."
  cat > "$INSTALL_DIR/.env" <<ENV
# Immich environment (generated by installer)
UPLOAD_LOCATION=$UPLOAD_LOCATION
DB_DATA_LOCATION=$DB_DATA_LOCATION
TZ=$TZ
IMMICH_VERSION=$IMMICH_VERSION
DB_PASSWORD=$DB_PASSWORD
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
ENV

  ok "Files ready."
}

start_stack() {
  info "Starting Immich (docker compose up -d)..."
  cd "$INSTALL_DIR"
  if docker info >/dev/null 2>&1; then
    docker compose up -d
  else
    sudo docker compose up -d
  fi
  ok "Containers started."
}

# ── uninstall ──────────────────────────────────────────────────────────────
uninstall() {
  echo "Immich uninstaller"
  echo "=================="
  detect_distro

  echo
  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"

  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    info "Stopping containers..."
    cd "$INSTALL_DIR"
    if docker info >/dev/null 2>&1; then
      docker compose down || true
    else
      sudo docker compose down || true
    fi
    ok "Containers stopped."
  else
    warn "No docker-compose.yml found in $INSTALL_DIR"
  fi

  if ask_yn "Remove install directory $INSTALL_DIR (includes .env and compose file)?"; then
    sudo rm -rf "$INSTALL_DIR"
    ok "Install directory removed."
  fi

  if ask_yn "Also remove uploaded photos and database folders (if outside install dir)?"; then
    # try to read from .env if it still exists, otherwise skip
    if [[ -f "$INSTALL_DIR/.env" ]]; then
      # already removed above in most cases
      :
    fi
    warn "If your library/db were outside $INSTALL_DIR, remove them manually."
  fi

  if ask_yn "Also remove Docker packages? (may affect other containers)"; then
    info "Removing Docker packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y docker.io docker-compose-v2 || true ;;
      dnf)    sudo dnf remove -y docker docker-compose moby-engine || true ;;
      pacman) sudo pacman -Rns --noconfirm docker docker-compose || true ;;
      zypper) sudo zypper --non-interactive remove docker docker-compose || true ;;
      apk)    sudo apk del docker docker-cli-compose || true ;;
    esac
    ok "Package removal finished."
  fi

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Immich installer (Docker Compose)"
      echo "================================="
      detect_distro
      install_docker
      ask_config
      setup_files
      start_stack

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:$SERVICE_PORT"
      echo "  Dir:   $INSTALL_DIR"
      echo "  Photos:$UPLOAD_LOCATION"
      echo
      echo "Useful commands (run from $INSTALL_DIR):"
      echo "  docker compose ps"
      echo "  docker compose logs -f"
      echo "  docker compose down"
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END immich-install.sh
###BEGIN nextcloud-install.sh
#!/usr/bin/env bash
#
# Nextcloud installer / uninstaller (Docker Compose)
# Detects distro, ensures Docker + Compose, writes a compose stack
# (Nextcloud + MariaDB + Redis), starts it, and prints the URL.
#
# Usage:
#   bash nextcloud-install.sh            # install
#   bash nextcloud-install.sh uninstall  # stop and optionally remove data
#

set -euo pipefail

START_TIME=$(date +%s)
DEFAULT_DIR="/opt/nextcloud"
DEFAULT_PORT=8080
NC_IMAGE="nextcloud:35-apache"

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── docker ─────────────────────────────────────────────────────────────────
install_docker() {
  info "Checking Docker..."

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + Compose already available"
  else
    info "Installing Docker..."
    case "$PKG" in
      apt)
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 curl ca-certificates
        ;;
      dnf)
        if ! command -v docker >/dev/null 2>&1; then
          sudo dnf install -y docker docker-compose curl ca-certificates || \
          sudo dnf install -y moby-engine docker-compose curl ca-certificates
        else
          sudo dnf install -y docker-compose curl ca-certificates || true
        fi
        ;;
      pacman)
        sudo pacman -Sy --noconfirm docker docker-compose curl ca-certificates
        ;;
      zypper)
        sudo zypper --non-interactive install docker docker-compose curl ca-certificates
        ;;
      apk)
        sudo apk add --no-cache docker docker-cli-compose curl ca-certificates
        ;;
    esac
  fi

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    sudo rc-update add docker default 2>/dev/null || true
    sudo rc-service docker start 2>/dev/null || true
  fi

  if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose plugin not available. Install docker-compose-v2 / docker-compose and re-run."
  fi
  ok "Docker ready."
}

# ── prompts ────────────────────────────────────────────────────────────────
ask_config() {
  echo
  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
  prompt PORT "Host port" "$DEFAULT_PORT"
  prompt DATA_DIR "Data directory" "$INSTALL_DIR/data"
  prompt ADMIN_USER "Admin username" "admin"
  prompt ADMIN_PASSWORD "Admin password" "changeme"
  prompt DB_PASSWORD "Database password" "nextcloud"
  prompt NC_IMAGE "Nextcloud image" "$NC_IMAGE"

  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

  # Build trusted domains: localhost + detected IPs + user extras
  local detected
  detected=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -5 | tr '\n' ' ')
  info "Detected IPs: ${detected:-none}"
  prompt EXTRA_DOMAINS "Extra trusted domains/IPs (space-separated, e.g. 10.0.0.101 my.domain)" ""

  TRUSTED_DOMAINS="localhost ${detected} ${EXTRA_DOMAINS}"
  # collapse extra spaces
  TRUSTED_DOMAINS=$(echo "$TRUSTED_DOMAINS" | xargs)
  info "Trusted domains will be: $TRUSTED_DOMAINS"
}

# ── files ──────────────────────────────────────────────────────────────────
setup_files() {
  info "Setting up $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR" "$DATA_DIR"
  sudo chown -R "$USER:$USER" "$INSTALL_DIR" "$DATA_DIR" 2>/dev/null || true

  info "Writing .env..."
  cat > "$INSTALL_DIR/.env" <<ENV
MYSQL_ROOT_PASSWORD=root${DB_PASSWORD}
MYSQL_PASSWORD=${DB_PASSWORD}
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
NEXTCLOUD_ADMIN_USER=${ADMIN_USER}
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PASSWORD}
NEXTCLOUD_TRUSTED_DOMAINS=${TRUSTED_DOMAINS}
ENV

  info "Writing docker-compose.yml..."
  cat > "$INSTALL_DIR/docker-compose.yml" <<YML
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW
    volumes:
      - db:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - MYSQL_DATABASE=\${MYSQL_DATABASE}
      - MYSQL_USER=\${MYSQL_USER}

  redis:
    image: redis:7-alpine
    restart: unless-stopped

  app:
    image: ${NC_IMAGE}
    restart: unless-stopped
    ports:
      - "${PORT}:80"
    depends_on:
      - db
      - redis
    volumes:
      - nextcloud:/var/www/html
      - ${DATA_DIR}:/var/www/html/data
    environment:
      - MYSQL_HOST=db
      - MYSQL_DATABASE=\${MYSQL_DATABASE}
      - MYSQL_USER=\${MYSQL_USER}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - REDIS_HOST=redis
      - NEXTCLOUD_ADMIN_USER=\${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=\${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=\${NEXTCLOUD_TRUSTED_DOMAINS}

  cron:
    image: ${NC_IMAGE}
    restart: unless-stopped
    entrypoint: /cron.sh
    depends_on:
      - db
      - redis
    volumes:
      - nextcloud:/var/www/html
      - ${DATA_DIR}:/var/www/html/data

volumes:
  db:
  nextcloud:
YML

  ok "Files ready."
}

start_stack() {
  info "Starting Nextcloud (docker compose up -d)..."
  cd "$INSTALL_DIR"
  if docker info >/dev/null 2>&1; then
    docker compose up -d
  else
    sudo docker compose up -d
  fi
  ok "Containers started."
}

# ── uninstall ──────────────────────────────────────────────────────────────
uninstall() {
  echo "Nextcloud uninstaller"
  echo "====================="
  detect_distro

  echo
  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"

  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    info "Stopping containers..."
    cd "$INSTALL_DIR"
    if docker info >/dev/null 2>&1; then
      docker compose down || true
    else
      sudo docker compose down || true
    fi
    ok "Containers stopped."
  else
    warn "No docker-compose.yml found in $INSTALL_DIR"
  fi

  if ask_yn "Remove install directory $INSTALL_DIR (compose file and .env)?"; then
    sudo rm -rf "$INSTALL_DIR"
    ok "Install directory removed."
  fi

  if ask_yn "Also remove Docker volumes (database + Nextcloud files)? This deletes all data."; then
    if docker info >/dev/null 2>&1; then
      docker volume ls -q | grep -E 'nextcloud|db' | xargs -r docker volume rm || true
    else
      sudo docker volume ls -q | grep -E 'nextcloud|db' | xargs -r sudo docker volume rm || true
    fi
    ok "Volumes removed."
  fi

  if ask_yn "Also remove Docker packages? (may affect other containers)"; then
    info "Removing Docker packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y docker.io docker-compose-v2 || true ;;
      dnf)    sudo dnf remove -y docker docker-compose moby-engine || true ;;
      pacman) sudo pacman -Rns --noconfirm docker docker-compose || true ;;
      zypper) sudo zypper --non-interactive remove docker docker-compose || true ;;
      apk)    sudo apk del docker docker-cli-compose || true ;;
    esac
    ok "Package removal finished."
  fi

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Nextcloud installer (Docker Compose)"
      echo "===================================="
      detect_distro
      install_docker
      ask_config
      setup_files
      start_stack

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:${PORT}"
      echo "  Dir:   $INSTALL_DIR"
      echo "  Data:  $DATA_DIR"
      echo "  User:  $ADMIN_USER"
      echo "  Trusted: $TRUSTED_DOMAINS"
      echo
      echo "First start can take a minute while Nextcloud initializes."
      echo
      echo "Useful commands (run from $INSTALL_DIR):"
      echo "  docker compose ps"
      echo "  docker compose logs -f app"
      echo "  docker compose down"
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END nextcloud-install.sh
###BEGIN romm-install.sh
#!/usr/bin/env bash
#
# RomM installer / uninstaller (Docker Compose)
# Detects distro, ensures Docker + Compose, writes a compose stack
# (RomM + MariaDB + Redis), starts it, and prints the URL.
#
# Usage:
#   bash romm-install.sh            # install
#   bash romm-install.sh uninstall  # stop and optionally remove data
#

set -euo pipefail

START_TIME=$(date +%s)
DEFAULT_DIR="/opt/romm"
DEFAULT_PORT=8081
ROMM_IMAGE="rommapp/romm:latest"
DB_IMAGE="mariadb:latest"

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── docker ─────────────────────────────────────────────────────────────────
install_docker() {
  info "Checking Docker..."

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + Compose already available"
  else
    info "Installing Docker..."
    case "$PKG" in
      apt)
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 curl ca-certificates openssl
        ;;
      dnf)
        if ! command -v docker >/dev/null 2>&1; then
          sudo dnf install -y docker docker-compose curl ca-certificates openssl || \
          sudo dnf install -y moby-engine docker-compose curl ca-certificates openssl
        else
          sudo dnf install -y docker-compose curl ca-certificates openssl || true
        fi
        ;;
      pacman)
        sudo pacman -Sy --noconfirm docker docker-compose curl ca-certificates openssl
        ;;
      zypper)
        sudo zypper --non-interactive install docker docker-compose curl ca-certificates openssl
        ;;
      apk)
        sudo apk add --no-cache docker docker-cli-compose curl ca-certificates openssl
        ;;
    esac
  fi

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    sudo rc-update add docker default 2>/dev/null || true
    sudo rc-service docker start 2>/dev/null || true
  fi

  if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose plugin not available. Install docker-compose-v2 / docker-compose and re-run."
  fi
  ok "Docker ready."
}

# ── prompts ────────────────────────────────────────────────────────────────
ask_config() {
  echo
  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
  prompt PORT "Host port" "$DEFAULT_PORT"
  prompt LIBRARY_DIR "ROM library directory" "$INSTALL_DIR/library"
  prompt ASSETS_DIR "Assets directory (saves/states)" "$INSTALL_DIR/assets"
  prompt CONFIG_DIR "Config directory" "$INSTALL_DIR/config"
  prompt DB_PASSWORD "Database password" "romm"
  prompt ROMM_IMAGE "RomM image" "$ROMM_IMAGE"

  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

  # auth secret
  AUTH_SECRET=$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-')
  info "Generated ROMM_AUTH_SECRET_KEY"

  echo
  info "Metadata providers are optional. Leave blank and set them later in the UI."
  prompt SCREENSCRAPER_USER "ScreenScraper username (optional)" ""
  prompt SCREENSCRAPER_PASSWORD "ScreenScraper password (optional)" ""
  prompt IGDB_CLIENT_ID "IGDB client ID (optional)" ""
  prompt IGDB_CLIENT_SECRET "IGDB client secret (optional)" ""
}

# ── files ──────────────────────────────────────────────────────────────────
setup_files() {
  info "Setting up $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR" "$LIBRARY_DIR" "$ASSETS_DIR" "$CONFIG_DIR"
  sudo chown -R "$USER:$USER" "$INSTALL_DIR" "$LIBRARY_DIR" "$ASSETS_DIR" "$CONFIG_DIR" 2>/dev/null || true

  info "Writing .env..."
  cat > "$INSTALL_DIR/.env" <<ENV
DB_PASSWORD=${DB_PASSWORD}
AUTH_SECRET=${AUTH_SECRET}
SCREENSCRAPER_USER=${SCREENSCRAPER_USER}
SCREENSCRAPER_PASSWORD=${SCREENSCRAPER_PASSWORD}
IGDB_CLIENT_ID=${IGDB_CLIENT_ID}
IGDB_CLIENT_SECRET=${IGDB_CLIENT_SECRET}
ENV

  info "Writing docker-compose.yml..."
  cat > "$INSTALL_DIR/docker-compose.yml" <<YML
services:
  romm:
    image: ${ROMM_IMAGE}
    container_name: romm
    restart: unless-stopped
    environment:
      - DB_HOST=romm-db
      - DB_NAME=romm
      - DB_USER=romm-user
      - DB_PASSWD=\${DB_PASSWORD}
      - ROMM_AUTH_SECRET_KEY=\${AUTH_SECRET}
      - SCREENSCRAPER_USER=\${SCREENSCRAPER_USER}
      - SCREENSCRAPER_PASSWORD=\${SCREENSCRAPER_PASSWORD}
      - IGDB_CLIENT_ID=\${IGDB_CLIENT_ID}
      - IGDB_CLIENT_SECRET=\${IGDB_CLIENT_SECRET}
      - HASHEOUS_API_ENABLED=true
      - SCAN_WORKERS=4
    volumes:
      - romm_resources:/romm/resources
      - romm_redis_data:/redis-data
      - ${LIBRARY_DIR}:/romm/library
      - ${ASSETS_DIR}:/romm/assets
      - ${CONFIG_DIR}:/romm/config
    ports:
      - "${PORT}:8080"
    depends_on:
      romm-db:
        condition: service_healthy
        restart: true

  romm-db:
    image: ${DB_IMAGE}
    container_name: romm-db
    restart: unless-stopped
    environment:
      - MARIADB_ROOT_PASSWORD=\${DB_PASSWORD}
      - MARIADB_DATABASE=romm
      - MARIADB_USER=romm-user
      - MARIADB_PASSWORD=\${DB_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      start_interval: 10s
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  mysql_data:
  romm_resources:
  romm_redis_data:
YML

  ok "Files ready."
}

start_stack() {
  info "Starting RomM (docker compose up -d)..."
  cd "$INSTALL_DIR"
  if docker info >/dev/null 2>&1; then
    docker compose up -d
  else
    sudo docker compose up -d
  fi
  ok "Containers started."
}

# ── uninstall ──────────────────────────────────────────────────────────────
uninstall() {
  echo "RomM uninstaller"
  echo "================"
  detect_distro

  echo
  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"

  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    info "Stopping containers..."
    cd "$INSTALL_DIR"
    if docker info >/dev/null 2>&1; then
      docker compose down || true
    else
      sudo docker compose down || true
    fi
    ok "Containers stopped."
  else
    warn "No docker-compose.yml found in $INSTALL_DIR"
  fi

  if ask_yn "Remove install directory $INSTALL_DIR (compose file and .env)?"; then
    sudo rm -rf "$INSTALL_DIR"
    ok "Install directory removed."
  fi

  if ask_yn "Also remove Docker volumes (database + resources)? This deletes RomM data."; then
    if docker info >/dev/null 2>&1; then
      docker volume ls -q | grep -E 'romm|mysql_data|romm_resources|romm_redis' | xargs -r docker volume rm || true
    else
      sudo docker volume ls -q | grep -E 'romm|mysql_data|romm_resources|romm_redis' | xargs -r sudo docker volume rm || true
    fi
    ok "Volumes removed."
  fi

  if ask_yn "Also remove Docker packages? (may affect other containers)"; then
    info "Removing Docker packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y docker.io docker-compose-v2 || true ;;
      dnf)    sudo dnf remove -y docker docker-compose moby-engine || true ;;
      pacman) sudo pacman -Rns --noconfirm docker docker-compose || true ;;
      zypper) sudo zypper --non-interactive remove docker docker-compose || true ;;
      apk)    sudo apk del docker docker-cli-compose || true ;;
    esac
    ok "Package removal finished."
  fi

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "RomM installer (Docker Compose)"
      echo "==============================="
      detect_distro
      install_docker
      ask_config
      setup_files
      start_stack

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:${PORT}"
      echo "  Dir:   $INSTALL_DIR"
      echo "  Library: $LIBRARY_DIR"
      echo "  Assets:  $ASSETS_DIR"
      echo
      echo "First start can take a minute while MariaDB initializes."
      echo "Create your admin account on first visit."
      echo
      echo "Library folder structure (example):"
      echo "  $LIBRARY_DIR/roms/nes/"
      echo "  $LIBRARY_DIR/roms/snes/"
      echo "  $LIBRARY_DIR/roms/switch/"
      echo
      echo "Useful commands (run from $INSTALL_DIR):"
      echo "  docker compose ps"
      echo "  docker compose logs -f romm"
      echo "  docker compose down"
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END romm-install.sh
###BEGIN npm-install.sh
#!/usr/bin/env bash
#
# Nginx Proxy Manager installer / uninstaller (Docker Compose)
# Detects distro, ensures Docker, writes compose file, starts the stack.
#
# Usage:
#   bash npm-install.sh            # install
#   bash npm-install.sh uninstall  # stop and optionally remove data
#

set -euo pipefail

START_TIME=$(date +%s)
DEFAULT_DIR="/opt/nginx-proxy-manager"
DEFAULT_HTTP=80
DEFAULT_HTTPS=443
DEFAULT_ADMIN=81

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── docker ─────────────────────────────────────────────────────────────────
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker and Compose already installed"
    return 0
  fi
  info "Installing Docker..."
  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/$ID/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    dnf)
      sudo dnf install -y dnf-plugins-core
      sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || \
        sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    pacman)
      sudo pacman -Sy --noconfirm docker docker-compose
      ;;
    zypper)
      sudo zypper --non-interactive install docker docker-compose
      ;;
    apk)
      sudo apk add --no-cache docker docker-cli-compose
      ;;
  esac
  sudo systemctl enable --now docker 2>/dev/null || sudo rc-service docker start 2>/dev/null || true
  ok "Docker ready."
}

# ── compose ────────────────────────────────────────────────────────────────
write_compose() {
  info "Writing docker-compose.yml..."
  sudo mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/letsencrypt"
  sudo tee "$INSTALL_DIR/docker-compose.yml" >/dev/null <<YAML
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '${HTTP_PORT}:80'
      - '${HTTPS_PORT}:443'
      - '${ADMIN_PORT}:81'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
YAML
  sudo chown -R "$USER:$USER" "$INSTALL_DIR" 2>/dev/null || true
  ok "Compose file written."
}

start_stack() {
  info "Starting Nginx Proxy Manager..."
  (cd "$INSTALL_DIR" && sudo docker compose up -d) || die "docker compose up failed"
  sleep 3
  if sudo docker compose -f "$INSTALL_DIR/docker-compose.yml" ps | grep -q "Up"; then
    ok "Container is running."
  else
    warn "Container may still be starting. Check: sudo docker compose -f $INSTALL_DIR/docker-compose.yml logs"
  fi

  if systemctl is-active --quiet firewalld 2>/dev/null; then
    info "Opening firewall ports ${HTTP_PORT}/tcp, ${HTTPS_PORT}/tcp, ${ADMIN_PORT}/tcp..."
    sudo firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp" || true
    sudo firewall-cmd --permanent --add-port="${HTTPS_PORT}/tcp" || true
    sudo firewall-cmd --permanent --add-port="${ADMIN_PORT}/tcp" || true
    sudo firewall-cmd --reload || true
    ok "Firewall updated."
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
uninstall() {
  echo "Nginx Proxy Manager uninstaller"
  echo "================================"
  detect_distro

  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    info "Stopping containers..."
    (cd "$INSTALL_DIR" && sudo docker compose down) || true
    ok "Containers stopped."
  fi

  if [[ -d "$INSTALL_DIR" ]]; then
    if ask_yn "Remove install directory $INSTALL_DIR (includes config and certificates)?"; then
      sudo rm -rf "$INSTALL_DIR"
      ok "Directory removed."
    else
      info "Kept $INSTALL_DIR"
    fi
  else
    warn "Install directory $INSTALL_DIR not found."
  fi

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Nginx Proxy Manager installer (Docker Compose)"
      echo "=============================================="
      detect_distro
      ensure_docker

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt HTTP_PORT "HTTP port" "$DEFAULT_HTTP"
      prompt HTTPS_PORT "HTTPS port" "$DEFAULT_HTTPS"
      prompt ADMIN_PORT "Admin UI port" "$DEFAULT_ADMIN"

      [[ "$HTTP_PORT" =~ ^[0-9]+$ && "$HTTPS_PORT" =~ ^[0-9]+$ && "$ADMIN_PORT" =~ ^[0-9]+$ ]] || die "Ports must be numbers."

      write_compose
      start_stack

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Admin:  http://${ip:-localhost}:${ADMIN_PORT}"
      echo "  Files:  $INSTALL_DIR"
      echo
      echo "Default login:"
      echo "  Email:    admin@example.com"
      echo "  Password: changeme"
      echo "Change these on first login."
      echo
      echo "Proxy ports: HTTP ${HTTP_PORT}, HTTPS ${HTTPS_PORT}"
      echo
      echo "Service commands:"
      echo "  sudo docker compose -f $INSTALL_DIR/docker-compose.yml logs"
      echo "  sudo docker compose -f $INSTALL_DIR/docker-compose.yml restart"
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END npm-install.sh
###BEGIN jellyfin-install.sh
#!/usr/bin/env bash
#
# Jellyfin installer / uninstaller (from source via jellyfin-packaging)
# Detects distro, installs build deps (including Docker), clones packaging repo,
# builds a portable Linux archive, installs it, and creates a systemd service.
#
# Usage:
#   bash jellyfin-install.sh            # install
#   bash jellyfin-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/jellyfin/jellyfin-packaging.git"
DEFAULT_DIR="/opt/jellyfin"
BUILD_DIR="/tmp/jellyfin-packaging"
SERVICE_NAME="jellyfin"
DEFAULT_PORT=8096

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── packages ───────────────────────────────────────────────────────────────
install_packages() {
  info "Checking / installing build dependencies..."

  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git python3 python3-git python3-yaml docker.io curl ca-certificates
      ;;
    dnf)
      if ! command -v docker >/dev/null 2>&1; then
        sudo dnf install -y git python3 python3-GitPython python3-pyyaml docker curl ca-certificates || \
        sudo dnf install -y git python3 python3-GitPython python3-pyyaml moby-engine curl ca-certificates
      else
        sudo dnf install -y git python3 python3-GitPython python3-pyyaml curl ca-certificates
      fi
      ;;
    pacman)
      sudo pacman -Sy --noconfirm git python python-gitpython python-pyyaml docker curl ca-certificates
      ;;
    zypper)
      sudo zypper --non-interactive install git python3 python3-GitPython python3-PyYAML docker curl ca-certificates
      ;;
    apk)
      sudo apk add --no-cache git python3 py3-gitpython py3-yaml docker curl ca-certificates
      ;;
  esac

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    sudo rc-update add docker default 2>/dev/null || true
    sudo rc-service docker start 2>/dev/null || true
  fi

  ok "Dependencies ready."
}

# ── build ──────────────────────────────────────────────────────────────────
# Returns archive path via global ARCHIVE (avoids pipefail + command-sub issues)
build_jellyfin() {
  info "Cloning jellyfin-packaging..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
  cd "$BUILD_DIR"

  info "Initializing submodules..."
  git submodule update --init

  info "Building portable Linux archive (this can take several minutes)..."
  if docker info >/dev/null 2>&1; then
    ./build.py auto linux amd64 || true
  else
    sudo ./build.py auto linux amd64 || true
  fi

  # Safe archive lookup (no pipefail issues)
  ARCHIVE=""
  local f
  for f in out/linux/jellyfin_*-amd64.tar.xz out/linux/jellyfin_*-amd64.tar.gz; do
    if [[ -f "$f" ]]; then
      ARCHIVE="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
      break
    fi
  done

  [[ -n "$ARCHIVE" ]] || die "Build finished but no archive found in out/linux/"
  info "Build complete: $ARCHIVE"
}

# ── install ────────────────────────────────────────────────────────────────
install_files() {
  local archive="$1"
  info "Installing to $INSTALL_DIR ..."
  [[ -f "$archive" ]] || die "Archive not found: $archive"
  sudo mkdir -p "$INSTALL_DIR"
  sudo tar -xf "$archive" -C "$INSTALL_DIR" --strip-components=1
  sudo chown -R "$USER:$USER" "$INSTALL_DIR"
  ok "Files installed."
}

create_service() {
  local bin="$INSTALL_DIR/jellyfin"
  [[ -x "$bin" ]] || die "jellyfin binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=Jellyfin Media Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$bin --datadir $INSTALL_DIR/data --cachedir $INSTALL_DIR/cache --webdir $INSTALL_DIR/jellyfin-web
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."
  else
    warn "No systemd detected. Start manually with: $bin"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes media data/cache)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove build packages (git, python3, docker, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y git python3 python3-git python3-yaml docker.io || true ;;
      dnf)    sudo dnf remove -y git python3 python3-GitPython python3-pyyaml docker || true ;;
      pacman) sudo pacman -Rns --noconfirm git python python-gitpython python-pyyaml docker || true ;;
      zypper) sudo zypper --non-interactive remove git python3 python3-GitPython python3-PyYAML docker || true ;;
      apk)    sudo apk del git python3 py3-gitpython py3-yaml docker || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "Jellyfin uninstaller"
  echo "===================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Jellyfin installer (from source)"
      echo "================================"
      detect_distro
      install_packages

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"

      ARCHIVE=""
      build_jellyfin
      install_files "$ARCHIVE"
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:$DEFAULT_PORT"
      echo "  Files: $INSTALL_DIR"
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END jellyfin-install.sh
###BEGIN navidrome-install.sh
#!/usr/bin/env bash
#
# Navidrome installer / uninstaller (from source)
# Detects distro, ensures Go 1.27+ and Node 24, clones repo,
# runs make setup + make build, installs the binary, and creates a systemd service.
#
# Usage:
#   bash navidrome-install.sh            # install
#   bash navidrome-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/navidrome/navidrome.git"
DEFAULT_DIR="/opt/navidrome"
BUILD_DIR="/tmp/navidrome-src"
SERVICE_NAME="navidrome"
DEFAULT_PORT=4533
GO_VERSION="1.27.3"
NODE_MIN=24

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── version helpers ────────────────────────────────────────────────────────
ver_ge() {
  # returns 0 if $1 >= $2
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ── packages ───────────────────────────────────────────────────────────────
install_base_packages() {
  info "Installing base build packages..."
  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git make pkg-config libtag1-dev ffmpeg curl ca-certificates tar
      ;;
    dnf)
      sudo dnf install -y \
        git make pkgconf-pkg-config taglib-devel ffmpeg curl ca-certificates tar
      ;;
    pacman)
      sudo pacman -Sy --noconfirm \
        git make pkgconf taglib ffmpeg curl ca-certificates tar
      ;;
    zypper)
      sudo zypper --non-interactive install \
        git make pkg-config libtag-devel ffmpeg curl ca-certificates tar
      ;;
    apk)
      sudo apk add --no-cache \
        git make pkgconf taglib-dev ffmpeg curl ca-certificates tar
      ;;
  esac
  ok "Base packages ready."
}

ensure_go() {
  local current=""
  if command -v go >/dev/null 2>&1; then
    current=$(go version | awk '{print $3}' | sed 's/go//')
  fi

  if [[ -n "$current" ]] && ver_ge "$current" "1.27"; then
    ok "Go $current is new enough"
    return 0
  fi

  info "Go ${current:-not found} is too old (need 1.27+). Installing official Go $GO_VERSION..."
  local tmp="/tmp/go${GO_VERSION}.linux-amd64.tar.gz"
  curl -fsSL -o "$tmp" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$tmp"
  rm -f "$tmp"

  # Prefer the official install for this script and the build
  export PATH="/usr/local/go/bin:$PATH"
  hash -r
  ok "Installed $(go version)"
}

ensure_node() {
  local current=""
  if command -v node >/dev/null 2>&1; then
    current=$(node -v | sed 's/v//' | cut -d. -f1)
  fi

  if [[ -n "$current" ]] && (( current >= NODE_MIN )); then
    ok "Node $current is new enough"
    return 0
  fi

  info "Node ${current:-not found} is too old (need $NODE_MIN+). Installing Node $NODE_MIN from NodeSource..."
  # NodeSource works on most distros; fall back to a note if it fails
  if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MIN}.x" | sudo bash - 2>/dev/null; then
    case "$PKG" in
      apt) sudo apt-get install -y nodejs ;;
      *)   warn "NodeSource setup ran; install nodejs with your package manager if needed." ;;
    esac
  else
    warn "Could not auto-install Node $NODE_MIN. Install it manually and re-run."
    warn "See: https://nodejs.org/ or your distro's nodejs24 package."
  fi

  if command -v node >/dev/null 2>&1; then
    ok "Node $(node -v) available"
  fi
}

# ── build ──────────────────────────────────────────────────────────────────
build_navidrome() {
  info "Cloning navidrome..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
  cd "$BUILD_DIR"

  # Make sure the official Go is first if we installed it
  export PATH="/usr/local/go/bin:$PATH"

  info "Running make setup (downloads build deps)..."
  make setup

  info "Running make build..."
  make build

  [[ -x "$BUILD_DIR/navidrome" ]] || die "Build finished but binary not found."
  info "Build complete: $BUILD_DIR/navidrome"
}

# ── install ────────────────────────────────────────────────────────────────
install_files() {
  info "Installing to $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR/data" "$MUSIC_DIR"
  sudo cp "$BUILD_DIR/navidrome" "$INSTALL_DIR/navidrome"
  sudo chmod +x "$INSTALL_DIR/navidrome"

  sudo tee "$INSTALL_DIR/navidrome.toml" >/dev/null <<CONF
MusicFolder = "$MUSIC_DIR"
DataFolder = "$INSTALL_DIR/data"
Port = $DEFAULT_PORT
Address = "0.0.0.0"
CONF

  sudo chown -R "$USER:$USER" "$INSTALL_DIR"
  ok "Files installed."
}

create_service() {
  local bin="$INSTALL_DIR/navidrome"
  [[ -x "$bin" ]] || die "navidrome binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=Navidrome Music Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$bin --configfile $INSTALL_DIR/navidrome.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."
  else
    warn "No systemd detected. Start manually with: $bin --configfile $INSTALL_DIR/navidrome.toml"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes data)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove official Go from /usr/local/go?"; then
    sudo rm -rf /usr/local/go
    ok "Removed /usr/local/go"
  fi
  if ask_yn "Also remove other build packages (make, taglib, ffmpeg, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y pkg-config libtag1-dev || true ;;
      dnf)    sudo dnf remove -y pkgconf-pkg-config taglib-devel || true ;;
      pacman) sudo pacman -Rns --noconfirm pkgconf taglib || true ;;
      zypper) sudo zypper --non-interactive remove pkg-config libtag-devel || true ;;
      apk)    sudo apk del pkgconf taglib-dev || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "Navidrome uninstaller"
  echo "====================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Navidrome installer (from source)"
      echo "================================="
      detect_distro
      install_base_packages
      ensure_go
      ensure_node

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt MUSIC_DIR "Music folder" "/mnt/music"

      build_navidrome
      install_files
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:$DEFAULT_PORT"
      echo "  Files: $INSTALL_DIR"
      echo "  Music: $MUSIC_DIR"
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END navidrome-install.sh
###BEGIN filebrowser-install.sh
#!/usr/bin/env bash
#
# FileBrowser installer / uninstaller (from source)
# Detects distro, installs Go + Node + Task, clones filebrowser,
# builds with `task build`, installs it, and creates a systemd service.
#
# Usage:
#   bash filebrowser-install.sh            # install
#   bash filebrowser-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/filebrowser/filebrowser.git"
DEFAULT_DIR="/opt/filebrowser"
BUILD_DIR="/tmp/filebrowser-src"
SERVICE_NAME="filebrowser"
DEFAULT_PORT=8082
DEFAULT_ROOT="/srv/files"
MIN_GO="1.22"

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

ver_ge() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── latest release check ───────────────────────────────────────────────────
check_latest() {
  info "Checking for latest release..."
  local api="https://api.github.com/repos/filebrowser/filebrowser/releases/latest"
  FB_LATEST=$(curl -fsSL "$api" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 || true)
  if [[ -n "${FB_LATEST:-}" ]]; then
    ok "Latest FileBrowser: $FB_LATEST"
  else
    warn "Could not query releases (will use master)"
    FB_LATEST=""
  fi
  echo
}

# ── packages ───────────────────────────────────────────────────────────────
install_packages() {
  info "Installing build dependencies..."

  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git curl ca-certificates tar gcc g++ make nodejs golang
      ;;
    dnf)
      sudo dnf install -y \
        git curl ca-certificates tar gcc gcc-c++ make nodejs npm golang
      ;;
    pacman)
      sudo pacman -Sy --noconfirm \
        git curl ca-certificates tar gcc make nodejs npm go
      ;;
    zypper)
      sudo zypper --non-interactive install \
        git curl ca-certificates tar gcc gcc-c++ make nodejs npm go
      ;;
    apk)
      sudo apk add --no-cache \
        git curl ca-certificates tar gcc g++ make nodejs npm go
      ;;
  esac

  ok "Build packages ready."
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    local ver
    ver=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | sed 's/go//')
    if ver_ge "$ver" "$MIN_GO"; then
      ok "Go $ver is new enough"
      return 0
    fi
    warn "Go $ver is older than $MIN_GO — installing official tarball"
  else
    warn "Go not found — installing official tarball"
  fi

  local tarball="/tmp/go.tar.gz"
  local url="https://go.dev/dl/go1.25.3.linux-amd64.tar.gz"
  info "Downloading $url"
  curl -fsSL -o "$tarball" "$url" || die "Failed to download Go tarball"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$tarball"
  rm -f "$tarball"
  export PATH="/usr/local/go/bin:$PATH"
  ok "Installed $(go version)"
}

ensure_task() {
  if command -v task >/dev/null 2>&1; then
    ok "task already installed"
  else
    info "Installing task (go-task)..."
    if [[ -d /usr/local/go/bin ]]; then
      export PATH="/usr/local/go/bin:$PATH"
    fi
    sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -d -b /tmp/taskbin || true
    if [[ -x /tmp/taskbin/task ]]; then
      sudo mv /tmp/taskbin/task /usr/local/bin/task
      ok "task installed"
    else
      warn "Could not install task. Will fall back to 'go build'."
    fi
  fi
}

ensure_pnpm() {
  if command -v pnpm >/dev/null 2>&1; then
    ok "pnpm already installed"
    return 0
  fi
  info "Installing pnpm via npm..."
  # npm -g works under sudo; the official pnpm install script does not.
  if command -v npm >/dev/null 2>&1; then
    sudo npm install -g pnpm || die "npm install -g pnpm failed"
  else
    # fallback: pinned standalone binary (latest redirect is unreliable)
    local arch url
    case "$(uname -m)" in
      x86_64|amd64) arch="x64" ;;
      aarch64|arm64) arch="arm64" ;;
      *) die "Unsupported arch for pnpm: $(uname -m)" ;;
    esac
    url="https://github.com/pnpm/pnpm/releases/download/v10.15.0/pnpm-linux-${arch}"
    sudo curl -fsSL -o /usr/local/bin/pnpm -L "$url" || die "Failed to download pnpm"
    sudo chmod +x /usr/local/bin/pnpm
  fi
  export PATH="/usr/local/bin:$PATH"
  if command -v pnpm >/dev/null 2>&1; then
    ok "pnpm installed: $(pnpm --version)"
  else
    die "pnpm is required to build the frontend. Install it and re-run."
  fi
}

# ── build ──────────────────────────────────────────────────────────────────
build_filebrowser() {
  info "Cloning FileBrowser..."
  rm -rf "$BUILD_DIR"
  if [[ -n "${FB_LATEST:-}" ]]; then
    info "Checking out release $FB_LATEST"
    git clone --depth 1 --branch "$FB_LATEST" "$REPO_URL" "$BUILD_DIR" || \
      git clone "$REPO_URL" "$BUILD_DIR"
  else
    git clone "$REPO_URL" "$BUILD_DIR"
  fi
  cd "$BUILD_DIR"

  if [[ -d /usr/local/go/bin ]]; then
    export PATH="/usr/local/go/bin:$PATH"
  fi
  export PATH="/usr/local/bin:$PATH"

  info "Building frontend (pnpm)..."
  if [[ -d frontend ]]; then
    (cd frontend && pnpm install && pnpm run build) || die "Frontend build failed."
  fi

  info "Building backend — this can take a few minutes..."
  if command -v task >/dev/null 2>&1 && [[ -f Taskfile.yml || -f Taskfile.yaml ]]; then
    task build || go build -o filebrowser
  else
    go build -o filebrowser
  fi

  [[ -x "$BUILD_DIR/filebrowser" ]] || die "Build finished but binary not found."
  info "Build complete."
}

# ── install ────────────────────────────────────────────────────────────────
install_files() {
  info "Installing to $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR" "$ROOT_DIR"
  # Fedora SELinux blocks binaries in /opt
  sudo cp "$BUILD_DIR/filebrowser" /usr/local/bin/filebrowser
  sudo chmod +x /usr/local/bin/filebrowser
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    info "SELinux is enforcing — setting bin_t context"
    sudo chcon -t bin_t /usr/local/bin/filebrowser || true
  fi

  # init config and database
  if [[ ! -f "$INSTALL_DIR/filebrowser.db" ]]; then
    info "Initializing config..."
    (cd "$INSTALL_DIR" && /usr/local/bin/filebrowser config init) || true
    (cd "$INSTALL_DIR" && /usr/local/bin/filebrowser config set --address "0.0.0.0" --port "$PORT" --root "$ROOT_DIR") || true
    info "Creating admin user (password must be 12+ characters)..."
    # Default admin / admin12345678 — meets the 12-char minimum
    (cd "$INSTALL_DIR" && /usr/local/bin/filebrowser users add admin admin12345678 --perm.admin) || \
      (cd "$INSTALL_DIR" && /usr/local/bin/filebrowser users update admin --password admin12345678) || true
  fi

  sudo chown -R "$USER:$USER" "$INSTALL_DIR" "$ROOT_DIR" 2>/dev/null || true
  ok "Files installed."
}

create_service() {
  local bin="/usr/local/bin/filebrowser"
  [[ -x "$bin" ]] || die "filebrowser binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=FileBrowser
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$bin -d $INSTALL_DIR/filebrowser.db -r $ROOT_DIR -a 0.0.0.0 -p $PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."

    if systemctl is-active --quiet firewalld 2>/dev/null; then
      info "Opening firewall port ${PORT}/tcp..."
      sudo firewall-cmd --permanent --add-port="${PORT}/tcp" || true
      sudo firewall-cmd --reload || true
      ok "Firewall updated."
    fi

    sleep 2
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
      ok "Web UI is listening on port ${PORT}"
    else
      warn "Web UI is not listening on port ${PORT}."
      warn "Last log lines:"
      sudo journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
    fi
  else
    warn "No systemd detected. Start manually with: $bin -r $ROOT_DIR -a 0.0.0.0 -p $PORT"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  sudo rm -f /usr/local/bin/filebrowser
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes database and config)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove Go tarball install (/usr/local/go)?"; then
    sudo rm -rf /usr/local/go
    ok "Go removed."
  fi
  if ask_yn "Also remove build packages (gcc, nodejs, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y gcc g++ nodejs npm golang || true ;;
      dnf)    sudo dnf remove -y gcc gcc-c++ nodejs npm golang || true ;;
      pacman) sudo pacman -Rns --noconfirm gcc nodejs npm go || true ;;
      zypper) sudo zypper --non-interactive remove gcc gcc-c++ nodejs npm go || true ;;
      apk)    sudo apk del gcc g++ nodejs npm go || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "FileBrowser uninstaller"
  echo "======================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "FileBrowser installer (from source)"
      echo "==================================="
      detect_distro
      check_latest
      install_packages
      ensure_go
      ensure_task
      ensure_pnpm

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt PORT "Listen port" "$DEFAULT_PORT"
      prompt ROOT_DIR "Root directory to serve" "$DEFAULT_ROOT"

      [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

      build_filebrowser
      install_files
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:${PORT}"
      echo "  Files: $INSTALL_DIR"
      echo "  Root:  $ROOT_DIR"
      echo
      echo "Default login: admin / admin12345678"
      echo "Change the password on first login. (minimum 12 characters)"
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END filebrowser-install.sh
###BEGIN adguard-install.sh
#!/usr/bin/env bash
#
# AdGuard Home installer / uninstaller (from source)
# Detects distro, installs Go + Node + build deps, clones AdGuardHome,
# builds with make, installs it, and creates a systemd service.
#
# Usage:
#   bash adguard-install.sh            # install
#   bash adguard-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/AdguardTeam/AdGuardHome.git"
DEFAULT_DIR="/opt/adguardhome"
BUILD_DIR="/tmp/adguard-src"
SERVICE_NAME="adguardhome"
DEFAULT_WEB_PORT=3000
MIN_GO="1.25"
MIN_NODE="24"

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

ver_ge() {
  # returns 0 if $1 >= $2
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# True for loopback / unset addresses that must never be an upstream.
is_loopback() {
  local ip="$1"
  [[ -z "$ip" || "$ip" == 127.* || "$ip" == "::1" || "$ip" == "0.0.0.0" || "$ip" == "::" || "$ip" == "127.0.0.53" ]]
}

# Detect a real upstream DNS. Never returns loopback.
# On a re-run the previous install may have pointed the system at 127.0.0.1;
# that is ignored so AdGuard is not told to query itself.
detect_router_dns() {
  local dns="" ip
  # 1) resolvectl
  if command -v resolvectl >/dev/null 2>&1; then
    while read -r ip; do
      if ! is_loopback "$ip"; then dns="$ip"; break; fi
    done < <(resolvectl dns 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
  fi
  # 2) resolv.conf
  if [[ -z "$dns" && -f /etc/resolv.conf ]]; then
    while read -r ip; do
      if ! is_loopback "$ip"; then dns="$ip"; break; fi
    done < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf)
  fi
  # 3) default gateway
  if [[ -z "$dns" ]]; then
    ip=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}' || true)
    if ! is_loopback "$ip"; then dns="$ip"; fi
  fi
  printf '%s' "$dns"
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── latest release check ───────────────────────────────────────────────────
check_latest() {
  info "Checking for latest release..."
  local api="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"
  AGH_LATEST=$(curl -fsSL "$api" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 || true)
  if [[ -n "${AGH_LATEST:-}" ]]; then
    ok "Latest AdGuard Home: $AGH_LATEST"
  else
    warn "Could not query releases (will use master)"
    AGH_LATEST=""
  fi
  echo
}

# ── packages ───────────────────────────────────────────────────────────────
install_packages() {
  info "Installing build dependencies..."

  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git make curl ca-certificates tar gcc g++ pkg-config nodejs golang
      ;;
    dnf)
      sudo dnf install -y \
        git make curl ca-certificates tar gcc gcc-c++ pkgconf-pkg-config nodejs npm golang
      ;;
    pacman)
      sudo pacman -Sy --noconfirm \
        git make curl ca-certificates tar gcc pkgconf nodejs npm go
      ;;
    zypper)
      sudo zypper --non-interactive install \
        git make curl ca-certificates tar gcc gcc-c++ pkg-config nodejs npm go
      ;;
    apk)
      sudo apk add --no-cache \
        git make curl ca-certificates tar gcc g++ pkgconf nodejs npm go
      ;;
  esac

  ok "Build packages ready."
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    local ver
    ver=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | sed 's/go//')
    if ver_ge "$ver" "$MIN_GO"; then
      ok "Go $ver is new enough"
      return 0
    fi
    warn "Go $ver is older than $MIN_GO — installing official tarball"
  else
    warn "Go not found — installing official tarball"
  fi

  local tarball="/tmp/go.tar.gz"
  local url="https://go.dev/dl/go1.25.3.linux-amd64.tar.gz"
  info "Downloading $url"
  curl -fsSL -o "$tarball" "$url" || die "Failed to download Go tarball"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$tarball"
  rm -f "$tarball"
  export PATH="/usr/local/go/bin:$PATH"
  ok "Installed $(go version)"
}

ensure_node() {
  if command -v node >/dev/null 2>&1; then
    local ver
    ver=$(node -v | sed 's/v//' | cut -d. -f1)
    if [[ "$ver" -ge "$MIN_NODE" ]]; then
      ok "Node $(node -v) is new enough"
      return 0
    fi
    warn "Node $(node -v) is older than v$MIN_NODE"
  else
    warn "Node not found"
  fi

  info "Installing Node $MIN_NODE from NodeSource..."
  case "$PKG" in
    apt)
      curl -fsSL "https://deb.nodesource.com/setup_${MIN_NODE}.x" | sudo -E bash -
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
      ;;
    dnf)
      curl -fsSL "https://rpm.nodesource.com/setup_${MIN_NODE}.x" | sudo bash -
      sudo dnf install -y nodejs
      ;;
    *)
      warn "Automatic Node upgrade not supported for $PKG. Install Node $MIN_NODE+ manually if the build fails."
      ;;
  esac

  if command -v node >/dev/null 2>&1; then
    ok "Node is now $(node -v)"
  fi
}

# ── build ──────────────────────────────────────────────────────────────────
build_adguard() {
  info "Cloning AdGuard Home..."
  rm -rf "$BUILD_DIR"
  # Full clone of the default branch so origin/master exists.
  # The Makefile's version.sh runs 'git rev-list origin/master..HEAD'
  # and fails on a shallow or tag-only clone.
  git clone "$REPO_URL" "$BUILD_DIR"
  cd "$BUILD_DIR"

  # Ensure origin/master exists for the version script
  git fetch origin master:refs/remotes/origin/master 2>/dev/null || true
  if ! git rev-parse --verify origin/master >/dev/null 2>&1; then
    # fallback: point origin/master at HEAD
    git update-ref refs/remotes/origin/master HEAD
  fi

  # Optional: check out the latest release tag if it exists and master is present
  if [[ -n "${AGH_LATEST:-}" ]]; then
    if git rev-parse --verify "refs/tags/$AGH_LATEST" >/dev/null 2>&1; then
      info "Checking out $AGH_LATEST (origin/master kept for build)"
      git checkout "$AGH_LATEST"
      # re-point origin/master so version.sh doesn't fail on detached HEAD
      git update-ref refs/remotes/origin/master HEAD
    fi
  fi

  git config advice.detachedHead false || true

  # make sure go is on PATH
  if [[ -d /usr/local/go/bin ]]; then
    export PATH="/usr/local/go/bin:$PATH"
  fi

  info "Building with make — this can take several minutes..."
  make
  [[ -x "$BUILD_DIR/AdGuardHome" ]] || die "Build finished but binary not found."
  info "Build complete."
}

# ── install ────────────────────────────────────────────────────────────────
install_files() {
  info "Installing to $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR"
  # Fedora SELinux blocks binaries in /opt. Put the binary in /usr/local/bin.
  sudo cp "$BUILD_DIR/AdGuardHome" /usr/local/bin/AdGuardHome
  sudo chmod +x /usr/local/bin/AdGuardHome
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    info "SELinux is enforcing — setting bin_t context"
    sudo chcon -t bin_t /usr/local/bin/AdGuardHome || true
  fi
  sudo chown -R "$USER:$USER" "$INSTALL_DIR" 2>/dev/null || true
  ok "Files installed."
}

free_port_53() {
  # systemd-resolved often holds 127.0.0.53:53 and makes AdGuard exit
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    info "systemd-resolved is active — disabling its DNS stub so AdGuard can bind port 53"
    sudo mkdir -p /etc/systemd/resolved.conf.d
    sudo tee /etc/systemd/resolved.conf.d/adguardhome.conf >/dev/null <<'RES'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
RES
    sudo systemctl restart systemd-resolved || true
    # point resolv.conf at the real resolved file if it's a stub
    if [[ -L /etc/resolv.conf ]] && [[ "$(readlink /etc/resolv.conf)" == *stub* ]]; then
      sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
    fi
    ok "Port 53 freed."
  fi
}

write_config() {
  if [[ "${ENABLE_BLOCKING:-false}" != "true" ]]; then
    info "Skipping ad-blocking config (setup wizard will run on first visit)."
    return 0
  fi

  info "Writing config with AdGuard DNS filter enabled..."
  sudo tee "$INSTALL_DIR/AdGuardHome.yaml" >/dev/null <<YAML
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:${WEB_PORT}
  session_ttl: 720h
users: []
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - ${UPSTREAM_DNS:-https://dns10.quad9.net/dns-query}
    - https://dns.cloudflare.com/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
    - 2620:fe::10
    - 2620:fe::fe:10
  fallback_dns: []
  all_servers: false
  fastest_addr: false
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 2160h
  size_memory: 1000
  enabled: true
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 24h
  enabled: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
whitelist_filters: []
user_rules:
  - "||ads.trafficjunky.net^"
  - "||pornhub.com^"
  - "||doubleclick.net^"
  - "||trafficjunky.net^"
dhcp:
  enabled: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: Local
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safe_fs_patterns:
    - /opt/adguardhome/userfilters/*
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 28
YAML
  sudo chown "$USER:$USER" "$INSTALL_DIR/AdGuardHome.yaml"
  ok "Config written. Ad blocking is enabled with the AdGuard DNS filter."
}

create_service() {
  free_port_53
  local bin="/usr/local/bin/AdGuardHome"
  [[ -x "$bin" ]] || die "AdGuardHome binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=AdGuard Home
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$bin -w $INSTALL_DIR --no-check-update
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."

    # open firewall if firewalld is running
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      info "Opening firewall ports 3000/tcp and 53/udp+tcp..."
      sudo firewall-cmd --permanent --add-port=${WEB_PORT}/tcp || true
      sudo firewall-cmd --permanent --add-port=53/tcp || true
      sudo firewall-cmd --permanent --add-port=53/udp || true
      sudo firewall-cmd --reload || true
      ok "Firewall updated."
    fi

    # verify it is actually listening
    sleep 2
    if ss -tlnp 2>/dev/null | grep -q ":${WEB_PORT} "; then
      ok "Web UI is listening on port ${WEB_PORT}"
    else
      warn "Web UI is not listening on port ${WEB_PORT}."
      warn "Last log lines:"
      sudo journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
    fi
  else
    warn "No systemd detected. Start manually with: $bin -w $INSTALL_DIR"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  sudo rm -f /usr/local/bin/AdGuardHome
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes config and query log)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove Go tarball install (/usr/local/go)?"; then
    sudo rm -rf /usr/local/go
    ok "Go removed."
  fi
  if ask_yn "Also remove build packages (gcc, nodejs, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y gcc g++ pkg-config nodejs npm golang || true ;;
      dnf)    sudo dnf remove -y gcc gcc-c++ pkgconf-pkg-config nodejs npm golang || true ;;
      pacman) sudo pacman -Rns --noconfirm gcc pkgconf nodejs npm go || true ;;
      zypper) sudo zypper --non-interactive remove gcc gcc-c++ pkg-config nodejs npm go || true ;;
      apk)    sudo apk del gcc g++ pkgconf nodejs npm go || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "AdGuard Home uninstaller"
  echo "========================"
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "AdGuard Home installer (from source)"
      echo "===================================="
      detect_distro
      check_latest
      install_packages
      ensure_go
      ensure_node

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt WEB_PORT "Web UI port" "$DEFAULT_WEB_PORT"

      if ask_yn "Enable ad blocking now with the AdGuard DNS filter?" "y"; then
        ENABLE_BLOCKING="true"
      else
        ENABLE_BLOCKING="false"
      fi

      [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

      # detect current router DNS for upstream (optional)
      DETECTED_DNS=$(detect_router_dns)
      UPSTREAM_DNS=""
      if is_loopback "$DETECTED_DNS"; then
        DETECTED_DNS=""
      fi
      if [[ -n "$DETECTED_DNS" ]]; then
        if ask_yn "Use detected router DNS ($DETECTED_DNS) as AdGuard upstream? (or set it later in the UI)"; then
          UPSTREAM_DNS="$DETECTED_DNS"
          ok "Will use $UPSTREAM_DNS as upstream"
        else
          info "Skipping — you can set upstream DNS later in the UI"
        fi
      else
        warn "No real upstream DNS detected (127.0.0.1 is ignored)."
        if ask_yn "Use 1.1.1.1 as upstream instead? (or set it later in the UI)"; then
          UPSTREAM_DNS="1.1.1.1"
          ok "Will use 1.1.1.1 as upstream"
        else
          info "Skipping — you can set upstream DNS later in the UI"
        fi
      fi

      build_adguard
      install_files
      write_config
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:${WEB_PORT}"
      echo "  Files: $INSTALL_DIR"
      echo
      # flush local DNS cache so tests aren't served from old answers
      info "Flushing local DNS cache..."
      if command -v resolvectl >/dev/null 2>&1; then
        sudo resolvectl flush-caches 2>/dev/null || true
      fi
      if command -v nscd >/dev/null 2>&1; then
        sudo nscd -i hosts 2>/dev/null || true
      fi
      ok "DNS cache flushed."

      if [[ "${ENABLE_BLOCKING:-false}" == "true" ]]; then
        echo "Ad blocking is enabled with the AdGuard DNS filter."
        if [[ -n "${UPSTREAM_DNS:-}" ]]; then
          echo "Upstream DNS set to detected router DNS: $UPSTREAM_DNS"
        fi
        echo "Set your device or router DNS to ${ip:-localhost} to use it."
        echo
        # prove blocking with a direct DNS query
        echo "Proof check (querying AdGuard directly):"
        # Domains known to be in the AdGuard DNS filter.
        # doubleclick.net is not always blocked; these are.
        local domains=("ads.trafficjunky.net" "pornhub.com" "doubleclick.net")
        local domain result blocked=0 checked=0
        if ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
          warn "dig/nslookup not found — install bind-utils or dnsutils for the proof check"
        else
          for domain in "${domains[@]}"; do
            checked=$((checked+1))
            result=""
            if command -v dig >/dev/null 2>&1; then
              result=$(dig +short @127.0.0.1 "$domain" 2>/dev/null | head -1 || true)
            else
              result=$(nslookup "$domain" 127.0.0.1 2>/dev/null | awk '/^Address: / && !/127\.0\.0\.1/ {print $2; exit}' || true)
            fi
            echo "  $domain -> ${result:-<empty>}"
            if [[ -z "$result" || "$result" == "0.0.0.0" || "$result" == "::" ]]; then
              ok "BLOCKED — $domain"
              blocked=$((blocked+1))
            else
              warn "NOT BLOCKED — $domain resolved to $result"
            fi
          done
          echo
          if [[ "$blocked" -gt 0 ]]; then
            ok "Proof: $blocked of $checked test domains blocked"
          else
            warn "Proof failed: none of the test domains were blocked"
            warn "Check that this machine is using AdGuard (127.0.0.1) as its DNS."
          fi
        fi
        echo
        echo "Browser test (clear the page cache first, or use a private window):"
        echo "  https://d3ward.github.io/toolz/adblock.html"
        echo "  A high score means blocking is working."
        echo
        echo "Also check the Query Log in the UI for blocked requests."
      else
        echo "First visit runs the setup wizard."
      fi
      echo "DNS listens on port 53 — make sure nothing else is using it."
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END adguard-install.sh
###BEGIN vaultwarden-install.sh
#!/usr/bin/env bash
#
# Vaultwarden installer / uninstaller (from source)
# Detects distro, installs Rust + build deps, clones vaultwarden,
# builds with cargo (sqlite), downloads the web vault, installs it,
# and creates a systemd service.
#
# Usage:
#   bash vaultwarden-install.sh            # install
#   bash vaultwarden-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/dani-garcia/vaultwarden.git"
DEFAULT_DIR="/opt/vaultwarden"
BUILD_DIR="/tmp/vaultwarden-src"
SERVICE_NAME="vaultwarden"
DEFAULT_PORT=8000

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── latest release check ───────────────────────────────────────────────────
check_latest() {
  info "Checking for latest releases..."

  # Vaultwarden
  local vw_api="https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest"
  VW_LATEST=$(curl -fsSL "$vw_api" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 || true)
  if [[ -n "${VW_LATEST:-}" ]]; then
    ok "Latest Vaultwarden: $VW_LATEST"
  else
    warn "Could not query Vaultwarden releases (will use main)"
    VW_LATEST=""
  fi

  # Web vault
  local web_api="https://api.github.com/repos/dani-garcia/bw_web_builds/releases/latest"
  WEB_LATEST=$(curl -fsSL "$web_api" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 || true)
  WEB_URL=$(curl -fsSL "$web_api" 2>/dev/null | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.tar\.gz"' | head -1 | cut -d'"' -f4 || true)
  if [[ -n "${WEB_LATEST:-}" ]]; then
    ok "Latest web vault: $WEB_LATEST"
  else
    warn "Could not query web vault releases (will use fallback)"
    WEB_LATEST=""
    WEB_URL="https://github.com/dani-garcia/bw_web_builds/releases/download/v2026.7.0/bw_web_v2026.7.0.tar.gz"
  fi

  echo
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── packages ───────────────────────────────────────────────────────────────
install_packages() {
  info "Installing build dependencies..."

  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git build-essential pkg-config libssl-dev libsqlite3-dev curl ca-certificates tar openssl
      ;;
    dnf)
      sudo dnf install -y \
        git gcc gcc-c++ make pkgconf-pkg-config openssl-devel sqlite-devel curl ca-certificates tar openssl
      ;;
    pacman)
      sudo pacman -Sy --noconfirm \
        git base-devel pkgconf openssl sqlite curl ca-certificates tar openssl
      ;;
    zypper)
      sudo zypper --non-interactive install \
        git gcc gcc-c++ make pkg-config libopenssl-devel sqlite3-devel curl ca-certificates tar openssl
      ;;
    apk)
      sudo apk add --no-cache \
        git build-base pkgconf openssl-dev sqlite-dev curl ca-certificates tar openssl
      ;;
  esac

  ok "Build packages ready."
}

install_rust() {
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    ok "Rust already installed: $(rustc --version)"
    return 0
  fi

  info "Installing Rust via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
  ok "Installed $(rustc --version)"
}

# ── build ──────────────────────────────────────────────────────────────────
build_vaultwarden() {
  info "Cloning vaultwarden..."
  rm -rf "$BUILD_DIR"
  if [[ -n "${VW_LATEST:-}" ]]; then
    info "Checking out release $VW_LATEST"
    git clone --depth 1 --branch "$VW_LATEST" "$REPO_URL" "$BUILD_DIR" ||       git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
  else
    git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
  fi
  cd "$BUILD_DIR"

  # make sure cargo is on PATH
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi

  info "Building with cargo (sqlite, release) — this can take several minutes..."
  cargo build --features sqlite --release

  [[ -x "$BUILD_DIR/target/release/vaultwarden" ]] || die "Build finished but binary not found."
  info "Build complete."
}

download_web_vault() {
  local url="${WEB_URL:-https://github.com/dani-garcia/bw_web_builds/releases/download/v2026.7.0/bw_web_v2026.7.0.tar.gz}"
  info "Downloading web vault: $url"
  local tmp="/tmp/bw_web.tar.gz"
  curl -fsSL -o "$tmp" -L "$url" || die "Web vault download failed."
  sudo mkdir -p "$INSTALL_DIR/web-vault"
  sudo tar -xzf "$tmp" -C "$INSTALL_DIR/web-vault" --strip-components=1
  rm -f "$tmp"
  ok "Web vault installed."
}

# ── install ────────────────────────────────────────────────────────────────
generate_cert() {
  info "Generating self-signed certificate..."
  sudo mkdir -p "$INSTALL_DIR/certs"
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="127.0.0.1"
  sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$INSTALL_DIR/certs/key.pem" \
    -out "$INSTALL_DIR/certs/cert.pem" \
    -subj "/CN=vaultwarden" \
    -addext "subjectAltName=IP:${ip},DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
  sudo chmod 600 "$INSTALL_DIR/certs/key.pem"
  sudo chown -R "$USER:$USER" "$INSTALL_DIR/certs"
  ok "Certificate created: $INSTALL_DIR/certs/"
}

install_files() {
  info "Installing to $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/web-vault"
  sudo cp "$BUILD_DIR/target/release/vaultwarden" "$INSTALL_DIR/vaultwarden"
  sudo chmod +x "$INSTALL_DIR/vaultwarden"

  local tls_line=""
  if [[ "${ENABLE_HTTPS:-false}" == "true" ]]; then
    generate_cert
    tls_line="ROCKET_TLS={certs=\"$INSTALL_DIR/certs/cert.pem\",key=\"$INSTALL_DIR/certs/key.pem\"}"
  fi

  # env file for the service
  sudo tee "$INSTALL_DIR/vaultwarden.env" >/dev/null <<ENV
DATA_FOLDER=$INSTALL_DIR/data
WEB_VAULT_FOLDER=$INSTALL_DIR/web-vault
ROCKET_ADDRESS=0.0.0.0
ROCKET_PORT=$PORT
SIGNUPS_ALLOWED=$SIGNUPS_ALLOWED
${tls_line}
${DOMAIN:+DOMAIN=$DOMAIN}
ENV

  sudo chown -R "$USER:$USER" "$INSTALL_DIR"
  ok "Files installed."
}

create_service() {
  local bin="$INSTALL_DIR/vaultwarden"
  [[ -x "$bin" ]] || die "vaultwarden binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=Vaultwarden Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/vaultwarden.env
ExecStart=$bin
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."
  else
    warn "No systemd detected. Start manually with: $bin"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes vault data)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove Rust (rustup)?"; then
    if command -v rustup >/dev/null 2>&1; then
      rustup self uninstall -y || true
      ok "Rust removed."
    fi
  fi
  if ask_yn "Also remove build packages (gcc, openssl-devel, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y build-essential pkg-config libssl-dev libsqlite3-dev || true ;;
      dnf)    sudo dnf remove -y gcc gcc-c++ make pkgconf-pkg-config openssl-devel sqlite-devel || true ;;
      pacman) sudo pacman -Rns --noconfirm base-devel pkgconf openssl sqlite || true ;;
      zypper) sudo zypper --non-interactive remove gcc gcc-c++ make pkg-config libopenssl-devel sqlite3-devel || true ;;
      apk)    sudo apk del build-base pkgconf openssl-dev sqlite-dev || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "Vaultwarden uninstaller"
  echo "======================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Vaultwarden installer (from source)"
      echo "==================================="
      detect_distro
      check_latest
      install_packages
      install_rust

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt PORT "Listen port" "$DEFAULT_PORT"

      # HTTPS avoids the "insecure URL" / Subtle Crypto error in the web vault
      if ask_yn "Enable HTTPS with a self-signed certificate? (recommended — required for account creation over LAN IP)" "y"; then
        ENABLE_HTTPS="true"
        # default domain to the IP over https if user doesn't set one
        local ip
        ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
        prompt DOMAIN "Domain (leave blank to use https://${ip}:${PORT})" ""
        if [[ -z "$DOMAIN" ]]; then
          DOMAIN="https://${ip}:${PORT}"
        fi
      else
        ENABLE_HTTPS="false"
        prompt DOMAIN "Domain (optional, e.g. https://vault.example.com)" ""
      fi

      if ask_yn "Allow open signups? (set to no after you create your account)"; then
        SIGNUPS_ALLOWED="true"
      else
        SIGNUPS_ALLOWED="false"
      fi

      [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

      build_vaultwarden
      download_web_vault
      install_files
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      if [[ "${ENABLE_HTTPS:-false}" == "true" ]]; then
        echo "  Open:  ${DOMAIN:-https://${ip:-localhost}:${PORT}}"
        echo
        echo "  Browser will warn about the self-signed certificate."
        echo "  Click Advanced -> Proceed to continue."
      else
        if [[ -n "$DOMAIN" ]]; then
          echo "  Open:  $DOMAIN"
        fi
        echo "  Open:  http://${ip:-localhost}:${PORT}"
        echo
        echo "  Note: account creation over a LAN IP requires HTTPS."
        echo "  Use http://localhost:${PORT} from this machine, or re-run with HTTPS."
      fi
      echo "  Files: $INSTALL_DIR"
      echo "  Data:  $INSTALL_DIR/data"
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END vaultwarden-install.sh
###BEGIN trilium-install.sh
#!/usr/bin/env bash
#
# Trilium Notes server installer / uninstaller (official server tarball)
# Detects distro, downloads the latest Linux server release, installs it,
# and creates a systemd service.
#
# Usage:
#   bash trilium-install.sh            # install
#   bash trilium-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO="TriliumNext/Trilium"
DEFAULT_DIR="/opt/trilium"
DEFAULT_DATA="/opt/trilium/data"
SERVICE_NAME="trilium"
DEFAULT_PORT=8083
BIN_NAME="trilium.sh"

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── latest release check ───────────────────────────────────────────────────
check_latest() {
  info "Checking for latest release..."
  local api="https://api.github.com/repos/$REPO/releases/latest"
  TRI_LATEST=$(curl -fsSL "$api" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 || true)
  if [[ -n "${TRI_LATEST:-}" ]]; then
    ok "Latest Trilium: $TRI_LATEST"
  else
    warn "Could not query releases, using v0.106.1"
    TRI_LATEST="v0.106.1"
  fi
  echo
}

# ── packages ───────────────────────────────────────────────────────────────
install_packages() {
  info "Installing dependencies..."
  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar xz-utils
      ;;
    dnf)
      sudo dnf install -y curl ca-certificates tar xz
      ;;
    pacman)
      sudo pacman -Sy --noconfirm curl ca-certificates tar xz
      ;;
    zypper)
      sudo zypper --non-interactive install curl ca-certificates tar xz
      ;;
    apk)
      sudo apk add --no-cache curl ca-certificates tar xz
      ;;
  esac
  ok "Dependencies ready."
}

# ── download and install ───────────────────────────────────────────────────
install_trilium() {
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac

  local asset="TriliumNotes-Server-${TRI_LATEST}-linux-${arch}.tar.xz"
  local url="https://github.com/$REPO/releases/download/${TRI_LATEST}/${asset}"
  local tmp="/tmp/${asset}"

  info "Downloading $url"
  curl -fsSL -o "$tmp" -L "$url" || die "Download failed. Check the asset name for $TRI_LATEST."

  info "Installing to $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR"
  # extract; the tarball has a top-level dir
  local extract="/tmp/trilium-extract"
  rm -rf "$extract"
  mkdir -p "$extract"
  tar -xJf "$tmp" -C "$extract"
  # move contents into INSTALL_DIR
  local inner
  inner=$(find "$extract" -mindepth 1 -maxdepth 1 -type d | head -1)
  if [[ -n "$inner" ]]; then
    sudo rm -rf "$INSTALL_DIR/app"
    sudo mv "$inner" "$INSTALL_DIR/app"
  else
    die "Unexpected archive layout."
  fi
  rm -f "$tmp"
  rm -rf "$extract"

  sudo mkdir -p "$DATA_DIR"
  # make sure the launcher is executable
  sudo chmod +x "$INSTALL_DIR/app/$BIN_NAME" 2>/dev/null || true
  sudo find "$INSTALL_DIR/app" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  # Fedora SELinux blocks executables in /opt
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    info "SELinux is enforcing — setting bin_t context on $INSTALL_DIR/app"
    sudo chcon -R -t bin_t "$INSTALL_DIR/app" || true
  fi
  sudo chown -R "$USER:$USER" "$INSTALL_DIR" "$DATA_DIR" 2>/dev/null || true
  ok "Files installed."
}

create_service() {
  local bin="$INSTALL_DIR/app/$BIN_NAME"
  [[ -x "$bin" ]] || die "Trilium launcher not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=Trilium Notes Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR/app
Environment=TRILIUM_DATA_DIR=$DATA_DIR
Environment=TRILIUM_PORT=$PORT
ExecStart=$bin
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."

    if systemctl is-active --quiet firewalld 2>/dev/null; then
      info "Opening firewall port ${PORT}/tcp..."
      sudo firewall-cmd --permanent --add-port="${PORT}/tcp" || true
      sudo firewall-cmd --reload || true
      ok "Firewall updated."
    fi

    sleep 3
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
      ok "Web UI is listening on port ${PORT}"
    else
      warn "Web UI is not listening on port ${PORT} yet."
      warn "Last log lines:"
      sudo journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
    fi
  else
    warn "No systemd detected. Start manually with: TRILIUM_DATA_DIR=$DATA_DIR TRILIUM_PORT=$PORT $bin"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

uninstall() {
  echo "Trilium uninstaller"
  echo "==================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  if [[ -d "$INSTALL_DIR" ]]; then
    if ask_yn "Remove install directory $INSTALL_DIR (includes notes data)?"; then
      sudo rm -rf "$INSTALL_DIR"
      ok "Directory removed."
    else
      info "Kept $INSTALL_DIR"
    fi
  else
    warn "Install directory $INSTALL_DIR not found."
  fi

  if ask_yn "Also remove packages (curl, tar, xz)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y curl tar xz-utils || true ;;
      dnf)    sudo dnf remove -y curl tar xz || true ;;
      pacman) sudo pacman -Rns --noconfirm curl tar xz || true ;;
      zypper) sudo zypper --non-interactive remove curl tar xz || true ;;
      apk)    sudo apk del curl tar xz || true ;;
    esac
    ok "Package removal finished."
  fi

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Trilium Notes installer (server tarball)"
      echo "========================================"
      detect_distro
      check_latest
      install_packages

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt DATA_DIR "Data directory" "$DEFAULT_DATA"
      prompt PORT "Listen port" "$DEFAULT_PORT"

      [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

      install_trilium
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:${PORT}"
      echo "  Files: $INSTALL_DIR"
      echo "  Data:  $DATA_DIR"
      echo
      echo "First visit creates your account and password."
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END trilium-install.sh
###BEGIN forgepanel-install.sh
#!/usr/bin/env bash
#
# ForgePanel-Dashboard installer / uninstaller
# Detects distro, ensures python3 + git are present, clones the repo,
# and sets up a simple service to serve it.
#
# Usage:
#   bash forgepanel-install.sh            # install
#   bash forgepanel-install.sh uninstall  # remove service (+ optional packages)
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/JeffTheTroubleshooter/ForgePanel-Dashboard.git"
DEFAULT_PORT=8084
DEFAULT_DIR="/opt/forgepanel"
SERVICE_NAME="forgepanel"

# ── helpers ────────────────────────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok() { echo -e "\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m==>\033[0m $*"; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── package check + install ────────────────────────────────────────────────
ensure_package() {
  local cmd="$1"
  local pkg="$2"

  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd already installed"
    return 0
  fi

  info "$cmd not found — installing $pkg..."
  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
      ;;
    dnf)
      sudo dnf install -y "$pkg"
      ;;
    pacman)
      sudo pacman -Sy --noconfirm "$pkg"
      ;;
    zypper)
      sudo zypper --non-interactive install "$pkg"
      ;;
    apk)
      sudo apk add --no-cache "$pkg"
      ;;
  esac
  ok "$pkg installed"
}

install_requirements() {
  info "Checking required packages..."
  ensure_package python3 python3
  ensure_package git git
}

# ── prompts ────────────────────────────────────────────────────────────────
ask_user() {
  echo
  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
  prompt PORT "Port to listen on" "$DEFAULT_PORT"

  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."
  (( PORT >= 1 && PORT <= 65535 )) || die "Port out of range."
}

# ── clone / update ─────────────────────────────────────────────────────────
setup_files() {
  info "Setting up files in $INSTALL_DIR ..."
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Existing install found — pulling latest..."
    sudo git -C "$INSTALL_DIR" pull --ff-only
  else
    sudo mkdir -p "$(dirname "$INSTALL_DIR")"
    sudo git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  fi
  sudo chown -R "$USER:$USER" "$INSTALL_DIR" 2>/dev/null || true
  ok "Files ready."
}

# ── service ────────────────────────────────────────────────────────────────
create_service() {
  local python
  python=$(command -v python3)

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=ForgePanel Dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$python -m http.server $PORT
Restart=on-failure
RestartSec=3
User=$USER

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."

  elif command -v rc-service >/dev/null 2>&1; then
    info "Creating OpenRC service (Alpine)..."
    sudo tee "/etc/init.d/${SERVICE_NAME}" >/dev/null <<OPENRC
#!/sbin/openrc-run
description="ForgePanel Dashboard"
command="$python"
command_args="-m http.server $PORT"
directory="$INSTALL_DIR"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"
OPENRC
    sudo chmod +x "/etc/init.d/${SERVICE_NAME}"
    sudo rc-update add "$SERVICE_NAME" default
    sudo rc-service "$SERVICE_NAME" restart
    ok "OpenRC service enabled and started."
  else
    warn "No systemd or OpenRC detected. Starting in background..."
    nohup "$python" -m http.server "$PORT" --directory "$INSTALL_DIR" >/dev/null 2>&1 &
    ok "Started in background (PID $!)."
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
      sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
      sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
      sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      sudo systemctl daemon-reload
      ok "systemd service removed."
    else
      warn "No systemd service found."
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    if [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
      sudo rc-service "$SERVICE_NAME" stop 2>/dev/null || true
      sudo rc-update del "$SERVICE_NAME" default 2>/dev/null || true
      sudo rm -f "/etc/init.d/${SERVICE_NAME}"
      ok "OpenRC service removed."
    else
      warn "No OpenRC service found."
    fi
  else
    # best-effort kill of background python http.server
    pkill -f "python3 -m http.server" 2>/dev/null || true
    warn "No service manager found — attempted to stop background process."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_packages() {
  if ask_yn "Also remove packages (python3 and git)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)
        sudo apt-get remove -y python3 git || true
        ;;
      dnf)
        sudo dnf remove -y python3 git || true
        ;;
      pacman)
        sudo pacman -Rns --noconfirm python git || true
        ;;
      zypper)
        sudo zypper --non-interactive remove python3 git || true
        ;;
      apk)
        sudo apk del python3 git || true
        ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "ForgePanel-Dashboard uninstaller"
  echo "================================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "ForgePanel-Dashboard installer"
      echo "==============================="
      detect_distro
      install_requirements
      ask_user
      setup_files
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:$PORT"
      echo "  Files: $INSTALL_DIR"
      echo
      echo "Default login (change on first use): admin / forgepanel"
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      elif command -v rc-service >/dev/null 2>&1; then
        echo "  sudo rc-service $SERVICE_NAME status"
        echo "  sudo rc-service $SERVICE_NAME restart"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
###END forgepanel-install.sh
