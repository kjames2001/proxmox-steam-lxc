#!/usr/bin/env bash

echo -e "Loading..."
APP="steam-gamescope"
var_disk="32"
var_cpu="4"
var_ram="4096"
var_os="debian"
var_version="13"
NSAPP=$(echo ${APP,,} | tr -d ' ' | tr '-' '_')
var_install="${NSAPP}-install"
NEXTID=$(pvesh get /cluster/nextid)
INTEGER='^[0-9]+$'
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR

function error_exit() {
  trap - ERR
  local reason="Unknown failure occurred."
  local msg="${1:-$reason}"
  local flag="${RD}‼ ERROR ${CL}$EXIT@$LINE"
  echo -e "$flag $msg" 1>&2
  exit $EXIT
}

if (whiptail --title "${APP} LXC" --yesno "This will create a New ${APP} LXC with Steam + Gamescope on TTY7. Proceed?" 10 68); then
    echo "User selected Yes"
else
    clear
    echo -e "⚠ User exited script \n"
    exit
fi

function header_info {
echo -e "Steam+Gamescope---\n\n"
}

function msg_info() {
    local msg="$1"
    echo -ne " ${HOLD} ${YW}${msg}..."
}

function msg_ok() {
    local msg="$1"
    echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

function msg_error() {
    local msg="$1"
    echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

function PVE_CHECK() {
    PVE=$(pveversion | grep -cE "pve-manager/[789]")
    if [[ $PVE != 1 ]]; then
       echo -e "${RD}This script requires Proxmox Virtual Environment 7.x or greater${CL}"
       echo -e "Exiting..."
       sleep 2
       exit
    fi
}

# ─────────────────────────────────────────────
# Settings persistence
# ─────────────────────────────────────────────
SETTINGS_FILE="/root/.steam-lxc-settings.conf"

function save_settings() {
    cat > "$SETTINGS_FILE" <<EOF
# Steam+Gamescope LXC Settings - Last saved $(date)
var_version="$var_version"
CT_TYPE="$CT_TYPE"
CT_ID="$CT_ID"
HN="$HN"
DISK_SIZE="$DISK_SIZE"
CORE_COUNT="$CORE_COUNT"
RAM_SIZE="$RAM_SIZE"
BRG="$BRG"
NET="$NET"
GATE="$GATE"
DNS="$DNS"
MAC="$MAC"
VLAN="$VLAN"
GAMER_PASS="$GAMER_PASS"
EOF
    echo -e "${GN}Settings saved to $SETTINGS_FILE${CL}"
}

function load_settings() {
    if [ -f "$SETTINGS_FILE" ]; then
        source "$SETTINGS_FILE"
        echo -e "${GN}Settings loaded from previous session${CL}"
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────
# Default values
# ─────────────────────────────────────────────
CT_TYPE="1"       # unprivileged
CT_ID="$NEXTID"
HN="steam-gamescope"
DISK_SIZE="32"
CORE_COUNT="4"
RAM_SIZE="4096"
BRG="vmbr0"
NET="dhcp"
GATE=""
DNS=""
MAC=""
VLAN=""
GAMER_PASS="gamer"

# ─────────────────────────────────────────────
# Interactive setup
# ─────────────────────────────────────────────
function default_settings() {
    echo -e "${DGN}Using Default Settings${CL}"
    echo -e "${DGN}Using CT Type ${BGN}Unprivileged${CL}"
    echo -e "${DGN}Using CT ID ${BGN}$CT_ID${CL}"
    echo -e "${DGN}Using CT Name ${BGN}$HN${CL}"
    echo -e "${DGN}Using Disk Size ${BGN}${DISK_SIZE}GB${CL}"
    echo -e "${DGN}Using ${BGN}${CORE_COUNT}vCPU${CL}"
    echo -e "${DGN}Using ${BGN}${RAM_SIZE}MiB${CL} RAM"
    echo -e "${DGN}Using Bridge ${BGN}$BRG${CL}"
    echo -e "${DGN}Using IP Address ${BGN}$NET${CL}"
    [ -n "$GATE" ] && echo -e "${DGN}Using Gateway ${BGN}$GATE${CL}"
    [ -n "$DNS" ] && echo -e "${DGN}Using DNS ${BGN}$DNS${CL}"
    [ -n "$MAC" ] && echo -e "${DGN}Using MAC Address ${BGN}$MAC${CL}"
    [ -n "$VLAN" ] && echo -e "${DGN}Using VLAN ${BGN}$VLAN${CL}"
    echo -e "${DGN}Using Password ${BGN}$GAMER_PASS${CL}"
}

function advanced_settings() {
    if CT_TYPE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CONTAINER TYPE" --radiolist --cancel-button Exit-Script "Choose Type" 10 58 2 \
    "1" "Unprivileged" ON \
    "0" "Privileged" OFF \
    3>&1 1>&2 2>&3); then
        [ -n "$CT_TYPE" ] && echo -e "${DGN}Using CT Type ${BGN}$CT_TYPE${CL}"
    else
        echo -e "${RD}Cancelled${CL}"
        exit
    fi

    while true; do
        CT_ID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CONTAINER ID" --inputbox "Set Container ID" 8 58 $NEXTID --cancel-button Exit-Script 3>&1 1>&2 2>&3)
        if [[ "$CT_ID" =~ $INTEGER ]] && pct status "$CT_ID" &>/dev/null; then
            echo -e "${CROSS}${RD}ID $CT_ID is already in use${CL}"
            continue
        fi
        [[ "$CT_ID" =~ $INTEGER ]] || { echo -e "${RD}$CT_ID is not a valid ID${CL}"; continue; }
        echo -e "${DGN}Using CT ID ${BGN}$CT_ID${CL}"
        break
    done

    HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "HOSTNAME" --inputbox "Set hostname" 8 58 $HN --cancel-button Exit-Script 3>&1 1>&2 2>&3)
    [ -n "$HN" ] && echo -e "${DGN}Using CT Name ${BGN}$HN${CL}" || exit

    while true; do
        DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK SIZE" --inputbox "Set Disk Size in GB (min 8)" 8 58 $DISK_SIZE --cancel-button Exit-Script 3>&1 1>&2 2>&3)
        [[ "$DISK_SIZE" =~ $INTEGER ]] && [ "$DISK_SIZE" -ge 8 ] || { echo -e "${RD}$DISK_SIZE is not a valid disk size${CL}"; continue; }
        echo -e "${DGN}Using Disk Size ${BGN}${DISK_SIZE}GB${CL}"
        break
    done

    while true; do
        CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CORE COUNT" --inputbox "Set Core Count (1-$MAX_CORES)" 8 58 $CORE_COUNT --cancel-button Exit-Script 3>&1 1>&2 2>&3)
        [[ "$CORE_COUNT" =~ $INTEGER ]] && [ "$CORE_COUNT" -ge 1 ] && [ "$CORE_COUNT" -le $MAX_CORES ] || { echo -e "${RD}$CORE_COUNT is not valid${CL}"; continue; }
        echo -e "${DGN}Using ${BGN}${CORE_COUNT}vCPU${CL}"
        break
    done

    RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "RAM SIZE" --inputbox "Set RAM in MiB (min 1024)" 8 58 $RAM_SIZE --cancel-button Exit-Script 3>&1 1>&2 2>&3)
    [[ "$RAM_SIZE" =~ $INTEGER ]] && [ "$RAM_SIZE" -ge 1024 ] || RAM_SIZE=4096
    echo -e "${DGN}Using ${BGN}${RAM_SIZE}MiB${CL} RAM"

    BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "BRIDGE" --inputbox "Set Bridge" 8 58 $BRG --cancel-button Exit-Script 3>&1 1>&2 2>&3)
    [ -n "$BRG" ] && echo -e "${DGN}Using Bridge ${BGN}$BRG${CL}" || exit

    NET=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "IP ADDRESS" --inputbox "Set IP Address (dhcp or CIDR)" 8 58 $NET --cancel-button Exit-Script 3>&1 1>&2 2>&3)
    echo -e "${DGN}Using IP Address ${BGN}$NET${CL}"

    GATE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "GATEWAY" --inputbox "Set Gateway (leave empty for dhcp)" 8 58 $GATE --cancel-button Exit-Script 3>&1 1>&2 2>&3)
    [ -n "$GATE" ] && echo -e "${DGN}Using Gateway ${BGN}$GATE${CL}"

    DNS=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DNS" --inputbox "Set DNS (leave empty for default)" 8 58 $DNS --cancel-button Exit-Script 3>&1 1>&2 2>&3)
    [ -n "$DNS" ] && echo -e "${DGN}Using DNS ${BGN}$DNS${CL}"

    MAC=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MAC ADDRESS" --inputbox "Set MAC Address (leave empty for random)" 8 58 $MAC --cancel-button Exit-Script 3>&1 1>&2 2>&3)
    [ -n "$MAC" ] && echo -e "${DGN}Using MAC Address ${BGN}$MAC${CL}"

    VLAN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "VLAN" --inputbox "Set VLAN (leave empty for none)" 8 58 $VLAN --cancel-button Exit-Script 3>&1 1>&2 2>&3)
    [ -n "$VLAN" ] && echo -e "${DGN}Using VLAN ${BGN}$VLAN${CL}"

    GAMER_PASS=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "GAMER USER PASSWORD" --inputbox "Set password for 'gamer' user" 8 58 $GAMER_PASS --cancel-button Exit-Script 3>&1 1>&2 2>&3)
    [ -n "$GAMER_PASS" ] && echo -e "${DGN}Using Password ${BGN}$GAMER_PASS${CL}" || GAMER_PASS="gamer"
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
MAX_CORES=$(nproc)
PVE_CHECK
clear
header_info

if load_settings; then
    if whiptail --backtitle "Proxmox VE Helper Scripts" --title "PREVIOUS SETTINGS" --yesno "Use settings from last session?\nCT ID: $CT_ID | Hostname: $HN | $CORE_COUNT CPU | ${RAM_SIZE}MiB RAM | ${DISK_SIZE}GB Disk" 12 58; then
        echo -e "${GN}Using saved settings${CL}"
    else
        load_settings_ok=false
    fi
fi

if [ "${load_settings_ok:-true}" = "false" ]; then
    :
fi

if whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETUP MODE" --yesno "Use Default Settings?\n(No = Advanced Setup)" 10 58; then
    default_settings
else
    advanced_settings
fi

save_settings

# ─────────────────────────────────────────────
# Build PCT options
# ─────────────────────────────────────────────
if [ "$CT_TYPE" = "1" ]; then
    TEMPLATE_FS="rootdir"
    FEATURES="nesting=1,keyctl=1"
else
    FEATURES="nesting=1,keyctl=1"
fi

# Network config
NET_OPTS="name=eth0,bridge=$BRG,ip=$NET"
[ -n "$GATE" ] && NET_OPTS="$NET_OPTS,gw=$GATE"
[ -n "$DNS" ] && NET_OPTS="$NET_OPTS,nameserver=$DNS"
[ -n "$MAC" ] && NET_OPTS="$NET_OPTS,hwaddr=$MAC"
[ -n "$VLAN" ] && NET_OPTS="$NET_OPTS,tag=$VLAN"

export CTTY=0
export ST="Unmount"
export CTID="$CT_ID"
export PCT_OSTYPE="$var_os"
export PCT_OSVERSION="$var_version"
export DISK_SIZE="$DISK_SIZE"
export CORER="$CORE_COUNT"
export RAM_SIZE="$RAM_SIZE"
export BRG="$BRG"
export NET="$NET"
export GATE="$GATE"
export DNS="$DNS"
export MAC="$MAC"
export VLAN="$VLAN"
export GAMER_PASS="$GAMER_PASS"

# ─────────────────────────────────────────────
# Download create_lxc-patched.sh and create container
# ─────────────────────────────────────────────
CREATE_LXC_URL="https://raw.githubusercontent.com/kjames2001/proxmox-steam-lxc/main/ct/create_lxc-patched.sh"

msg_info "Creating LXC Container"
bash -c "$(wget -qLO - $CREATE_LXC_URL)" || exit

# ─────────────────────────────────────────────
# Post-create config: GPU/display/audio/input passthrough
# ─────────────────────────────────────────────
msg_info "Configuring GPU/display/audio passthrough"

# GPU render nodes
pct set $CT_ID --lxc cgroup2.devices.allow c 226:0 rwm
pct set $CT_ID --lxc cgroup2.devices.allow c 226:128 rwm
pct set $CT_ID --lxc cgroup2.devices.allow c 226:64 rwm

# DRM / GPU
pct set $CT_ID --lxc mount.entry /dev/dri dev/dri none bind,optional,create=dir
pct set $CT_ID --lxc mount.entry /dev/dri/renderD128 dev/renderD128 none bind,optional,create=file
pct set $CT_ID --lxc mount.entry /dev/kfd dev/kfd none bind,optional,create=file

# Framebuffer + TTY7
pct set $CT_ID --lxc cgroup2.devices.allow c 4:7 rwm
pct set $CT_ID --lxc mount.entry /dev/fb0 dev/fb0 none bind,optional,create=file
pct set $CT_ID --lxc cgroup2.devices.allow c 29:0 rwm
pct set $CT_ID --lxc mount.entry /dev/tty7 dev/tty7 none bind,optional,create=file

# Input devices (controllers, keyboards, mice)
pct set $CT_ID --lxc cgroup2.devices.allow c 13:* rwm
pct set $CT_ID --lxc mount.entry /dev/input dev/input none bind,optional,create=dir

# Audio (ALSA + USB audio if present)
pct set $CT_ID --lxc cgroup2.devices.allow c 116:* rwm
pct set $CT_ID --lxc mount.entry /dev/snd dev/snd none bind,optional,create=dir

# USB devices (hidraw for controllers, etc.)
pct set $CT_ID --lxc cgroup2.devices.allow c 188:* rwm
pct set $CT_ID --lxc cgroup2.devices.allow c 10:200 rwm

# /dev/net/tun for Steam networking
pct set $CT_ID --lxc mount.entry /dev/net/tun dev/net/tun none bind,create=file

# /dev/fuse for Steam proton
pct set $CT_ID --features nesting=1,keyctl=1
pct set $CT_ID --dev0 /dev/fuse

# idmap for unprivileged GPU access (match video/render/audio groups)
if [ "$CT_TYPE" = "1" ]; then
    pct set $CT_ID --lxc idmap u 0 100000 65536
    pct set $CT_ID --lxc idmap g 0 100000 5
    pct set $CT_ID --lxc idmap g 5 5 1
    pct set $CT_ID --lxc idmap g 6 100006 23
    pct set $CT_ID --lxc idmap g 29 29 1
    pct set $CT_ID --lxc idmap g 30 100030 14
    pct set $CT_ID --lxc idmap g 44 44 1
    pct set $CT_ID --lxc idmap g 45 100045 947
    pct set $CT_ID --lxc idmap g 992 993 1
    pct set $CT_ID --lxc idmap g 993 100993 3
    pct set $CT_ID --lxc idmap g 996 997 1
    pct set $CT_ID --lxc idmap g 997 100997 64539
fi

# Disable capability drops for GPU access
pct set $CT_ID --lxc cap.drop ""

msg_ok "Configured GPU/display/audio passthrough"

# ─────────────────────────────────────────────
# Start container and run installer
# ─────────────────────────────────────────────
msg_info "Starting container"
pct start $CT_ID
sleep 5
msg_ok "Container started"

msg_info "Running Steam+Gamescope installer"
pct push $CT_ID - /tmp/steam-install.sh --perms 755 << 'INSTALLER_EOF'
#!/usr/bin/env bash
exec bash -c "$(curl -sL https://raw.githubusercontent.com/kjames2001/proxmox-steam-lxc/main/setup/steam-install.sh)"
INSTALLER_EOF

pct exec $CT_ID -- bash /tmp/steam-install.sh || {
    msg_error "Installer failed. Run manually in the LXC console."
    exit 1
}

msg_ok "Steam+Gamescope LXC created successfully"
echo ""
echo -e "${GN}Container ${BGN}$CT_ID${CL} ${GN}is ready${CL}"
echo -e "${GN}Steam will launch via Gamescope on TTY7 on next boot${CL}"
echo ""
echo -e "${YW}Access the container console:${CL}"
echo -e "  pct enter $CT_ID"
echo -e ""
echo -e "${YW}To restart the Gamescope session:${CL}"
echo -e "  pct exec $CT_ID -- systemctl restart steam-gamescope"
echo ""