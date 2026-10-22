#!/usr/bin/env bash
# OpenCode Mobile installer for Linux and macOS.
#
# Defaults are deliberately conservative: the bridge listens on loopback, the
# config file is mode 600, and the token is generated locally. Nothing is
# printed that can be used to authenticate.
set -euo pipefail

INSTALLER_VERSION="0.1.0"
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
PURGE=0
NO_COLOR_FLAG=0
COMMAND="install"
TARGET_BRIDGE=1
TARGET_APK=0
SHOW_VERSION=0
TMP_DIR=""

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

info() { printf '%s\n' "${BOLD}::${RESET} $*"; }
ok() { printf '%s\n' "${GREEN}OK${RESET}  $*"; }
warn() { printf '%s\n' "${YELLOW}WARN${RESET} $*" >&2; }
die() {
  trap - ERR
  printf '%s\n' "${RED}ERROR${RESET} $*" >&2
  exit 1
}
step() { printf '\n%s\n' "${BOLD}$*${RESET}"; }

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT
trap 'code=$?; trap - ERR; printf "%s\n" "${RED}ERROR${RESET} command failed (exit ${code}): ${BASH_COMMAND}" >&2; exit "$code"' ERR

usage() {
  cat <<'EOF'
OpenCode Mobile installer

Usage:
  install.sh [command] [options]

Commands:
  install       Install the bridge (default) and optionally the Android app.
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
  --no-color        Disable ANSI color.
  --purge           With uninstall, also remove the config and data directory.
  -h, --help        Show this help.
  -V, --version     Print the installer version.

Examples:
  ./install.sh install --workdir "$HOME/code"
  ./install.sh install --apk
  ./install.sh install --all --dry-run
  ./install.sh doctor
  ./install.sh uninstall --purge

The installer never prints the generated AUTH_TOKEN. It writes it to:
  ~/.config/opencode-mobile/bridge.env
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install|update|doctor|uninstall|version|help)
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
      --no-color)
        NO_COLOR_FLAG=1
        ;;
      --purge)
        PURGE=1
        ;;
      --yes)
        # Accepted for non-interactive use. This installer has no prompts.
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
    curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$dest" "$url"
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
  [ "$major" -ge 20 ] || die "Node.js 20 or newer is required (found $(node -v))"
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
    ok "Keeping existing config: $CONFIG_FILE"
    return 0
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
  token="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
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

install_bridge() {
  step "Installing the bridge"
  check_node
  require_sha_tool
  prepare_workdir

  if [ "$DRY_RUN" = 1 ]; then
    info "Would resolve the latest release for $REPO"
    info "Would download and verify the bridge archive"
    info "Would install under $PREFIX/bridge/current"
    info "Would create launcher: $BIN_DIR/opencode-mobile-bridge"
    create_config
    info "Dry run complete. No files were changed."
    return 0
  fi

  resolve_release
  local asset="opencode-mobile-bridge-${VERSION_NUM}.tar.gz"
  local url
  url="$(release_url "$asset")"
  info "Release: $TAG"
  info "Asset: $asset"

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile.XXXXXX")"
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

  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR" 2>/dev/null || true
  create_config

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not in PATH. Add it or run $launcher directly." ;;
  esac
  ok "Start with: opencode-mobile-bridge"
}

install_apk() {
  step "Installing the Android app"
  need_cmd adb
  if [ "$DRY_RUN" = 1 ]; then
    info "Would resolve the latest release for $REPO"
    info "Would download and verify the APK"
    info "Would run: adb install -r <apk>"
    info "Dry run complete. No files were changed."
    return 0
  fi

  resolve_release
  local asset="opencode-mobile-${VERSION_NUM}.apk"
  local url
  url="$(release_url "$asset")"
  info "Release: $TAG"
  info "Asset: $asset"

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile.XXXXXX")"
  local apk="$TMP_DIR/$asset"
  download_file "$url" "$apk"
  download_file "$(release_url "SHA256SUMS")" "$TMP_DIR/SHA256SUMS"

  local expected actual
  expected="$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1; exit }' "$TMP_DIR/SHA256SUMS")"
  [ -n "$expected" ] || die "SHA256SUMS does not list $asset"
  actual="$(sha256_of "$apk")"
  [ "$expected" = "$actual" ] || die "Checksum mismatch for $asset"
  ok "Checksum verified"

  if [ -n "$ADB_SERIAL" ]; then
    adb -s "$ADB_SERIAL" install -r "$apk"
  else
    adb install -r "$apk"
  fi
  ok "APK installed"
}

doctor() {
  step "Doctor"
  local failures=0

  printf 'OS: %s %s\n' "$(uname -s)" "$(uname -m)"
  if has_cmd node; then
    printf 'Node: %s\n' "$(node -v)"
    local major
    major="$(node -p 'process.versions.node.split(".")[0]')"
    if [ "$major" -ge 20 ]; then ok "Node version is supported"; else warn "Node 20 or newer is required"; failures=$((failures + 1)); fi
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
    # shellcheck disable=SC1090
    local config_port
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
    else
      rm -rf "$PREFIX/bridge"
      rm -f "$BIN_DIR/opencode-mobile-bridge"
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
    install|update)
      if [ "$TARGET_BRIDGE" = 1 ]; then
        install_bridge
      fi
      if [ "$TARGET_APK" = 1 ]; then
        install_apk
      fi
      ;;
    doctor)
      if ! doctor; then
        exit 1
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
