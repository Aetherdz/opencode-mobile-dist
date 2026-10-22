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

"$ROOT_DIR/install.sh" install --prefix "$PREFIX" --bin-dir "$BIN_DIR" --workdir "$WORKDIR" --no-color
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
output="$("$ROOT_DIR/install.sh" setup --prefix "$PREFIX" --bin-dir "$BIN_DIR" --workdir "$WORKDIR" --no-color)"
printf '%s\n' "$output" | grep -q 'Setup complete. Run: opencode-mobile'
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
