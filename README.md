# Proxmox Steam + Gamescope LXC

A minimal Proxmox LXC container that boots directly into **Steam Big Picture**
via **Gamescope** on TTY7 — no XFCE, no lightdm, no desktop environment.

## Features

- **Debian 13 (Trixie)** base with AMD GPU passthrough (`/dev/dri`, `/dev/kfd`)
- **Steam** from Debian contrib (steam-installer, i386 multilib)
- **Gamescope** 3.16.x from trixie-backports
- **No display manager** — autologin to TTY7, Xinit starts Gamescope directly
- **MangoHud** for optional overlay metrics
- Full audio (`/dev/snd`) and input (`/dev/input`) passthrough
- Unprivileged container with uid/gid idmap for GPU access

## To create a new Steam + Gamescope LXC, run the following in the Proxmox Shell.

```bash
bash -c "$(curl -sL https://raw.githubusercontent.com/kjames2001/proxmox-steam-lxc/main/ct/steam-gamescope.sh)"
```

If Steam is not installed automatically, run in the LXC console:

```bash
bash -c "$(curl -sL https://raw.githubusercontent.com/kjames2001/proxmox-steam-lxc/main/setup/steam-install.sh)"
```

## Architecture

```
Container boots
  → systemd autologin to 'gamer' user on tty7
    → ~/.xinitrc starts gamescope
      → gamescope -e -- steam -gamepadui
```

No XFCE. No lightdm. No session manager. Just Gamescope + Steam.

## Notes

- Requires `trixie-backports` repo for gamescope package
- AMD iGPU shared via bind-mounts; only one container owns the physical display
- For Xorg on TTY7 in unprivileged containers, may need `chmod 660 /dev/tty7` on host

## Troubleshooting

### Xorg: "Cannot run in framebuffer mode" / "Failed to open DRM device for pci:... -19"

On hosts with both an AMD iGPU and a discrete GPU, the firmware may select the
dGPU as the boot VGA device (`dmesg | grep "setting as boot VGA"`). Xorg then
probes the dGPU and gives up. Pin Xorg to the iGPU inside the container:

```
# /etc/X11/xorg.conf.d/20-igpu.conf
Section "Device"
    Identifier "iGPU"
    Driver "amdgpu"
    BusID "PCI:200:0:0"
EndSection
```

`BusID` is **decimal**. Convert the `lspci` address: `c8:00.0` -> `PCI:200:0:0`.
Writing `PCI:0xc8:0x0:0x0` is parsed as bus 0 and fails with "No devices detected".
`setup/steam-install.sh` generates this file automatically.

### glamor: "Refusing to try glamor on llvmpipe"

The container's Mesa is too old for the iGPU (gfx1150 / Radeon 880M/890M needs
Mesa 24.1+). Ubuntu 22.04 ships 23.2 and falls back to software rendering.
Debian 13 (Mesa 25.0) works out of the box.

### Only one container can drive the display

Only one Xorg can be DRM master of `/dev/dri/card0` at a time. Stop the other
display container first (`pct stop <id>`).

### Xorg: "Cannot open virtual console 7 (Permission denied)" from autologin

Check `ls -l /usr/lib/xorg/Xorg.wrap` inside the container. If it is owned by
`100000` rather than `root`, the rootfs was created unprivileged and later
switched to `unprivileged: 0` without shifting ownership, so no setuid binary
(Xorg.wrap, sudo, su) works. Stop the CT, back up the rootfs, loop-mount it,
and shift every uid/gid in 100000-165535 down by 100000.

### Steam: "Timed out waiting for webhelper init", X exits after ~10s

Usually Steam was launched with root's environment (`/run/user/0/bus`).
Launch it only from the gamer's tty7 login (`.xinitrc`), not via
`pct exec ... runuser`. Also avoid starting `steam --install` in the background
from `.xinitrc`; the first-run bootstrap should run in the foreground.