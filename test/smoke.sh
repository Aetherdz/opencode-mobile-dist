#!/usr/bin/env bash
# Offline smoke test for install.sh. It uses a fake curl and a fake release so
# the test never touches GitHub or the network.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile-smoke.XXXXXX")"
cleanup() { [ "${KEEP_SMOKE:-0}" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

RELEASE_DIR="$WORK/release"
FAKE_BIN="$WORK/fakebin"
PREFIX="$WORK/prefix"
BIN_DIR="$WORK/bin"
WORKDIR="$WORK/work"
CONFIG_HOME="$WORK/config"
DATA_HOME="$WORK/data"

mkdir -p "$RELEASE_DIR" "$FAKE_BIN" "$WORK/bundle/dist" "$WORK/bundle/node_modules" "$WORKDIR"

cat > "$WORK/bundle/package.json" <<'EOF'
{"name":"bridge-fixture","version":"1.0.0"}
EOF
cat > "$WORK/bundle/dist/index.js" <<'EOF'
console.log("fixture");
EOF
tar -czf "$RELEASE_DIR/opencode-mobile-bridge-1.0.0-beta.1.tar.gz" -C "$WORK/bundle" .
(
  cd "$RELEASE_DIR"
  sha256sum opencode-mobile-bridge-1.0.0-beta.1.tar.gz > SHA256SUMS
)

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --retry|--proto|--max-time|--connect-timeout) shift 2 ;;
    --progress-bar|--tlsv1.2) shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://api.github.com/*)
    if [[ "$url" == *"/releases?per_page=1" ]]; then
      printf '%s\n' '[{"tag_name":"v1.0.0-beta.1"}]'
    else
      printf '%s\n' '{"tag_name":"1.0.0"}'
    fi
    ;;
  https://github.com/*/releases/download/*/*)
    asset="${url##*/}"
    [ -f "$RELEASE_DIR/$asset" ] || { echo "missing $asset" >&2; exit 22; }
    if [ "${FAIL_ARCHIVE_DOWNLOAD:-}" = "$asset" ] && [ -n "$out" ]; then
      head -c 37 "$RELEASE_DIR/$asset" > "$out"
      echo "simulated interrupted archive download" >&2
      exit 18
    fi
    if [ -n "$out" ]; then cp "$RELEASE_DIR/$asset" "$out"; else cat "$RELEASE_DIR/$asset"; fi
    ;;
  *)
    echo "unexpected URL: $url" >&2
    exit 22
    ;;
esac
EOF
chmod +x "$FAKE_BIN/curl"

SYSTEMCTL_LOG="$WORK/systemctl.log"
SYSTEMCTL_STATE="$WORK/systemctl.active"
export SYSTEMCTL_LOG SYSTEMCTL_STATE
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  "--user show-environment")
    [ "${SYSTEMCTL_UNAVAILABLE:-0}" != 1 ]
    ;;
  "--user daemon-reload") exit 0 ;;
  "--user enable --now opencode-mobile-bridge.service") touch "$SYSTEMCTL_STATE" ;;
  "--user is-active --quiet opencode-mobile-bridge.service") test -f "$SYSTEMCTL_STATE" ;;
  "--user is-active opencode-mobile-bridge.service")
    if [ -f "$SYSTEMCTL_STATE" ]; then echo active; else echo inactive; exit 3; fi
    ;;
  "--user stop opencode-mobile-bridge.service"|"--user disable --now opencode-mobile-bridge.service") rm -f "$SYSTEMCTL_STATE" ;;
  *) echo "unexpected systemctl invocation: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKE_BIN/systemctl"

export PATH="$FAKE_BIN:$PATH"
export RELEASE_DIR
export XDG_CONFIG_HOME="$CONFIG_HOME"
export XDG_DATA_HOME="$DATA_HOME"

INSTALLER_COPY="$WORK/install-copy.sh"
cp "$ROOT_DIR/install.sh" "$INSTALLER_COPY"
bash "$INSTALLER_COPY" install --prefix "$PREFIX" --bin-dir "$BIN_DIR" --workdir "$WORKDIR" --no-color
test -f "$PREFIX/bridge/current/dist/index.js"
test -x "$BIN_DIR/opencode-mobile-bridge"
test -f "$CONFIG_HOME/opencode-mobile/bridge.env"
test "$(stat -c '%a' "$CONFIG_HOME/opencode-mobile/bridge.env")" = "600"
test "$(awk -F= '/^AUTH_TOKEN=/{print length($2)}' "$CONFIG_HOME/opencode-mobile/bridge.env")" -ge 32
test -x "$BIN_DIR/opencode-mobile-installer"
test -x "$PREFIX/installer"
cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = mcp ] && [ "${2:-}" = add ]; then
  printf '%s\n' "$*" >> "${MCP_LOG:?}"
  config="$XDG_CONFIG_HOME/opencode/opencode.json"
  mkdir -p "$(dirname "$config")"
  if [ ! -f "$config" ]; then
    cat > "$config" <<JSONC
{
  // unrelated user configuration must survive removal
  "theme": "dark",
  "mcp": { "servers": {
    "keep-me": { "type": "remote", "url": "https://example.invalid/mcp" },
    "opencode-mobile": { "type": "local", "command": ["/usr/bin/node", "$MCP_BRIDGE_ENTRY", "mcp"], "environment": { "PORT": "8787" } },
  } },
}
JSONC
  fi
  exit 0
fi
if [ "${1:-}" = debug ] && [ "${2:-}" = paths ] && [ "${3:-}" = config ]; then
  printf '%s\n' "$XDG_CONFIG_HOME/opencode"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/opencode"
MCP_LOG="$WORK/mcp-add.log"
MCP_BRIDGE_ENTRY="$PREFIX/bridge/current/dist/index.js"
export MCP_LOG MCP_BRIDGE_ENTRY
test -x "$BIN_DIR/opencode-mobile"
test -x "$BIN_DIR/opencode-mobile-down"
test -x "$BIN_DIR/opencode-mobile-apk"
test -x "$BIN_DIR/opencode-mobile-up"
grep -q 'opencode-mobile-installer" up' "$BIN_DIR/opencode-mobile"
cmp "$INSTALLER_COPY" "$BIN_DIR/opencode-mobile-installer"
output="$("$ROOT_DIR/install.sh" setup --prefix "$PREFIX" --bin-dir "$BIN_DIR" --workdir "$WORKDIR" --no-color)"
printf '%s\n' "$output" | grep -q 'Installed successfully'
printf '%s\n' "$output" | grep -q 'Run this to start:'
printf '%s\n' "$output" | grep -q 'opencode-mobile --copy-pairing'
printf '%s\n' "$output" | grep -q '→ Installing'
SERVICE_UNIT="$CONFIG_HOME/systemd/user/opencode-mobile-bridge.service"
test -f "$SERVICE_UNIT"
test "$(stat -c '%a' "$SERVICE_UNIT")" = "600"
grep -q '^# Managed by OpenCode Mobile installer\.' "$SERVICE_UNIT"
grep -q '^Restart=on-failure$' "$SERVICE_UNIT"
grep -q '^RestartSec=10s$' "$SERVICE_UNIT"
grep -q 'opencode-mobile-bridge"$' "$SERVICE_UNIT"
test -f "$SYSTEMCTL_STATE"
grep -q -- '--user enable --now opencode-mobile-bridge.service' "$SYSTEMCTL_LOG"
grep -q -- '--user daemon-reload' "$SYSTEMCTL_LOG"
test -f "$CONFIG_HOME/opencode/opencode.json"
grep -q 'mcp add --global --env PORT=8787 opencode-mobile -- .*node .*bridge/current/dist/index.js mcp' "$MCP_LOG"
if grep -Eqi 'AUTH_TOKEN|password|secret' "$MCP_LOG"; then
  echo "MCP registration unexpectedly included a secret" >&2
  exit 1
fi
if printf '%s\n' "$output" | grep -Eq 'Release:|Checksum verified|WARN|ERROR'; then
  echo "setup output contains verbose diagnostics" >&2
  exit 1
fi
REAL_NODE="$(command -v node)"
export REAL_NODE
cat > "$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -p) echo 22 ;;
  -v) echo v22.0.0 ;;
  *) exec "$REAL_NODE" "$@" ;;
esac
EOF
chmod +x "$FAKE_BIN/node"
cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "opencode 1.0.0"; exit 0; fi
if [ "$1" = "service" ] && [ "$2" = "start" ]; then
  mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
  printf '{"url":"http://127.0.0.1:9999","password":"fixture"}' > "${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/opencode"

# A rejected bridge update must not replace the installed version or break the
# existing current symlink when the published checksum does not match.
GOOD_SUMS="$WORK/SHA256SUMS.good"
cp "$RELEASE_DIR/SHA256SUMS" "$GOOD_SUMS"
CURRENT_TARGET="$(readlink "$PREFIX/bridge/current")"
printf '%064d  opencode-mobile-bridge-1.0.0-beta.1.tar.gz\n' 0 > "$RELEASE_DIR/SHA256SUMS"
if "$ROOT_DIR/install.sh" update --prefix "$PREFIX" --bin-dir "$BIN_DIR" --workdir "$WORKDIR" --no-color > "$WORK/bad-update.log" 2>&1; then
  echo "expected update rejection for a checksum mismatch" >&2
  exit 1
fi
test "$(readlink "$PREFIX/bridge/current")" = "$CURRENT_TARGET"
test -f "$PREFIX/bridge/current/dist/index.js"
grep -q 'Checksum mismatch' "$WORK/bad-update.log"
cp "$GOOD_SUMS" "$RELEASE_DIR/SHA256SUMS"

# A curl failure after writing a partial archive must leave the active bridge
# untouched (download and verification happen before replacing current).
cp "$CONFIG_HOME/opencode-mobile/bridge.env" "$WORK/config.before-interrupted-update"
if FAIL_ARCHIVE_DOWNLOAD=opencode-mobile-bridge-1.0.0-beta.1.tar.gz \
  "$ROOT_DIR/install.sh" update --prefix "$PREFIX" --bin-dir "$BIN_DIR" --workdir "$WORKDIR" --no-color > "$WORK/interrupted-update.log" 2>&1; then
  echo "expected update rejection for an interrupted archive download" >&2
  exit 1
fi
test "$(readlink "$PREFIX/bridge/current")" = "$CURRENT_TARGET"
test -f "$PREFIX/bridge/current/dist/index.js"
grep -q 'simulated interrupted archive download' "$WORK/interrupted-update.log"
cmp "$WORK/config.before-interrupted-update" "$CONFIG_HOME/opencode-mobile/bridge.env"

# A checksum manifest that omits the requested bridge is rejected before any
# versioned bridge is installed.
MISSING_SUMS_PREFIX="$WORK/missing-sums-prefix"
MISSING_SUMS_BIN="$WORK/missing-sums-bin"
printf '%064d  unrelated-asset.tar.gz\n' 0 > "$RELEASE_DIR/SHA256SUMS"
if "$ROOT_DIR/install.sh" install --prefix "$MISSING_SUMS_PREFIX" --bin-dir "$MISSING_SUMS_BIN" --workdir "$WORKDIR" --no-color > "$WORK/missing-sums.log" 2>&1; then
  echo "expected install rejection for a missing checksum entry" >&2
  exit 1
fi
test ! -e "$MISSING_SUMS_PREFIX/bridge/current"
grep -q 'SHA256SUMS does not list' "$WORK/missing-sums.log"
cp "$GOOD_SUMS" "$RELEASE_DIR/SHA256SUMS"

REPAIR_PREFIX="$WORK/repair-prefix"
REPAIR_BIN="$WORK/repair-bin"
REPAIR_CONFIG="$WORK/repair-config"
REPAIR_DATA="$WORK/repair-data"
mkdir -p "$REPAIR_PREFIX/bridge/current/dist" "$REPAIR_PREFIX/bridge/current/node_modules" "$REPAIR_BIN" "$REPAIR_CONFIG/opencode-mobile"
cp "$WORK/bundle/package.json" "$REPAIR_PREFIX/bridge/current/package.json"
cp "$WORK/bundle/dist/index.js" "$REPAIR_PREFIX/bridge/current/dist/index.js"
printf 'PORT=8787\nHOST=127.0.0.1\nAUTH_TOKEN=%064d\nALLOWED_WORKDIRS="%s"\nDATA_DIR="%s"\n' 0 "$WORKDIR" "$REPAIR_DATA" > "$REPAIR_CONFIG/opencode-mobile/bridge.env"
chmod 600 "$REPAIR_CONFIG/opencode-mobile/bridge.env"
XDG_CONFIG_HOME="$REPAIR_CONFIG" XDG_DATA_HOME="$REPAIR_DATA" "$ROOT_DIR/install.sh" setup --prefix "$REPAIR_PREFIX" --bin-dir "$REPAIR_BIN" --workdir "$WORKDIR" --no-color >/dev/null 2>&1
test -x "$REPAIR_BIN/opencode-mobile"
test -x "$REPAIR_BIN/opencode-mobile-bridge"
test -x "$REPAIR_BIN/opencode-mobile-installer"
test -x "$REPAIR_PREFIX/installer"
test -x "$REPAIR_BIN/opencode-mobile-up"
test -x "$REPAIR_BIN/opencode-mobile-down"
test -x "$REPAIR_BIN/opencode-mobile-apk"
grep -q 'opencode-mobile-installer" up' "$REPAIR_BIN/opencode-mobile"
grep -q 'up "\$@"' "$REPAIR_BIN/opencode-mobile"
test -f "$REPAIR_PREFIX/bridge/current/dist/index.js"
test "$(awk -F= '/^AUTH_TOKEN=/{print $2}' "$REPAIR_CONFIG/opencode-mobile/bridge.env")" = "$(printf '%064d' 0)"
test "$(stat -c '%a' "$REPAIR_CONFIG/opencode-mobile/bridge.env")" = "600"
mv "$REPAIR_BIN/opencode-mobile" "$REPAIR_BIN/opencode-mobile.removed"
mv "$REPAIR_BIN/opencode-mobile-apk" "$REPAIR_BIN/opencode-mobile-apk.removed"
mv "$REPAIR_BIN/opencode-mobile-installer" "$REPAIR_BIN/opencode-mobile-installer.removed"
XDG_CONFIG_HOME="$REPAIR_CONFIG" XDG_DATA_HOME="$REPAIR_DATA" "$ROOT_DIR/install.sh" setup --prefix "$REPAIR_PREFIX" --bin-dir "$REPAIR_BIN" --workdir "$WORKDIR" --no-color >/dev/null 2>&1
test -x "$REPAIR_BIN/opencode-mobile"
test -x "$REPAIR_BIN/opencode-mobile-apk"
test -x "$REPAIR_BIN/opencode-mobile-installer"
test -f "$REPAIR_PREFIX/bridge/current/dist/index.js"

STREAM_PREFIX="$WORK/stream-prefix"
STREAM_BIN="$WORK/stream-bin"
STREAM_CONFIG="$WORK/stream-config"
STREAM_DATA="$WORK/stream-data"
mkdir -p "$STREAM_BIN" "$STREAM_PREFIX" "$STREAM_CONFIG" "$STREAM_DATA"
export XDG_CONFIG_HOME="$STREAM_CONFIG" XDG_DATA_HOME="$STREAM_DATA"
cat "$ROOT_DIR/install.sh" | "$ROOT_DIR/install.sh" setup --prefix "$STREAM_PREFIX" --bin-dir "$STREAM_BIN" --workdir "$WORKDIR" --no-color > "$WORK/stream-output"
grep -q 'Installed successfully' "$WORK/stream-output"
grep -q 'opencode-mobile' "$WORK/stream-output"
grep -q '→ Downloading' "$WORK/stream-output"
test -x "$STREAM_BIN/opencode-mobile-installer"
test -x "$STREAM_BIN/opencode-mobile"
grep -q 'opencode-mobile-installer" up' "$STREAM_BIN/opencode-mobile"
cmp "$ROOT_DIR/install.sh" "$STREAM_BIN/opencode-mobile-installer"
test ! -e "$WORK"/opencode-mobile-installer.*
export XDG_CONFIG_HOME="$CONFIG_HOME" XDG_DATA_HOME="$DATA_HOME"
"$ROOT_DIR/install.sh" doctor --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
"$ROOT_DIR/install.sh" status --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
before="$(awk -F= '/^AUTH_TOKEN=/{print $2}' "$CONFIG_HOME/opencode-mobile/bridge.env")"
cp "$CONFIG_HOME/opencode-mobile/bridge.env" "$WORK/config.before-setup"
chmod 644 "$CONFIG_HOME/opencode-mobile/bridge.env"
"$ROOT_DIR/install.sh" setup --workdir "$WORKDIR" --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
test "$(stat -c '%a' "$CONFIG_HOME/opencode-mobile/bridge.env")" = "600"
cmp "$WORK/config.before-setup" "$CONFIG_HOME/opencode-mobile/bridge.env"
after="$(awk -F= '/^AUTH_TOKEN=/{print $2}' "$CONFIG_HOME/opencode-mobile/bridge.env")"
test "$before" = "$after"
"$ROOT_DIR/install.sh" down --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
test ! -e "$SYSTEMCTL_STATE"
grep -q -- '--user stop opencode-mobile-bridge.service' "$SYSTEMCTL_LOG"
"$ROOT_DIR/install.sh" setup --workdir "$WORKDIR" --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color >/dev/null
test -f "$SYSTEMCTL_STATE"
"$ROOT_DIR/install.sh" quickstart --dry-run --yes --workdir "$WORKDIR" --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
"$ROOT_DIR/install.sh" up --dry-run --yes --workdir "$WORKDIR" --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
"$ROOT_DIR/install.sh" up --dry-run --copy-pairing --workdir "$WORKDIR" --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
"$ROOT_DIR/install.sh" version --no-color | grep -q '0.3.1'
"$ROOT_DIR/install.sh" status --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color | grep -q 'bridge service: active'
if "$ROOT_DIR/install.sh" install --workdir "$HOME" --prefix "$WORKDIR/prefix" --bin-dir "$WORKDIR/bin" --no-color >/dev/null 2>&1; then
  echo "expected refusal of home directory as workdir" >&2
  exit 1
fi
before="$(awk -F= '/^AUTH_TOKEN=/{print $2}' "$CONFIG_HOME/opencode-mobile/bridge.env")"
"$ROOT_DIR/install.sh" install --prefix "$PREFIX" --bin-dir "$BIN_DIR" --workdir "$WORKDIR" --no-color >/dev/null
after="$(awk -F= '/^AUTH_TOKEN=/{print $2}' "$CONFIG_HOME/opencode-mobile/bridge.env")"
test "$before" = "$after"
"$ROOT_DIR/install.sh" uninstall --prefix "$PREFIX" --bin-dir "$BIN_DIR" --purge --no-color

test ! -e "$PREFIX/bridge"
test ! -e "$BIN_DIR/opencode-mobile-bridge"
test ! -e "$BIN_DIR/opencode-mobile"
test ! -e "$BIN_DIR/opencode-mobile-up"
test ! -e "$BIN_DIR/opencode-mobile-down"
test ! -e "$BIN_DIR/opencode-mobile-apk"
test ! -e "$BIN_DIR/opencode-mobile-installer"
test ! -e "$CONFIG_HOME/opencode-mobile"
test ! -e "$SERVICE_UNIT"
test ! -e "$SYSTEMCTL_STATE"
grep -q -- '--user disable --now opencode-mobile-bridge.service' "$SYSTEMCTL_LOG"
test -f "$CONFIG_HOME/opencode/opencode.json"
grep -q '"theme": "dark"' "$CONFIG_HOME/opencode/opencode.json"
grep -q 'keep-me' "$CONFIG_HOME/opencode/opencode.json"
! grep -q '"opencode-mobile"' "$CONFIG_HOME/opencode/opencode.json"
test -n "$(find "$CONFIG_HOME/opencode" -name 'opencode.json.opencode-mobile.bak.*' -print -quit)"

# If no systemd user manager exists, setup must leave the ordinary foreground
# launcher in place and avoid writing/enabling a service unit.
FALLBACK_HOME="$WORK/fallback-home"
FALLBACK_PREFIX="$FALLBACK_HOME/prefix"
FALLBACK_BIN="$FALLBACK_HOME/bin"
FALLBACK_CONFIG="$FALLBACK_HOME/config"
FALLBACK_DATA="$FALLBACK_HOME/data"
mkdir -p "$FALLBACK_HOME/work"
mkdir -p "$FALLBACK_CONFIG/opencode"
cat > "$FALLBACK_CONFIG/opencode/opencode.json" <<'JSON'
{"theme":"dark","mcp":{"servers":{"opencode-mobile":{"type":"local","command":["other-tool","serve"]}}}}
JSON
output="$(SYSTEMCTL_UNAVAILABLE=1 XDG_CONFIG_HOME="$FALLBACK_CONFIG" XDG_DATA_HOME="$FALLBACK_DATA" \
  "$ROOT_DIR/install.sh" setup --prefix "$FALLBACK_PREFIX" --bin-dir "$FALLBACK_BIN" --workdir "$FALLBACK_HOME/work" --no-color 2>&1)"
test -x "$FALLBACK_BIN/opencode-mobile-bridge"
test ! -e "$FALLBACK_CONFIG/systemd/user/opencode-mobile-bridge.service"
grep -qi 'systemd user manager is unavailable' "${TMPDIR:-/tmp}/opencode-install.log"
SYSTEMCTL_UNAVAILABLE=1 XDG_CONFIG_HOME="$FALLBACK_CONFIG" XDG_DATA_HOME="$FALLBACK_DATA" \
  "$ROOT_DIR/install.sh" uninstall --prefix "$FALLBACK_PREFIX" --bin-dir "$FALLBACK_BIN" --no-color >/dev/null 2>&1
grep -q '"other-tool","serve"' "$FALLBACK_CONFIG/opencode/opencode.json"

echo "smoke test passed"
