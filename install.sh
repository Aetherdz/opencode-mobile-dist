#!/usr/bin/env bash
# OpenCode Mobile installer for Linux and macOS.
#
# Defaults are deliberately conservative: the bridge listens on loopback, the
# config file is mode 600, and the token is generated locally. `up` displays
# pairing details only in the foreground terminal.
set -euo pipefail

# Write setup diagnostics to a private local log while keeping the terminal clean.
INSTALL_LOG="${TMPDIR:-/tmp}/opencode-install.log"
UI_CURSOR_HIDDEN=0
exec 3>&1
ui_restore_cursor() {
  if (( UI_CURSOR_HIDDEN )); then
    printf '\033[?25h' >&2
    UI_CURSOR_HIDDEN=0
  fi
}
ui_hide_cursor() {
  if [[ -t 1 ]]; then
    printf '\033[?25l' >&2
    UI_CURSOR_HIDDEN=1
  fi
}
ui_arrow() { printf '%s→%s %s%s%s\n' "${UI_CYAN:-}" "${UI_RESET:-}" "${UI_WHITE:-}" "$1" "${UI_RESET:-}" >&3; }
ui_logo() {
  local version="${INSTALLER_VERSION:-0.3.0}"
  printf '%s%s░█▀█░█▀█░█▀▀░█▄░█\n░█░█░█▀▀░█▀▀░█░▀█\n░▀▀▀░▀░░░▀▀▀░▀░░▀\n\n░█▀▀░█▀█░█▀▄░█▀▀\n░█░░░█░█░█░█░█▀▀\n░▀▀▀░▀▀▀░▀▀░░▀▀▀\n\n░█▄█▄█░█▀█░█▀▄░█░█░░░█▀▀\n░█░█░█░█░█░█▀▄░█░█░░░█▀▀\n░▀░▀░▀░▀▀▀░▀▀░░▀░▀▀▀░▀▀▀\n░█▀▄▀█░█▀▀░█▀▄░█▀▀░█░░░█▀▀\n░█░▀░█░█▀▀░█▀▄░█▀▀░█░░░█▀▀\n░▀░░░▀░▀▀▀░▀░▀░▀▀▀░▀▀▀░▀▀▀%s\n' "${UI_BOLD:-}" "${UI_CYAN:-}" "${UI_RESET:-}" >&3
  printf '%sOpenCode Mobile · %s%s\n' "${UI_DIM:-}" "$version" "${UI_RESET:-}" >&3
}

# Bash may pre-buffer piped script input, so it cannot be safely copied back
# from stdin for persistent installation. Require a downloaded, inspectable file.
if [[ "${1:-}" == setup && ( "$0" == bash || "$0" == -bash || ! -f "$0" ) ]]; then
  printf '%s\n' "ERROR: Do not pipe this installer into bash. Download it to a temporary file, then run: bash <file> setup" >&2
  exit 1
fi

# Keep setup UI colors separate from the installer command's existing colors.
UI_CYAN= UI_BLUE= UI_GREEN= UI_RED= UI_YELLOW= UI_DIM= UI_WHITE= UI_BOLD= UI_RESET=
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb && "${NO_COLOR_FLAG:-0}" == 0 ]]; then
  UI_CYAN=$'\033[36m'; UI_BLUE=$'\033[34m'; UI_GREEN=$'\033[32m'
  UI_RED=$'\033[31m'; UI_YELLOW=$'\033[1;33m'; UI_DIM=$'\033[2;37m'
  UI_WHITE=$'\033[37m'; UI_BOLD=$'\033[1m'; UI_RESET=$'\033[0m'
fi

INSTALLER_VERSION="0.3.2"
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
COPY_PAIRING=0
PURGE=0
NO_COLOR_FLAG=0
COMMAND="install"
SETUP_COMMAND=0
TARGET_BRIDGE=1
TARGET_APK=0
SHOW_VERSION=0
QUIET=0
BRIDGE_PID=""
TUNNEL_PID=""
TMP_DIR=""
TAILSCALE_SERVE=0
LOCK_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/opencode-mobile-${UID:-$(id -u)}.lock"
SERVICE_UNIT_NAME="opencode-mobile-bridge.service"
SERVICE_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_UNIT_FILE="$SERVICE_UNIT_DIR/$SERVICE_UNIT_NAME"
TAILSCALE_STATE_FILE="$CONFIG_DIR/tailscale-serve.env"

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

info() { [ "$QUIET" = 1 ] || { [[ "${UI_MINIMAL:-0}" == 1 ]] || printf '%s\n' "${BOLD}›${RESET} $*"; }; }
ok() { [ "$QUIET" = 1 ] || { [[ "${UI_MINIMAL:-0}" == 1 ]] || printf '%s\n' "${GREEN}✓${RESET} $*"; }; }
warn() { [ "$QUIET" = 1 ] || printf '%s\n' "${YELLOW}WARN${RESET} $*" >&2; }
die() {
  trap - ERR
  printf '%s\n' "${RED}ERROR${RESET} $*" >&2
  exit 1
}
step() {
  [ "$QUIET" = 1 ] && return 0
  if [[ "${UI_MINIMAL:-0}" == 1 ]]; then
    case "$*" in
      *Installing*) ui_arrow Installing ;;
      *Downloading*) ui_arrow Downloading ;;
      *Verifying*) ui_arrow Verifying ;;
    esac
  else printf '\n%s\n' "${BOLD}$*${RESET}"; fi
}

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
  up            Start OpenCode and bridge; prefer persistent private Tailscale Serve.
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
  --copy-pairing    Copy the temporary connection URL and QR payload to clipboard when supported.
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
  elif [ -d "$PREFIX/bridge/current/node_modules/qrcode-terminal" ]; then
    # qrcode-terminal is bundled with the checksum-verified bridge release,
    # so QR output works on stock Linux/macOS hosts without a system package.
    printf '%s' "$value" | node -e '
      const qr = require(process.argv[1]);
      let payload = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => { payload += chunk; });
      process.stdin.on("end", () => qr.generate(payload, { small: true }));
    ' "$PREFIX/bridge/current/node_modules/qrcode-terminal"
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
      --copy-pairing|--copy)
        COPY_PAIRING=1
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

download_with_spinner() {
  local url="$1" dest="$2" label pid frame=0 rc
  label="${url##*/}"
  if has_cmd curl; then
    curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "$dest" "$url" >/dev/null 2>&1 &
  else
    wget -q --https-only -O "$dest" "$url" >/dev/null 2>&1 &
  fi
  pid=$!
  local -a frames=('▱▱▱▱' '▰▱▱▱' '▰▰▱▱' '▰▰▰▱' '▰▰▰▰' '▱▰▰▰' '▱▱▰▰' '▱▱▱▰')
  [[ -t 3 ]] && printf '\033[?25l' >&3
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[K%s→ Downloading%s %s %s' "$UI_CYAN" "$UI_RESET" "$label" "${frames[$frame]}" >&3
    frame=$(( (frame + 1) % ${#frames[@]} ))
    sleep 0.12
  done
  if wait "$pid"; then
    [[ -t 3 ]] && printf '\033[?25h' >&3
    printf '\r\033[K%s✓ Downloaded%s %s\n' "$UI_GREEN" "$UI_RESET" "$label" >&3
    return 0
  else
    rc=$?
    [[ -t 3 ]] && printf '\033[?25h' >&3
    printf '\r\033[K%s✗ Download failed%s %s\n' "$UI_RED" "$UI_RESET" "$label" >&3
    return "$rc"
  fi
}

download_file() {
  local url="$1"
  local dest="$2"
  if has_cmd curl; then
    if [ "$QUIET" = 1 ]; then
      curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "$dest" "$url"
    elif [[ "${UI_MINIMAL:-0}" == 1 ]]; then
      if [[ -t 3 ]]; then
        download_with_spinner "$url" "$dest"
      else
        curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "$dest" "$url" >/dev/null 2>&1
      fi
    else
      curl -fL --retry 3 --proto '=https' --tlsv1.2 --progress-bar -o "$dest" "$url"
    fi
  elif has_cmd wget; then
    if [[ "${UI_MINIMAL:-0}" == 1 && -t 3 ]]; then
      download_with_spinner "$url" "$dest"
    else
      wget -q --https-only -O "$dest" "$url"
    fi
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
    # GitHub's /releases/latest endpoint excludes pre-releases, which would
    # leave beta users pinned to an older bridge. The first public release is
    # the newest published release, including pre-releases.
    json="$(fetch_text "https://api.github.com/repos/$REPO/releases?per_page=1")"
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
    if [[ "${UI_MINIMAL:-0}" != 1 ]]; then info "Would ensure workdir exists: $WORKDIR"; fi
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
    if [ "$SETUP_COMMAND" = 1 ] && { [ ! -x "$BIN_DIR/opencode-mobile" ] || [ ! -x "$BIN_DIR/opencode-mobile-bridge" ] || [ ! -d "$PREFIX/bridge/current" ]; }; then
      info "Existing secure config found; completing bridge and command installation."
    fi
    if [ "$DRY_RUN" = 1 ]; then
      info "Would enforce mode 600 on existing config without changing its token/settings"
      return 0
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    ok "Keeping existing config: $CONFIG_FILE"
    if { [ "$COMMAND" != "update" ] && [ "$SETUP_COMMAND" = 0 ]; } || { [ "$SETUP_COMMAND" = 1 ] && [ -x "$BIN_DIR/opencode-mobile" ] && [ -x "$BIN_DIR/opencode-mobile-bridge" ] && [ -d "$PREFIX/bridge/current" ]; }; then
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
  if [[ "${UI_MINIMAL:-0}" != 1 ]]; then info "Using project directory: $WORKDIR (override with --workdir /path)"; fi
  prepare_workdir
}

install_bridge() {
  if [[ "${UI_MINIMAL:-0}" == 1 ]]; then step "Installing"; else step "Installing the bridge"; fi
  check_node
  require_sha_tool
  select_workdir
  if [ -f "$CONFIG_FILE" ] && [ "$DRY_RUN" != 1 ]; then chmod 600 "$CONFIG_FILE" 2>/dev/null || true; fi

  if [ "$COMMAND" != "update" ] && { [ "$SETUP_COMMAND" = 0 ] || { [ -x "$BIN_DIR/opencode-mobile" ] && [ -x "$BIN_DIR/opencode-mobile-bridge" ] && [ -d "$PREFIX/bridge/current" ]; }; } && { [ -d "$PREFIX/bridge/current" ] || { [ "$DRY_RUN" = 1 ] && [ -f "$CONFIG_FILE" ]; }; }; then
    if [ "$DRY_RUN" = 1 ]; then
      if [ "$SETUP_COMMAND" = 1 ]; then
        info "Would keep the installed bridge and repair any missing command launchers"
      else
        info "Existing bridge installation found at $PREFIX/bridge/current"
        info "Would keep the installed bridge and its configuration"
      fi
      return 0
    fi
    if [ "$SETUP_COMMAND" = 1 ]; then
      # Refresh the persisted installer on setup even when the bridge itself is
      # already installed. This is how fixes to quickstart reach existing users.
      persist_installer
      # Repair launchers independently: the bridge can already be present while
      # a user removed just the primary command.
      if [ ! -x "$BIN_DIR/opencode-mobile" ]; then
        mkdir -p "$BIN_DIR"
        cat > "$BIN_DIR/opencode-mobile" <<EOF
#!/usr/bin/env sh
set -eu
exec "$BIN_DIR/opencode-mobile-installer" up "\$@"
EOF
        chmod 755 "$BIN_DIR/opencode-mobile"
      fi
      if [ ! -x "$BIN_DIR/opencode-mobile-bridge" ]; then
        mkdir -p "$BIN_DIR"
        cat > "$BIN_DIR/opencode-mobile-bridge" <<EOF
#!/usr/bin/env sh
set -eu
CONFIG="\${OPENCODE_MOBILE_CONFIG:-$CONFIG_FILE}"
[ -f "\$CONFIG" ] || { echo "Missing config: \$CONFIG" >&2; exit 1; }
set -a
. "\$CONFIG"
set +a
exec node "$PREFIX/bridge/current/dist/index.js" "\$@"
EOF
        chmod 755 "$BIN_DIR/opencode-mobile-bridge"
      fi
      for local_cmd in opencode-mobile-up opencode-mobile-down opencode-mobile-apk; do
        if [ ! -x "$BIN_DIR/$local_cmd" ]; then
          local subcommand="${local_cmd#opencode-mobile-}"
          cat > "$BIN_DIR/$local_cmd" <<EOF
#!/usr/bin/env sh
set -eu
exec "$BIN_DIR/opencode-mobile-installer" $subcommand "\$@"
EOF
          chmod 755 "$BIN_DIR/$local_cmd"
        fi
      done
    fi
    if [[ "${UI_MINIMAL:-0}" != 1 ]]; then ok "Keeping the existing bridge installation"; fi
    if [[ "${UI_MINIMAL:-0}" == 1 && "$COMMAND" != setup ]]; then persist_installer; fi
    return 0
  fi
  if [ -d "$PREFIX/bridge/current" ] && { [ ! -x "$BIN_DIR/opencode-mobile" ] || [ ! -x "$BIN_DIR/opencode-mobile-bridge" ]; }; then
    if [[ "${UI_MINIMAL:-0}" != 1 ]]; then info "Existing bridge archive found; repairing launchers without replacing configuration."; fi
    mkdir -p "$BIN_DIR"
    local installer_copy="$BIN_DIR/opencode-mobile-installer"
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
    persist_installer
    for local_cmd in opencode-mobile opencode-mobile-up opencode-mobile-down opencode-mobile-apk; do
      local subcommand="${local_cmd#opencode-mobile-}"
      if [ "$local_cmd" = opencode-mobile ]; then subcommand="up"; fi
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
    if [ "$SETUP_COMMAND" = 1 ]; then
      info "Would create the opencode-mobile startup command and helper launchers"
      info "Would create or preserve the private pairing configuration"
    fi
    info "Dry run complete. No files were changed."
    return 0
  fi
  persist_installer

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
  if [[ "${UI_MINIMAL:-0}" != 1 ]]; then info "Release: $TAG"; info "Asset: $asset"; fi

  [ -n "$TMP_DIR" ] || TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile.XXXXXX")"
  local archive="$TMP_DIR/$asset"
  download_file "$url" "$archive"
  download_file "$(release_url "SHA256SUMS")" "$TMP_DIR/SHA256SUMS"

  local expected actual
  expected="$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1; exit }' "$TMP_DIR/SHA256SUMS")"
  [ -n "$expected" ] || die "SHA256SUMS does not list $asset"
  actual="$(sha256_of "$archive")"
  [ "$expected" = "$actual" ] || die "Checksum mismatch for $asset"
  if [[ "${UI_MINIMAL:-0}" == 1 ]]; then step "Verifying"; else ok "Checksum verified"; fi

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
  if [[ "${UI_MINIMAL:-0}" != 1 ]]; then ok "Bridge installed at $dest"; fi

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
  if [[ "${UI_MINIMAL:-0}" != 1 ]]; then ok "Launcher: $launcher"; fi

  mkdir -p "$BIN_DIR"
  local installer_copy="$BIN_DIR/opencode-mobile-installer"
  if [[ -n "${OPENCODE_MOBILE_INSTALLER_SOURCE:-}" && "$OPENCODE_MOBILE_INSTALLER_SOURCE" != "$installer_copy" ]] && [ -f "$OPENCODE_MOBILE_INSTALLER_SOURCE" ] && [ -r "$OPENCODE_MOBILE_INSTALLER_SOURCE" ]; then
    cp "$OPENCODE_MOBILE_INSTALLER_SOURCE" "$installer_copy"
    chmod 755 "$installer_copy"
    cp "$OPENCODE_MOBILE_INSTALLER_SOURCE" "$PREFIX/installer"
    chmod 755 "$PREFIX/installer"
  elif [ -f "$0" ] && [ -r "$0" ]; then
    cp "$0" "$installer_copy"
    chmod 755 "$installer_copy"
    cp "$0" "$PREFIX/installer"
    chmod 755 "$PREFIX/installer"
  elif [ -x "$installer_copy" ] && [ -x "$PREFIX/installer" ]; then
    : # The streamed setup path persisted these copies before installing.
  else
    die "Cannot persist the installer required by opencode-mobile. Use the published one-line setup command."
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
exec "$BIN_DIR/opencode-mobile-installer" up "\$@"
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
  if [[ "${UI_MINIMAL:-0}" != 1 ]]; then
    ok "Start the app with: opencode-mobile"
    ok "Management: opencode-mobile down | status | doctor | apk"
  fi
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

  if [[ "${UI_MINIMAL:-0}" != 1 ]]; then printf '\nLatest Android APK (arm64-v8a only):\n  URL:    %s\n  SHA256: %s\n' "$url" "$expected"; fi
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
  # Some terminal wrappers launch the persisted installer with fd 3 closed.
  # Pairing details are deliberately written to this user-visible descriptor;
  # rebind it before any quickstart output so the tunnel can never be left
  # running without showing its URL and token.
  if ! { : >&3; } 2>/dev/null; then exec 3>&1; fi
  check_node
  require_sha_tool
  need_cmd curl
  if [ "$DRY_RUN" = 1 ]; then
    step "Quickstart plan"
    info "Would check the latest bridge release and update an outdated installation"
    info "Would prepare a private mode-600 config and local pairing token"
    info "Would start OpenCode and bridge, prefer private persistent Tailscale Serve, or create a public temporary Quick Tunnel only after explicit consent"
    info "Would print the connection URL/token and render a scannable QR from the bundled renderer"
    [ "$COPY_PAIRING" = 1 ] && info "Would try to copy the QR connection payload to a supported clipboard"
    return 0
  fi

  QUIET=1
  if [[ "${UI_MINIMAL:-0}" == 1 ]]; then QUIET=0; fi
  # A quickstart must not silently reuse an older install that lacks routes
  # used by the app (for example GET /models). Resolve the current published
  # version and refresh only when the installed bridge is outdated; config and
  # its existing AUTH_TOKEN/ALLOWED_WORKDIRS remain untouched.
  local installed_version=""
  if [ -L "$PREFIX/bridge/current" ]; then
    installed_version="$(readlink "$PREFIX/bridge/current" 2>/dev/null || true)"
    installed_version="${installed_version##*/}"
  fi
  resolve_release
  if [ "$installed_version" != "$VERSION_NUM" ]; then
    local original_command="$COMMAND"
    COMMAND=update
    install_bridge
    COMMAND="$original_command"
    # Recycle only this installer's own managed service so it loads the new
    # verified release before the public tunnel is attached.
    if [ -f "$SERVICE_UNIT_FILE" ] &&
      grep -q '^# Managed by OpenCode Mobile installer\.' "$SERVICE_UNIT_FILE" &&
      managed_service_available &&
      systemctl --user is-active --quiet "$SERVICE_UNIT_NAME" 2>/dev/null; then
      systemctl --user restart "$SERVICE_UNIT_NAME" || die "Updated bridge installed, but its managed service could not be restarted."
    fi
  else
    install_bridge
  fi
  QUIET=0
  [ -t 0 ] || die "up requires a terminal to show the local pairing details."
  local answer mode="cloudflare" tailscale_dns=""
  if [[ "$(uname -s)" == Linux ]] && managed_service_available && has_cmd tailscale; then
    tailscale_dns="$( { tailscale status --json 2>/dev/null || true; } | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const x=JSON.parse(s),n=x.Self?.DNSName||"";if(x.BackendState==="Running"&&/^[A-Za-z0-9.-]+\.ts\.net\.?$/.test(n))process.stdout.write(n.replace(/\.$/,""))}catch{}})')"
  fi
  if [ -n "$tailscale_dns" ]; then
    printf 'Use private, persistent Tailscale Serve at https://%s:8443? [Y/n] ' "$tailscale_dns"
    read -r answer || answer=""
    case "$answer" in n|N|no|NO) mode="cloudflare" ;; *) mode="tailscale" ;; esac
  else
    info "Tailscale is not connected; only a temporary public tunnel is available."
  fi
  if [ "$mode" = cloudflare ]; then
    if [[ "${UI_MINIMAL:-0}" == 1 ]]; then
      printf '%sPublic temporary link: URL + code allow agent control. Continue? [y/N] ' "$UI_YELLOW"
    else
      printf 'WARNING: this creates a public temporary URL. Anyone with URL and token can control the agent. Continue? [y/N] '
    fi
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES) ;;
      *)
        if [[ "${UI_MINIMAL:-0}" == 1 ]]; then ui_restore_cursor; fi
        die "No changes made."
        ;;
    esac
  fi
  if [ "$mode" = cloudflare ] && ! has_cmd cloudflared; then
    if [[ "${UI_MINIMAL:-0}" == 1 ]]; then printf 'Download verified cloudflared to your user bin? [Y/n] '; else printf 'cloudflared is missing. Download the official binary, verify its SHA-256, and install it under %s (no sudo)? [Y/n] ' "$BIN_DIR"; fi
    read -r answer || answer=""
    case "$answer" in
      n|N|no|NO)
        if [[ "${UI_MINIMAL:-0}" == 1 ]]; then ui_restore_cursor; fi
        die "Cancelled. Install cloudflared manually, then run opencode-mobile."
        ;;
    esac
    install_cloudflared
  fi
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) PATH="$BIN_DIR:$PATH"; export PATH ;;
  esac
  acquire_lock
  trap 'stop_children; release_lock; cleanup' EXIT
  trap 'exit 130' INT TERM
  if [[ "${UI_MINIMAL:-0}" == 1 ]]; then ui_arrow "Starting OpenCode"; else printf 'Starting OpenCode…\n'; fi
  start_opencode_service
  if [[ "${UI_MINIMAL:-0}" == 1 ]]; then ui_arrow "Starting bridge"; else printf 'Starting bridge…\n'; fi

  local port host token bridge_log tunnel_log tunnel_url connect_url bridge_managed=0
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
    if [ -f "$SERVICE_UNIT_FILE" ] && grep -q '^# Managed by OpenCode Mobile installer\.' "$SERVICE_UNIT_FILE" && managed_service_available && systemctl --user is-active --quiet "$SERVICE_UNIT_NAME" 2>/dev/null; then
      bridge_managed=1
      info "Using the already-running OpenCode Mobile bridge service"
    else
      die "Port $port is already serving. Stop the existing bridge, then rerun quickstart."
    fi
  fi

  [ -n "$TMP_DIR" ] || TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile.XXXXXX")"
  bridge_log="$TMP_DIR/bridge.log"
  tunnel_log="$TMP_DIR/cloudflared.log"
  if [ "$bridge_managed" = 0 ]; then
    "$BIN_DIR/opencode-mobile-bridge" >"$bridge_log" 2>&1 &
    BRIDGE_PID=$!
    printf '%s\n' "$BRIDGE_PID" > "$LOCK_DIR/bridge.pid"
  fi

  local attempt health ready=0 opencode_connected=0
  [ "$bridge_managed" = 1 ] && opencode_connected=1
  for ((attempt = 0; attempt < 45; attempt += 1)); do
    if [ "$bridge_managed" = 0 ] && ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
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
  [ "$ready" = 1 ] || die "OpenCode did not connect. Start 'opencode service start', then rerun 'opencode-mobile'."

  if [ "$mode" = tailscale ]; then
    [ "$bridge_managed" = 1 ] || die "Persistent Tailscale Serve requires the managed systemd --user bridge service. Rerun setup in a Linux user session with systemd available, or choose the temporary tunnel."
    local serve_status
    serve_status="$(tailscale serve status 2>&1 || true)"
    if [ ! -f "$TAILSCALE_STATE_FILE" ] && grep -qE '(:8443|https://[^[:space:]]+:8443)' <<<"$serve_status"; then
      die "Tailscale Serve already uses port 8443 and is not managed by this installer; refusing to replace it."
    fi
    tailscale serve --bg --https=8443 --yes "http://127.0.0.1:$port" || die "Could not configure Tailscale Serve."
    local serve_state_tmp="$TAILSCALE_STATE_FILE.tmp.$$"
    (umask 077; printf 'PORT=%s\n' "$port" > "$serve_state_tmp")
    chmod 600 "$serve_state_tmp"
    mv -f "$serve_state_tmp" "$TAILSCALE_STATE_FILE"
    connect_url="https://$tailscale_dns:8443"
  else
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
  printf '\n%sOpenCode Mobile is ready%s\n' "$UI_GREEN" "$UI_RESET" >&3
  printf '  Bridge URL: %s\n' "$connect_url" >&3
  printf '  Pairing token: %s\n' "$token" >&3
  printf '  QR payload: scanned by OpenCode Mobile to fill URL and token.\n' >&3
  local qr_payload
  qr_payload="$(node -e 'const u=new URL("opencode-mobile://connect");u.searchParams.set("url",process.argv[1]);u.searchParams.set("token",process.argv[2]);process.stdout.write(u.toString())' "$connect_url" "$token")"
  if [[ "${UI_MINIMAL:-0}" == 1 ]]; then
    printf '\nScan this code in OpenCode Mobile:\n' >&3
    if has_cmd qrencode || [ -d "$PREFIX/bridge/current/node_modules/qrcode-terminal" ]; then
      qr_output "$qr_payload" >&3 2>/dev/null || printf '  Could not render QR; enter the URL and pairing token manually.\n' >&3
    else
      printf '  QR unavailable: install qrencode; enter the URL and pairing token shown above manually.\n' >&3
    fi
  else
    printf '\nScan this code in OpenCode Mobile:\n' >&3
    qr_output "$qr_payload" >&3
    if ! has_cmd qrencode && [ ! -d "$PREFIX/bridge/current/node_modules/qrcode-terminal" ]; then printf '  URL and token above can be entered manually.\n' >&3; fi
  fi
  if [ "$COPY_PAIRING" = 1 ]; then
    if has_cmd termux-clipboard-set; then
      printf '%s' "$qr_payload" | termux-clipboard-set && printf '  QR connection data copied to clipboard.\n' >&3
    elif has_cmd pbcopy; then
      printf '%s' "$qr_payload" | pbcopy && printf '  QR connection data copied to clipboard.\n' >&3
    elif has_cmd xclip; then
      printf '%s' "$qr_payload" | xclip -selection clipboard && printf '  QR connection data copied to clipboard.\n' >&3
    elif has_cmd wl-copy; then
      printf '%s' "$qr_payload" | wl-copy && printf '  QR connection data copied to clipboard.\n' >&3
    else
      printf '  Clipboard unavailable: install wl-clipboard, xclip, pbcopy, or termux-api.\n' >&3
    fi
  fi
  unset qr_payload
  unset token
  if [[ "${UI_MINIMAL:-0}" != 1 ]]; then
    printf 'Scan QR or enter URL and token manually.\n'
    if [ "$mode" = cloudflare ]; then printf 'Keep this terminal open; Ctrl+C stops the temporary tunnel.\nThis public temporary URL is not saved and expires when stopped.\n'; fi
  fi

  if [ "$mode" = cloudflare ]; then
    wait "$TUNNEL_PID" || die "Cloudflare Tunnel stopped unexpectedly."
    die "Cloudflare Tunnel stopped unexpectedly."
  fi
  info "Tailscale Serve is persistent and private to your tailnet; the OpenCode Mobile bridge starts at user login when systemd --user is available."
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
  local active=0 service_state="unavailable"
  if [ -f "$SERVICE_UNIT_FILE" ] && grep -q '^# Managed by OpenCode Mobile installer\.' "$SERVICE_UNIT_FILE"; then
    if managed_service_available; then
      service_state="$(systemctl --user is-active "$SERVICE_UNIT_NAME" 2>/dev/null || true)"
      printf 'OpenCode Mobile bridge service: %s\n' "${service_state:-unknown}"
      [ "$service_state" = active ] && active=1
    else
      printf 'OpenCode Mobile bridge service: installed (systemd user manager unavailable)\n'
    fi
  fi
  if [ -f "$TAILSCALE_STATE_FILE" ]; then
    local serve_port serve_status
    serve_port="$(awk -F= '$1 == "PORT" { print $2 }' "$TAILSCALE_STATE_FILE")"
    serve_status="$(tailscale serve status 2>&1 || true)"
    if [ -n "$serve_port" ] && grep -Fq "http://127.0.0.1:$serve_port" <<<"$serve_status"; then
      printf 'Tailscale Serve: active (private HTTPS, port 8443)\n'
    else
      printf 'Tailscale Serve: configured but not active or changed\n'
    fi
  fi
  if [ -d "$LOCK_DIR" ]; then
    local pid
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      local bridge_pid tunnel_pid
      bridge_pid="$(cat "$LOCK_DIR/bridge.pid" 2>/dev/null || true)"
      tunnel_pid="$(cat "$LOCK_DIR/tunnel.pid" 2>/dev/null || true)"
      printf 'OpenCode Mobile: managed session active (bridge %s, tunnel %s)\n' "${bridge_pid:-starting}" "${tunnel_pid:-none/private}"
      active=1
    else
      printf 'OpenCode Mobile: stale lock (pid %s)\n' "${pid:-unknown}"
    fi
  fi
  if [ "$active" = 1 ]; then return 0; fi
  printf 'OpenCode Mobile: stopped\n'
  return 1
}

down() {
  if [ -f "$TAILSCALE_STATE_FILE" ] && ! has_cmd tailscale; then
    die "Tailscale CLI is unavailable; refusing to stop the bridge while leaving an unknown Serve route."
  fi
  local stopped=0
  if [ -f "$TAILSCALE_STATE_FILE" ] && has_cmd tailscale; then
    local serve_port serve_status
    serve_port="$(awk -F= '$1 == "PORT" { print $2 }' "$TAILSCALE_STATE_FILE")"
    case "$serve_port" in *[!0-9]*|'') warn "Invalid managed Tailscale state; leaving Serve configuration untouched."; return 1 ;; esac
    if [ "$serve_port" -lt 1 ] || [ "$serve_port" -gt 65535 ]; then warn "Invalid managed Tailscale port; leaving Serve configuration untouched."; return 1; fi
    serve_status="$(tailscale serve status 2>&1 || true)"
    if grep -Fq "http://127.0.0.1:$serve_port" <<<"$serve_status"; then
      tailscale serve --https=8443 "http://127.0.0.1:$serve_port" off || die "Could not stop the managed Tailscale Serve endpoint."
      rm -f "$TAILSCALE_STATE_FILE"
      info "Stopped the OpenCode Mobile Tailscale Serve endpoint"
      stopped=1
    else
      warn "Tailscale Serve no longer matches the managed bridge target; leaving it untouched and retaining ownership state."
      return 1
    fi
  fi
  if [ -f "$SERVICE_UNIT_FILE" ] && grep -q '^# Managed by OpenCode Mobile installer\.' "$SERVICE_UNIT_FILE"; then
    if has_cmd systemctl && systemctl --user show-environment >/dev/null 2>&1; then
      if systemctl --user is-active --quiet "$SERVICE_UNIT_NAME" 2>/dev/null; then
        systemctl --user stop "$SERVICE_UNIT_NAME" || die "Could not stop the OpenCode Mobile user service."
        info "Stopped OpenCode Mobile bridge service"
        stopped=1
      fi
    fi
  fi
  if [ ! -d "$LOCK_DIR" ]; then
    [ "$stopped" = 1 ] || info "No managed session is running"
    return 0
  fi
  local pid
  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    info "Sent stop signal to managed session $pid"
    # The process cleanup handler stops its children and releases the lock.
    stopped=1
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
  register_mcp
  install_managed_service
  if [ "$DRY_RUN" = 1 ]; then
    info "Dry run complete; no installation was performed."
  elif [[ "${UI_MINIMAL:-0}" == 1 ]]; then
    ui_restore_cursor
    printf '%s→ Installed successfully%s\n' "$UI_GREEN" "$UI_RESET" >&3
    printf '%sRun this to start: %sopencode-mobile%s\n' "$UI_DIM" "$UI_YELLOW" "$UI_RESET" >&3
    printf '%sPair your phone once: %sopencode-mobile --copy-pairing%s\n' "$UI_DIM" "$UI_YELLOW" "$UI_RESET" >&3
    UI_CURSOR_HIDDEN=0
  else
    printf '\nSetup complete. Run: opencode-mobile\n'
  fi
}

systemd_quote() {
  local value="$1"
  case "$value" in *$'\n'*|*$'\r'*) die "Newlines are not allowed in systemd service paths." ;; esac
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '"%s"' "$value"
}

managed_service_available() {
  has_cmd systemctl && systemctl --user show-environment >/dev/null 2>&1
}

install_managed_service() {
  if [ "$DRY_RUN" = 1 ]; then
    info "Would install and enable a systemd user service when systemctl --user is available"
    return 0
  fi
  case "$(uname -s)" in Linux) ;; *) info "Persistent system service is available only on Linux; use the foreground launcher on this platform."; return 0 ;; esac
  if ! managed_service_available; then
    warn "systemd user manager is unavailable; bridge service was not installed. The foreground opencode-mobile command remains available." >&3
    return 0
  fi
  if [ -e "$SERVICE_UNIT_FILE" ] && ! grep -q '^# Managed by OpenCode Mobile installer\.' "$SERVICE_UNIT_FILE"; then
    warn "A non-OpenCode-Mobile unit already exists at $SERVICE_UNIT_FILE; leaving it untouched and using foreground mode."
    return 0
  fi

  local node_bin opencode_bin path_value unit_tmp
  node_bin="$(command -v node)"
  opencode_bin="$(command -v opencode)"
  [ -x "$node_bin" ] && [ -x "$opencode_bin" ] || {
    warn "Could not resolve Node.js/OpenCode executables; persistent service was not installed."
    return 0
  }
  path_value="$BIN_DIR:$PATH"
  mkdir -p "$SERVICE_UNIT_DIR"
  chmod 700 "$SERVICE_UNIT_DIR" 2>/dev/null || true
  unit_tmp="$SERVICE_UNIT_FILE.tmp.$$"
  (
    umask 077
    {
      printf '# Managed by OpenCode Mobile installer. Do not edit.\n'
      printf '[Unit]\nDescription=OpenCode Mobile local bridge\nAfter=default.target\nStartLimitIntervalSec=300\nStartLimitBurst=30\n\n'
      printf '[Service]\nType=simple\n'
      printf 'WorkingDirectory=%s\n' "$(systemd_quote "$WORKDIR")"
      printf 'Environment=HOME=%s\n' "$(systemd_quote "$HOME")"
      printf 'Environment=PATH=%s\n' "$(systemd_quote "$path_value")"
      printf 'ExecStartPre=%s service start\n' "$(systemd_quote "$opencode_bin")"
      printf 'ExecStart=%s\n' "$(systemd_quote "$BIN_DIR/opencode-mobile-bridge")"
      printf 'Restart=on-failure\nRestartSec=10s\nUMask=0077\nNoNewPrivileges=true\n\n'
      printf '[Install]\nWantedBy=default.target\n'
    } > "$unit_tmp"
  ) || { rm -f "$unit_tmp"; warn "Could not write the systemd user unit; using foreground mode."; return 0; }
  chmod 600 "$unit_tmp"
  mv -f "$unit_tmp" "$SERVICE_UNIT_FILE"
  if ! systemctl --user daemon-reload || ! systemctl --user enable --now "$SERVICE_UNIT_NAME"; then
    warn "Could not enable/start the systemd user service; the unit is installed but the foreground launcher remains available." >&3
    return 0
  fi
  ok "Enabled persistent systemd user bridge service"
}

remove_managed_service() {
  [ -f "$SERVICE_UNIT_FILE" ] || return 0
  if ! grep -q '^# Managed by OpenCode Mobile installer\.' "$SERVICE_UNIT_FILE"; then
    warn "Leaving unowned service unit untouched: $SERVICE_UNIT_FILE"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "Would stop, disable, and remove the OpenCode Mobile user service"
    return 0
  fi
  managed_service_available || die "Cannot reach the user service manager; start a user session and retry uninstall so the bridge can be stopped safely."
  if [ -f "$TAILSCALE_STATE_FILE" ]; then
    # Refuse removal if the current Serve route differs from the installer-owned route.
    local serve_port serve_status
    serve_port="$(awk -F= '$1 == "PORT" { print $2 }' "$TAILSCALE_STATE_FILE")"
    case "$serve_port" in *[!0-9]*|'') die "Invalid managed Tailscale state; installation was left intact." ;; esac
    serve_status="$(tailscale serve status 2>&1 || true)"
    printf '%s' "$serve_status" | grep -Fq "http://127.0.0.1:$serve_port" || die "Tailscale Serve route changed; installation was left intact."
    tailscale serve --https=8443 "http://127.0.0.1:$serve_port" off || die "Could not stop managed Tailscale Serve; installation was left intact."
    rm -f "$TAILSCALE_STATE_FILE"
  fi
  systemctl --user disable --now "$SERVICE_UNIT_NAME" >/dev/null 2>&1 || die "Could not stop/disable the OpenCode Mobile user service; installation was left intact."
  systemctl --user daemon-reload >/dev/null 2>&1 || die "Could not reload the user service manager; installation was left intact."
  local wanted_link="$SERVICE_UNIT_DIR/default.target.wants/$SERVICE_UNIT_NAME"
  if [ -L "$wanted_link" ] && [ "$(readlink "$wanted_link" 2>/dev/null || true)" = "../$SERVICE_UNIT_NAME" ]; then
    rm -f "$wanted_link"
  fi
  rm -f "$SERVICE_UNIT_FILE"
  ok "Removed OpenCode Mobile user service unit"
}

register_mcp() {
  if [ "$DRY_RUN" = 1 ]; then
    info "Would register the local opencode-mobile MCP server in the global OpenCode config (without bridge credentials)"
    return 0
  fi
  need_cmd opencode
  [ -x "$BIN_DIR/opencode-mobile-bridge" ] || die "Bridge launcher is missing; cannot register MCP."

  local port
  port="$(awk -F= '$1 == "PORT" { value=$2; gsub(/["[:space:]]/, "", value) } END { print value }' "$CONFIG_FILE")"
  [ -n "$port" ] || port=8787
  case "$port" in *[!0-9]*) die "Invalid bridge PORT; refusing to register MCP." ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "Invalid bridge PORT; refusing to register MCP."

  # Delegate JSON/JSONC editing to the installed OpenCode CLI. The MCP process
  # receives only the non-secret port; it launches directly with Node rather
  # than through the bridge launcher, so bridge.env is never loaded.
  local config_dir config_file entry node_bin
  config_dir="$(opencode debug paths config 2>/dev/null || true)"
  [ -n "$config_dir" ] || config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  entry="$PREFIX/bridge/current/dist/index.js"
  for config_file in "$config_dir/opencode.json" "$config_dir/opencode.jsonc"; do
    [ -f "$config_file" ] || continue
    if grep -Eq '"opencode-mobile"[[:space:]]*:' "$config_file" && ! grep -Fq "\"$entry\"" "$config_file"; then
      warn "The global MCP name opencode-mobile is already used by another command; leaving it untouched. Choose another name before setup to register this integration."
      return 0
    fi
  done
  node_bin="$(command -v node)"
  opencode mcp add --global --env "PORT=$port" opencode-mobile -- "$node_bin" "$entry" mcp
  ok "Registered local OpenCode Mobile MCP server (reload OpenCode to activate it)"
}

unregister_mcp() {
  if [ "$DRY_RUN" = 1 ]; then
    info "Would remove only the OpenCode Mobile-owned MCP entry from OpenCode global config"
    return 0
  fi
  local config_dir="" entry file result
  if has_cmd opencode; then config_dir="$(opencode debug paths config 2>/dev/null || true)"; fi
  [ -n "$config_dir" ] || config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  entry="$PREFIX/bridge/current/dist/index.js"
  for file in "$config_dir/opencode.json" "$config_dir/opencode.jsonc"; do
    [ -f "$file" ] || continue
    result="$(node - "$file" "$entry" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const file = process.argv[2];
const expectedEntry = process.argv[3];
const source = fs.readFileSync(file, 'utf8');
let i = 0;
function trivia() {
  for (;;) {
    while (/\s/.test(source[i] || '')) i++;
    if (source.slice(i, i + 2) === '//') { i += 2; while (i < source.length && source[i] !== '\n') i++; continue; }
    if (source.slice(i, i + 2) === '/*') { const end = source.indexOf('*/', i + 2); if (end < 0) throw Error('unterminated comment'); i = end + 2; continue; }
    return;
  }
}
function string() {
  const start = i++;
  while (i < source.length) {
    if (source[i] === '\\') { i += 2; continue; }
    if (source[i++] === '"') return { value: JSON.parse(source.slice(start, i)), start, end: i };
  }
  throw Error('unterminated string');
}
function value() {
  trivia();
  const start = i;
  if (source[i] === '"') { const s = string(); return { kind: 'string', value: s.value, start, end: i }; }
  if (source[i] === '{') {
    i++; const props = []; trivia();
    while (source[i] !== '}') {
      const key = string(); trivia(); if (source[i++] !== ':') throw Error('expected colon');
      const child = value(); trivia(); let comma = null;
      if (source[i] === ',') { comma = i++; trivia(); }
      props.push({ key: key.value, start: key.start, child, comma });
      if (comma === null && source[i] !== '}') throw Error('expected object delimiter');
    }
    i++; return { kind: 'object', props, start, end: i };
  }
  if (source[i] === '[') {
    i++; const items = []; trivia();
    while (source[i] !== ']') {
      items.push(value()); trivia();
      if (source[i] === ',') { i++; trivia(); } else if (source[i] !== ']') throw Error('expected array delimiter');
    }
    i++; return { kind: 'array', items, start, end: i };
  }
  const match = /^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(source.slice(i));
  if (!match) throw Error('invalid JSONC value');
  i += match[0].length;
  return { kind: 'literal', value: JSON.parse(match[0]), start, end: i };
}
function prop(node, name) { return node?.kind === 'object' ? node.props.find(p => p.key === name)?.child : undefined; }
function plain(node) {
  if (node?.kind === 'string' || node?.kind === 'literal') return node.value;
  if (node?.kind === 'array') return node.items.map(plain);
  if (node?.kind === 'object') return Object.fromEntries(node.props.map(p => [p.key, plain(p.child)]));
  return undefined;
}
try {
  const root = value(); trivia();
  if (i !== source.length || root.kind !== 'object') throw Error('invalid config root');
  const servers = prop(prop(root, 'mcp'), 'servers');
  if (servers?.kind !== 'object') { process.stdout.write('none'); process.exit(0); }
  const matches = servers.props.filter(p => p.key === 'opencode-mobile');
  if (matches.length === 0) { process.stdout.write('none'); process.exit(0); }
  if (matches.length !== 1) throw Error('ambiguous MCP entry');
  const owned = plain(matches[0].child);
  const command = owned?.command;
  if (owned?.type !== 'local' || !Array.isArray(command) || command[1] !== expectedEntry || command.at(-1) !== 'mcp') {
    process.stdout.write('not-owned'); process.exit(0);
  }
  const member = matches[0];
  const index = servers.props.indexOf(member);
  let from = member.start;
  let to = member.child.end;
  if (member.comma !== null) to = member.comma + 1;
  else if (index > 0) from = servers.props[index - 1].comma;
  const updated = source.slice(0, from) + source.slice(to);
  const stat = fs.statSync(file);
  const backup = `${file}.opencode-mobile.bak.${Date.now()}`;
  fs.copyFileSync(file, backup, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(backup, stat.mode & 0o777);
  const temp = path.join(path.dirname(file), `.${path.basename(file)}.tmp.${process.pid}`);
  fs.writeFileSync(temp, updated, { mode: stat.mode & 0o777 });
  fs.chmodSync(temp, stat.mode & 0o777);
  fs.renameSync(temp, file);
  process.stdout.write('removed');
} catch (error) {
  console.error(`Could not safely update OpenCode config: ${error instanceof Error ? error.message : 'parse error'}`);
  process.exit(2);
}
NODE
)" || die "Could not safely remove the owned OpenCode Mobile MCP entry. OpenCode config and installed files were left in place."
    case "$result" in
      removed) ok "Removed OpenCode Mobile MCP entry (backup retained beside OpenCode config)" ;;
      not-owned) warn "The opencode-mobile MCP name is not owned by this installer; leaving it untouched." ;;
    esac
  done
}

persist_installer() {
  local source="${OPENCODE_MOBILE_INSTALLER_SOURCE:-}"
  [ -n "$source" ] || source="$0"
  if [[ "$source" == "$BIN_DIR/opencode-mobile-installer" ]]; then return 0; fi
  [ -r "$source" ] || die "Installer source is no longer readable: $source"
  if [[ "$source" != "$BIN_DIR/opencode-mobile-installer" ]]; then
    mkdir -p "$BIN_DIR" "$PREFIX"
    cp "$source" "$BIN_DIR/opencode-mobile-installer"
    chmod 755 "$BIN_DIR/opencode-mobile-installer"
    cp "$source" "$PREFIX/installer"
    chmod 755 "$PREFIX/installer"
  fi
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
      remove_managed_service
      unregister_mcp
    else
      remove_managed_service
      unregister_mcp
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
  if [[ "$COMMAND" == setup ]]; then
    INSTALL_LOG="${TMPDIR:-/tmp}/opencode-install.log"
    : >"$INSTALL_LOG" 2>/dev/null || true
    UI_MINIMAL=1
    NO_COLOR_FLAG=1
    exec > >(tee -a "$INSTALL_LOG" >/dev/null) 2>&1
    ui_hide_cursor
    ui_logo
    ui_arrow Downloading
    trap 'rc=$?; ui_restore_cursor; if (( rc != 0 )); then printf "%s→ Failed: setup failed%s\nFull log: %s\n" "$UI_RED" "$UI_RESET" "$INSTALL_LOG" >&3; fi; exit "$rc"' EXIT
  elif [[ "${UI_MINIMAL:-0}" == 1 ]]; then
    ui_logo
  fi

  case "$COMMAND" in
    setup)
      if [[ -z "${OPENCODE_MOBILE_INSTALLER_SOURCE:-}" && -f "$0" && -r "$0" ]]; then export OPENCODE_MOBILE_INSTALLER_SOURCE="$0"; fi
      SETUP_COMMAND=1
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
