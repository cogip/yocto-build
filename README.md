# Cogip Yocto Kiosk Image

Yocto-based replacement for `raspios/`: a minimal Wayland kiosk image
for Raspberry Pi 4 that boots straight into Cog (WPE WebKit) displaying
a local web page.

## Stack

- **Base**: Yocto Scarthgap (5.0 LTS, supported until 2028)
- **BSP**: `meta-raspberrypi` (Pi 4 64-bit, KMS/DRM via vc4)
- **Browser**: Cog + WPE WebKit (hardware-accelerated via Mesa V3D)
- **Compositor**: cage (single-app Wayland compositor, ~0.5 MB)
- **Init**: systemd

## Prerequisites

- A Linux host with disk space (~50 GB for the first build)
- [`uv`](https://docs.astral.sh/uv/) (Python tool runner) for the local
  `kas` venv:
  ```sh
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```
- Docker (kas-container runs the build inside the Siemens Yocto image,
  so the host doesn't need chrpath/diffstat/lz4/gcc/etc.):
  ```sh
  sudo apt install docker.io
  sudo usermod -aG docker $USER       # log out / back in
  ```

`make build` materializes a local `.venv/` from `pyproject.toml` +
`uv.lock` automatically on first run, then delegates the actual bitbake
to a containerized Yocto environment (`kas-container`). No system
Python pollution, no host build deps to install. The kas lock file
(`kas-cogip.lock.yml`) pins each layer to a commit SHA for reproducible
builds across machines and CI.

To run kas natively on the host instead of in a container (e.g. for
debugging), pass `USE_CONTAINER=0`:
```sh
make build USE_CONTAINER=0
```
This path requires installing the host Yocto deps manually
(`sudo apt install chrpath diffstat lz4 ...`).

## Build

```sh
cd yocto
make build                           # default KIOSK_URL=http://localhost:8080
make build KIOSK_URL=http://localhost:5000
```

First build pulls poky, meta-openembedded, meta-raspberrypi, meta-browser
(~10-15 minutes on a fast link) then bitbakes the image (45 min - 2 h
depending on cores).

Subsequent builds use sstate-cache and are typically under 5 minutes.

## Flash

```sh
make flash SDCARD_DEV=/dev/sda       # or /dev/mmcblk0
```

Reads `build/tmp/deploy/images/raspberrypi4-64/cogip-kiosk-image-raspberrypi4-64.wic.bz2`
and `dd`s it to the SD card.

## Configure the kiosk URL

The URL is baked into `/usr/bin/cog-kiosk` at image build time via the
`KIOSK_URL` make variable. To change it without a rebuild, edit
`/usr/bin/cog-kiosk` on-target and restart:

```sh
systemctl restart cog-kiosk
```

## Layout

```
yocto/
├── kas-cogip.yml           # kas config: layers, MACHINE, distro, target
├── Makefile                # build / flash helpers
├── meta-cogip/
│   ├── conf/
│   │   ├── layer.conf      # layer metadata
│   │   └── distro/
│   │       └── cogip.conf  # Wayland-only, systemd, image format
│   └── recipes-cogip/
│       ├── images/
│       │   └── cogip-kiosk-image.bb  # image content
│       └── cog-service/
│           ├── cog-service_1.0.bb    # systemd unit recipe
│           └── files/
│               ├── cog-kiosk.service
│               └── cog-kiosk.sh
```

## Boot time

First-iteration target: **< 15 s** to first paint. A later pass will
trim further by:
- Stripping unused kernel modules (currently shipped as a sweep set)
- Replacing systemd with finit or a minimal PID 1 if budget demands it
- Pre-loading the Cog process via systemd socket activation
- Building the Pi 4 firmware with `disable_splash=1` + console silenced

## Differences vs `raspios/`

| Aspect          | `raspios/`                 | `yocto/`                       |
|-----------------|----------------------------|--------------------------------|
| Base            | Debian Bookworm + Docker   | Yocto Scarthgap from source    |
| Browser         | Chromium                   | Cog (WPE WebKit)               |
| Compositor      | LXDE / labwc / X11         | cage (Wayland)                 |
| Reproducibility | Apt versions drift         | Bit-for-bit reproducible       |
| Image size      | ~2 GB                      | < 500 MB target                |
| First boot      | ~30 s                      | target < 15 s, optims later    |

## Status

Bootstrap scaffold. Builds the image but has not yet been booted on
hardware; verification on a Pi 4 + flash + first paint is the next step.
