#!/usr/bin/env bash
# OpenCode Mobile installer for Linux and macOS.
#
# Defaults are deliberately conservative: the bridge listens on loopback, the
# config file is mode 600, and the token is generated locally. `up` displays
# pairing details only in the foreground terminal.
set -euo pipefail

INSTALLER_VERSION="0.3.0"
DEFAULT_REPO="Aetherdz/opencode-mobile"
DEFAULT_PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/opencode-mobile"
DEFAULT_BIN_DIR="$HOME/.local/bin"
DEFAULT_WORKDIR="$HOME/projects"
DEFAULT_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode-mobile/data"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode-mobile"
CONFIG_FILE="$CONFIG_DIR/bridge.env"
PACKAGE_ID="com.aetherdz.opencodemobile"

REPO="$DEFAULT_REPO"
PREFIX="$DEFAULT_PREFIX"
BIN_DIR="$DEFAULT_BIN_DIR"
WORKDIR=""
DATA_DIR="$DEFAULT_DATA_DIR"
RELEASE_TAG=""
ADB_SERIAL="${ADB_SERIAL:-}"
DRY_RUN=0
YES=0
PURGE=0
NO_COLOR_FLAG=0
COMMAND="install"
TARGET_BRIDGE=1
TARGET_APK=0
SHOW_VERSION=0
QUIET=0
BRIDGE_PID=""
TUNNEL_PID=""
TMP_DIR=""
TAILSCALE_SERVE=0
LOCK_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/opencode-mobile-${UID:-$(id -u)}.lock"

RED=""
GREEN=""
YELLOW=""
BOLD=""
RESET=""

setup_colors() {
  if [ "$NO_COLOR_FLAG" = 0 ] && [ -z "${NO_COLOR:-}" ] && [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
  fi
}

info() { [ "$QUIET" = 1 ] || printf '%s\n' "${BOLD}::${RESET} $*"; }
ok() { [ "$QUIET" = 1 ] || printf '%s\n' "${GREEN}OK${RESET}  $*"; }
warn() { [ "$QUIET" = 1 ] || printf '%s\n' "${YELLOW}WARN${RESET} $*" >&2; }
die() {
  trap - ERR
  printf '%s\n' "${RED}ERROR${RESET} $*" >&2
  exit 1
}
step() { [ "$QUIET" = 1 ] || printf '\n%s\n' "${BOLD}$*${RESET}"; }

stop_children() {
  local pid
  for pid in "$TUNNEL_PID" "$BRIDGE_PID"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$TUNNEL_PID" "$BRIDGE_PID"; do
    if [ -n "$pid" ]; then wait "$pid" 2>/dev/null || true; fi
  done
  if [ "$TAILSCALE_SERVE" = 1 ] && has_cmd tailscale; then
    tailscale serve reset >/dev/null 2>&1 || true
    TAILSCALE_SERVE=0
  fi
}

cleanup() {
  stop_children
  if [ -d "$LOCK_DIR" ]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    [ "$lock_pid" != "$$" ] || rm -rf "$LOCK_DIR"
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# shellcheck disable=SC2154
trap 'code=$?; trap - ERR; printf "%s\n" "${RED}ERROR${RESET} command failed (exit ${code}): ${BASH_COMMAND}" >&2; exit "$code"' ERR

usage() {
  cat <<'EOF'
OpenCode Mobile installer

Usage:
  install.sh [command] [options]

Commands:
  install       Install the bridge (default) and optionally the Android app.
  setup         Install/configure once; preserves existing token and settings.
  up            Start OpenCode and bridge, then create a temporary public link.
  down          Stop services started by this tool and release its lock.
  status        Show a short local service status.
  apk           Verify and display the latest Android APK URL and SHA-256.
  update        Replace the installed bridge with the latest release.
  doctor        Check dependencies, permissions, and bridge health.
  uninstall     Remove installed files. Add --purge to remove config and data.
  version       Print the installer version.
  help          Show this help.

Targets:
  --bridge      Install or remove the bridge only (default).
  --apk         Install or remove the Android APK only.
  --all         Install or remove both the bridge and the APK.

Options:
  --prefix DIR      Install root. Default: ~/.local/share/opencode-mobile
  --bin-dir DIR     Launcher directory. Default: ~/.local/bin
  --workdir DIR     Directory the bridge may access. Default: ~/projects
  --repo OWNER/REPO Source repository. Default: Aetherdz/opencode-mobile
  --release TAG     Release tag to install. Default: latest release
  --dry-run         Print actions without downloading or writing files.
  --yes             Non-interactive mode (does not bypass public-tunnel consent).
  --no-color        Disable ANSI color.
  --purge           With uninstall, also remove the config and data directory.
  -h, --help        Show this help.
  -V, --version     Print the installer version.

Examples:
  ./install.sh install --workdir "$HOME/code"
  ./install.sh setup --workdir "$HOME/code"
  ./install.sh up
  ./install.sh install --apk
  ./install.sh install --all --dry-run
  ./install.sh doctor
  ./install.sh uninstall --purge

The generated AUTH_TOKEN stays in this config until `up`; only then is it
displayed locally in the foreground for pairing. It is never logged remotely:
  ~/.config/opencode-mobile/bridge.env
EOF
}

qr_output() {
  local value="$1"
  if has_cmd qrencode; then
    printf '%s' "$value" | qrencode -t ANSIUTF8
  else
    printf 'QR code unavailable (install qrencode with your package manager); use the URL and token above.\n'
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
  install|setup|quickstart|up|down|status|apk|update|doctor|uninstall|version|help)
        COMMAND="$1"
        ;;
      --bridge)
        TARGET_BRIDGE=1
        TARGET_APK=0
        ;;
      --apk)
        TARGET_BRIDGE=0
        TARGET_APK=1
        ;;
      --all)
        TARGET_BRIDGE=1
        TARGET_APK=1
        ;;
      --prefix)
        [ "$#" -ge 2 ] || die "--prefix needs a directory"
        PREFIX="$2"
        shift
        ;;
      --bin-dir)
        [ "$#" -ge 2 ] || die "--bin-dir needs a directory"
        BIN_DIR="$2"
        shift
        ;;
      --workdir)
        [ "$#" -ge 2 ] || die "--workdir needs a directory"
        WORKDIR="$2"
        shift
        ;;
      --repo)
        [ "$#" -ge 2 ] || die "--repo needs OWNER/REPO"
        REPO="$2"
        shift
        ;;
      --release)
        [ "$#" -ge 2 ] || die "--release needs a tag"
        RELEASE_TAG="$2"
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --yes)
        YES=1
        ;;
      --no-color)
        NO_COLOR_FLAG=1
        ;;
      --purge)
        PURGE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -V|--version)
        SHOW_VERSION=1
        ;;
      --)
        shift
        break
        ;;
      *)
        die "Unknown argument: $1 (try --help)"
        ;;
    esac
    shift
  done

  CONFIG_FILE="${OPENCODE_MOBILE_CONFIG:-$CONFIG_FILE}"
  CONFIG_DIR="$(dirname "$CONFIG_FILE")"

  if [ "$SHOW_VERSION" = 1 ]; then
    printf 'opencode-mobile-installer %s\n' "$INSTALLER_VERSION"
    exit 0
  fi

  case "$REPO" in
    */*) ;;
    *) die "--repo must look like OWNER/REPO" ;;
  esac
  case "$REPO" in
    *[!A-Za-z0-9_.-]*/*|*/[!A-Za-z0-9_.-]*|*/*/*)
      die "--repo contains invalid characters"
      ;;
  esac

  PREFIX="${PREFIX%/}"
  BIN_DIR="${BIN_DIR%/}"
  case "$PREFIX" in
    ""|"/") die "--prefix cannot be the filesystem root" ;;
    /*) ;;
    *) die "--prefix must be an absolute path" ;;
  esac
  case "$BIN_DIR" in
    ""|"/") die "--bin-dir cannot be the filesystem root" ;;
    /*) ;;
    *) die "--bin-dir must be an absolute path" ;;
  esac
  case "$DATA_DIR" in
    /*) ;;
    *) die "DATA_DIR must be absolute" ;;
  esac
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

fetch_text() {
  if has_cmd curl; then
    curl -fsSL --retry 2 --proto '=https' --tlsv1.2 "$1"
  elif has_cmd wget; then
    wget -q --https-only -O - "$1"
  else
    die "Need curl or wget"
  fi
}

download_file() {
  local url="$1"
  local dest="$2"
  if has_cmd curl; then
    if [ "$QUIET" = 1 ]; then
      curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "$dest" "$url"
    else
      curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$dest" "$url"
    fi
  elif has_cmd wget; then
    wget -q --https-only -O "$dest" "$url"
  else
    die "Need curl or wget"
  fi
}

check_node() {
  need_cmd node
  local major
  major="$(node -p 'process.versions.node.split(".")[0]')"
  case "$major" in
    ''|*[!0-9]*) die "Could not read the Node.js version" ;;
  esac
  [ "$major" -ge 22 ] || die "Node.js 22 or newer is required (found $(node -v))"
}

require_sha_tool() {
  if has_cmd sha256sum || has_cmd shasum; then
    return 0
  fi
  die "Need sha256sum or shasum to verify release checksums"
}

sha256_of() {
  local file="$1"
  if has_cmd sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

resolve_release() {
  if [ -n "$RELEASE_TAG" ]; then
    TAG="$RELEASE_TAG"
  else
    local json
    json="$(fetch_text "https://api.github.com/repos/$REPO/releases/latest")"
    TAG="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  fi
  [ -n "${TAG:-}" ] || die "Could not determine the latest release for $REPO"
  case "$TAG" in
    *[!A-Za-z0-9._-]*) die "Release tag contains invalid characters: $TAG" ;;
  esac
  case "$TAG" in
    v*) VERSION_NUM="${TAG#v}" ;;
    *) TAG="v$TAG"; VERSION_NUM="$TAG" ;;
  esac
  [ -n "$VERSION_NUM" ] || die "Release tag is empty"
}

release_url() {
  local asset="$1"
  printf 'https://github.com/%s/releases/download/%s/%s' "$REPO" "$TAG" "$asset"
}

prepare_workdir() {
  if [ -z "$WORKDIR" ]; then
    WORKDIR="$DEFAULT_WORKDIR"
  fi
  case "$WORKDIR" in
    /*) ;;
    *) die "--workdir must be an absolute path" ;;
  esac
  case "$WORKDIR" in
    *,*) die "--workdir cannot contain a comma" ;;
  esac
  [ "$WORKDIR" != "$HOME" ] || die "Refusing to allow the entire home directory; select a projects folder"
  if [ "$DRY_RUN" = 1 ]; then
    info "Would ensure workdir exists: $WORKDIR"
    return 0
  fi
  mkdir -p "$WORKDIR"
  [ -d "$WORKDIR" ] || die "Workdir does not exist: $WORKDIR"
  WORKDIR="$(cd "$WORKDIR" && pwd -P)"
  [ "$WORKDIR" != "/" ] || die "Refusing to use the filesystem root as the workdir"
}

create_config() {
  if [ -f "$CONFIG_FILE" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "Would enforce mode 600 on existing config without changing its token/settings"
      return 0
    fi
    [ ! -L "$CONFIG_FILE" ] || die "Refusing to follow symlink config: $CONFIG_FILE"
    # Preserve the existing token and bridge settings; only add a missing scoped workdir.
    # shellcheck disable=SC1090
    local existing_host existing_workdir
    existing_host="$(# shellcheck disable=SC1090
      . "$CONFIG_FILE"; printf '%s' "${HOST:-}")"
    existing_workdir="$(# shellcheck disable=SC1090
      . "$CONFIG_FILE"; printf '%s' "${ALLOWED_WORKDIRS:-}")"
    [ "$existing_host" = 127.0.0.1 ] || die "Existing config must use HOST=127.0.0.1; refusing unsafe setup."
    if [ -z "$existing_workdir" ]; then
      [ -n "$WORKDIR" ] || die "Existing config has no ALLOWED_WORKDIRS; rerun setup with --workdir /path/to/projects."
      printf '\nALLOWED_WORKDIRS="%s"\n' "$WORKDIR" >> "$CONFIG_FILE"
    fi
    if [ "$COMMAND" = "setup" ] && { [ ! -x "$BIN_DIR/opencode-mobile" ] || [ ! -x "$BIN_DIR/opencode-mobile-bridge" ] || [ ! -d "$PREFIX/bridge/current" ]; }; then
      info "Existing secure config found; completing bridge and command installation."
    fi
    if [ "$DRY_RUN" = 1 ]; then
      info "Would enforce mode 600 on existing config without changing its token/settings"
      return 0
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    ok "Keeping existing config: $CONFIG_FILE"
    if { [ "$COMMAND" != "update" ] && [ "$COMMAND" != "setup" ]; } || { [ "$COMMAND" = "setup" ] && [ -x "$BIN_DIR/opencode-mobile" ] && [ -x "$BIN_DIR/opencode-mobile-bridge" ] && [ -d "$PREFIX/bridge/current" ]; }; then
      return 0
    fi
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "Would write config: $CONFIG_FILE (mode 600, generated token)"
    return 0
  fi

  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR" 2>/dev/null || true
  if ! has_cmd node; then
    die "Node.js is required to generate the token"
  fi

  local token
  if has_cmd openssl; then
    token="$(openssl rand -hex 32)"
  else
    token="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
  fi
  [ "${#token}" -ge 32 ] || die "Token generation failed"

  umask 077
  cat > "$CONFIG_FILE" <<EOF
# Generated by opencode-mobile-installer. Keep this file private.
PORT=8787
HOST=127.0.0.1
AUTH_TOKEN=$token
ALLOWED_WORKDIRS="$WORKDIR"
DATA_DIR="$DATA_DIR"
LOG_LEVEL=info
PUSH_ENABLED=1
EOF
  chmod 600 "$CONFIG_FILE"
  ok "Wrote config: $CONFIG_FILE"
}

select_workdir() {
  if [ -n "$WORKDIR" ]; then
    prepare_workdir
    return
  fi
  if [ "$DRY_RUN" = 1 ]; then
    WORKDIR="$HOME/projects"
    prepare_workdir
    return
  fi
  local suggested
  suggested="$HOME/projects"
  WORKDIR="$suggested"
  info "Using project directory: $WORKDIR (override with --workdir /path)"
  prepare_workdir
}

install_bridge() {
  step "Installing the bridge"
  check_node
  require_sha_tool
  select_workdir
  if [ -f "$CONFIG_FILE" ] && [ "$DRY_RUN" != 1 ]; then chmod 600 "$CONFIG_FILE" 2>/dev/null || true; fi

  if [ "$COMMAND" != "update" ] && { [ "$COMMAND" != "setup" ] || { [ -x "$BIN_DIR/opencode-mobile" ] && [ -x "$BIN_DIR/opencode-mobile-bridge" ] && [ -d "$PREFIX/bridge/current" ]; }; } && { [ -d "$PREFIX/bridge/current" ] || { [ "$DRY_RUN" = 1 ] && [ -f "$CONFIG_FILE" ]; }; }; then
    if [ "$DRY_RUN" = 1 ]; then
      info "Existing bridge installation found at $PREFIX/bridge/current"
      info "Would keep the installed bridge and its configuration"
      return 0
    fi
    ok "Keeping the existing bridge installation"
    return 0
  fi
  if [ -d "$PREFIX/bridge/current" ] && { [ ! -x "$BIN_DIR/opencode-mobile" ] || [ ! -x "$BIN_DIR/opencode-mobile-bridge" ]; }; then
    info "Existing bridge archive found; repairing launchers without replacing configuration."
    mkdir -p "$BIN_DIR"
    local launcher="$BIN_DIR/opencode-mobile-bridge"
    cat > "$launcher" <<EOF
#!/usr/bin/env sh
set -eu
CONFIG="\${OPENCODE_MOBILE_CONFIG:-$CONFIG_FILE}"
[ -f "\$CONFIG" ] || { echo "Missing config: \$CONFIG" >&2; exit 1; }
set -a
. "\$CONFIG"
set +a
exec node "$PREFIX/bridge/current/dist/index.js" "\$@"
EOF
    chmod 755 "$launcher"
    local installer_copy="$BIN_DIR/opencode-mobile-installer"
    cp "$0" "$installer_copy"; chmod 755 "$installer_copy"
    cp "$0" "$PREFIX/installer"; chmod 755 "$PREFIX/installer"
    for local_cmd in opencode-mobile opencode-mobile-up opencode-mobile-down opencode-mobile-apk; do
      local subcommand="${local_cmd#opencode-mobile-}"
      [ "$local_cmd" = opencode-mobile ] && subcommand=""
      cat > "$BIN_DIR/$local_cmd" <<EOF
#!/usr/bin/env sh
set -eu
exec "$installer_copy" $subcommand "\$@"
EOF
      chmod 755 "$BIN_DIR/$local_cmd"
    done
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "Would resolve the latest release for $REPO"
    info "Would download and verify the bridge archive"
    info "Would install under $PREFIX/bridge/current"
    info "Would create launcher: $BIN_DIR/opencode-mobile-bridge"
    create_config
    info "Dry run complete. No files were changed."
    return 0
  fi

  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:aarch64|Linux:arm64|Darwin:x86_64|Darwin:arm64) ;;
    Linux:*) die "This Linux architecture is not in the published bridge release matrix: $(uname -m)" ;;
    Darwin:*) die "This macOS architecture is not in the published bridge release matrix: $(uname -m)" ;;
    *) die "Bridge installation is supported only on Linux/macOS shells. For Windows, use install.ps1." ;;
  esac

  resolve_release
  local asset="opencode-mobile-bridge-${VERSION_NUM}.tar.gz"
  local url
  url="$(release_url "$asset")"
  info "Release: $TAG"
  info "Asset: $asset"

  [ -n "$TMP_DIR" ] || TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile.XXXXXX")"
  local archive="$TMP_DIR/$asset"
  download_file "$url" "$archive"
  download_file "$(release_url "SHA256SUMS")" "$TMP_DIR/SHA256SUMS"

  local expected actual
  expected="$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1; exit }' "$TMP_DIR/SHA256SUMS")"
  [ -n "$expected" ] || die "SHA256SUMS does not list $asset"
  actual="$(sha256_of "$archive")"
  [ "$expected" = "$actual" ] || die "Checksum mismatch for $asset"
  ok "Checksum verified"

  mkdir -p "$TMP_DIR/unpack"
  tar -xzf "$archive" -C "$TMP_DIR/unpack"
  local src="$TMP_DIR/unpack"
  if [ ! -f "$src/package.json" ]; then
    local first
    first="$(find "$src" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [ -n "$first" ] || die "Bridge archive has an unexpected layout"
    src="$first"
  fi
  [ -f "$src/package.json" ] || die "Bridge archive is missing package.json"
  [ -f "$src/dist/index.js" ] || die "Bridge archive is missing dist/index.js"
  [ -d "$src/node_modules" ] || die "Bridge archive is missing node_modules"

  mkdir -p "$PREFIX/bridge"
  local dest="$PREFIX/bridge/$VERSION_NUM"
  rm -rf "$dest"
  cp -a "$src" "$dest"
  ln -sfn "$VERSION_NUM" "$PREFIX/bridge/current"
  ok "Bridge installed at $dest"

  mkdir -p "$BIN_DIR"
  local launcher="$BIN_DIR/opencode-mobile-bridge"
  cat > "$launcher" <<EOF
#!/usr/bin/env sh
set -eu
CONFIG="\${OPENCODE_MOBILE_CONFIG:-$CONFIG_FILE}"
if [ ! -f "\$CONFIG" ]; then
  echo "Missing config: \$CONFIG" >&2
  exit 1
fi
set -a
. "\$CONFIG"
set +a
exec node "$PREFIX/bridge/current/dist/index.js" "\$@"
EOF
  chmod 755 "$launcher"
  ok "Launcher: $launcher"

  mkdir -p "$BIN_DIR"
  local installer_copy="$BIN_DIR/opencode-mobile-installer"
  if [ -f "$0" ] && [ -r "$0" ]; then
    cp "$0" "$installer_copy"
    chmod 755 "$installer_copy"
    cp "$0" "$PREFIX/installer"
    chmod 755 "$PREFIX/installer"
  else
    die "Cannot persist the installer required by the opencode-mobile command. Run setup from a saved local installer file."
  fi

  local up_launcher="$BIN_DIR/opencode-mobile-up"
  cat > "$up_launcher" <<EOF
#!/usr/bin/env sh
set -eu
exec "$BIN_DIR/opencode-mobile-installer" up "\$@"
EOF
  chmod 755 "$up_launcher"
  cat > "$BIN_DIR/opencode-mobile" <<EOF
#!/usr/bin/env sh
set -eu
exec "$BIN_DIR/opencode-mobile-installer" "\$@"
EOF
  chmod 755 "$BIN_DIR/opencode-mobile"
  local apk_launcher="$BIN_DIR/opencode-mobile-apk"
  cat > "$apk_launcher" <<EOF
#!/usr/bin/env sh
set -eu
exec "$BIN_DIR/opencode-mobile-installer" apk "\$@"
EOF
  chmod 755 "$apk_launcher"
  local down_launcher="$BIN_DIR/opencode-mobile-down"
  cat > "$down_launcher" <<EOF
#!/usr/bin/env sh
set -eu
exec "$BIN_DIR/opencode-mobile-installer" down "\$@"
EOF
  chmod 755 "$down_launcher"

  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR" 2>/dev/null || true
  create_config

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not in PATH. Add it or run $launcher directly." ;;
  esac
  ok "Start the bridge with: opencode-mobile-bridge"
  ok "Run: opencode-mobile up | down | status | doctor | apk"
}

install_apk() {
  step "Installing the Android app"
  if [ "$DRY_RUN" = 1 ]; then
    info "Would resolve the latest release for $REPO"
    info "Would download and verify the APK"
    info "Would display the APK URL and checksum; adb install requires a separate explicit prompt"
    info "Dry run complete. No files were changed."
    return 0
  fi

  resolve_release
  if [ "$(uname -s)" != "Linux" ] || { [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; }; then
    info "The release APK targets Android arm64-v8a only; this host cannot install or emulate it."
  fi
  local asset="opencode-mobile-${VERSION_NUM}.apk"
  local url
  url="$(release_url "$asset")"
  info "Release: $TAG"
  info "Asset: $asset"

  [ -n "$TMP_DIR" ] || TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile.XXXXXX")"
  local apk="$TMP_DIR/$asset"
  download_file "$url" "$apk"
  download_file "$(release_url "SHA256SUMS")" "$TMP_DIR/SHA256SUMS"

  local expected actual
  expected="$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1; exit }' "$TMP_DIR/SHA256SUMS")"
  [ -n "$expected" ] || die "SHA256SUMS does not list $asset"
  actual="$(sha256_of "$apk")"
  [ "$expected" = "$actual" ] || die "Checksum mismatch for $asset"
  ok "Checksum verified"

  printf '\nLatest Android APK (arm64-v8a only):\n  URL:    %s\n  SHA256: %s\n' "$url" "$expected"
  if [ "${INSTALL_APK_WITH_ADB:-0}" = 1 ]; then
    [ "$YES" = 0 ] || die "ADB installation cannot be approved non-interactively; run without --yes and confirm on the terminal."
    need_cmd adb
    [ -t 0 ] || die "ADB installation requires an interactive terminal"
    printf 'Install this APK to the connected device using adb? [y/N] '
    local answer
    read -r answer || answer=""
    case "$answer" in y|Y|yes|YES) ;; *) info "APK verified; not installed."; return 0 ;; esac
    if [ -n "$ADB_SERIAL" ]; then adb -s "$ADB_SERIAL" install -r "$apk"; else adb install -r "$apk"; fi
    ok "APK installed"
  fi
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    need_cmd sudo
    sudo "$@"
  fi
}

install_cloudflared() {
  has_cmd cloudflared && return 0
  local system arch
  system="$(uname -s)"
  arch="$(uname -m)"

  case "$system:$PREFIX:$PATH" in
    Linux:*:*"/com.termux"*|Linux:/data/data/com.termux/*)
      need_cmd pkg
      [ "$YES" = 1 ] || die "Termux requires approval to install cloudflared using pkg. Run again with --yes."
      pkg install -y cloudflared
      ;;
    Linux:*)
      case "$arch" in
        x86_64|amd64) asset="cloudflared-linux-amd64" ;;
        aarch64|arm64) asset="cloudflared-linux-arm64" ;;
        *) die "Unsupported Linux architecture for automatic setup: $arch. See https://developers.cloudflare.com/tunnel/downloads/" ;;
      esac
      [ -n "$TMP_DIR" ] || TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile.XXXXXX")"
      local binary="$TMP_DIR/cloudflared"
      local checksum
      local cloudflared_version
      local release_json
      release_json="$(fetch_text https://api.github.com/repos/cloudflare/cloudflared/releases/latest)"
      cloudflared_version="$(printf '%s' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' | head -n 1)"
      [ -n "$cloudflared_version" ] || die "Could not resolve a cloudflared release version"
      case "$cloudflared_version" in *[!0-9.]*|.*|*..*|*.) die "Invalid cloudflared release version" ;; esac
      checksum="$(printf '%s' "$release_json" | awk -v asset="$asset" '
        /### SHA256 Checksums:/ { in_checksums=1; next }
        in_checksums && $1 == asset ":" { print $2; exit }
      ')"
      case "$checksum" in *[!0-9a-f]*|'') die "No official SHA-256 checksum found for $asset" ;; esac
      [ "${#checksum}" -eq 64 ] || die "Invalid official SHA-256 checksum for $asset"
      download_file "https://github.com/cloudflare/cloudflared/releases/download/$cloudflared_version/$asset" "$binary"
      [ "$(sha256_of "$binary")" = "$checksum" ] || die "cloudflared checksum mismatch; refusing to install the binary"
      chmod 755 "$binary"
      mkdir -p "$BIN_DIR"
      install -m 0755 "$binary" "$BIN_DIR/cloudflared"
      PATH="$BIN_DIR:$PATH"
      export PATH
      ;;
    Darwin:*)
      if has_cmd brew; then
        [ "$YES" = 1 ] || die "Homebrew installation needs approval. Run again with --yes, or install cloudflared manually."
        brew install cloudflared
      else
        [ "$arch" = arm64 ] || [ "$arch" = x86_64 ] || die "Unsupported macOS architecture for cloudflared: $arch"
        local mac_asset mac_binary checksum release_json cloudflared_version
        case "$arch" in arm64) mac_asset=cloudflared-darwin-arm64 ;; x86_64) mac_asset=cloudflared-darwin-amd64 ;; esac
        release_json="$(fetch_text https://api.github.com/repos/cloudflare/cloudflared/releases/latest)"
        cloudflared_version="$(printf '%s' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' | head -n 1)"
        checksum="$(printf '%s' "$release_json" | awk -v asset="$mac_asset" '/### SHA256 Checksums:/ { active=1; next } active && $1 == asset ":" { print $2; exit }')"
        case "$checksum" in *[!0-9a-f]*|'') die "No official SHA-256 checksum for $mac_asset" ;; esac
        [ "${#checksum}" -eq 64 ] || die "Invalid cloudflared checksum"
        [ -n "$TMP_DIR" ] || TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile.XXXXXX")"
        mac_binary="$TMP_DIR/cloudflared"
        download_file "https://github.com/cloudflare/cloudflared/releases/download/$cloudflared_version/$mac_asset" "$mac_binary"
        [ "$(sha256_of "$mac_binary")" = "$checksum" ] || die "cloudflared checksum mismatch"
        mkdir -p "$BIN_DIR"
        install -m 0755 "$mac_binary" "$BIN_DIR/cloudflared"
        PATH="$BIN_DIR:$PATH"; export PATH
      fi
      ;;
    *)
      die "Automatic cloudflared setup is unsupported on this OS. See https://developers.cloudflare.com/tunnel/downloads/"
      ;;
  esac
  has_cmd cloudflared || die "cloudflared did not install successfully."
}

quickstart() {
  check_node
  require_sha_tool
  need_cmd curl
  if [ "$DRY_RUN" = 1 ]; then
    step "Quickstart plan"
    info "Would install and verify the bridge release"
    info "Would prepare a private mode-600 config and local pairing token"
    info "Would start OpenCode and bridge, create a public temporary Quick Tunnel after explicit consent"
    info "Would display a QR when qrencode is present and always print URL plus token locally"
    return 0
  fi

  QUIET=1
  install_bridge
  QUIET=0
  [ -t 0 ] || die "up requires a terminal to show the local pairing details."
  printf 'WARNING: this creates a public temporary URL. Anyone with the URL and token can control the agent, which may allow shell-level actions on the allowed project folders. The URL is not saved and changes on restart. Continue? [y/N] '
  local answer
  read -r answer || answer=""
  case "$answer" in y|Y|yes|YES) ;; *) die "No changes made." ;; esac
  if ! has_cmd cloudflared; then
    printf 'cloudflared is missing. Download the official binary, verify its SHA-256, and install it under %s (no sudo)? [Y/n] ' "$BIN_DIR"
    read -r answer || answer=""
    case "$answer" in n|N|no|NO) die "Cancelled. Install cloudflared manually, then run opencode-mobile up." ;; esac
    install_cloudflared
  fi
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) PATH="$BIN_DIR:$PATH"; export PATH ;;
  esac
  local mode="cloudflare"

  acquire_lock
  trap 'stop_children; release_lock; cleanup' EXIT
  trap 'exit 130' INT TERM
  printf 'Starting OpenCode…\n'
  start_opencode_service
  printf 'Starting bridge…\n'

  local port host token bridge_log tunnel_log tunnel_url connect_url
  port="$(awk -F= '$1 == "PORT" { value=$2 } END { print value }' "$CONFIG_FILE")"
  host="$(awk -F= '$1 == "HOST" { value=$2 } END { print value }' "$CONFIG_FILE")"
  local configured_workdir
  configured_workdir="$(awk -F= '$1 == "ALLOWED_WORKDIRS" { sub(/^[^=]*=/, ""); gsub(/^\"|\"$/, ""); value=$0 } END { print value }' "$CONFIG_FILE")"
  if [ -f "$CONFIG_FILE" ]; then
    if awk -F= '$1 == "OPENCODE_URL" && $2 != "" { found=1 } END { exit !found }' "$CONFIG_FILE"; then
      die "quickstart supports automatic OpenCode discovery only. For OPENCODE_URL credentials, use the standard install and tunnel setup instead."
    fi
  fi
  port="${port:-8787}"
  host="${host:-127.0.0.1}"
  [ "$host" = "127.0.0.1" ] || die "quickstart requires HOST=127.0.0.1 in $CONFIG_FILE"
  [ -n "$configured_workdir" ] || die "ALLOWED_WORKDIRS is empty in $CONFIG_FILE"
  case "$configured_workdir" in *,*) die "quickstart needs exactly one configured workdir; configure the bridge manually for multiple roots." ;; esac
  [ -d "$configured_workdir" ] || die "Configured ALLOWED_WORKDIRS directory does not exist: $configured_workdir"
  configured_workdir="$(cd "$configured_workdir" && pwd -P)"
  [ "$configured_workdir" != "/" ] || die "Refusing to expose the filesystem root as a workdir"
  case "$port" in *[!0-9]*|'') die "PORT in $CONFIG_FILE must be a number" ;; esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    die "PORT in $CONFIG_FILE is outside the valid range"
  fi

  if curl -fsS --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    die "Port $port is already serving. Stop the existing bridge, then rerun quickstart."
  fi

  [ -n "$TMP_DIR" ] || TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile.XXXXXX")"
  bridge_log="$TMP_DIR/bridge.log"
  tunnel_log="$TMP_DIR/cloudflared.log"
  "$BIN_DIR/opencode-mobile-bridge" >"$bridge_log" 2>&1 &
  BRIDGE_PID=$!
  printf '%s\n' "$BRIDGE_PID" > "$LOCK_DIR/bridge.pid"

  local attempt health ready=0 opencode_connected=0
  for ((attempt = 0; attempt < 45; attempt += 1)); do
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      die "Bridge stopped during startup. Start OpenCode and check $CONFIG_FILE."
    fi
    health="$(curl -fsS --max-time 1 "http://127.0.0.1:$port/health" 2>/dev/null || true)"
    if grep -q 'connected to OpenCode' "$bridge_log"; then
      opencode_connected=1
    fi
    if [ "$health" = '{"ok":true}' ] && [ "$opencode_connected" = 1 ]; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "OpenCode did not connect. Start 'opencode service start', then rerun 'opencode-mobile up'."

  if [ "$mode" = cloudflare ]; then
    cloudflared tunnel --url "http://127.0.0.1:$port" >"$tunnel_log" 2>&1 &
    TUNNEL_PID=$!
    printf '%s\n' "$TUNNEL_PID" > "$LOCK_DIR/tunnel.pid"
    for ((attempt = 0; attempt < 45; attempt += 1)); do
      tunnel_url="$(grep -Eo 'https://[[:alnum:]-]+\.trycloudflare\.com' "$tunnel_log" | head -n 1 || true)"
      [ -n "$tunnel_url" ] && break
      if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then die "Cloudflare Tunnel stopped before creating a link."; fi
      sleep 1
    done
    [ -n "$tunnel_url" ] || die "Cloudflare Tunnel did not return a link in time."
    connect_url="$tunnel_url"
  fi

  # Read only the hex token from a non-executed config parser; don't source
  # untrusted config text in the privileged launcher process.
  token="$(awk -F= '$1 == "AUTH_TOKEN" { value=substr($0, index($0, "=") + 1); gsub(/^\"|\"$/, "", value) } END { print value }' "$CONFIG_FILE")"
  [ "${#token}" -ge 32 ] || die "Could not read a valid pairing token from $CONFIG_FILE"
  printf '\nOpenCode Mobile is ready\n'
  printf '  Bridge:  %s\n' "$connect_url"
  printf '  Token:   %s\n' "$token"
  local qr_payload
  qr_payload="$(node -e 'const u=new URL("opencode-mobile://connect");u.searchParams.set("url",process.argv[1]);u.searchParams.set("token",process.argv[2]);process.stdout.write(u.toString())' "$connect_url" "$token")"
  qr_output "$qr_payload"
  if ! has_cmd qrencode; then
    printf '  QR unavailable: install qrencode (or enable it in the installer) to render the code here.\n'
  fi
  unset qr_payload
  unset token
  printf 'Scan QR or enter URL and token manually. Keep this terminal open; Ctrl+C stops the managed bridge/session.\n'
  if [ -n "$tunnel_url" ]; then printf 'This public temporary URL is not saved and expires when stopped.\n'; fi

  wait "$TUNNEL_PID" || die "Cloudflare Tunnel stopped unexpectedly."
  die "Cloudflare Tunnel stopped unexpectedly."
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "Another opencode-mobile session may be running (lock: $LOCK_DIR). Use 'opencode-mobile status' or 'down'; if stale, remove that lock after verifying no bridge/tunnel process remains."
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  printf '%s\n' "$BRIDGE_PID" > "$LOCK_DIR/bridge.pid"
  printf '%s\n' "$TUNNEL_PID" > "$LOCK_DIR/tunnel.pid"
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

start_opencode_service() {
  local service_file="${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json"
  local fallback_service_file="$HOME/.local/state/opencode/service.json"
  local service_url=""
  if [ -f "$service_file" ]; then
    service_url="$(node -e 'try { const x=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(x.url || "") } catch {}' "$service_file")"
  elif [ "$fallback_service_file" != "$service_file" ] && [ -f "$fallback_service_file" ]; then
    service_file="$fallback_service_file"
    service_url="$(node -e 'try { const x=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(x.url || "") } catch {}' "$service_file")"
  fi
  if [ -n "$service_url" ]; then
    local service_password
    service_password="$(node -e 'try { const x=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(x.password || "") } catch {}' "$service_file")"
    [ -n "$service_password" ] || die "OpenCode service metadata is missing its password; refusing to start a duplicate service."
    if [ -n "$service_password" ] && curl -fsS --max-time 2 -u "opencode:$service_password" "${service_url%/}/global/health" >/dev/null 2>&1; then
      info "OpenCode service is already responding"
      return
    fi
  fi
  need_cmd opencode
  info "Starting OpenCode service"
  opencode service start >/dev/null 2>&1 || true
  local i
  for ((i=0; i<20; i++)); do
    if [ -f "$service_file" ]; then
      service_url="$(node -e 'try { const x=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(x.url || "") } catch {}' "$service_file")"
      local service_password
      service_password="$(node -e 'try { const x=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(x.password || "") } catch {}' "$service_file")"
      if [ -n "$service_url" ] && [ -n "$service_password" ] && curl -fsS --max-time 2 -u "opencode:$service_password" "${service_url%/}/global/health" >/dev/null 2>&1; then return 0; fi
    fi
    sleep 1
  done
  die "OpenCode service is not responding. Start it with 'opencode service start' and retry."
}

status() {
  if [ -d "$LOCK_DIR" ]; then
    local pid
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      local bridge_pid tunnel_pid
      bridge_pid="$(cat "$LOCK_DIR/bridge.pid" 2>/dev/null || true)"
      tunnel_pid="$(cat "$LOCK_DIR/tunnel.pid" 2>/dev/null || true)"
      printf 'OpenCode Mobile: managed session active (bridge %s, tunnel %s)\n' "${bridge_pid:-starting}" "${tunnel_pid:-none/private}"
      return 0
    fi
    printf 'OpenCode Mobile: stale lock (pid %s)\n' "${pid:-unknown}"
    return 1
  fi
  printf 'OpenCode Mobile: stopped\n'
}

down() {
  if [ ! -d "$LOCK_DIR" ]; then info "No managed session is running"; return 0; fi
  local pid
  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    info "Sent stop signal to managed session $pid"
    # The process cleanup handler stops its children and releases the lock.
    return 0
  fi
  die "Stale lock found at $LOCK_DIR; verify processes, then remove it manually."
}

apk_info() {
  local previous_target="$TARGET_APK"
  TARGET_APK=1
  install_apk
  TARGET_APK="$previous_target"
}

do_setup() {
  check_node
  need_cmd opencode
  COMMAND="setup"
  install_bridge
  printf '\nSetup complete. Run: opencode-mobile up\n'
}

doctor() {
  step "Doctor"
  local failures=0

  printf 'OS: %s %s\n' "$(uname -s)" "$(uname -m)"
  if has_cmd node; then
    printf 'Node: %s\n' "$(node -v)"
    local major
    major="$(node -p 'process.versions.node.split(".")[0]')"
    if [ "$major" -ge 22 ]; then ok "Node version is supported"; else warn "Node 22 or newer is required"; failures=$((failures + 1)); fi
  else
    warn "Node.js is not installed"
    failures=$((failures + 1))
  fi
  if has_cmd npm; then ok "npm: $(npm -v)"; else warn "npm is not installed"; failures=$((failures + 1)); fi
  if has_cmd curl || has_cmd wget; then ok "Download tool available"; else warn "curl or wget is required"; failures=$((failures + 1)); fi
  if has_cmd sha256sum || has_cmd shasum; then ok "SHA-256 tool available"; else warn "sha256sum or shasum is required"; failures=$((failures + 1)); fi

  if [ -f "$CONFIG_FILE" ]; then
    ok "Config exists: $CONFIG_FILE"
    local perms
    perms="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || true)"
    case "$perms" in
      600|400) ok "Config permissions: $perms" ;;
      "") warn "Could not read config permissions" ;;
      *) warn "Config permissions are $perms; use chmod 600"; failures=$((failures + 1)) ;;
    esac
    local token_length
    token_length="$(
      # shellcheck disable=SC1090
      ( set -a; . "$CONFIG_FILE"; printf '%s' "${AUTH_TOKEN:-}" ) | wc -c | tr -d ' '
    )"
    if [ "${token_length:-0}" -ge 32 ]; then ok "Token length: $token_length characters"; else warn "Token is shorter than 32 characters"; failures=$((failures + 1)); fi
    local configured_host allowed_roots
    # shellcheck disable=SC1090
    configured_host="$(. "$CONFIG_FILE"; printf '%s' "${HOST:-}")"
    # shellcheck disable=SC1090
    allowed_roots="$(. "$CONFIG_FILE"; printf '%s' "${ALLOWED_WORKDIRS:-}")"
    [ "$configured_host" = 127.0.0.1 ] || { warn "HOST must be 127.0.0.1; edit $CONFIG_FILE"; failures=$((failures + 1)); }
    [ -n "$allowed_roots" ] || { warn "ALLOWED_WORKDIRS is missing; run setup and select a project folder"; failures=$((failures + 1)); }
    # shellcheck disable=SC1090
    local config_port
    # shellcheck disable=SC1090
    # shellcheck disable=SC1090
    config_port="$( set -a; . "$CONFIG_FILE"; printf '%s' "${PORT:-8787}" )"
    if has_cmd curl; then
      if curl -fsS --max-time 3 "http://127.0.0.1:${config_port}/health" >/dev/null 2>&1; then
        ok "Bridge health endpoint responds on port $config_port"
      else
        warn "Bridge health endpoint did not respond on port $config_port"
      fi
    fi
  else
    warn "Config not found: $CONFIG_FILE (run install first)"
    failures=$((failures + 1))
  fi

  if [ -x "$BIN_DIR/opencode-mobile-bridge" ]; then
    ok "Launcher exists: $BIN_DIR/opencode-mobile-bridge"
  else
    warn "Launcher not found: $BIN_DIR/opencode-mobile-bridge"
    failures=$((failures + 1))
  fi

  if has_cmd adb; then
    ok "adb: $(adb version | head -n 1)"
  else
    info "adb not installed; APK installation is unavailable"
  fi

  if [ "$failures" -eq 0 ]; then
    ok "No blocking issues found"
    return 0
  fi
  warn "$failures issue(s) found"
  return 1
}

uninstall_all() {
  step "Uninstalling"
  if [ "$TARGET_APK" = 1 ]; then
    if has_cmd adb; then
      if [ "$DRY_RUN" = 1 ]; then
        info "Would run: adb uninstall $PACKAGE_ID"
      else
        if [ -n "$ADB_SERIAL" ]; then
          adb -s "$ADB_SERIAL" uninstall "$PACKAGE_ID" || warn "APK was not installed on this device"
        else
          adb uninstall "$PACKAGE_ID" || warn "APK was not installed on this device"
        fi
      fi
    else
      warn "adb is not installed; skipped APK removal"
    fi
  fi

  if [ "$TARGET_BRIDGE" = 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "Would remove $PREFIX/bridge"
      info "Would remove $BIN_DIR/opencode-mobile-bridge"
      info "Would remove opencode-mobile commands and the installer launcher"
    else
      rm -rf "$PREFIX/bridge"
      rm -f "$BIN_DIR/opencode-mobile-bridge" "$BIN_DIR/opencode-mobile-up" "$BIN_DIR/opencode-mobile-down" "$BIN_DIR/opencode-mobile-apk" "$BIN_DIR/opencode-mobile" "$BIN_DIR/opencode-mobile-installer"
      ok "Removed bridge files"
    fi
  fi

  if [ "$PURGE" = 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "Would remove $CONFIG_DIR"
      info "Would remove $DATA_DIR"
    else
      rm -rf "$CONFIG_DIR" "$DATA_DIR"
      ok "Removed config and data"
    fi
  else
    info "Config and data were kept. Use --purge to remove them."
  fi
}

main() {
  setup_colors
  parse_args "$@"

  case "$COMMAND" in
    setup)
      do_setup
      ;;
    quickstart)
      quickstart
      ;;
    up)
      quickstart
      ;;
    down)
      down
      ;;
    status)
      status
      ;;
    apk)
      apk_info
      ;;
    doctor)
      doctor
      ;;
    install|update)
      if [ "$TARGET_BRIDGE" = 1 ]; then
        install_bridge
      fi
      if [ "$TARGET_APK" = 1 ]; then
        install_apk
      fi
      ;;
    uninstall)
      uninstall_all
      ;;
    version)
      printf 'opencode-mobile-installer %s\n' "$INSTALLER_VERSION"
      ;;
    help)
      usage
      ;;
    *)
      die "Unknown command: $COMMAND"
      ;;
  esac
}

main "$@"
