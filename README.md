# OpenCode Mobile distribution

Terminal installers for [OpenCode Mobile](https://github.com/Aetherdz/opencode-mobile),
an unofficial mobile and web client for a local OpenCode service.

This repository contains the installers, checksums policy, and release
documentation. The application source lives in the main repository. Release
binaries are attached to that repository's GitHub Releases.

## What the installer does

- Installs the authenticated bridge into a versioned directory.
- Generates a random `AUTH_TOKEN` locally and writes it to a private config
  file. The token is shown only during `up` in the local terminal. Config files
  use restrictive owner-only permissions/ACLs where supported.
- Creates a launcher in your user `bin` directory.
- Optionally downloads and installs the Android APK through `adb`.
- Verifies every downloaded asset against the release `SHA256SUMS`.
- Provides `doctor`, `update`, and `uninstall` commands.
- On Linux/macOS, prints a phone pairing QR, URL, and token on startup (QR
  rendering requires `qrencode`).

The bridge listens on `127.0.0.1:8787` by default. Remote access is expected to
go through Tailscale or a reverse proxy; see the main repository's deployment
guide.

## Linux and macOS quick setup

Run this single command to download and install the current script. It trusts
the GitHub `main` branch; downloaded release assets are separately checked
against `SHA256SUMS`.

```bash
curl -fsSL https://raw.githubusercontent.com/Aetherdz/opencode-mobile-dist/main/install.sh | bash -s -- setup
```

On Linux/macOS, after setup, start it with just `opencode-mobile` (no `up`).

This command invokes the installer directly; use it only if you trust the
repository's current `main` branch. For high-assurance or offline review,
download a pinned commit, inspect it, and execute the local copy instead.

For review-first installation, download the script from a specific commit,
inspect it, then run `bash install.sh setup`.

`setup` checks Node/OpenCode, installs the bridge after verifying its release
`SHA256SUMS`, creates `$HOME/projects` if missing, and preserves an existing
token/config. It repairs missing command launchers without reinstalling an
existing bridge. It never uses the entire home directory as a workdir.
`opencode-mobile` starts OpenCode and the bridge, checks health, and creates a public
temporary Cloudflare Quick Tunnel after explicit confirmation each run. Once
ready, it prints the bridge URL and pairing token and displays a QR payload that
the app scans to fill both fields automatically. You can also enter the URL and
token manually. Use `opencode-mobile --copy-pairing` (or `--copy`) to copy the
QR connection payload if a supported clipboard utility is installed. Anyone
with both URL and token can control the agent. These credentials are printed
only in the local terminal, never stored in logs. `cloudflared` is
downloaded from the official release and checked against its SHA-256 before
being placed in the user bin directory; no sudo or system package changes are
needed on supported Linux/macOS architectures. `down`, `status`, `doctor`, and `apk` are also
available. `apk` verifies and prints the release URL/checksum; the release APK
currently targets arm64-v8a only and is never installed with adb without an
extra explicit interactive confirmation.

The whole selected project directory is exposed via the bearer token. For
reduced exposure, use a dedicated work directory containing only projects
intended for remote agent access. For a fixed public hostname, the owner must
configure a Cloudflare named tunnel and domain; this installer does not invent
or create persistent public URLs.

Useful commands:

```bash
./install.sh setup                  # one-time setup
./install.sh up                     # start / choose a transport
./install.sh down                   # stop managed bridge/tunnel
./install.sh status                 # concise status
./install.sh doctor                 # dependencies, permissions, health
./install.sh apk                    # verified APK URL and checksum
./install.sh update                 # replace the bridge with the latest release
./install.sh uninstall              # remove the bridge, keep config and data
./install.sh uninstall --purge      # remove config and data too
```

The installer writes:

| Path | Purpose |
| --- | --- |
| `~/.local/share/opencode-mobile/bridge/current` | Installed bridge |
| `~/.local/share/opencode-mobile/data` | Runtime data |
| `~/.local/bin/opencode-mobile-bridge` | Launcher |
| `~/.config/opencode-mobile/bridge.env` | Token and bridge configuration |

If `~/.local/bin` is not in `PATH`, the installer prints the exact launcher
path. Add it to `PATH` or call the launcher directly.

## Windows

Windows 10 or newer with PowerShell 5.1 or later. The current PowerShell
installer installs and verifies the bridge, but does not yet provide the
Cloudflare quickstart, pairing QR, or the `opencode-mobile` launcher. `adb` is
required only for optional APK installation.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1 -Command install -WorkDir "$env:USERPROFILE\projects"
```

Useful commands:

```powershell
.\install.ps1 -Command install -Apk
.\install.ps1 -Command install -All
.\install.ps1 -Command install -DryRun
.\install.ps1 -Command doctor
.\install.ps1 -Command update
.\install.ps1 -Command uninstall
.\install.ps1 -Command uninstall -Purge
```

The Windows installer writes under `%LOCALAPPDATA%\opencode-mobile` and
`%APPDATA%\opencode-mobile\bridge.env`. It restricts the config ACL with
`icacls` when available.

## Requirements

- Node.js 22 or newer for the bridge and installer.
- `curl` or `wget`, and `tar` on Linux/macOS.
- `sha256sum` or `shasum`.
- Android platform tools (`adb`) for APK installation.
- `cloudflared` for the Linux/macOS temporary public-tunnel pairing flow; the
  installer can install a checksum-verified binary where supported.
- `qrencode` for a terminal-rendered QR code. Without it, the bridge URL and
  token are printed for manual entry.
- A reachable OpenCode service. The bridge discovers the local service file
  automatically, or you can set `OPENCODE_URL` and `OPENCODE_PASSWORD` in the
  config file.

The installer does not install Node.js, OpenCode, or `adb` for you.

## After installation

1. Edit the generated config if OpenCode is not discoverable:
   ```dotenv
   OPENCODE_URL=http://127.0.0.1:4096
   OPENCODE_PASSWORD=<the OpenCode password>
   ```
2. Start the bridge:
   ```bash
   opencode-mobile-bridge
   ```
3. Check health:
   ```bash
   curl http://127.0.0.1:8787/health
   ```
4. Open the app on the same device, or use a Tailscale address. Enter the
   bridge URL and the `AUTH_TOKEN` from the config file.

To read the token locally:

```bash
grep '^AUTH_TOKEN=' ~/.config/opencode-mobile/bridge.env
```

Do not paste the token into a chat, issue, screenshot, or shell history. The
installer itself never prints it.

## Release asset contract

The source repository's release workflow must publish these files for a tag
such as `v1.0.0-beta.1`:

| Asset | Contents |
| --- | --- |
| `opencode-mobile-bridge-1.0.0-beta.1.tar.gz` | Bridge `dist/`, `package.json`, `package-lock.json`, and production `node_modules/` |
| `opencode-mobile-bridge-1.0.0-beta.1.zip` | The same tree for the Windows installer |
| `opencode-mobile-1.0.0-beta.1.apk` | Signed Android APK |
| `opencode-mobile-web-1.0.0-beta.1.tar.gz` | Static web export |
| `SHA256SUMS` | `sha256  filename` lines for every asset |

The installer refuses to continue when an asset is missing from `SHA256SUMS`
or when the digest does not match.

## Security

- Downloads use HTTPS and are checksum-verified before extraction.
- The token is generated locally with 32 random bytes and written with mode
  `600` on POSIX or a restricted ACL on Windows.
- The bridge binds to loopback by default.
- The installer never enables a service, opens a firewall port, or writes to
  the system package manager.
- `uninstall` keeps config and data unless `--purge` is explicit.
- Do not run the installer as root. It is designed for a normal user account.

Report vulnerabilities through the main repository's private security
advisory, not a public issue. See [SECURITY.md](SECURITY.md).

## Development

```bash
bash -n install.sh
./install.sh --help
./install.sh install --dry-run --workdir "$PWD"
```

The installers are intentionally dependency-free shell and PowerShell scripts.
Keep them readable and reviewable. A release is not trusted because the
installer is short; it is trusted because the checksums and source are
reviewable.

## License

MIT. See [LICENSE](LICENSE). OpenCode Mobile is an unofficial project and is not
endorsed by the OpenCode team.
