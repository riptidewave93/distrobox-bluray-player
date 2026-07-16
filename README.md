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

See below for options like `--backend makemkv`.

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
play-bluray                                # defaults to /dev/sr0
play-bluray --bluray-device=/dev/sr1 bd://   # override device/URL
```

The wrapper in `~/.local/bin/play-bluray` (ensure it's in PATH) adds the
gpu-next/hwdec render flags plus cache/buffer flags that read ahead so a slow disc
buffers instead of stuttering. It supplies `--bluray-device=/dev/sr0` and `bd://`
if omitted; any other arguments pass through to mpv and override the defaults.

**Rendering:**
- AMD/Intel: `/dev/dri` + Mesa (script passes `--device /dev/dri` and `--group-add video`).
- NVIDIA: auto `--nvidia`; host `nvidia-container-toolkit` recommended.
- distrobox shares the host Wayland/X11 sockets automatically — no extra mounts needed.

## Command-line Options

| Flag                    | Description                                              |
|-------------------------|----------------------------------------------------------|
| `--container-name NAME` | Name of the distrobox (default: `bazzite-bluray`)        |
| `--image IMAGE`         | Container base image                                     |
| `--backend free\|makemkv` | Decryption backend (default: `free`); `makemkv` installs+activates MakeMKV |
| `--setup-keys-only`     | Only (re)download `KEYDB.cfg` on the host                |
| `--force-recreate`      | Remove and recreate the container                        |
| `--help`                | Show help                                                |

Re-running the script is safe and mostly idempotent.

## Backends

### Free (default)
`libaacs` + `libbdplus` + `KEYDB.cfg` (in `~/.config/aacs`).

Update keys: `./setup-bluray-player.sh --setup-keys-only --force-recreate`

> **Standard (1080p) Blu-ray only.** `libaacs` is AACS 1.0; 4K UHD discs use AACS 2.0,
> which it cannot decrypt — the title never starts regardless of KEYDB. UHD requires
> `--backend makemkv` (LibreDrive).

### MakeMKV
Install + activate:
```bash
./setup-bluray-player.sh --backend makemkv
```

Uses `libmmbd` symlink. To disable: remove the symlinks inside container and reinstall libaacs.

## Desktop Integration (optional)
```bash
distrobox-export --app mpv
distrobox-export --app makemkv
```
(Or use DistroShelf.)

## Menus (not supported)

Disc menus (HDMV and BD-J/Java) are **not supported**. mpv only does title
playback — it never drives libbluray's menu mode. Playback skips straight to the
main title, which is fine for most use. Menus do work under VLC with a legacy
JDK; `AGENTS.md` documents that path if we ever switch players.

## Troubleshooting

**Devices not visible**
- Check: `ls /dev/sr* /dev/sg* /dev/dri /dev/nvidia*`
- NVIDIA: script auto uses `--nvidia` (pair with host nvidia-ctk for best results).

**Missing AACS config**
- Check `~/.config/aacs/KEYDB.cfg` (uppercase). Re-run `--setup-keys-only --force-recreate`.

**Title never starts on the free backend**
- 4K UHD disc? Expected — `libaacs` can't do AACS 2.0; use `--backend makemkv`.
- 1080p disc? Refresh KEYDB (`--setup-keys-only --force-recreate`) or use `--backend makemkv`; check the error with `BD_DEBUG_MASK=0x90 mpv -v --bluray-device=/dev/sr0 bd://`.

**MakeMKV needs key / license**
- Script checks/prompts for key during `--backend makemkv`.
- Get key: https://www.makemkv.com/forum2/viewtopic.php?f=5&t=1053
- License pre-accepted on install.

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

**Drive disconnects mid-playback**
`dmesg` shows `hostbyte=DID_ERROR` then `usb ... USB disconnect` (no `Sense Key`/`Medium Error`) — the USB drive is dropping off the bus, not hitting a bad disc. External slim BD drives brown out under load. Fix the power/connection: dual-USB "Y" cable or powered hub, a rear motherboard port (USB 2.0 is fine), a shorter cable, or disable autosuspend (`usbcore.autosuspend=-1`). No buffer setting helps — a disconnected drive has nothing to read.

## Updating

Re-run with desired flags. Use `--force-recreate` for clean container or fresh KEYDB.

## Contributing

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)
(`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, …). See `AGENTS.md` for code
and documentation style.

## Files / Credits

- Container, `~/.config/aacs/KEYDB.cfg`, `~/.local/bin/play-bluray`, MakeMKV build artifacts.

Sources: Arch Wiki (Blu-ray), fvonline-db KEYDB, MakeMKV forum, Bazzite docs.

## Legal

The MIT license covers only this repository's own files — the setup script and
docs. It grants no rights to, and does not alter the license of, the third-party
software the script downloads, builds, or installs (MakeMKV, libaacs/libbdplus,
ffmpeg, KEYDB.cfg, etc.); each keeps its own license and terms. This project
ships none of them and no decryption keys.

Circumventing copy protection is regulated differently by jurisdiction (e.g.
DMCA, EUCD) — complying is your responsibility. Use only with discs you own.

## License

MIT — see [LICENSE](LICENSE). Applies to this repo's code/docs only (see Legal).
