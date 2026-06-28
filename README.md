# distrobox-bluray-player

Blu-ray player via distrobox (mpv + optional MakeMKV backend).

- Free backend: libaacs + libbdplus + KEYDB.cfg
- MakeMKV backend: optional, uses libmmbd
- All packages inside container (no base OS changes)

## Quick Start

```bash
git clone https://github.com/riptidewave93/distrobox-bluray-player.git
cd distrobox-bluray-player
chmod +x setup-bluray-player.sh
./setup-bluray-player.sh
```

See below for options like `--with-makemkv --backend makemkv` or `--with-menus`.

## Prerequisites

- Atomic Fedora (Bazzite etc.) with distrobox + podman
- Optical drive + GPU visible on host
- NVIDIA: script auto-passes `--nvidia` to distrobox create if /dev/nvidia0 detected (recommended for Wayland + accel)
- Internet + Blu-ray disc you own

## Usage

Enter container:

```bash
distrobox enter bazzite-bluray
```

### Play a disc

```bash
# Recommended: device option before the URL
distrobox enter bazzite-bluray -- mpv --vo=gpu-next --hwdec=auto --gpu-context=auto --bluray-device=/dev/sr0 bd://
# or use the wrapper (forces a window)
play-bluray --bluray-device=/dev/sr0 bd://
```

The wrapper in `~/.local/bin/play-bluray` (ensure it's in PATH) adds
`--vo=gpu-next --hwdec=auto --gpu-context=auto --force-window=immediate --fs`.

**Rendering:**
- AMD/Intel: `/dev/dri` + Mesa (script passes `--device /dev/dri` and `--group-add video`).
- NVIDIA: auto `--nvidia`; host `nvidia-container-toolkit` recommended.
- distrobox shares the host Wayland/X11 sockets automatically — no extra mounts needed.

## Command-line Options

| Flag                    | Description                                              |
|-------------------------|----------------------------------------------------------|
| `--container-name NAME` | Name of the distrobox (default: `bazzite-bluray`)        |
| `--image IMAGE`         | Container base image                                     |
| `--with-makemkv`        | Install MakeMKV software (does not activate backend)     |
| `--backend free\|makemkv` | Choose decryption backend (default: `free`)            |
| `--with-menus`          | Enable BD-J / Java menu support (default: disabled)      |
| `--setup-keys-only`     | Only (re)download `KEYDB.cfg` on the host                |
| `--force-recreate`      | Remove and recreate the container                        |
| `--help`                | Show help                                                |

Re-running the script is safe and mostly idempotent.

## Backends

### Free (default)
`libaacs` + `libbdplus` + `KEYDB.cfg` (in `~/.config/aacs`).

Update keys: `./setup-bluray-player.sh --setup-keys-only --force-recreate`

### MakeMKV
Install + activate:
```bash
./setup-bluray-player.sh --with-makemkv --backend makemkv
```

Uses `libmmbd` symlink. To disable: remove the symlinks inside container and reinstall libaacs.

Install MakeMKV without activating backend with just `--with-makemkv`.

## Desktop Integration (optional)
```bash
distrobox-export --app mpv
distrobox-export --app makemkv
```
(Or use DistroShelf.)

## Menus (BD-J)

Optional, off by default. Enable with `--with-menus`.

Installs `libbluray-bdj`, `libbluray-utils`, Java 21+ (Java 8 unavailable in F44).

Diagnostics (inside, disc inserted):
```bash
bd_info /dev/sr0
```
Look for `BD-J handled: yes`.

**Limitations**: Experimental in libbluray + mpv. Menus often don't work well. Use MakeMKV backend + rip for better results.

## Troubleshooting

**Devices not visible**
- Check: `ls /dev/sr* /dev/sg* /dev/dri /dev/nvidia*`
- NVIDIA: script auto uses `--nvidia` (pair with host nvidia-ctk for best results).

**Missing AACS config**
- Check `~/.config/aacs/KEYDB.cfg` (uppercase). Re-run `--setup-keys-only --force-recreate`.

**Newer discs fail**
- Update KEYDB or use `--backend makemkv`.

**MakeMKV needs key / license**
- Script checks/prompts for key during `--with-makemkv --backend makemkv`.
- Get key: https://www.makemkv.com/forum2/viewtopic.php?f=5&t=1053
- License pre-accepted on install.

**Menus broken**
- BD-J is experimental in libbluray/mpv. Java 21+ used (no 1.8 in F44).
- Use makemkvcon to rip if needed.

**mpv not found after export**
- Use full `distrobox enter ... -- mpv` or ensure PATH.

**Black video, audio plays**
Missing HEVC codec (Fedora strips it from `ffmpeg-free`/`mesa-va-drivers`). Re-run the setup script, or fix by hand:
```bash
distrobox enter bazzite-bluray -- sudo dnf install -y --allowerasing ffmpeg ffmpeg-libs mesa-va-drivers-freeworld
```

**No window, audio only**
A display/VO issue — run from a desktop session, not ssh. Test the software VO to isolate it:
```bash
distrobox enter bazzite-bluray -- mpv --vo=wlshm --force-window=immediate --idle --no-terminal
```
Window appears → display works, issue is GPU/VO context (try `--vo=x11` under XWayland). No window → check the session, or `nvidia-container-toolkit` on NVIDIA hosts.

## Updating

Re-run with desired flags. Use `--force-recreate` for clean container or fresh KEYDB.

## Files / Credits

- Container, `~/.config/aacs/KEYDB.cfg`, `~/.local/bin/play-bluray`, MakeMKV build artifacts.

Sources: Arch Wiki (Blu-ray), fvonline-db KEYDB, MakeMKV forum, Bazzite docs.

## Legal

This project ships no decryption keys or libraries; it only installs third-party
software (libaacs/libbdplus, MakeMKV, KEYDB.cfg) from their own sources at your
direction. Circumventing copy protection is regulated differently by jurisdiction
(e.g. DMCA, EUCD) — complying is your responsibility. Use only with discs you own.

## License

MIT — see [LICENSE](LICENSE).
