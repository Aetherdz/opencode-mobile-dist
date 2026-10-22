# Security policy

## Supported versions

The installers follow the latest published OpenCode Mobile release. Older
installer snapshots are not supported.

## Reporting a vulnerability

Do not open a public issue for a security problem. Use GitHub's private
vulnerability reporting on the main repository:

https://github.com/Aetherdz/opencode-mobile/security/advisories/new

Include the installer version, operating system, the affected command, and
reproduction steps. Remove tokens, personal paths, and private source code from
logs.

## Installer-specific scope

In scope:

- Checksum verification bypass.
- Downloading over a non-HTTPS URL.
- Writing the token to a world-readable file.
- Printing the token or an OpenCode password.
- Path traversal through release tags or asset names.
- Command injection through repository, release, or path arguments.
- A `--dry-run` action that writes or downloads.
- `uninstall --purge` deleting a path outside the documented prefix.

Out of scope:

- Vulnerabilities in OpenCode itself.
- Vulnerabilities in the Android app or bridge; report those to the main
  repository.
- A compromised GitHub account or release signing key.
- A user running the installer as root or ignoring a checksum warning.

## Trust model

The installer trusts GitHub Releases and the repository contents. It does not
have a separate signing key. Checksums detect corruption and a swapped asset
only if the `SHA256SUMS` file itself is authentic. Treat the GitHub account and
release workflow as the root of trust.
