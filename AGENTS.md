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
- Optional BD-J (Java menu) support via `--with-menus`.
- GPU + optical drive passthrough for hardware-decoded playback on Wayland.

## Design goals

- Re-runnable and mostly idempotent; running twice is safe.
- No host pollution — everything, including the MakeMKV build, happens in the container.
- Non-interactive by default (`|| true` on best-effort installs, pre-answered prompts).
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
libs. `--backend makemkv` without `--with-makemkv` is rejected.

## Configuration

```bash
CONTAINER_NAME="bazzite-bluray"
IMAGE="registry.fedoraproject.org/fedora-toolbox:44"
BACKEND="free"
MAKEMKV_VER="1.18.4"   # must match https://www.makemkv.com/download/
```

`MAKEMKV_VER` is maintained by hand — the website tarballs are not discoverable
programmatically. Pin `IMAGE` to a specific Fedora tag (never `:latest`); a new
major version can break the Java/BD-J and MakeMKV build steps.

## Execution flow

1. Parse args, validate `BACKEND`, check prereqs (`distrobox`, `podman`/`docker`, `curl`).
2. `setup_keys()` — download `KEYDB.cfg`. `--setup-keys-only` exits here.
3. Detect devices → build `--device` flags.
4. Create the container (with `--nvidia` and device flags) if missing.
   `--force-recreate` removes it first.
5. Install core packages (mpv, libbluray stack, Mesa drivers).
6. Optional BD-J / Java (`--with-menus`).
7. If `--with-makemkv`: build + install MakeMKV (oss then bin); if
   `--backend makemkv`, create libmmbd symlinks; then `check_makemkv_key()` on host.
8. Write the `play-bluray` wrapper.
9. Print summary.

## Gotchas and rules

### MakeMKV build: never glob `cd`

`rm -rf` clears old build dirs but `curl` leaves the `.tar.gz` files behind, so a
`makemkv-oss-*` glob matches both the tarball and the extracted directory —
`cd` then gets multiple arguments and fails (`cd: too many arguments`). Always
`cd` into the explicit versioned directory name, and return via an absolute
`cd ~/makemkv-build` between the oss and bin builds.

### MakeMKV EULA: must be fully non-interactive

The `makemkv-bin` EULA prompt (and "Aborting installation") fires during the
plain `make` step for the bin tarball (target `tmp/eula_accepted` around
Makefile:48). It is **not** during `sudo make install`.

Reliable non-interactive method (used by distro packagers):

```bash
cd makemkv-bin-VER
mkdir -p tmp
echo accepted > tmp/eula_accepted
make -j$(nproc)
sudo make install
```

Piping `yes`, touching `/tmp/...`, or `sed`-patching the Makefile are fragile
and do not work reliably (the prompt code may read from `/dev/tty`, the check
is a file existence for `tmp/eula_accepted` in the build dir, and sed strings
drift across versions).

Pre-create the marker file in the build directory **before** `make`. The
`rm -rf` + fresh extract happens on every `--with-makemkv` run, so the marker
is always set for that build.

### Java / BD-J

`java-1.8.0-openjdk` does not exist in Fedora 44 images. BD-J uses Java 21 +
`java-latest-openjdk-headless`, installed only under `--with-menus` with `|| true`
(support is experimental and disc-dependent).

### Device passthrough

Pass `/dev/dri` as a **directory** (`--device /dev/dri`); individual-file or
by-path forms caused "No such file" errors in the container. NVIDIA nodes are
added individually, and the host side also sets `--nvidia` when `/dev/nvidia0`
exists. Best NVIDIA + Wayland results need host-side `nvidia-container-toolkit`.

### Wayland passthrough is automatic

distrobox already shares the host Wayland/X11 sockets and `/run/user/$UID`. Don't
add `--volume /run/user/$UID` or `/tmp/.X11-unix` to `--additional-flags` —
podman fails with `duplicate mount destination`. Keep those flags to devices and
`--group-add video`.

### No window vs. black window — different causes

- **No window, audio only:** VO/display. Pass `--vo=gpu-next --gpu-context=auto
  --force-window=immediate`; use `auto`, not a hardcoded `=wayland` (which
  hard-fails to audio-only when no Wayland context). Isolate with `--vo=wlshm`:
  window appears → passthrough works, issue is GPU/VO context.
- **Window opens, video black, audio plays:** a decoder problem → next item.

### HEVC black video: Fedora codec stripping

Fedora's `ffmpeg-free`/`mesa-va-drivers` omit HEVC/H.265. Most UHD/newer discs
are HEVC, so they play audio with a black window; mpv logs `Failed to initialize
a decoder for codec 'hevc'` even with `--hwdec=no`. Fix (script does this after
enabling RPM Fusion): install the freeworld builds —
`ffmpeg ffmpeg-libs` + `mesa-va-drivers-freeworld`/`mesa-vdpau-drivers-freeworld`.
Use `dnf install --allowerasing`, not `dnf swap`, so re-runs stay idempotent.

### KEYDB.cfg

- Host path: `~/.config/aacs/KEYDB.cfg` (exact case/path matter).
- Source: `http://fvonline-db.bplaced.net/fv_download.php?lang=eng`.
- Extraction searches the zip for a `.cfg`/`*keydb*` file, with fallbacks.
- Refresh: `./setup-bluray-player.sh --setup-keys-only --force-recreate`.

Newer protected discs fail with AACS errors until KEYDB (or MakeMKV) is updated.

### `No protocol handler found to open URL bd://`

Means libaacs/libbdplus (or their libmmbd replacements) are missing, or the disc
needs a key that isn't present. The makemkv backend + symlinks + a valid key is
the usual fix.

### MakeMKV key

`check_makemkv_key()` runs on the host only when `--with-makemkv` is set. It looks
for `^app_Key` in `~/.MakeMKV/settings.conf` and prompts otherwise. The build step
pre-creates a skeleton `settings.conf`. Free monthly beta keys:
https://www.makemkv.com/forum2/viewtopic.php?f=5&t=1053

## Diagnostics

```bash
# Manual playback (diagnostics)
distrobox enter bazzite-bluray -- mpv --vo=gpu-next --hwdec=auto \
  --gpu-context=auto --no-terminal bd:// --bluray-device=/dev/sr0

# Inside the container
bd_info /dev/sr0            # BD-J status
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
- Test both backends (free + KEYDB, and `--with-makemkv --backend makemkv`), and
  with/without `--with-menus`.
- Verify the generated `play-bluray` wrapper contains the gpu-next flags.
- Confirm `set -e` actually halts the MakeMKV build on failure — the "complete"
  message must not appear if an earlier step failed.

## Known limitations

- BD-J / menu support is hit-or-miss even with `--with-menus`.
- Very new discs may need a fresh MakeMKV beta key or updated KEYDB.
- Assumes an x86_64 Fedora toolbox image.
- `MAKEMKV_VER` must be bumped manually.

## Future ideas

- A `--verify` health-check subcommand (symlinks, key, mpv version, `bd_info`).
- Optional cleanup of `~/makemkv-build` after install.
- `.desktop` integration that survives OS updates.
- Custom container image support.

## References

- MakeMKV download / version: https://www.makemkv.com/download/
- MakeMKV free keys: https://www.makemkv.com/forum2/viewtopic.php?f=5&t=1053
- KEYDB source: http://fvonline-db.bplaced.net/
- distrobox: https://distrobox.it/
- Arch Wiki "Blu-ray"

---

When you fix something non-obvious, add it to **Gotchas and rules** with the
symptom, cause, and the rule going forward. Update `README.md` only for
user-visible changes. Don't regress the non-interactive, re-runnable design.
