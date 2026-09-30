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