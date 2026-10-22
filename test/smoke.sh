#!/usr/bin/env bash
# Offline smoke test for install.sh. It uses a fake curl and a fake release so
# the test never touches GitHub or the network.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/opencode-mobile-smoke.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
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
    if [[ "$url" == *"/releases/latest" ]]; then
      printf '%s\n' '{"tag_name":"v1.0.0-beta.1"}'
    else
      printf '%s\n' '{"tag_name":"1.0.0"}'
    fi
    ;;
  https://github.com/*/releases/download/*/*)
    asset="${url##*/}"
    [ -f "$RELEASE_DIR/$asset" ] || { echo "missing $asset" >&2; exit 22; }
    if [ -n "$out" ]; then cp "$RELEASE_DIR/$asset" "$out"; else cat "$RELEASE_DIR/$asset"; fi
    ;;
  *)
    echo "unexpected URL: $url" >&2
    exit 22
    ;;
esac
EOF
chmod +x "$FAKE_BIN/curl"

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
test -x "$BIN_DIR/opencode-mobile"
test -x "$BIN_DIR/opencode-mobile-down"
test -x "$BIN_DIR/opencode-mobile-apk"
test -x "$BIN_DIR/opencode-mobile-up"
grep -q 'opencode-mobile-installer" up' "$BIN_DIR/opencode-mobile"
cmp "$INSTALLER_COPY" "$BIN_DIR/opencode-mobile-installer"
output="$("$ROOT_DIR/install.sh" setup --prefix "$PREFIX" --bin-dir "$BIN_DIR" --workdir "$WORKDIR" --no-color)"
printf '%s\n' "$output" | grep -q 'Installed successfully'
printf '%s\n' "$output" | grep -q 'Run this to start:'
printf '%s\n' "$output" | grep -q '→ Installing'
if printf '%s\n' "$output" | grep -Eq 'Release:|Checksum verified|WARN|ERROR'; then
  echo "setup output contains verbose diagnostics" >&2
  exit 1
fi
printf 'fake node\n' > "$FAKE_BIN/node"
cat > "$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-p" ]; then echo 22; else echo v22.0.0; fi
EOF
chmod +x "$FAKE_BIN/node"
cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/opencode"

# An existing bridge with missing launchers must persist the new installer
# before writing launchers that delegate back to it.
REPAIR_PREFIX="$WORK/repair-prefix"
REPAIR_BIN="$WORK/repair-bin"
mkdir -p "$REPAIR_PREFIX/bridge/current/dist" "$REPAIR_PREFIX/bridge/current/node_modules" "$REPAIR_BIN"
cp "$WORK/bundle/package.json" "$REPAIR_PREFIX/bridge/current/package.json"
cp "$WORK/bundle/dist/index.js" "$REPAIR_PREFIX/bridge/current/dist/index.js"
cp "$ROOT_DIR/install.sh" "$REPAIR_PREFIX/bridge/current/unused"
printf 'PORT=8787\nHOST=127.0.0.1\nAUTH_TOKEN=%064d\nALLOWED_WORKDIRS="%s"\nDATA_DIR="%s"\n' 0 "$WORKDIR" "$DATA_HOME" > "$CONFIG_HOME/opencode-mobile/bridge.env"
"$ROOT_DIR/install.sh" setup --prefix "$REPAIR_PREFIX" --bin-dir "$REPAIR_BIN" --workdir "$WORKDIR" --no-color >/dev/null
test -x "$REPAIR_BIN/opencode-mobile-installer"
test -x "$REPAIR_BIN/opencode-mobile"
grep -q 'opencode-mobile-installer" up' "$REPAIR_BIN/opencode-mobile"

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
chmod 644 "$CONFIG_HOME/opencode-mobile/bridge.env"
"$ROOT_DIR/install.sh" setup --workdir "$WORKDIR" --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
test "$(stat -c '%a' "$CONFIG_HOME/opencode-mobile/bridge.env")" = "600"
after="$(awk -F= '/^AUTH_TOKEN=/{print $2}' "$CONFIG_HOME/opencode-mobile/bridge.env")"
test "$before" = "$after"
"$ROOT_DIR/install.sh" quickstart --dry-run --yes --workdir "$WORKDIR" --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
"$ROOT_DIR/install.sh" up --dry-run --yes --workdir "$WORKDIR" --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
"$ROOT_DIR/install.sh" up --dry-run --copy-pairing --workdir "$WORKDIR" --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color
"$ROOT_DIR/install.sh" version --no-color | grep -q '0.3.1'
"$ROOT_DIR/install.sh" status --prefix "$PREFIX" --bin-dir "$BIN_DIR" --no-color | grep -q 'stopped'
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
test ! -e "$CONFIG_HOME/opencode-mobile"

echo "smoke test passed"
