#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329,SC2001  # single-quoted remote scripts; compose_/env_ called via "compose_$app"; sed on multi-line env
#
# Proxmox homelab — one script
# Creates 4 Debian LXC containers with Docker + Compose, runs every app from its
# official Docker image inside the right one, health-checks them, and prints the URLs.
#
# Usage (on the Proxmox host):
#   bash proxmox.sh            # create + install everything
#   bash proxmox.sh update     # pull newer images and recreate the apps in existing CTs
#   bash proxmox.sh reset-logins  # reset default logins + redeploy Vaultwarden (HTTPS), keeps data
#   bash proxmox.sh destroy    # remove only guests this script created (tagged homelab-script)
#   bash <(curl -fsSL <raw proxmox.sh URL>)   # run straight from GitHub
#   curl -fsSL <raw proxmox.sh URL> | bash    # also works (re-downloads itself to /tmp)
#
# Containers (each: Debian, nesting=1,keyctl=1, Docker CE + compose plugin):
#   200 docker-stack   Immich, Nextcloud, RomM, Nginx Proxy Manager
#   201 source-stack   Jellyfin, Navidrome, FileBrowser, AdGuard Home
#   202 light-stack    Vaultwarden, Trilium
#   203 forgepanel     ForgePanel dashboard
#
# Each app lives in /opt/homelab/<app>/ inside its CT (docker-compose.yml, .env,
# data). Generated passwords are written to .env files there (mode 600) and are
# never printed. The standalone per-app repos stay native installers; this
# script does not use them.
#
# Environment overrides:
#   HEARTBEAT_SECS=30      progress line interval
#   APP_TIMEOUT_SECS=1800  hard limit per app install (0 = none)
#   HEALTH_TIMEOUT=300     seconds each app gets to answer on its port
#   HOMELAB_ADMIN_USER / HOMELAB_ADMIN_EMAIL / HOMELAB_ADMIN_PASS  default app login
#

set -Eeuo pipefail

START_TIME=$(date +%s)

# Base for raw downloads: $REPO_BASE/<Repo>/main/<file>
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/JeffTheTroubleshooter}"
SCRIPT_REPO="Proxmox-Homelab-Automated-Setup-Script"

# State kept on the host so destroy only touches what this script made.
STATE_DIR="/root/.homelab-script"
IDS_FILE="$STATE_DIR/ids"                 # lines: "ct 200" / "vm 100"
HOST_PKGS_FILE="$STATE_DIR/host-packages" # host packages installed by older (build-on-host) versions
RUST_MARKER="$STATE_DIR/rust-installed"   # present if an older version installed rustup
BUILD_ROOT="/root/homelab-builds"         # build dir of older versions (cleanup only)
GUEST_TAG="homelab-script"
SKIP_IMMICH_ML=0
SELF=""                                   # readable path to this script (set by resolve_self)
APP_ROOT="/opt/homelab"                   # per-app compose dirs inside each CT
END_MARKER='###END proxmox.sh'

PASSWORD="admin"   # root password of every CT

# Default app login, applied wherever an app allows presetting it (see the
# login table printed at the end). At least 12 characters (FileBrowser's
# minimum), letters/digits/._@+=- only. CHANGE IT after the first login.
HOMELAB_ADMIN_USER="${HOMELAB_ADMIN_USER:-admin}"
HOMELAB_ADMIN_EMAIL="${HOMELAB_ADMIN_EMAIL:-admin@example.com}"
HOMELAB_ADMIN_PASS="${HOMELAB_ADMIN_PASS:-Homelab-Admin-2026}"

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

# ctid|hostname|cores|memory MB|disk GB|role|cpulimit
CONTAINERS=(
  "200|docker-stack|2|2048|40|docker|2"   # RAM/cores auto-sized by size_docker_ct
  "201|source-stack|4|3072|24|source|4"
  "202|light-stack|1|1024|8|light|1"
  "203|forgepanel|1|768|6|forge|1"
)

# role -> "app|Service Name|port" entries (port = the one health-checked)
declare -A ROLE_APPS=(
  [docker]="immich|Immich|2283 nextcloud|Nextcloud|8080 romm|RomM|8081 npm|NginxProxyManager|81"
  [source]="jellyfin|Jellyfin|8096 navidrome|Navidrome|4533 filebrowser|FileBrowser|8082 adguard|AdGuardHome|3000"
  [light]="vaultwarden|Vaultwarden|8000 trilium|Trilium|8083"
  [forge]="forgepanel|ForgePanel|8084"
)

# Official images (override any with e.g. JELLYFIN_IMAGE=jellyfin/jellyfin:10.11.5)
JELLYFIN_IMAGE="${JELLYFIN_IMAGE:-jellyfin/jellyfin:latest}"
NAVIDROME_IMAGE="${NAVIDROME_IMAGE:-deluan/navidrome:latest}"
FILEBROWSER_IMAGE="${FILEBROWSER_IMAGE:-filebrowser/filebrowser:latest}"
ADGUARD_IMAGE="${ADGUARD_IMAGE:-adguard/adguardhome:latest}"
VAULTWARDEN_IMAGE="${VAULTWARDEN_IMAGE:-vaultwarden/server:latest}"
TRILIUM_IMAGE="${TRILIUM_IMAGE:-triliumnext/trilium:latest}"
NEXTCLOUD_IMAGE="${NEXTCLOUD_IMAGE:-nextcloud:apache}"
ROMM_IMAGE="${ROMM_IMAGE:-rommapp/romm:latest}"
NPM_IMAGE="${NPM_IMAGE:-jc21/nginx-proxy-manager:latest}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
# Immich: its own release compose file (immich-server, machine-learning, valkey, postgres)
IMMICH_COMPOSE_URL="${IMMICH_COMPOSE_URL:-https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml}"
# ForgePanel publishes no image; it is built from its repo's own Dockerfile.
FORGEPANEL_REPO="${FORGEPANEL_REPO:-https://github.com/JeffTheTroubleshooter/ForgePanel-Dashboard.git}"

# Raw URL of this script on GitHub. Override with UPDATE_URL=... if the repo path differs.
UPDATE_URL="${UPDATE_URL:-$REPO_BASE/$SCRIPT_REPO/main/proxmox.sh}"

die()  { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok()   { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }

# ── strict mode: the first failed step stops the whole run ─────────────────
STEP="startup"     # human-readable "<app>: <step>" for error messages
step() { STEP="$*"; }
fail() {
  local msg="$1" log="${2:-}"
  echo -e "\n\033[1;31mFAILED:\033[0m \033[1m${STEP}\033[0m" >&2
  echo -e "\033[1;31m  ${msg}\033[0m" >&2
  [[ -n "$log" ]] && echo -e "\033[1;31m  Log: ${log}\033[0m" >&2
  echo -e "  Stopped here; nothing after this step ran. Fix the cause, then rerun:\n    bash $0\n  or start clean with:\n    bash $0 destroy" >&2
  exit 1
}
# shellcheck disable=SC2329  # invoked via trap
on_err() {
  local rc=$? line=${BASH_LINENO[0]} cmd=$BASH_COMMAND
  trap - ERR
  fail "Command failed (exit $rc) at line $line: $cmd"
}
trap on_err ERR
elapsed() { local e; e=$(date +%s); printf '%dm %ds' $(((e-START_TIME)/60)) $(((e-START_TIME)%60)); }

# Heartbeat: long builds/installs print "still running" every HEARTBEAT_SECS
# with the last lines of their log, so a quiet step never looks frozen.
HEARTBEAT_SECS="${HEARTBEAT_SECS:-30}"
# Hard limit per app install / host build; 0 disables it.
APP_TIMEOUT_SECS="${APP_TIMEOUT_SECS:-1800}"
# Set by heartbeat when it gave up on the job (empty when the job just exited).
HB_REASON=""
# oom_count <ctid>: kernel OOM kills charged to the CT's memory cgroup so far.
oom_count() {
  { dmesg 2>/dev/null || true; } | grep -c "oom_memcg=/lxc/${1}[,/ ]" || true
}
# stop_job <pid> [ctid] [pattern]: kill a background job, its children, and
# (when given) the matching processes still running inside the CT.
stop_job() {
  local pid="$1" ctid="${2:-}" pat="${3:-}"
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  if [[ -n "$ctid" && -n "$pat" ]]; then
    pct exec "$ctid" -- pkill -TERM -f "$pat" >/dev/null 2>&1 || true
  fi
  sleep 2
  pkill -KILL -P "$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
# heartbeat <pid> <label> [cmd...]: until <pid> exits, print elapsed time
# every HEARTBEAT_SECS plus the last 3 lines printed by cmd (e.g. tail of a log).
# HB_CTID=<ctid> also watches dmesg for an OOM kill in that CT's memcg.
# Returns 0 when the job exited by itself (caller checks its exit code with
# wait), 1 when it gave up (timeout or OOM; reason in HB_REASON). It never
# loops forever: a dead job ends it at once, a stuck one at APP_TIMEOUT_SECS.
heartbeat() {
  local pid="$1" label="$2" t0 now i ctid="${HB_CTID:-}" oom0=0
  shift 2
  HB_REASON=""
  t0=$(date +%s)
  [[ -n "$ctid" ]] && oom0=$(oom_count "$ctid")
  while kill -0 "$pid" 2>/dev/null; do
    i=0
    while (( i < HEARTBEAT_SECS )) && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    kill -0 "$pid" 2>/dev/null || break
    now=$(date +%s)
    if [[ -n "$ctid" ]] && (( $(oom_count "$ctid") > oom0 )); then
      HB_REASON="CT $ctid ran out of memory: the kernel OOM-killed a process in oom_memcg=/lxc/$ctid (see: dmesg -T | grep -i oom). Give CT $ctid more memory or reduce what it runs."
      return 1
    fi
    if (( APP_TIMEOUT_SECS > 0 && now - t0 >= APP_TIMEOUT_SECS )); then
      HB_REASON="${label} did not finish within $(( APP_TIMEOUT_SECS / 60 ))m (APP_TIMEOUT_SECS=${APP_TIMEOUT_SECS}); stopped it."
      return 1
    fi
    echo -e "\033[1;36m  ... ${label}: still running ($(( (now - t0) / 60 ))m $(( (now - t0) % 60 ))s, total $(elapsed))\033[0m" >&2
    if (( $# > 0 )); then
      { "$@" 2>/dev/null || true; } | tail -n 3 | cut -c1-160 | sed 's/^/      | /' >&2 || true
    fi
  done
  return 0
}
# run_logged <label> <logfile> <cmd...>: run cmd with its output in logfile and a
# heartbeat while it runs. HB_CTID=<ctid> adds OOM detection for that CT and
# HB_KILL=<pattern> names processes to kill inside the CT if it is stopped.
# Dead job -> its exit code; OOM or timeout -> FAILED with the log tail.
run_logged() {
  local label="$1" log="$2" rc=0 pid
  shift 2
  mkdir -p "$(dirname "$log")"
  : > "$log"
  info "$label (log: $log)"
  # background job: drop the ERR trap there so only the parent prints FAILED
  ( trap - ERR; "$@" ) >>"$log" 2>&1 &
  pid=$!
  if ! heartbeat "$pid" "$label" tail -n 3 "$log"; then
    stop_job "$pid" "${HB_CTID:-}" "${HB_KILL:-}"
    echo "----- last 40 lines of $log -----" >&2
    tail -n 40 "$log" >&2 || true
    fail "$HB_REASON" "$log"
  fi
  wait "$pid" || rc=$?
  if (( rc != 0 )); then
    echo "----- last 40 lines of $log -----" >&2
    tail -n 40 "$log" >&2 || true
    if [[ -n "${HB_CTID:-}" ]] && (( $(oom_count "$HB_CTID") > 0 )); then
      warn "dmesg shows OOM kills in oom_memcg=/lxc/$HB_CTID (dmesg -T | grep -i oom)."
    fi
  fi
  return "$rc"
}

# Find a readable copy of this script (needed so prompts work under curl | bash).
resolve_self() {
  if [[ -f "$0" && -r "$0" ]] && grep -qxF "$END_MARKER" "$0" 2>/dev/null; then
    SELF="$0"
    return 0
  fi
  local tmp="/tmp/homelab-proxmox.sh"
  # bash <(curl ...): $0 is /dev/fd/NN. Try to save what is left of it.
  if [[ "$0" == /dev/fd/* || "$0" == /proc/self/fd/* ]] && [[ -r "$0" ]]; then
    cat "$0" > "$tmp" 2>/dev/null || true
    if grep -qxF "$END_MARKER" "$tmp" 2>/dev/null && head -1 "$tmp" | grep -q '^#!'; then
      SELF="$tmp"
      return 0
    fi
  fi
  if [[ "${HOMELAB_REEXEC:-0}" == "1" ]]; then
    die "Could not find a readable copy of this script. Download proxmox.sh and run: bash proxmox.sh"
  fi
  info "Running from a pipe — downloading a full copy of proxmox.sh to $tmp ..."
  if ! curl -fsSL -o "$tmp" "$UPDATE_URL" || ! grep -qxF "$END_MARKER" "$tmp"; then
    die "Could not download $UPDATE_URL (offline or GitHub unreachable?). Download proxmox.sh and run: bash proxmox.sh"
  fi
  chmod +x "$tmp"
  export HOMELAB_REEXEC=1 HOMELAB_PIPED=1
  if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
    exec bash "$tmp" "$@" </dev/tty
  fi
  exec bash "$tmp" "$@"
}

record_id() {
  local type="$1" id="$2"
  mkdir -p "$STATE_DIR"
  touch "$IDS_FILE"
  grep -qx "$type $id" "$IDS_FILE" || echo "$type $id" >> "$IDS_FILE"
}

# True if guest <type> <id> exists and carries the homelab-script tag.
has_tag() {
  local type="$1" id="$2" cfg
  if [[ "$type" == "ct" ]]; then
    cfg=$(pct config "$id" 2>/dev/null) || return 1
  else
    cfg=$(qm config "$id" 2>/dev/null) || return 1
  fi
  grep -E '^tags:' <<< "$cfg" | grep -qE "(^tags:|[ ;,])${GUEST_TAG}([ ;,]|\$)"
}

# Size the Docker CT from host RAM/CPU. Sets DOCKER_MEM / DOCKER_CORES / SKIP_IMMICH_ML.
DOCKER_MEM=2048
DOCKER_CORES=2
DOCKER_SWAP=2048
DOCKER_DISK=40
size_docker_ct() {
  local total_mb cpus mem cores ans
  total_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  [[ "$total_mb" =~ ^[0-9]+$ && "$total_mb" -gt 0 ]] || total_mb=$(free -m | awk '/^Mem:/ {print $2}')
  cpus=$(nproc 2>/dev/null || echo 2)
  # memory = clamp(total/3, 2048, 6144), rounded to the nearest 256 MB
  mem=$(( (total_mb / 3 + 128) / 256 * 256 ))
  (( mem < 2048 )) && mem=2048
  (( mem > 6144 )) && mem=6144
  # cores = min(4, nproc/2), at least 2
  cores=$(( cpus / 2 ))
  (( cores > 4 )) && cores=4
  (( cores < 2 )) && cores=2
  DOCKER_MEM="$mem"
  DOCKER_CORES="$cores"
  info "Host: ${total_mb} MB RAM, ${cpus} CPUs -> docker-stack: ${DOCKER_MEM} MB RAM, ${DOCKER_SWAP} MB swap, ${DOCKER_CORES} cores, ${DOCKER_DISK}G disk"
  if (( total_mb < 8192 )); then
    warn "This host has less than 8 GB RAM (${total_mb} MB). Immich/Nextcloud may run out of memory."
    read -rp "Continue anyway? [y/N]: " ans
    [[ "${ans,,}" == y* ]] || die "Stopped. Add RAM or remove services, then re-run."
  fi
  if (( total_mb < 16384 )); then
    read -rp "Host has under 16 GB RAM. Skip the Immich machine-learning container (face/smart search)? [Y/n]: " ans
    ans="${ans:-y}"
    if [[ "${ans,,}" == y* ]]; then
      SKIP_IMMICH_ML=1
      info "Immich machine-learning will be disabled."
    fi
  fi
}

check_host() {
  command -v pct >/dev/null 2>&1 || die "pct not found. Run this on a Proxmox host."
  [[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
  command -v openssl >/dev/null 2>&1 || die "openssl not found on the host (needed to generate app passwords)."
  ok "Proxmox host detected."
}

# Newest Debian standard template: 13 (trixie) preferred, 12 as fallback.
ensure_template() {
  pveam update >/dev/null || true
  local name="" want
  for want in 13 12; do
    name=$(pveam available 2>/dev/null | awk -v t="^debian-${want}-standard" '$2 ~ t && /amd64/ {print $2}' | sort -V | tail -1)
    [[ -n "$name" ]] && break
  done
  [[ -n "$name" ]] || die "No Debian 13 or 12 template found. Run 'pveam available'."
  TEMPLATE="local:vztmpl/$name"
  if ! pveam list local 2>/dev/null | grep -q "$name"; then
    info "Downloading $name ..."
    pveam download local "$name" || die "Failed to download $name"
  fi
  ok "Template ready: $name"
}

# Every CT runs Docker. Docker inside an unprivileged CT falls back to slow
# fuse-overlayfs/vfs, so the CTs are privileged with nesting=1,keyctl=1 and
# Docker uses overlay2.
create_ct() {
  local ctid="$1" hostname="$2" cores="$3" memory="$4" disk="$5" cpulimit="$6" swap="${7:-512}"
  if pct status "$ctid" >/dev/null 2>&1; then
    if pct config "$ctid" 2>/dev/null | grep -q '^unprivileged: 1'; then
      fail "CT $ctid ($hostname) is an unprivileged CT from an older version of this script (native installs). Remove it first: bash $0 destroy (or: pct stop $ctid; pct destroy $ctid --purge), then rerun."
    fi
    warn "CT $ctid already exists — updating limits."
    pct set "$ctid" --cores "$cores" --memory "$memory" --swap "$swap" --cpulimit "$cpulimit" || true
    return 0
  fi
  info "Creating CT $ctid ($hostname) — ${cores} cores, ${memory}MB RAM, ${disk}G disk, Docker-ready"
  pct create "$ctid" "$TEMPLATE" \
    --hostname "$hostname" \
    --cores "$cores" \
    --memory "$memory" \
    --swap "$swap" \
    --cpulimit "$cpulimit" \
    --cpuunits 1024 \
    --rootfs "${STORAGE}:${disk}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --password "$PASSWORD" \
    --unprivileged 0 \
    --features "nesting=1,keyctl=1" \
    --onboot 1 \
    --tags "$GUEST_TAG"
  record_id ct "$ctid"
  ok "CT $ctid created."
}

container_ip() {
  local ctid="$1" ip=""
  for _ in $(seq 1 15); do
    ip=$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
    [[ -n "$ip" ]] && break
    sleep 2
  done
  printf '%s' "$ip"
}

LOG_DIR="/var/log/homelab-script"

# Start the CT and install Docker CE + compose plugin (official Docker apt repo).
setup_docker() {
  local ctid="$1"
  step "CT $ctid: start"
  if [[ "$(pct status "$ctid" 2>/dev/null)" != "status: running" ]]; then
    pct start "$ctid" || fail "pct start $ctid failed."
  fi
  [[ -n "$(container_ip "$ctid")" ]] || fail "CT $ctid has no IP address (DHCP on $BRIDGE?)."
  step "CT $ctid: install Docker"
  if pct exec "$ctid" -- sh -c 'docker compose version >/dev/null 2>&1 && systemctl is-active -q docker'; then
    ok "Docker already running in CT $ctid"
    return 0
  fi
  HB_CTID="$ctid" HB_KILL="apt-get" run_logged "CT $ctid: installing Docker" "$LOG_DIR/ct${ctid}-docker.log" \
    pct exec "$ctid" -- bash -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y ca-certificates curl git
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      mkdir -p /etc/docker
      printf "%s\n" "{\"storage-driver\":\"overlay2\",\"max-concurrent-downloads\":3,\"log-driver\":\"local\"}" > /etc/docker/daemon.json
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      systemctl enable docker
      systemctl restart docker
    ' || fail "Docker install failed in CT $ctid." "$LOG_DIR/ct${ctid}-docker.log"
  local driver
  driver=$(pct exec "$ctid" -- docker info -f '{{.Driver}}' 2>/dev/null || true)
  [[ "$driver" == "overlay2" ]] || fail "Docker in CT $ctid is not using overlay2 (got: '${driver:-docker not running}'). Check: pct exec $ctid -- journalctl -u docker -n 50"
  ok "Docker ready in CT $ctid (storage driver: overlay2)"
}

# ── per-app compose files ──────────────────────────────────────────────────
# compose_<app> prints docker-compose.yml. Values like ${DB_PASSWORD} come from
# the app's .env (written once by env_<app>, kept on reruns).
compose_jellyfin() { cat <<YML
services:
  jellyfin:
    image: ${JELLYFIN_IMAGE}
    container_name: jellyfin
    restart: always
    ports:
      - "8096:8096"
      - "7359:7359/udp"
    volumes:
      - ./config:/config
      - ./cache:/cache
      - /srv/media:/media
YML
}
compose_navidrome() { cat <<YML
services:
  navidrome:
    image: ${NAVIDROME_IMAGE}
    container_name: navidrome
    restart: always
    ports:
      - "4533:4533"
    volumes:
      - ./data:/data
      - /mnt/music:/music:ro
YML
}
compose_filebrowser() { cat <<YML
services:
  filebrowser:
    image: ${FILEBROWSER_IMAGE}
    container_name: filebrowser
    restart: always
    user: "0:0"
    ports:
      - "8082:80"
    volumes:
      - /srv/files:/srv
      - ./database:/database
      - ./config:/config
YML
}
compose_adguard() { cat <<YML
services:
  adguardhome:
    image: ${ADGUARD_IMAGE}
    container_name: adguardhome
    restart: always
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:3000/tcp"
    volumes:
      - ./work:/opt/adguardhome/work
      - ./conf:/opt/adguardhome/conf
YML
}
# HTTPS (self-signed cert in ./ssl): the web vault needs a secure context.
compose_vaultwarden() { cat <<YML
services:
  vaultwarden:
    image: ${VAULTWARDEN_IMAGE}
    container_name: vaultwarden
    restart: always
    environment:
      - ROCKET_TLS={certs="/ssl/cert.pem",key="/ssl/key.pem"}
      - ADMIN_TOKEN=${HOMELAB_ADMIN_PASS}
    ports:
      - "8000:80"
    volumes:
      - ./data:/data
      - ./ssl:/ssl:ro
YML
}
compose_trilium() { cat <<YML
services:
  trilium:
    image: ${TRILIUM_IMAGE}
    container_name: trilium
    restart: always
    ports:
      - "8083:8080"
    volumes:
      - ./data:/home/node/trilium-data
YML
}
compose_npm() { cat <<YML
services:
  app:
    image: ${NPM_IMAGE}
    container_name: nginx-proxy-manager
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      - INITIAL_ADMIN_EMAIL=${HOMELAB_ADMIN_EMAIL}
      - INITIAL_ADMIN_PASSWORD=${HOMELAB_ADMIN_PASS}
YML
}
compose_nextcloud() { cat <<YML
services:
  db:
    image: ${MARIADB_IMAGE}
    restart: always
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW
    volumes:
      - ./db:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
  redis:
    image: ${REDIS_IMAGE}
    restart: always
  app:
    image: ${NEXTCLOUD_IMAGE}
    restart: always
    ports:
      - "8080:80"
    depends_on:
      - db
      - redis
    volumes:
      - ./html:/var/www/html
    environment:
      - MYSQL_HOST=db
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - REDIS_HOST=redis
      - NEXTCLOUD_ADMIN_USER=\${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=\${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=\${NEXTCLOUD_TRUSTED_DOMAINS}
  cron:
    image: ${NEXTCLOUD_IMAGE}
    restart: always
    entrypoint: /cron.sh
    depends_on:
      - db
      - redis
    volumes:
      - ./html:/var/www/html
YML
}
compose_romm() { cat <<YML
services:
  romm:
    image: ${ROMM_IMAGE}
    container_name: romm
    restart: always
    environment:
      - DB_HOST=romm-db
      - DB_NAME=romm
      - DB_USER=romm-user
      - DB_PASSWD=\${DB_PASSWORD}
      - ROMM_AUTH_SECRET_KEY=\${AUTH_SECRET}
      - IGDB_CLIENT_ID=\${IGDB_CLIENT_ID:-}
      - IGDB_CLIENT_SECRET=\${IGDB_CLIENT_SECRET:-}
      - HASHEOUS_API_ENABLED=true
    volumes:
      - ./resources:/romm/resources
      - ./redis-data:/redis-data
      - ./library:/romm/library
      - ./assets:/romm/assets
      - ./config:/romm/config
    ports:
      - "8081:8080"
    depends_on:
      romm-db:
        condition: service_healthy
  romm-db:
    image: ${MARIADB_IMAGE}
    container_name: romm-db
    restart: always
    environment:
      - MARIADB_ROOT_PASSWORD=\${DB_PASSWORD}
      - MARIADB_DATABASE=romm
      - MARIADB_USER=romm-user
      - MARIADB_PASSWORD=\${DB_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      interval: 10s
      timeout: 5s
      retries: 10
YML
}
compose_forgepanel() { cat <<YML
services:
  forgepanel:
    build: ./src
    image: forgepanel:local
    container_name: forgepanel
    restart: always
    command: ["--https"]
    # Host networking: the scanner must see the LAN (10.0.0.x), not Docker's 172.x bridge,
    # or Scan Network finds 0 services. Serves on the CT's own IP at :8084.
    network_mode: host
    environment:
      FORGEPANEL_SCAN_SUBNET: "\${FORGEPANEL_SCAN_SUBNET:-auto}"
    volumes:
      - forgepanel-data:/app/database
      - forgepanel-custom:/app/custom_services
volumes:
  forgepanel-data:
  forgepanel-custom:
YML
}
# Immich: overrides on top of its release compose file.
compose_immich_override() {
  if [[ "$SKIP_IMMICH_ML" == "1" ]]; then
    printf 'services:\n  immich-machine-learning:\n    profiles: ["disabled"]\n'
  else
    printf 'services: {}\n'
  fi
}

rand_secret() { openssl rand -hex 16; }

# Self-signed cert for Vaultwarden (made on the host, pushed into the CT, kept on reruns).
vaultwarden_cert() {
  local ctid="$1" ip="$2" d="$APP_ROOT/vaultwarden/ssl" tmp
  ct_has_file "$ctid" "$d/cert.pem" && ct_has_file "$ctid" "$d/key.pem" && return 0
  tmp=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -subj "/CN=vaultwarden" -addext "subjectAltName=IP:${ip},DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "openssl could not create the Vaultwarden certificate."; }
  pct exec "$ctid" -- mkdir -p "$d"
  pct push "$ctid" "$tmp/cert.pem" "$d/cert.pem" --perms 644
  pct push "$ctid" "$tmp/key.pem" "$d/key.pem" --perms 644
  rm -rf "$tmp"
  info "Vaultwarden: self-signed HTTPS certificate created."
}

# env_<app> <ip>: prints the first-run .env (secrets generated here, never shown).
env_nextcloud() {
  printf 'MYSQL_ROOT_PASSWORD=%s\nMYSQL_PASSWORD=%s\nNEXTCLOUD_ADMIN_USER=%s\nNEXTCLOUD_ADMIN_PASSWORD=%s\nNEXTCLOUD_TRUSTED_DOMAINS=%s localhost\n' \
    "$(rand_secret)" "$(rand_secret)" "$HOMELAB_ADMIN_USER" "$HOMELAB_ADMIN_PASS" "$1"
}
env_romm() { printf 'DB_PASSWORD=%s\nAUTH_SECRET=%s\nIGDB_CLIENT_ID=\nIGDB_CLIENT_SECRET=\n' "$(rand_secret)" "$(openssl rand -hex 32)"; }

# Push stdin to <ctid>:<path> with <mode>.
push_file() {
  local ctid="$1" path="$2" mode="$3" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  pct push "$ctid" "$tmp" "$path" --perms "$mode"
  rm -f "$tmp"
}
ct_has_file() { pct exec "$1" -- test -s "$2" 2>/dev/null; }

# Write an app's files into CT, pull/build and start it, then make sure
# none of its containers exited or is crash-looping.
install_app() {
  local ctid="$1" app="$2" svc="$3" ip="$4"
  local dir="$APP_ROOT/$app" log="$LOG_DIR/ct${ctid}-${app}.log"
  step "$svc in CT $ctid: write compose files"
  pct exec "$ctid" -- mkdir -p "$dir"
  case "$app" in
    immich)
      pct exec "$ctid" -- bash -c "cd $dir && curl -fsSL --retry 3 -o docker-compose.yml '$IMMICH_COMPOSE_URL'" \
        || fail "Could not download Immich's docker-compose.yml ($IMMICH_COMPOSE_URL)."
      if ! ct_has_file "$ctid" "$dir/.env"; then
        local env
        env=$(curl -fsSL --retry 3 "${IMMICH_COMPOSE_URL%/*}/example.env") || fail "Could not download Immich's example.env."
        sed -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$(rand_secret)|" <<< "$env" | push_file "$ctid" "$dir/.env" 600
      fi
      compose_immich_override | push_file "$ctid" "$dir/docker-compose.override.yml" 644
      ;;
    vaultwarden)
      vaultwarden_cert "$ctid" "$ip"
      compose_vaultwarden | push_file "$ctid" "$dir/docker-compose.yml" 644
      ;;
    forgepanel)
      pct exec "$ctid" -- bash -c "if [ -d $dir/src/.git ]; then git -C $dir/src pull --ff-only; else rm -rf $dir/src && git clone --depth 1 '$FORGEPANEL_REPO' $dir/src; fi" \
        || fail "Could not clone/update $FORGEPANEL_REPO in CT $ctid."
      compose_forgepanel | push_file "$ctid" "$dir/docker-compose.yml" 644
      ;;
    *)
      "compose_$app" | push_file "$ctid" "$dir/docker-compose.yml" 644
      if declare -F "env_$app" >/dev/null && ! ct_has_file "$ctid" "$dir/.env"; then
        "env_$app" "$ip" | push_file "$ctid" "$dir/.env" 600
      fi
      ;;
  esac
  case "$app" in
    jellyfin) pct exec "$ctid" -- mkdir -p /srv/media ;;
    navidrome) pct exec "$ctid" -- mkdir -p /mnt/music ;;
    filebrowser) pct exec "$ctid" -- mkdir -p /srv/files ;;
  esac

  step "$svc in CT $ctid: pull + start"
  # Retry pulls: registries (ghcr.io, Docker Hub) can answer "toomanyrequests" for a short while.
  local fetch="for i in 1 2 3 4 5; do docker compose --progress plain pull && break; [ \$i = 5 ] && exit 1; echo \"pull failed (attempt \$i/5), retrying in \$((i*30))s...\"; sleep \$((i*30)); done"
  [[ "$app" == "forgepanel" ]] && fetch="docker compose --progress plain build --pull"
  HB_CTID="$ctid" HB_KILL="docker compose" run_logged "$svc: pull (with retry) && up -d in CT $ctid" "$log" \
    pct exec "$ctid" -- bash -c "cd $dir && docker compose config -q && $fetch && docker compose up -d --remove-orphans" \
    || fail "$svc did not start (docker compose failed in CT $ctid:$dir)." "$log"

  step "$svc in CT $ctid: containers running"
  sleep 10
  local states bad
  states=$(pct exec "$ctid" -- bash -c "cd $dir && docker compose ps -a --format '{{.Service}} {{.State}}'" 2>/dev/null || true)
  bad=$(awk '$2 ~ /^(exited|dead|restarting)$/' <<< "$states")
  if [[ -n "$bad" ]]; then
    echo "----- docker compose logs (CT $ctid:$dir) -----" >&2
    pct exec "$ctid" -- bash -c "cd $dir && docker compose logs --tail 30 --no-color" >&2 2>/dev/null || true
    local oom=""
    pct exec "$ctid" -- bash -c "docker inspect -f '{{.State.OOMKilled}}' \$(cd $dir && docker compose ps -aq) 2>/dev/null" | grep -q true && oom=" (OOM-killed: give CT $ctid more memory)"
    fail "$svc container(s) not running${oom}: $(tr '\n' ' ' <<< "$bad")"
  fi
  ok "$svc running in CT $ctid"
}

install_role() {
  local ctid="$1" role="$2" ip item app svc port
  ip=$(container_ip "$ctid")
  [[ -n "$ip" ]] || { step "CT $ctid: network"; fail "CT $ctid has no IP address (DHCP on $BRIDGE?)."; }
  for item in ${ROLE_APPS[$role]}; do
    IFS='|' read -r app svc port <<< "$item"
    install_app "$ctid" "$app" "$svc" "$ip"
  done
  ok "Apps running in CT $ctid ($ip)"
}

# URL scheme a service answers on (ForgePanel is HTTPS with a self-signed cert).
svc_scheme() { [[ "$1" == "ForgePanel" || "$1" == "Vaultwarden" ]] && echo https || echo http; }

# ── default logins ─────────────────────────────────────────────────────────
check_login_config() {
  [[ "$HOMELAB_ADMIN_PASS" =~ ^[A-Za-z0-9._@+=-]{12,}$ ]] \
    || die "HOMELAB_ADMIN_PASS must be 12+ characters of letters, digits or ._@+=- (FileBrowser needs 12)."
  [[ "$HOMELAB_ADMIN_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "HOMELAB_ADMIN_USER may only use letters, digits and ._-"
  [[ "$HOMELAB_ADMIN_EMAIL" =~ ^[^[:space:]\'\"]+@[^[:space:]\'\"]+$ ]] || die "HOMELAB_ADMIN_EMAIL is not an email address."
}

# Run a command inside an app's compose dir in the CT.
ct_compose() { local ctid="$1" app="$2"; shift 2; pct exec "$ctid" -- bash -c "cd $APP_ROOT/$app && $*"; }
app_ct() {  # app -> ctid|ip of the CT running it ('' if none)
  local entry ctid role item
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r ctid _ _ _ _ role _ <<< "$entry"
    for item in ${ROLE_APPS[$role]}; do
      [[ "${item%%|*}" == "$1" ]] && pct status "$ctid" >/dev/null 2>&1 && { printf '%s|%s' "$ctid" "$(container_ip "$ctid")"; return 0; }
    done
  done
}

# FileBrowser: set (or create) the admin user. Works on new and existing installs.
login_filebrowser() {
  local ctid="$1" u="$HOMELAB_ADMIN_USER" p="$HOMELAB_ADMIN_PASS"
  step "FileBrowser in CT $ctid: set default login"
  ct_compose "$ctid" filebrowser "docker compose stop filebrowser >/dev/null 2>&1
    docker compose run --rm --no-deps -T filebrowser users update '$u' --password '$p' --perm.admin >/dev/null 2>&1 \
      || docker compose run --rm --no-deps -T filebrowser users add '$u' '$p' --perm.admin >/dev/null 2>&1
    rc=\$?; docker compose start filebrowser >/dev/null 2>&1; exit \$rc" \
    || { warn "Could not set the FileBrowser login (CT $ctid: cd $APP_ROOT/filebrowser && docker compose logs filebrowser)."; return 0; }
  ok "FileBrowser login: $u"
}

# Nextcloud: wait for the install to finish, then reset (or add) the admin.
login_nextcloud() {
  local ctid="$1" u="$HOMELAB_ADMIN_USER" i
  step "Nextcloud in CT $ctid: set default login"
  for i in $(seq 1 60); do
    ct_compose "$ctid" nextcloud "docker compose exec -T -u www-data app php occ status --output=json 2>/dev/null" \
      | grep -q '"installed":true' && break
    (( i == 60 )) && { warn "Nextcloud did not finish installing within 5 minutes (CT $ctid: cd $APP_ROOT/nextcloud && docker compose logs app)."; return 0; }
    (( i % 6 == 0 )) && info "  waiting for Nextcloud to finish installing ($((i * 5))s)"
    sleep 5
  done
  ct_compose "$ctid" nextcloud "export OC_PASS='$HOMELAB_ADMIN_PASS'
    if docker compose exec -T -u www-data app php occ user:info '$u' >/dev/null 2>&1; then
      docker compose exec -T -u www-data -e OC_PASS app php occ user:resetpassword --password-from-env '$u'
    else
      docker compose exec -T -u www-data -e OC_PASS app php occ user:add --password-from-env --group admin '$u'
    fi >/dev/null" \
    || { warn "Could not set the Nextcloud login (occ user:resetpassword failed in CT $ctid)."; return 0; }
  ok "Nextcloud login: $u"
}

# Apps with a first-run API: create the admin if none exists yet (best effort).
login_firstrun() {
  local app="$1" ip="$2" u="$HOMELAB_ADMIN_USER" p="$HOMELAB_ADMIN_PASS" e="$HOMELAB_ADMIN_EMAIL" code
  case "$app" in
    immich)
      code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -H 'Content-Type: application/json' \
        -d "{\"email\":\"$e\",\"password\":\"$p\",\"name\":\"$u\"}" "http://$ip:2283/api/auth/admin-sign-up" || true)
      case "$code" in 2*) ok "Immich admin created: $e" ;;
        *) warn "Immich already has an admin (HTTP $code); kept it. Reset with: docker exec -it immich_server immich-admin reset-admin-password" ;; esac
      ;;
    navidrome)
      code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -H 'Content-Type: application/json' \
        -d "{\"username\":\"$u\",\"password\":\"$p\"}" "http://$ip:4533/auth/createAdmin" || true)
      case "$code" in 2*) ok "Navidrome admin created: $u" ;; *) warn "Navidrome already has an admin (HTTP $code); kept it." ;; esac
      ;;
    jellyfin)
      local b="http://$ip:8096" j='Content-Type: application/json'
      if curl -fs -m 10 "$b/Startup/Configuration" >/dev/null 2>&1; then
        curl -fs -m 20 -H "$j" -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' "$b/Startup/Configuration" >/dev/null 2>&1 || true
        curl -fs -m 20 "$b/Startup/User" >/dev/null 2>&1 || true
        if curl -fs -m 20 -H "$j" -d "{\"Name\":\"$u\",\"Password\":\"$p\"}" "$b/Startup/User" >/dev/null 2>&1 \
           && curl -fs -m 20 -H "$j" -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' "$b/Startup/RemoteAccess" >/dev/null 2>&1 \
           && curl -fs -m 20 -X POST "$b/Startup/Complete" >/dev/null 2>&1; then
          ok "Jellyfin setup wizard completed, admin: $u"
        else
          warn "Could not finish Jellyfin's setup wizard automatically; open Jellyfin and create the admin there."
        fi
      else
        warn "Jellyfin setup wizard was already completed; kept its admin."
      fi
      ;;
  esac
}

apply_logins() {
  local app cp ctid ip
  info "Applying default logins..."
  for app in filebrowser nextcloud immich navidrome jellyfin; do
    cp=$(app_ct "$app"); [[ -n "$cp" ]] || continue
    IFS='|' read -r ctid ip <<< "$cp"
    case "$app" in
      filebrowser) login_filebrowser "$ctid" ;;
      nextcloud)   login_nextcloud "$ctid" ;;
      *)           login_firstrun "$app" "$ip" ;;
    esac
  done
}

# Fix logins on an existing install without destroying anything:
# FileBrowser + Nextcloud passwords reset, Vaultwarden redeployed with HTTPS.
reset_logins() {
  echo "Resetting default logins (and Vaultwarden HTTPS) in existing containers"
  echo "======================================================================="
  check_host
  local cp ctid ip
  cp=$(app_ct vaultwarden)
  if [[ -n "$cp" ]]; then
    IFS='|' read -r ctid ip <<< "$cp"
    pct start "$ctid" >/dev/null 2>&1 || true
    install_app "$ctid" vaultwarden Vaultwarden "$ip"
  fi
  cp=$(app_ct npm)
  if [[ -n "$cp" ]]; then
    IFS='|' read -r ctid ip <<< "$cp"
    install_app "$ctid" npm NginxProxyManager "$ip"
  fi
  apply_logins
  health_checks
  print_logins
}

print_logins() {
  local u="$HOMELAB_ADMIN_USER" p="$HOMELAB_ADMIN_PASS" e="$HOMELAB_ADMIN_EMAIL" cp ip app svc port fmt='  %-20s %-30s %-20s %s\n'
  echo
  echo "Default logins (CHANGE THESE after the first login):"
  # shellcheck disable=SC2059
  printf "$fmt" APP URL USER PASSWORD
  for item in "immich|Immich|2283|$e|$p" "nextcloud|Nextcloud|8080|$u|$p" "romm|RomM|8081|(create in setup wizard)|" \
              "npm|NginxProxyManager|81|$e|$p" "jellyfin|Jellyfin|8096|$u|$p" "navidrome|Navidrome|4533|$u|$p" \
              "filebrowser|FileBrowser|8082|$u|$p" "adguard|AdGuardHome|3000|(create in setup wizard)|" \
              "vaultwarden|Vaultwarden|8000|(create an account)|admin page /admin token: $p" \
              "trilium|Trilium|8083|(set password on first open)|" "forgepanel|ForgePanel|8084|admin|forgepanel"; do
    IFS='|' read -r app svc port user pass <<< "$item"
    cp=$(app_ct "$app"); ip="${cp#*|}"
    # shellcheck disable=SC2059
    printf "$fmt" "$svc" "$(svc_scheme "$svc")://${ip:-?}:$port" "$user" "$pass"
  done
  echo "  (NPM: on installs made before this version the login is admin@example.com / changeme.)"
}

# After the final start, every service must answer on its port. A 404 on "/"
# counts as broken.
health_checks() {
  info "Health checks: every service must answer on its port..."
  local entry ctid hostname role ip item app svc port url code t0 deadline
  local timeout="${HEALTH_TIMEOUT:-300}"
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r ctid hostname _ _ _ role _ <<< "$entry"
    ip=$(container_ip "$ctid")
    for item in ${ROLE_APPS[$role]}; do
      IFS='|' read -r app svc port <<< "$item"
      step "$svc in CT $ctid: health check"
      [[ -n "$ip" ]] || fail "CT $ctid ($hostname) has no IP address, so $svc cannot be reached."
      url="$(svc_scheme "$svc")://$ip:$port/"
      t0=$(date +%s); deadline=$((t0 + timeout)); code=000
      while :; do
        code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "$url" 2>/dev/null) || true
        [[ "$code" =~ ^[23][0-9][0-9]$|^401$ ]] && break
        (( $(date +%s) >= deadline )) && break
        sleep 5
        (( ( $(date +%s) - t0 ) % 30 < 5 )) && info "  waiting for $svc at $url (HTTP ${code:-000}, $(( $(date +%s) - t0 ))s)"
      done
      if [[ ! "$code" =~ ^[23][0-9][0-9]$|^401$ ]]; then
        pct exec "$ctid" -- bash -c "cd $APP_ROOT/$app && docker compose ps -a && docker compose logs --tail 30 --no-color" >&2 2>/dev/null || true
        fail "$svc is not answering at $url (HTTP ${code:-000} after ${timeout}s). Check: pct exec $ctid -- bash -c 'cd $APP_ROOT/$app && docker compose logs --tail 100'"
      fi
      ok "  $svc OK  $url (HTTP $code)"
    done
  done
}

print_summary() {
  echo
  echo "========================================"
  echo "  Homelab ready"
  echo "========================================"
  echo
  local entry ctid hostname role ip item app svc port forge_ip=""
  declare -A CT_IP
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r ctid hostname _ _ _ role _ <<< "$entry"
    ip=$(container_ip "$ctid")
    CT_IP[$ctid]="$ip"
    [[ "$role" == "forge" ]] && forge_ip="$ip"
  done
  if [[ -n "$forge_ip" ]]; then
    echo "Open ForgePanel to see every service in one place:"
    echo "  ForgePanel:  https://${forge_ip}:8084  (self-signed cert: browser warns once; login admin / forgepanel, change it)"
    echo
  fi
  echo "Services by container:"
  echo
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r ctid hostname _ _ _ role _ <<< "$entry"
    ip="${CT_IP[$ctid]:-}"
    echo "  $hostname (CT $ctid)  ${ip:-no-ip}"
    for item in ${ROLE_APPS[$role]}; do
      IFS='|' read -r app svc port <<< "$item"
      if [[ -n "$ip" ]]; then
        printf '    %-22s %s://%s:%s\n' "$svc" "$(svc_scheme "$svc")" "$ip" "$port"
      else
        printf '    %-22s (container has no IP)\n' "$svc"
      fi
    done
    echo
  done
  echo "Each app: $APP_ROOT/<app>/ inside its CT (docker-compose.yml, .env, data)."
  print_logins
  echo "  AdGuard Home: in the wizard keep the admin web port at 3000."
  echo "  Database passwords are generated and stored in $APP_ROOT/<app>/.env (mode 600)."
  echo "Logs of this run: $LOG_DIR/"
  echo
  echo "Default root password for every container: $PASSWORD"
  echo "CHANGE THIS PASSWORD on each container once the script is done:"
  echo "  pct enter <ctid>"
  echo "  passwd"
  echo
  ok "Done in $(elapsed)"
}

self_update() {
  local force="${1:-}"
  if [[ "${HOMELAB_PIPED:-0}" == "1" ]]; then
    ok "Running a fresh copy downloaded from GitHub — no self-update needed."
    return 0
  fi
  if [[ "$SELF" != "$0" ]]; then
    info "Script was not run from a saved file — skipping self-update (it runs the GitHub copy already)."
    return 0
  fi
  info "Checking GitHub for a newer script..."
  local tmp
  tmp=$(mktemp)
  if ! curl -fsSL -o "$tmp" "$UPDATE_URL" 2>/dev/null; then
    warn "Could not reach GitHub. Continuing with the current script."
    rm -f "$tmp"
    return 0
  fi
  if cmp -s "$tmp" "$SELF"; then
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
    cp "$SELF" "${SELF}.bak"
    cp "$tmp" "$SELF"
    chmod +x "$SELF"
    rm -f "$tmp"
    ok "Updated. Backup saved as ${SELF}.bak"
    ok "Re-run the script to use the new version."
    exit 0
  fi
  rm -f "$tmp"
  info "Skipped update. Continuing with the current script."
}

service_update() {
  echo "Updating apps in existing containers (pull newer images, recreate)"
  echo "=================================================================="
  check_host
  local entry ctid hostname role
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r ctid hostname _ _ _ role _ <<< "$entry"
    if ! pct status "$ctid" >/dev/null 2>&1; then
      warn "CT $ctid ($hostname) not found — skipping."
      continue
    fi
    setup_docker "$ctid"
    install_role "$ctid" "$role"
  done
  health_checks
  apply_logins
  print_summary
}

destroy_guest() {
  local type="$1" id="$2"
  if [[ "$type" == "ct" ]]; then
    pct unlock "$id" 2>/dev/null || true
    info "Removing CT $id (and its app data)..."
    pct stop "$id" 2>/dev/null || true
    pct destroy "$id" --purge || { warn "Could not destroy CT $id"; return 1; }
    ok "CT $id removed."
  else
    info "Removing VM $id..."
    qm stop "$id" 2>/dev/null || true
    qm destroy "$id" --purge || { warn "Could not destroy VM $id"; return 1; }
    ok "VM $id removed."
  fi
}

destroy_all() {
  echo "Destroying homelab guests created by this script"
  echo "================================================"
  check_host
  local type id ans
  local -a targets=() keep=()

  if [[ -f "$IDS_FILE" ]]; then
    while read -r type id; do
      [[ "$type" =~ ^(ct|vm)$ && "$id" =~ ^[0-9]+$ ]] || continue
      if has_tag "$type" "$id"; then
        targets+=("$type $id")
      else
        warn "$type $id is listed in $IDS_FILE but is missing or not tagged '$GUEST_TAG' — leaving it alone."
      fi
    done < "$IDS_FILE"
  else
    warn "$IDS_FILE not found. Looking for guests tagged '$GUEST_TAG'..."
    for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
      if has_tag ct "$id"; then
        read -rp "Destroy CT $id ($(pct config "$id" | awk '/^hostname:/ {print $2}'))? [y/N]: " ans
        [[ "${ans,,}" == y* ]] && targets+=("ct $id")
      fi
    done
  fi

  (( ${#targets[@]} == 0 )) && info "No guests to remove."
  local t
  for t in "${targets[@]}"; do
    read -r type id <<< "$t"
    destroy_guest "$type" "$id" || keep+=("$t")
  done

  # rewrite the IDs file with whatever is still there
  if [[ -f "$IDS_FILE" ]]; then
    local tmp
    tmp=$(mktemp)
    while read -r type id; do
      if [[ "$type" == "ct" ]] && pct status "$id" >/dev/null 2>&1; then echo "$type $id"
      elif [[ "$type" == "vm" ]] && qm status "$id" >/dev/null 2>&1; then echo "$type $id"
      fi
    done < "$IDS_FILE" > "$tmp"
    if [[ -s "$tmp" ]]; then mv "$tmp" "$IDS_FILE"; else rm -f "$tmp" "$IDS_FILE"; fi
  fi

  # leftovers from older versions of this script (SSH key, host build tools)
  if [[ -f /root/.ssh/homelab_key ]]; then
    rm -f /root/.ssh/homelab_key /root/.ssh/homelab_key.pub
    ok "Removed old host SSH key."
  fi
  if [[ -s "$HOST_PKGS_FILE" || -f "$RUST_MARKER" ]]; then
    echo "An older version of this script installed these host build packages:"
    [[ -s "$HOST_PKGS_FILE" ]] && tr '\n' ' ' < "$HOST_PKGS_FILE" | fold -s -w 76 | sed 's/^/  /' && echo
    [[ -f "$RUST_MARKER" ]] && echo "  rust (rustup in $HOME/.cargo)"
    read -r -p "Remove them? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
      if [[ -s "$HOST_PKGS_FILE" ]]; then
        # shellcheck disable=SC2046
        DEBIAN_FRONTEND=noninteractive apt-get remove -y $(cat "$HOST_PKGS_FILE") >/dev/null 2>&1 || \
          warn "Some packages could not be removed (check with apt)."
        rm -f "$HOST_PKGS_FILE"
      fi
      if [[ -f "$RUST_MARKER" && -x "$HOME/.cargo/bin/rustup" ]]; then
        "$HOME/.cargo/bin/rustup" self uninstall -y >/dev/null 2>&1 || true
        rm -rf "$HOME/.cargo" "$HOME/.rustup"
      fi
      rm -f "$RUST_MARKER"
      ok "Host packages removed."
    fi
  fi
  if [[ -d "$BUILD_ROOT" ]]; then
    read -r -p "Remove the old host build directory $BUILD_ROOT? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] && rm -rf "$BUILD_ROOT" && ok "Removed $BUILD_ROOT"
  fi
  ok "Done. Guests created by this script removed."
}

main() {
  local mode="${1:-create}"
  resolve_self "$@"
  mkdir -p "$LOG_DIR"
  case "$mode" in
    destroy|remove)
      destroy_all
      ;;
    update)
      check_login_config
      service_update
      ;;
    reset-logins)
      check_login_config
      reset_logins
      ;;
    self-update)
      self_update --yes
      ;;
    create|"")
      self_update
      echo "Proxmox homelab — full install (Docker, official images)"
      echo "========================================================"
      check_host
      check_login_config
      ensure_template
      size_docker_ct

      # Assign free IDs if the defaults are taken by guests this script did not make
      local -a assigned=() new_list=()
      local entry ctid hostname cores memory disk role cpulimit free
      for entry in "${CONTAINERS[@]}"; do
        IFS='|' read -r ctid hostname cores memory disk role cpulimit <<< "$entry"
        if [[ "$role" == "docker" ]]; then
          cores="$DOCKER_CORES"; memory="$DOCKER_MEM"; disk="$DOCKER_DISK"; cpulimit="$DOCKER_CORES"
        fi
        if { pct status "$ctid" >/dev/null 2>&1 && ! has_tag ct "$ctid"; } || qm status "$ctid" >/dev/null 2>&1; then
          free=$(next_free_id "$ctid")
          while printf '%s\n' "${assigned[@]}" | grep -qx "$free"; do
            free=$(next_free_id "$((free + 1))")
          done
          warn "ID $ctid is taken — using $free for $hostname"
          ctid="$free"
        fi
        assigned+=("$ctid")
        new_list+=("$ctid|$hostname|$cores|$memory|$disk|$role|$cpulimit")
      done
      CONTAINERS=("${new_list[@]}")

      for entry in "${CONTAINERS[@]}"; do
        IFS='|' read -r ctid hostname cores memory disk role cpulimit <<< "$entry"
        step "CT $ctid ($hostname): create"
        if [[ "$role" == "docker" ]]; then
          create_ct "$ctid" "$hostname" "$cores" "$memory" "$disk" "$cpulimit" "$DOCKER_SWAP"
        else
          create_ct "$ctid" "$hostname" "$cores" "$memory" "$disk" "$cpulimit" 512
        fi
        setup_docker "$ctid"
        install_role "$ctid" "$role"
      done
      health_checks
      apply_logins
      print_summary
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [create|update|reset-logins|self-update|destroy]"
      ;;
  esac
}

main "$@"
exit 0
###END proxmox.sh
