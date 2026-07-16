#!/bin/bash
#
# Blu-ray player setup (distrobox + mpv + optional MakeMKV).
# Free backend: libaacs + KEYDB. MakeMKV backend: libmmbd.
# No base OS changes.

set -euo pipefail

# Defaults
CONTAINER_NAME="bazzite-bluray"
IMAGE="registry.fedoraproject.org/fedora-toolbox:44"
BACKEND="free"
SETUP_KEYS_ONLY=false
FORCE_RECREATE=false
MAKEMKV_VER="1.18.4" # Update as needed from https://www.makemkv.com/download/ or forum

# Helpers
print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --container-name NAME   (default: $CONTAINER_NAME)
  --image IMAGE           (default: $IMAGE)
  --backend free|makemkv  (default: free; makemkv installs+activates MakeMKV)
  --setup-keys-only       Refresh KEYDB only
  --force-recreate        Nuke container
  --help

Re-run is safe/idempotent. makemkv backend checks ~/.MakeMKV/settings.conf for key.
EOF
}

log() {
  echo "[setup-bluray] $*"
}

die() {
  echo "[setup-bluray] ERROR: $*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

check_makemkv_key() {
  local settings="$HOME/.MakeMKV/settings.conf"
  mkdir -p "$(dirname "$settings")"

  if [[ -f "$settings" ]] && grep -q '^app_Key' "$settings" 2>/dev/null; then
    log "MakeMKV key found."
    return
  fi
  log "No MakeMKV key in $settings. Get one from https://www.makemkv.com/forum2/viewtopic.php?f=5&t=1053"
  read -r -p "Paste key now (or Enter to skip): " key || true
  if [[ -n "$key" ]]; then
    echo "app_Key = \"$key\"" >> "$settings"
    log "Key saved."
  fi
}

# Arg parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container-name)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --backend)
      BACKEND="$2"
      shift 2
      ;;
    --setup-keys-only)
      SETUP_KEYS_ONLY=true
      shift
      ;;
    --force-recreate)
      FORCE_RECREATE=true
      shift
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    *)
      die "Unknown argument: $1. Use --help for usage."
      ;;
  esac
done

# Validate backend
case "$BACKEND" in
  free|makemkv) ;;
  *) die "Invalid --backend value: '$BACKEND' (use free or makemkv)" ;;
esac

# Prereqs
command_exists distrobox || die "distrobox required"
command_exists podman || command_exists docker || die "podman/docker required"
[[ "$SETUP_KEYS_ONLY" == "true" ]] || command_exists curl || die "curl required"

# Device detection
detect_devices() {
  local devices=""
  shopt -s nullglob
  for dev in /dev/sr* /dev/sg*; do [[ -e "$dev" ]] && devices+=" --device $dev"; done
  [[ -d /dev/dri ]] && devices+=" --device /dev/dri"      # AMD/Intel
  for dev in /dev/nvidia*; do [[ -e "$dev" ]] && devices+=" --device $dev"; done  # NVIDIA (script also adds --nvidia)
  shopt -u nullglob
  echo "$devices"
}

DEVICES=$(detect_devices)
[[ -z "$DEVICES" && "$SETUP_KEYS_ONLY" != "true" ]] && log "WARNING: no optical or GPU devices found"

# Warn only on real access failure (-r/-w honors logind ACLs, not bare group
# membership). Check /dev/sr* only; its optical sg sibling shares the same access.
check_device_access() {
  local groups="" dev g
  shopt -s nullglob
  for dev in /dev/sr*; do
    [[ -e "$dev" && ! ( -r "$dev" && -w "$dev" ) ]] || continue
    g=$(stat -c '%G' "$dev")
    [[ " $groups " == *" $g "* ]] || groups+=" $g"
  done
  shopt -u nullglob
  groups="${groups# }"
  [[ -z "$groups" ]] && return 0
  log "WARNING: no access to optical device(s); add your user to group(s): $groups"
  log "  sudo usermod -aG ${groups// /,} $USER   # then log out and back in"
}
check_device_access

GUI_FLAGS=""
if [[ -d /dev/dri ]]; then
  GUI_FLAGS=" --group-add video"  # helps dri access for video decode/render on AMD/Intel
fi

setup_keys() {
  local aacs_dir="${HOME}/.config/aacs"
  local keydb_path="${aacs_dir}/KEYDB.cfg"

  mkdir -p "$aacs_dir"

  if [[ -f "$keydb_path" && "$FORCE_RECREATE" != "true" ]]; then
    log "KEYDB exists, skipping"
    return 0
  fi

  log "Downloading KEYDB..."

  local tmp_zip="/tmp/keydb_$$.zip"
  local tmp_dir="/tmp/keydb_extract_$$"

  if ! curl -fL --progress-bar -o "$tmp_zip" \
       "http://fvonline-db.bplaced.net/fv_download.php?lang=eng"; then
    die "Failed to download KEYDB from fvonline-db. Check network or try again later."
  fi

  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  if unzip -o "$tmp_zip" -d "$tmp_dir" >/dev/null 2>&1; then
    # Find any .cfg file (usually keydb.cfg)
    local found
    found=$(find "$tmp_dir" -type f \( -iname "*.cfg" -o -iname "*keydb*" \) | head -n1 || true)
    if [[ -n "$found" ]]; then
      cp "$found" "$keydb_path"
    else
      # Fallback: try to extract first file that looks right
      unzip -p "$tmp_zip" | head -c 100 > /dev/null && \
        unzip -p "$tmp_zip" > "$keydb_path" || \
        die "Could not locate KEYDB.cfg inside archive"
    fi
  else
    # Some downloads may not be zip in future; try direct
    log "Unzip failed..."
    cp "$tmp_zip" "$keydb_path" 2>/dev/null || die "KEYDB extract failed"
  fi

  rm -rf "$tmp_zip" "$tmp_dir"
  chmod 644 "$keydb_path" || true
  log "KEYDB at $keydb_path"
}

[[ "$SETUP_KEYS_ONLY" == "true" ]] && { setup_keys; exit 0; }

setup_keys

# Container
container_exists() {
  distrobox list --no-color 2>/dev/null | grep -q "$CONTAINER_NAME"
}

if [[ "$FORCE_RECREATE" == "true" ]] && container_exists; then
  distrobox stop "$CONTAINER_NAME" --yes 2>/dev/null || true
  distrobox rm -f "$CONTAINER_NAME" || true
fi

if ! container_exists; then
  # distrobox already shares the Wayland/X11 sockets and /run/user/$UID; don't
  # re-mount them or podman errors with "duplicate mount destination".
  create_args=(--image "$IMAGE" --name "$CONTAINER_NAME" --yes)
  [[ -e /dev/nvidia0 ]] && create_args=(--nvidia "${create_args[@]}")
  additional="${DEVICES}${GUI_FLAGS}"
  [[ -n "${additional// }" ]] && create_args+=(--additional-flags "${additional# }")
  distrobox create "${create_args[@]}"
fi
sleep 1

run_in_box() { distrobox enter "$CONTAINER_NAME" -- bash -c "$1"; }

run_in_box '
  set -euo pipefail
  sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
  sudo dnf update -y
'

run_in_box '
  set -euo pipefail
  sudo dnf install -y mpv libbluray libaacs libbdplus \
    mesa-dri-drivers mesa-vulkan-drivers libva vulkan-loader \
    mesa-libGL mesa-libEGL libglvnd libglvnd-glx ffmpeg ffmpeg-libs \
    mesa-va-drivers-freeworld mesa-vulkan-drivers-freeworld
'

if [[ "$BACKEND" == "makemkv" ]]; then
  log "Installing MakeMKV..."
  run_in_box '
    set -euo pipefail
    sudo dnf install -y expat-devel ffmpeg-devel qt5-qtbase-gui qt5-qtbase-devel zlib-devel openssl-devel make gcc gcc-c++ pkg-config libcurl-devel
    mkdir -p ~/makemkv-build && cd ~/makemkv-build
    rm -rf makemkv-oss-* makemkv-bin-*
    curl -fL -O "https://www.makemkv.com/download/makemkv-oss-'"$MAKEMKV_VER"'.tar.gz"
    curl -fL -O "https://www.makemkv.com/download/makemkv-bin-'"$MAKEMKV_VER"'.tar.gz"
    tar xf "makemkv-oss-'"$MAKEMKV_VER"'.tar.gz"
    cd "makemkv-oss-'"$MAKEMKV_VER"'"
    ./configure
    make -j$(nproc)
    sudo make install
    cd ~/makemkv-build
    tar xf "makemkv-bin-'"$MAKEMKV_VER"'.tar.gz"
    cd "makemkv-bin-'"$MAKEMKV_VER"'"
    # The bin Makefile aborts on an interactive EULA prompt; pre-creating its
    # marker accepts it non-interactively (reliable where piping yes is not).
    mkdir -p tmp
    echo accepted > tmp/eula_accepted
    make -j$(nproc)
    mkdir -p tmp && echo accepted > tmp/eula_accepted
    sudo make install
    echo "MakeMKV build complete."
    mkdir -p ~/.MakeMKV
    [ -f ~/.MakeMKV/settings.conf ] || echo "[app]" > ~/.MakeMKV/settings.conf
  '
  run_in_box '
    set -euo pipefail
    LIBMMBD=$(find /usr -name "libmmbd.so.0*" 2>/dev/null | head -1)
    if [[ -n "$LIBMMBD" ]]; then
      sudo ln -sf "$LIBMMBD" /usr/lib64/libaacs.so.0
      sudo ln -sf "$LIBMMBD" /usr/lib64/libbdplus.so.0
    fi
    true  # ensure this run_in_box always exits 0 under set -e
  '
  check_makemkv_key
fi

# Launcher
LAUNCHER_DIR="${HOME}/.local/bin"
LAUNCHER_PATH="${LAUNCHER_DIR}/play-bluray"
mkdir -p "$LAUNCHER_DIR"

cat > "$LAUNCHER_PATH" <<'LAUNCHER_EOF'
#!/bin/bash
CONTAINER="__CONTAINER_NAME__"
DEFAULT_DEVICE="/dev/sr0"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[[ -n "$WAYLAND_DISPLAY" ]] && export WAYLAND_DISPLAY

# Default --bluray-device=DEV and a bd:// URL if the user omits; pass
# everything else straight through to mpv. The default device is prepended
# so it always precedes the URL, which bd:// requires.
have_device=false
have_url=false
passthrough=()
for arg in "$@"; do
  case "$arg" in
    --bluray-device=*|--bluray-device) have_device=true ;;
    bd://*) have_url=true ;;
  esac
  passthrough+=("$arg")
done

mpv_args=()
$have_device || mpv_args+=("--bluray-device=$DEFAULT_DEVICE")
mpv_args+=("${passthrough[@]}")
$have_url || mpv_args+=("bd://")

# Cache/buffer flags absorb optical-read slowdowns: bd:// is treated as local
# so the cache is off by default. Force it on with a large read-ahead buffer,
# and if it still underruns, pause and rebuild a cushion instead of stuttering.
exec distrobox enter "$CONTAINER" -- mpv \
  --vo=gpu-next \
  --hwdec=auto \
  --gpu-context=auto \
  --no-terminal \
  --audio-device=auto \
  --force-window=immediate \
  --fs \
  --cache=yes \
  --demuxer-max-bytes=1GiB \
  --demuxer-max-back-bytes=256MiB \
  --demuxer-readahead-secs=300 \
  --cache-pause=yes \
  --cache-pause-wait=3 \
  --cache-pause-initial=yes \
  "${mpv_args[@]}"
LAUNCHER_EOF

sed -i "s|__CONTAINER_NAME__|$CONTAINER_NAME|g" "$LAUNCHER_PATH"
chmod +x "$LAUNCHER_PATH"

log "Setup complete!"
cat <<EOF
Container: ${CONTAINER_NAME} (image: $IMAGE)
Backend: $BACKEND
KEYDB: ~/.config/aacs/KEYDB.cfg

Enter: distrobox enter $CONTAINER_NAME
Play:  play-bluray                              # defaults to --bluray-device=/dev/sr0 bd://
       play-bluray --bluray-device=/dev/sr1 bd://   # override device/URL; extra args pass to mpv

Re-run with flags to update. --force-recreate for clean slate.
EOF
log "Done."
