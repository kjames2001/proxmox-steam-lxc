#!/usr/bin/env bash

# ──────────────────────────────────────────────────────────────
# Steam + Gamescope Installer for Debian 13 (Trixie) LXC
#
# Installs:
#   - Steam (steam-installer from Debian contrib, i386 multilib)
#   - Gamescope (from trixie-backports)
#   - MangoHud (overlay metrics)
#   - Xorg + Xinit (no display manager, no desktop)
#   - systemd service that autologins 'gamer' user on TTY7
#     and starts gamescope → steam -gamepadui
#
# Based on the tteck/Proxmox helper pattern (MIT license)
# ──────────────────────────────────────────────────────────────

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR

YW=$(echo "\033[33m")
RD=$(echo "\033[01;31m")
BL=$(echo "\033[36m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
RETRY_NUM=10
RETRY_EVERY=3
NUM=$RETRY_NUM
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
BFR="\\r\\033[K"
HOLD="-"

function error_exit() {
  trap - ERR
  local reason="Unknown failure occurred."
  local msg="${1:-$reason}"
  local flag="${RD}‼ ERROR ${CL}$EXIT@$LINE"
  echo -e "$flag $msg" 1>&2
  exit $EXIT
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

GAMER_PASS="${GAMER_PASS:-gamer}"

# ─────────────────────────────────────────────
# 1. OS setup + network wait
# ─────────────────────────────────────────────
msg_info "Setting up Container OS"
sed -i "/$LANG/ s/\(^# \)//" /etc/locale.gen
locale-gen >/dev/null 2>&1 || true
while [ "$(hostname -I)" = "" ]; do
  1>&2 echo -en "${CROSS}${RD} No Network! "
  sleep $RETRY_EVERY
  ((NUM--))
  if [ $NUM -eq 0 ]; then
    1>&2 echo -e "${CROSS}${RD} No Network After $RETRY_NUM Tries${CL}"
    exit 1
  fi
done
msg_ok "Network Connected: ${BL}$(hostname -I)"

if nc -zw1 8.8.8.8 443 2>/dev/null; then
    msg_ok "Internet Connected"
else
    msg_error "Internet NOT Connected"
    exit 1
fi

RESOLVEDIP=$(nslookup "github.com" 2>/dev/null | awk -F':' '/^Address: / { matched = 1 } matched { print $2}' | xargs)
if [[ -n "$RESOLVEDIP" ]]; then
    msg_ok "DNS Resolved github.com to $RESOLVEDIP"
else
    msg_error "DNS Lookup Failure"
fi

msg_info "Updating Container OS"
apt-get update &>/dev/null
apt-get -y upgrade &>/dev/null
msg_ok "Updated Container OS"

# ─────────────────────────────────────────────
# 2. APT sources: add contrib, non-free, non-free-firmware + backports
# ─────────────────────────────────────────────
msg_info "Configuring APT sources"
SOURCES_DIR="/etc/apt/sources.list.d"
DEBIAN_SOURCES="$SOURCES_DIR/debian.sources"

if [ -f "$DEBIAN_SOURCES" ]; then
    # Ensure main contrib non-free non-free-firmware
    sed -i 's/^Components:.*$/Components: main contrib non-free non-free-firmware/' "$DEBIAN_SOURCES"
    # Add trixie-backports if not present
    if ! grep -q "trixie-backports" "$DEBIAN_SOURCES"; then
        cat >> "$DEBIAN_SOURCES" << 'EOF'

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    fi
elif [ -f /etc/apt/sources.list ]; then
    sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list
    sed -i 's/main \[/main contrib non-free non-free-firmware \[/' /etc/apt/sources.list 2>/dev/null || true
    if ! grep -q "trixie-backports" /etc/apt/sources.list; then
        echo "deb http://deb.debian.org/debian trixie-backports main contrib non-free non-free-firmware" >> /etc/apt/sources.list
    fi
fi

apt-get update &>/dev/null
msg_ok "Configured APT sources (contrib + non-free-firmware + backports)"

# ─────────────────────────────────────────────
# 3. Hardware acceleration (AMD GPU)
# ─────────────────────────────────────────────
msg_info "Installing GPU drivers and firmware"
dpkg --add-architecture i386 &>/dev/null
apt-get update -qq &>/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    firmware-amd-graphics \
    mesa-va-drivers \
    mesa-vulkan-drivers \
    libgl1-mesa-dri \
    vulkan-tools \
    ocl-icd-libopencl1 \
    &>/dev/null
msg_ok "Installed GPU drivers and firmware"

# ─────────────────────────────────────────────
# 4. Create 'gamer' user
# ─────────────────────────────────────────────
msg_info "Creating 'gamer' user"
if ! id -u gamer &>/dev/null; then
    useradd -m -s /bin/bash -G audio,input,video,render,tty gamer
fi
usermod -aG audio,input,video,render,tty gamer
echo "gamer:${GAMER_PASS}" | chpasswd
# Create autologin group for tty7
groupadd -r autologin 2>/dev/null || true
usermod -aG autologin gamer
msg_ok "Created 'gamer' user (password: ${GAMER_PASS})"

# ─────────────────────────────────────────────
# 5. Install Xorg (no display manager)
# ─────────────────────────────────────────────
msg_info "Installing Xorg (no display manager)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    xorg \
    xserver-xorg \
    xserver-xorg-video-all \
    xserver-xorg-input-evdev \
    xinit \
    xauth \
    &>/dev/null
msg_ok "Installed Xorg"

# ─────────────────────────────────────────────
# 6. Input device detection (same pattern as kodi-install.sh)
# ─────────────────────────────────────────────
msg_info "Setting up input device detection"
mkdir -p /etc/X11/xorg.conf.d
cat > /usr/local/bin/preX-populate-input.sh << 'INPUTEOF'
#!/usr/bin/env bash
# Creates X config with all currently present input devices
cat > /etc/X11/xorg.conf.d/10-lxc-input.conf << _EOF_
Section "ServerFlags"
     Option "AutoAddDevices" "False"
EndSection
_EOF_
cd /dev/input
for input in event*; do
    cat >> /etc/X11/xorg.conf.d/10-lxc-input.conf << _EOF_
Section "InputDevice"
    Identifier "$input"
    Option "Device" "/dev/input/$input"
    Option "AutoServerLayout" "true"
    Driver "evdev"
EndSection
_EOF_
done
INPUTEOF
chmod +x /usr/local/bin/preX-populate-input.sh
msg_ok "Input device detection configured"

# ─────────────────────────────────────────────
# 7. Install Steam
# ─────────────────────────────────────────────
msg_info "Installing Steam (steam-installer from Debian contrib)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    steam-installer \
    steam-libs-amd64:i386 \
    &>/dev/null
apt-get install -y -f -qq &>/dev/null || true

STEAM_BIN=""
if command -v steam &>/dev/null; then
    STEAM_BIN="steam"
elif [ -f /usr/games/steam ]; then
    STEAM_BIN="/usr/games/steam"
fi

if [ -n "$STEAM_BIN" ]; then
    msg_ok "Steam installed (${STEAM_BIN})"
else
    msg_error "Steam install failed — trying alternative method"
    # Fallback: direct download from Steam
    wget -q https://steamcdn-a.akamaihd.net/client/installer/steam.deb -O /tmp/steam.deb 2>/dev/null
    dpkg -i /tmp/steam.deb 2>/dev/null || apt-get install -y -f -qq &>/dev/null
    command -v steam &>/dev/null && STEAM_BIN="steam" || {
        msg_error "Steam install failed completely"
        echo "  Install manually: apt install steam-installer"
    }
fi

# ─────────────────────────────────────────────
# 8. Install Gamescope (from trixie-backports)
# ─────────────────────────────────────────────
msg_info "Installing Gamescope (from trixie-backports)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -t trixie-backports \
    gamescope \
    &>/dev/null

if command -v gamescope &>/dev/null; then
    GAMESCOPE_VER=$(gamescope --version 2>&1 | head -1 || echo "unknown")
    msg_ok "Gamescope installed (${GAMESCOPE_VER})"
else
    msg_error "Gamescope install failed from backports"
    echo "  Trying from vlshields/gamescope-manager..."
    # Fallback: use gamescope-manager
    apt-get install -y -qq git curl &>/dev/null
    git clone https://github.com/vlshields/gamescope-manager.git /tmp/gamescope-manager 2>/dev/null
    cd /tmp/gamescope-manager && chmod +x build.sh && ./build.sh 2>/dev/null
    gamescope-manager install 2>/dev/null || {
        msg_error "Gamescope install failed completely"
        echo "  Install manually: apt install -t trixie-backports gamescope"
    }
fi

# ─────────────────────────────────────────────
# 9. Install MangoHud (optional overlay)
# ─────────────────────────────────────────────
msg_info "Installing MangoHud (overlay metrics)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mangohud &>/dev/null \
    && msg_ok "MangoHud installed" \
    || msg_error "MangoHud install failed (non-critical)"

# ─────────────────────────────────────────────
# 10. Configure Xorg for gamer user
# ─────────────────────────────────────────────
msg_info "Configuring Xorg for gamer user"

# Pin Xorg to the AMD iGPU.
# On hosts that also have a discrete GPU (e.g. NVIDIA), the firmware may mark
# the dGPU as boot VGA. With no config Xorg then probes the dGPU, fails with
# "Failed to open DRM device ... -19" and exits with
# "Cannot run in framebuffer mode". An explicit BusID fixes it.
# NOTE: Xorg BusID values are DECIMAL (PCI c8:00.0 -> "PCI:200:0:0").
mkdir -p /etc/X11/xorg.conf.d
IGPU_BUSID=""
for dev in /sys/class/drm/card*/device; do
    [ "$(cat "$dev/vendor" 2>/dev/null)" = "0x1002" ] || continue
    addr=$(basename "$(readlink -f "$dev")")          # e.g. 0000:c8:00.0
    bus=${addr#*:}; bus=${bus%%:*}
    slot=${addr##*:}; slot=${slot%%.*}
    fn=${addr##*.}
    IGPU_BUSID="PCI:$((16#$bus)):$((16#$slot)):$((16#$fn))"
    break
done
if [ -n "$IGPU_BUSID" ]; then
    cat > /etc/X11/xorg.conf.d/20-igpu.conf << XORGEOF
Section "Device"
    Identifier "iGPU"
    Driver "amdgpu"
    BusID "$IGPU_BUSID"
EndSection
XORGEOF
    msg_ok "Xorg pinned to AMD iGPU ($IGPU_BUSID)"
else
    msg_error "No AMD DRM device found; Xorg left on autodetect"
fi

# steam-installer asks for confirmation through zenity on first run, which
# blocks an unattended autostart. Stub it out so the bootstrap proceeds.
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/zenity
chmod 755 /usr/local/bin/zenity

# ─────────────────────────────────────────────
# 11. .xinitrc — gamescope launches steam -gamepadui
# ─────────────────────────────────────────────
GAMER_HOME=$(getent passwd gamer | cut -d: -f6)
mkdir -p "$GAMER_HOME"

cat > "$GAMER_HOME/.xinitrc" << 'XINITRC'
#!/usr/bin/env bash
# .xinitrc — launched by startx on TTY7
# Gamescope wraps Steam in Big Picture / Gamepad UI mode

export DISPLAY=:0
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# Set DRM device for gamescope
export DRM_DEV=/dev/dri/renderD128

# Vulkan for AMD
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json:/usr/share/vulkan/icd.d/radeon_icd.i686.json
export RADV_PERFTEST=aco

# Gamescope options:
#   -e          = embed (borderless fullscreen)
#   -W 1920 -H 1080 = output resolution
#   -w 1920 -h 1080 = internal resolution
#   --steam     = use Steam integration
#
# Steam options:
#   -gamepadui  = Steam Deck UI (Big Picture replacement)

# Detect native resolution from DRM
NATIVE_W=1920
NATIVE_H=1080
if command -v xrandr &>/dev/null; then
    RES=$(xrandr 2>/dev/null | grep ' connected' | grep -oE '[0-9]+x[0-9]+' | head -1)
    if [ -n "$RES" ]; then
        NATIVE_W=$(echo "$RES" | cut -dx -f1)
        NATIVE_H=$(echo "$RES" | cut -dx -f2)
    fi
fi

STEAM_BIN="steam"
[ -f /usr/games/steam ] && STEAM_BIN="/usr/games/steam"

# Launch gamescope with Steam
exec gamescope \
    -e \
    -W ${NATIVE_W} -H ${NATIVE_H} \
    -w ${NATIVE_W} -h ${NATIVE_H} \
    -- ${STEAM_BIN} -gamepadui
XINITRC
chmod +x "$GAMER_HOME/.xinitrc"
chown gamer:gamer "$GAMER_HOME/.xinitrc"

# ─────────────────────────────────────────────
# 12. systemd service: autologin gamer on TTY7 + startx
# ─────────────────────────────────────────────
msg_info "Creating Steam+Gamescope systemd service"

# Override getty on tty7 to autologin as gamer
TTY7_OVERRIDE="/etc/systemd/system/container-getty@7.service.d/override.conf"
mkdir -p "$(dirname "$TTY7_OVERRIDE")"
cat > "$TTY7_OVERRIDE" << 'GETTYEOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin gamer --noclear --keep-baud tty7 115200,38400,9600 $TERM
GETTYEOF

# Keep the tty7 login out of systemd-logind. In LXC the host owns VT
# switching, so logind never marks the session active and hands Xorg
# *paused* input fds: the display works but keyboard/mouse are dead.
# Skipping pam_systemd for tty7 makes Xorg open /dev/input/* directly.
# Linger keeps the gamer user manager (and its D-Bus session bus) running.
if ! grep -q 'pam_succeed_if.so quiet tty in tty7' /etc/pam.d/common-session; then
    sed -i '/pam_systemd.so/i session [success=1 default=ignore] pam_succeed_if.so quiet tty in tty7:/dev/tty7' \
        /etc/pam.d/common-session
fi
mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/gamer

# Create a profile script that auto-starts X when gamer logs in on tty7.
# -keeptty/-novtswitch/-sharevts: LXC has no real VT ownership; without these
# Xorg fails with "xf86OpenConsole: Cannot open virtual console 7".
cat > "/etc/profile.d/steam-autostart.sh" << 'PROFILEEOF'
# Auto-start X + Steam Big Picture when gamer logs in on tty7
if [ "$(tty)" = "/dev/tty7" ] && [ "$(id -un)" = "gamer" ]; then
    if ! pgrep -x Xorg >/dev/null 2>&1; then
        exec startx -- :0 vt7 -keeptty -novtswitch -sharevts
    fi
fi
PROFILEEOF

# Also create a dedicated systemd service as an alternative approach
cat > /etc/systemd/system/steam-gamescope.service << 'SERVICEEOF'
[Unit]
Description=Steam + Gamescope on TTY7
After=network-online.target
Wants=network-online.target
Conflicts=getty@tty7.service

[Service]
Type=simple
User=gamer
Group=gamer
WorkingDirectory=/home/gamer
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1000
PAMName=login
TTYPath=/dev/tty7
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal
ExecStartPre=/usr/local/bin/preX-populate-input.sh
ExecStart=/usr/bin/startx -- :0 vt7
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
# Enable the service — this takes ownership of TTY7
systemctl enable steam-gamescope.service 2>/dev/null || true
msg_ok "Steam+Gamescope service created and enabled"

# ─────────────────────────────────────────────
# 13. udev rules for GPU access
# ─────────────────────────────────────────────
msg_info "Setting up udev rules for GPU access"
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-gpu-access.rules << 'UDEVEOF'
# Allow render + video group access to GPU devices
SUBSYSTEM=="drm", GROUP="video", MODE="0666"
SUBSYSTEM=="drm", RENDER=="*", GROUP="render", MODE="0666"
KERNEL=="card*", GROUP="video", MODE="0666"
KERNEL=="renderD*", GROUP="render", MODE="0666"
KERNEL=="kfd", GROUP="render", MODE="0666"
UDEVEOF

# Audio: allow audio group access
cat > /etc/udev/rules.d/99-audio-access.rules << 'AUDEVEOF'
KERNEL=="snd*", GROUP="audio", MODE="0666"
AUDEVEOF

# Input: allow input group access
cat > /etc/udev/rules.d/99-input-access.rules << 'INPUTEOF'
KERNEL=="event*", GROUP="input", MODE="0666"
KERNEL=="input/*", GROUP="input", MODE="0666"
INPUTEOF

msg_ok "udev rules configured"

# ─────────────────────────────────────────────
# 14. Polkit rules for gamer user
# ─────────────────────────────────────────────
msg_info "Setting up polkit rules"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq polkitd &>/dev/null || true
mkdir -p /etc/polkit-1/localauthority/50-local.d
cat > /etc/polkit-1/localauthority/50-local.d/allow-gamer.pkla << 'POLKITEOF'
[Allow gamer user all permissions]
Identity=unix-user:gamer
Action=*
ResultAny=yes
ResultInactive=yes
ResultActive=yes
POLKITEOF
msg_ok "Polkit rules configured"

# ─────────────────────────────────────────────
# 15. Clean up
# ─────────────────────────────────────────────
msg_info "Cleaning up"
apt-get autoremove -y &>/dev/null
apt-get autoclean &>/dev/null
msg_ok "Cleaned"

# ─────────────────────────────────────────────
# 16. Start the session
# ─────────────────────────────────────────────
msg_info "Starting Steam+Gamescope session"

# Run input device detection
/usr/local/bin/preX-populate-input.sh 2>/dev/null || true

# Start the service
systemctl start steam-gamescope.service 2>/dev/null || {
    echo -e "${YW}Warning: service did not start. Trying getty autologin approach.${CL}"
    # Enable getty on tty7 with autologin
    systemctl enable getty@tty7.service 2>/dev/null || true
    systemctl start getty@tty7.service 2>/dev/null || true
}

msg_ok "Steam+Gamescope installation complete"
echo ""
echo -e "${GN}════════════════════════════════════════${CL}"
echo -e "${GN} Steam + Gamescope LXC is ready${CL}"
echo -e "${GN}════════════════════════════════════════${CL}"
echo ""
echo -e "  User: ${BGN}gamer${CL} (password: ${BGN}${GAMER_PASS}${CL})"
echo -e "  Steam: ${BGN}${STEAM_BIN:-steam}${CL}"
echo -e "  Gamescope: ${BGN}$(command -v gamescope 2>/dev/null || echo 'not found')${CL}"
echo ""
echo -e "${YW}The session runs on TTY7 and should appear on the display.${CL}"
echo -e "${YW}If the screen is black, check:${CL}"
echo -e "  1. /dev/fb0 and /dev/dri are mounted (lxc config)"
echo -e "  2. Host: chmod 660 /dev/tty7 (for unprivileged container)"
echo -e "  3. systemctl status steam-gamescope"
echo -e "  4. journalctl -u steam-gamescope -f"
echo ""
echo -e "${YW}To restart the session:${CL}"
echo -e "  systemctl restart steam-gamescope"
echo ""