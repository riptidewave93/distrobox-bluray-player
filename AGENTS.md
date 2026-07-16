# AGENTS.md

Implementation reference for `setup-bluray-player.sh`: architecture, non-obvious
constraints, and the rules that keep the script non-interactive and re-runnable.
User-facing docs live in `README.md` and should stay terse; design rationale and
gotchas belong here.

## Overview

Sets up Blu-ray playback inside a distrobox container on immutable/atomic Fedora
(Bazzite, Bluefin, Aurora, etc.) without modifying the host. A single bash
script, `setup-bluray-player.sh`, is the entire implementation.

Components:
- **mpv** with the `bd://` protocol (via libbluray).
- **Decryption backend**, selected by `--backend`:
  - `free` (default): `libaacs` + `libbdplus` + a downloaded `KEYDB.cfg`.
  - `makemkv`: `libmmbd`, symlinked over the AACS/BD+ libraries.
- GPU + optical drive passthrough for hardware-decoded playback on Wayland.

## Design goals

- Re-runnable and mostly idempotent; running twice is safe.
- No base-OS changes — all packages and the MakeMKV build stay in the container; only user-home helper files are written.
- Non-interactive by default — `--yes`, pre-answered EULA, skippable key prompt.
- Works across AMD/Intel/NVIDIA GPUs.

## Repository layout

```
setup-bluray-player.sh   # entire implementation
README.md                # user-facing quick start (keep terse)
AGENTS.md                # this file
```

The script generates, but does not ship:
- `~/.config/aacs/KEYDB.cfg` (host)
- `~/.local/bin/play-bluray` (host launcher)
- `~/.MakeMKV/settings.conf` (host, when a key is provided)
- `~/makemkv-build/` (in container, transient)

## Architecture

### Host vs. container split

The host handles anything needing real device visibility or user home files:
device detection (`/dev/sr*`, `/dev/sg*`, `/dev/dri`, `/dev/nvidia*`), container
creation, KEYDB download, the `play-bluray` wrapper, the MakeMKV key prompt
(`check_makemkv_key`), and argument parsing.

The container (via `run_in_box`) handles all `dnf`/rpmfusion work, the MakeMKV
build, libmmbd symlinks, and the mpv + libbluray + Mesa install.

### `run_in_box` and quoting

```bash
run_in_box() { distrobox enter "$CONTAINER_NAME" -- bash -c "$1"; }
```

The argument is a single-quoted heredoc-like string. To inject an outer-script
variable, break out of the single quotes with the `'"$VAR"'` concatenation trick:

```bash
curl ... "https://.../makemkv-oss-'"$MAKEMKV_VER"'.tar.gz"
cd "makemkv-oss-'"$MAKEMKV_VER"'"
```

Every `run_in_box` body starts with `set -euo pipefail`. Preserve this quoting
pattern when editing container blocks.

### Backend switching

`--backend makemkv` runs a **separate** `run_in_box` after the build to point the
AACS/BD+ sonames at libmmbd:

```bash
sudo ln -sf "$LIBMMBD" /usr/lib64/libaacs.so.0
sudo ln -sf "$LIBMMBD" /usr/lib64/libbdplus.so.0
```

Switching back to `free` means removing those symlinks and reinstalling the real
libs. `--backend makemkv` is what installs and activates MakeMKV; `free` (the
default) installs neither.

## Configuration

```bash
CONTAINER_NAME="bazzite-bluray"
IMAGE="registry.fedoraproject.org/fedora-toolbox:44"
BACKEND="free"
MAKEMKV_VER="1.18.4"   # must match https://www.makemkv.com/download/
```

`MAKEMKV_VER` is maintained by hand — the website tarballs are not discoverable
programmatically. Pin `IMAGE` to a specific Fedora tag (never `:latest`); a new
major version can break the MakeMKV build step.

## Execution flow

1. Parse args, validate `BACKEND`, check prereqs (`distrobox`, `podman`/`docker`, `curl`).
2. `setup_keys()` — download `KEYDB.cfg`. `--setup-keys-only` exits here.
3. Detect devices → build `--device` flags.
4. Create the container (with `--nvidia` and device flags) if missing.
   `--force-recreate` removes it first.
5. Install core packages (mpv, libbluray stack, Mesa drivers, RPM Fusion ffmpeg).
6. If `--backend makemkv`: build + install MakeMKV (oss then bin), create libmmbd
   symlinks, then `check_makemkv_key()` on host.
7. Write the `play-bluray` wrapper.
8. Print summary.

## Gotchas and rules

- **MakeMKV `cd` globbing:** after extract, `cd` the explicit `makemkv-oss-$VER` dir, never `makemkv-oss-*` — the leftover tarball makes the glob match two paths (`cd: too many arguments`). Use absolute `cd ~/makemkv-build` between the oss and bin builds.
- **MakeMKV EULA:** the bin `make` step (not `make install`) aborts on the EULA prompt; pre-create its marker `tmp/eula_accepted` in the build dir before `make`. Piping `yes` or sed-patching the Makefile are unreliable.
- **Never mask `dnf install` with `|| true`:** install is atomic, so one absent package name fails the whole transaction and the mask hides it (bit us on `gcc-c++`, and on `java-21` which F44 lacks). Pin to packages that exist.
- **Use one ffmpeg:** the player install pulls RPM Fusion full `ffmpeg`, so the MakeMKV build must use `ffmpeg-devel`, not Fedora's `libav*-free-devel` (the `-free` libs conflict with the full `ffmpeg-libs`).
- **Device passthrough:** pass `/dev/dri` as a directory (`--device /dev/dri`); file/by-path forms error with "No such file". NVIDIA nodes are added individually plus host-side `--nvidia` (when `/dev/nvidia0` exists); best results need host `nvidia-container-toolkit`.
- **Wayland passthrough is automatic:** distrobox already shares the host Wayland/X11 sockets and `/run/user/$UID`. Re-mounting them (`--volume /run/user/$UID`, `/tmp/.X11-unix`) makes podman fail with `duplicate mount destination`.
- **No window, audio only:** VO/display problem — pass `--vo=gpu-next --gpu-context=auto --force-window=immediate` (use `auto`, never hardcoded `=wayland`, which hard-fails to audio-only). Isolate with `--vo=wlshm`.
- **Black window, audio plays:** missing HEVC decoder. Fedora's `ffmpeg-free`/`mesa-va-drivers` strip it; install RPM Fusion `ffmpeg ffmpeg-libs` + `mesa-*-freeworld` via `dnf install --allowerasing` (not `swap`, to stay idempotent). mpv logs `Failed to initialize a decoder for codec 'hevc'` even with `--hwdec=no`.
- **`play-bluray` default args:** the wrapper defaults `--bluray-device=/dev/sr0` and `bd://` when the user omits them, and passes everything else through to mpv. The default device is **prepended** (not appended) so it always precedes any `bd://` URL — bd:// fails if the device option comes after it.
- **Read-slowdown buffering:** `bd://` is treated as local, so mpv's cache is off by default and a slow read starves the decoder. The wrapper forces `--cache=yes` (load-bearing — the rest are no-ops without it) plus a large forward buffer and `--cache-pause-*` to rebuffer on underrun. Flags precede the passthrough args so users can override.
- **Drive disconnects mid-playback (USB, not disc):** `dmesg` `hostbyte=DID_ERROR` → `usb ... USB disconnect` → re-enumeration (no `Sense Key`/`Medium Error`) is the drive dropping off the bus, not a read error. External slim BD drives brown out under load — a power/cable/port fix (Y-cable, powered hub, rear/USB-2 port, `usbcore.autosuspend=-1`), not software. Already `usb-storage` (BOT) not UAS, so the `usb-storage.quirks` workaround doesn't apply.
- **Stutter from split-lock throttling (makemkv backend):** repeated `split lock detection: ... bus_lock trap` from a MakeMKV thread means the kernel is throttling it as a penalty — that throttle is the stutter. Host fix `kernel.split_lock_mitigate=0`; stays out of the script (no base-OS changes).
- **`No protocol handler ... bd://`:** libaacs/libbdplus (or their libmmbd replacements) missing, or the disc needs an absent key — makemkv backend + symlinks + valid key is the usual fix.
- **KEYDB.cfg:** host path `~/.config/aacs/KEYDB.cfg` (exact case); from `http://fvonline-db.bplaced.net/fv_download.php?lang=eng`; refresh with `--setup-keys-only --force-recreate`. Newer discs fail with AACS errors until it's updated.
- **MakeMKV key:** `check_makemkv_key()` (host, only under `--backend makemkv`) checks `^app_Key` in `~/.MakeMKV/settings.conf` and prompts; the build pre-creates a skeleton.

## Disc menus (not shipped — VLC + legacy JDK recipe)

Menus are intentionally unsupported. mpv only does title playback and never
drives libbluray's menu mode, so it can't show HDMV or BD-J menus regardless of
Java. The verified path, if we ever want them, is **VLC + a legacy JDK**:

1. **Packages** (in container): `libbluray-bdj libbluray-utils vlc`.
2. **JDK with a working SecurityManager.** BD-J sandboxes disc Java via
   `SecurityManager`, which JDK 24 removed — and F44 ships only JDK 25/latest.
   Use **Temurin JDK 8**: SecurityManager works with no
   `-Djava.security.manager=allow` flag, and it matches the jar exactly
   (`libbluray-*-j2se` is Java 8 bytecode, class version 52). Bundle it
   self-contained in the container:
   ```bash
   curl -fsSL -o /tmp/jdk8.tgz \
     "https://api.adoptium.net/v3/binary/latest/8/ga/linux/x64/jdk/hotspot/normal/eclipse"
   mkdir -p ~/.local/lib/temurin8 && tar -C ~/.local/lib/temurin8 -xf /tmp/jdk8.tgz
   ```
3. **Launch** — point libbluray at the JDK via `JAVA_HOME`, and force VLC audio to
   `pulse` (its native `pipewire` aout in 3.0.x is broken: `sample frequency (0)`
   + stuttering):
   ```bash
   JAVA_HOME=~/.local/lib/temurin8/jdk8u<ver> vlc --aout=pulse bluray:///dev/sr0
   ```
   `BD_DEBUG_MASK=0x90` surfaces BD-J VM logs (`0x80` is the BDJ flag). Verified
   working: video + menus render, audio clean. Would live as a VLC menu launcher
   alongside the mpv title-playback wrapper.

## Diagnostics

```bash
# Manual playback (diagnostics)
distrobox enter bazzite-bluray -- mpv --vo=gpu-next --hwdec=auto \
  --gpu-context=auto --no-terminal bd:// --bluray-device=/dev/sr0

# Inside the container
makemkvcon info disc:0
ls -l /usr/lib64/libaacs*   # should point at libmmbd under the makemkv backend
```

Checklist when playback is broken:
1. Devices visible on host? `ls -l /dev/sr* /dev/dri /dev/nvidia*`
2. Devices visible in container? `distrobox enter ... -- ls -l /dev/sr0 /dev/dri`
3. Correct backend active? `ls -l /usr/lib64/libaacs.so.0`
4. KEYDB present? `ls -l ~/.config/aacs/KEYDB.cfg`
5. MakeMKV key present (makemkv backend)? `grep app_Key ~/.MakeMKV/settings.conf`
6. mpv VO/hwdec flags in use?
7. NVIDIA: host has `nvidia-container-toolkit` and container created with `--nvidia`?

## Testing

- Use `--force-recreate` during development; recreate the container after editing
  device or container-creation logic.
- Test both backends (`--backend free` and `--backend makemkv`).
- Verify the generated `play-bluray` wrapper contains the gpu-next flags.
- Confirm `set -e` actually halts the MakeMKV build on failure — the "complete"
  message must not appear if an earlier step failed.

## Known limitations

- No disc menus (HDMV or BD-J): mpv does title playback only. A VLC + legacy-JDK
  path works if ever needed — see "Disc menus" above.
- **Free backend is AACS 1.0 only — no 4K UHD.** `libaacs` can't decrypt AACS 2.0 (all UHD discs); the title never starts regardless of KEYDB. Architectural, not a bug. UHD needs `--backend makemkv` (LibreDrive). The default `free` means UHD users hit this silently.
- Very new discs may need a fresh MakeMKV beta key or updated KEYDB.
- Assumes an x86_64 Fedora toolbox image.
- `MAKEMKV_VER` must be bumped manually.

## Future ideas

- A `--verify` health-check subcommand (symlinks, key, mpv version, devices).
- Optional cleanup of `~/makemkv-build` after install.
- `.desktop` integration that survives OS updates.
- Custom container image support.

## References

- MakeMKV download / version: https://www.makemkv.com/download/
- MakeMKV free keys: https://www.makemkv.com/forum2/viewtopic.php?f=5&t=1053
- KEYDB source: http://fvonline-db.bplaced.net/
- distrobox: https://distrobox.it/
- Arch Wiki "Blu-ray"

## Contributing & style

- **Comments: minimal and short.** Explain the non-obvious *why* in one line; never narrate what the code already says. Delete a comment before letting it go stale.
- **Docs: no bloat.** `README.md` stays terse and user-facing. `AGENTS.md` holds durable rationale and gotchas as one-line bullets (symptom → cause → rule); expand only when a one-liner genuinely can't carry it. When in doubt, cut.
- **Keep the script non-interactive and re-runnable.** Prefer `--yes`/pre-answered prompts and `install --allowerasing` over `dnf swap`; never mask a real failure with `|| true`.
- **Commit messages:** [Conventional Commits](https://www.conventionalcommits.org) — `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, etc.
- Fixed something non-obvious? Add a bullet to **Gotchas and rules**. Changed user-visible behavior? Update `README.md`.
