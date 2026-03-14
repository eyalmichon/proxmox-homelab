#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Docker Host LXC — one-time Proxmox setup
#
# Run from the Proxmox host shell (web UI or SSH):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/eyalmichon/proxmox-homelab/main/create-docker-host.sh)"
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GN="\033[1;32m"  YW="\033[33m"  BL="\033[36m"  RD="\033[01;31m"  CL="\033[m"
header()  { echo -e "\n${BL}──── $1 ────${CL}"; }
msg()     { echo -e " ${GN}✓${CL} $1"; }
info()    { echo -e " ${YW}→${CL} $1"; }
err()     { echo -e " ${RD}✗ $1${CL}" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || err "Run as root on the Proxmox host."
command -v pct &>/dev/null || err "pct not found — are you on a Proxmox host?"

# ── Defaults ─────────────────────────────────────────────────────────────────
HOSTNAME="docker-host"
TEMPLATE="debian-12-standard"
DISK_SIZE="8"
RAM="1024"
CORES="2"
STORAGE="local-lvm"
BRIDGE="vmbr0"

# ── Gather settings ──────────────────────────────────────────────────────────
header "Docker Host LXC Setup"
echo ""
echo " This will create a Debian 12 LXC with Docker + Compose installed."
echo " All your services (bots, tools) will run as containers inside it."
echo ""

NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
read -rp " Container ID [$NEXT_ID]: " CT_ID
CT_ID="${CT_ID:-$NEXT_ID}"

read -rp " Hostname [$HOSTNAME]: " INPUT
HOSTNAME="${INPUT:-$HOSTNAME}"

read -rp " Disk size in GB [$DISK_SIZE]: " INPUT
DISK_SIZE="${INPUT:-$DISK_SIZE}"

read -rp " RAM in MB [$RAM]: " INPUT
RAM="${INPUT:-$RAM}"

read -rp " Storage pool [$STORAGE]: " INPUT
STORAGE="${INPUT:-$STORAGE}"

read -rp " Network bridge [$BRIDGE]: " INPUT
BRIDGE="${INPUT:-$BRIDGE}"

read -rp " Static IP with CIDR, e.g. 192.168.1.50/24 (blank for DHCP): " STATIC_IP

if [[ -n "$STATIC_IP" ]]; then
  read -rp " Gateway: " GATEWAY
  NET_CONF="name=eth0,bridge=${BRIDGE},ip=${STATIC_IP},gw=${GATEWAY}"
else
  NET_CONF="name=eth0,bridge=${BRIDGE},ip=dhcp"
fi

# ── Find template ────────────────────────────────────────────────────────────
header "Preparing template"
TMPL_STORAGE="local"
TMPL=$(pveam list "$TMPL_STORAGE" 2>/dev/null | grep "$TEMPLATE" | sort -V | tail -1 | awk '{print $1}' || true)

if [[ -z "$TMPL" ]]; then
  info "Downloading template..."
  pveam update >/dev/null 2>&1
  AVAIL=$(pveam available --section system | grep "$TEMPLATE" | sort -V | tail -1 | awk '{print $2}')
  [[ -z "$AVAIL" ]] && err "Could not find $TEMPLATE template."
  pveam download "$TMPL_STORAGE" "$AVAIL" >/dev/null 2>&1
  TMPL="${TMPL_STORAGE}:vztmpl/${AVAIL}"
else
  msg "Using cached template: $TMPL"
fi

# ── Create container ─────────────────────────────────────────────────────────
header "Creating LXC $CT_ID ($HOSTNAME)"

pct create "$CT_ID" "$TMPL" \
  --hostname "$HOSTNAME" \
  --storage "$STORAGE" \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --memory "$RAM" \
  --cores "$CORES" \
  --net0 "$NET_CONF" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --start 0 \
  --onboot 1 \
  >/dev/null 2>&1

msg "Container created"

# ── Start and wait for network ───────────────────────────────────────────────
header "Starting container"
pct start "$CT_ID"
sleep 3

for i in $(seq 1 30); do
  if pct exec "$CT_ID" -- ping -c1 -W1 8.8.8.8 &>/dev/null; then
    msg "Network is up"
    break
  fi
  [[ $i -eq 30 ]] && err "Network not available after 30s"
  sleep 1
done

lxc_exec() { pct exec "$CT_ID" -- bash -c "$1"; }

# ── Install Docker ───────────────────────────────────────────────────────────
header "Installing Docker"
lxc_exec "apt-get update -qq > /dev/null 2>&1"
lxc_exec "apt-get install -y -qq ca-certificates curl gnupg > /dev/null 2>&1"
lxc_exec "install -m 0755 -d /etc/apt/keyrings"
lxc_exec "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
lxc_exec "chmod a+r /etc/apt/keyrings/docker.gpg"
lxc_exec 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list'
lxc_exec "apt-get update -qq > /dev/null 2>&1"
lxc_exec "apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1"
msg "Docker installed"

# ── Install useful tools ─────────────────────────────────────────────────────
lxc_exec "apt-get install -y -qq git rsync python3 > /dev/null 2>&1"
msg "git, rsync, python3 installed"

# ── Create services directory ────────────────────────────────────────────────
header "Setting up /opt/services"
lxc_exec "mkdir -p /opt/services"
pct exec "$CT_ID" -- bash -c 'cat > /opt/services/docker-compose.yml << EOF
services: {}
EOF'
msg "/opt/services ready"

# ── Verify Docker ────────────────────────────────────────────────────────────
header "Verifying Docker"
lxc_exec "docker run --rm hello-world > /dev/null 2>&1" && msg "Docker is working" || info "Docker test failed — may need manual check"

# ── Get IP ───────────────────────────────────────────────────────────────────
CT_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

# ── Done ─────────────────────────────────────────────────────────────────────
header "Done! Docker host ready"
echo ""
echo -e " ${GN}Container:${CL}  $CT_ID ($HOSTNAME)"
echo -e " ${GN}IP:${CL}         ${CT_IP:-check DHCP}"
echo -e " ${GN}Console:${CL}    Proxmox UI → $CT_ID → Console"
echo -e " ${GN}Services:${CL}   /opt/services/"
echo ""
echo -e " ${YW}To deploy a service, open the LXC console and run its one-liner.${CL}"
echo ""
