# OpenCode Mobile installer for Windows PowerShell 5.1+.
# The pairing token is shown only during explicit foreground pairing.
# Setup and pairing protect the config with a user-scoped Windows ACL.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "setup", "up", "down", "status", "update", "doctor", "uninstall", "version", "help")]
    [string]$Command = "install",

    [switch]$Bridge,
    [switch]$Apk,
    [switch]$All,

    [string]$Prefix = "",
    [string]$BinDir = "",
    [string]$WorkDir = "",
    [string]$DataDir = "",
    [string]$ConfigFile = "",
    [string]$Repo = "Aetherdz/opencode-mobile",
    [string]$Release = "",
    [switch]$CopyPairing,

    [switch]$DryRun,
    [switch]$NoColor,
    [switch]$Purge,
    [switch]$Yes,
    [string]$WorkDirOverride = ""
)

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:InstallerVersion = "0.3.1"
$script:PackageId = "com.aetherdz.opencodemobile"
$script:NoColorOutput = [bool]$NoColor
$script:Prefix = ""
$script:BinDir = ""
$script:WorkDir = ""
$script:DataDir = ""
$script:ConfigFile = ""
$script:Repo = $Repo
    $script:Release = $Release
    $script:TargetBridge = $true
    $script:TargetApk = $false
    $script:TargetCommandOnly = $false
$script:TempDir = ""
$script:TunnelProcess = $null

function Write-Line {
    param([string]$Text, [string]$Color = "White")
    if ($script:NoColorOutput) {
        Write-Host $Text
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Write-Info { param([string]$Text) Write-Line ":: $Text" "Cyan" }
function Write-Ok { param([string]$Text) Write-Line "OK  $Text" "Green" }
function Write-Warn { param([string]$Text) Write-Line "WARN $Text" "Yellow" }
function Write-Step { param([string]$Text) Write-Host ""; Write-Line $Text "White" }

function Die {
    param([string]$Text)
    Write-Line "ERROR $Text" "Red"
    exit 1
}

function Has-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Need-Command {
    param([string]$Name)
    if (-not (Has-Command $Name)) {
        Die "Missing required command: $Name"
    }
}

function Test-Node {
    Need-Command "node"
    $raw = (& node -p "process.versions.node.split('.')[0]").Trim()
    if ($raw -notmatch '^\d+$') {
        Die "Could not read the Node.js version"
    }
    if ([int]$raw -lt 22) {
        Die "Node.js 22 or newer is required (found $(& node -v))"
    }
}

function Initialize-Paths {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $homeDir ".local\share" }
    $appData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $homeDir ".config" }

    if (-not $Prefix) { $Prefix = Join-Path $localAppData "opencode-mobile" }
    if (-not $BinDir) { $BinDir = Join-Path $Prefix "bin" }
    if ($WorkDirOverride -and $Command -notin @("up", "down", "status", "uninstall")) { Die "-WorkDirOverride is reserved for generated launchers" }
    if ($WorkDirOverride -and $Command -in @("up", "down", "status", "uninstall")) { $ConfigFile = $WorkDirOverride }
    if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) "opencode-mobile-workspace" }
    if (-not $DataDir) { $DataDir = Join-Path $Prefix "data" }
    if (-not $ConfigFile) { $ConfigFile = Join-Path $appData "opencode-mobile\bridge.env" }
    if ($Command -in @("up", "down", "status") -and -not $WorkDirOverride) {
        $Prefix = Join-Path $localAppData "opencode-mobile"
        $BinDir = Join-Path $Prefix "bin"
        $DataDir = Join-Path $Prefix "data"
        $ConfigFile = Join-Path $appData "opencode-mobile\bridge.env"
    }
    if ([string]::IsNullOrWhiteSpace($WorkDir) -or [string]::IsNullOrWhiteSpace($Prefix) -or [string]::IsNullOrWhiteSpace($BinDir)) {
        Die "WorkDir, Prefix, and BinDir must be non-empty paths"
    }

    try {
    $script:Prefix = [IO.Path]::GetFullPath($Prefix)
        $script:BinDir = [IO.Path]::GetFullPath($BinDir)
        $script:WorkDir = [IO.Path]::GetFullPath($WorkDir)
        $script:DataDir = [IO.Path]::GetFullPath($DataDir)
        $script:ConfigFile = [IO.Path]::GetFullPath($ConfigFile)
    } catch {
        Die "Invalid installation path: $($_.Exception.Message)"
    }

    if ($Command -notin @("up", "down", "status", "uninstall")) {
        foreach ($path in @($script:Prefix, $script:BinDir, $script:WorkDir, $script:DataDir)) {
            if ($path -eq [IO.Path]::GetPathRoot($path)) { Die "Refusing to use the filesystem root: $path" }
        }
    }
    if ($Command -in @("up", "down", "status")) {
        $script:TargetCommandOnly = $true
        $script:TargetBridge = $false
        $script:TargetApk = $false
        return
    }
    $homeFull = [IO.Path]::GetFullPath($homeDir).TrimEnd([char[]]@('\', '/'))
    $workFull = $script:WorkDir.TrimEnd([char[]]@('\', '/'))
    if ($Command -notin @("up", "down", "status", "uninstall") -and $workFull -ieq ([IO.Path]::GetPathRoot($script:WorkDir).TrimEnd([char[]]@('\', '/')))) {
        Die "Refusing to use a filesystem root as the workdir"
    }
    if ($Command -notin @("up", "down", "status", "uninstall") -and $workFull -ieq $homeFull) {
        Die "Refusing to use the entire user profile as the workdir"
    }
    $homePrefix = $homeFull + [IO.Path]::DirectorySeparatorChar
    $workPrefix = $workFull + [IO.Path]::DirectorySeparatorChar
    if ($env:OPENCODE_MOBILE_DEBUG_PATHS -eq "1") {
        Write-Host "PATHCHECK homeDir=[$homeDir] homeFull=[$homeFull] workFull=[$workFull] homePrefix=[$homePrefix] workPrefix=[$workPrefix] inside=$($workPrefix.StartsWith($homePrefix, [StringComparison]::OrdinalIgnoreCase))"
    }
    if ($Command -notin @("up", "down", "status", "uninstall") -and $workPrefix.StartsWith($homePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Die "The configured workdir may not be inside the user profile; use a dedicated project directory outside it"
    }
    if ($Command -notin @("up", "down", "status", "uninstall") -and $script:BinDir.TrimEnd([char[]]@('\', '/')) -ieq $script:WorkDir.TrimEnd([char[]]@('\', '/'))) {
        Die "Launcher directory and configured workdir may not be the same path"
    }
    foreach ($candidate in @($script:Prefix, $script:DataDir, $script:BinDir)) {
        $left = $candidate.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
        $right = $script:WorkDir.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
        if (($Command -notin @("up", "down", "status", "uninstall")) -and ($left.StartsWith($right, [StringComparison]::OrdinalIgnoreCase) -or $right.StartsWith($left, [StringComparison]::OrdinalIgnoreCase))) {
            Die "Install paths and configured workdir must not contain one another"
        }
    }
    if ($Command -notin @("up", "down", "status", "uninstall")) {
        $configDirFull = [IO.Path]::GetFullPath((Split-Path -Parent $script:ConfigFile)).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
        if (($script:WorkDir.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar).StartsWith($configDirFull, [StringComparison]::OrdinalIgnoreCase)) {
            Die "Configured workdir may not be inside the protected config directory"
        }
    }
    if ($Command -notin @("up", "down", "status", "uninstall")) {
        foreach ($path in @($script:Prefix, $script:BinDir, $script:WorkDir, $script:DataDir, $script:ConfigFile)) {
            if ($path -match '[\r\n%"]') { Die "Path contains unsupported characters: $path" }
        }
    }
    if ($Command -notin @("up", "down", "status", "uninstall")) {
        if (-not $script:WorkDir.StartsWith([IO.Path]::GetPathRoot($script:WorkDir), [StringComparison]::OrdinalIgnoreCase)) { Die "Work directory must be absolute" }
        if ($script:WorkDir.Contains(',')) { Die "Work directory may not contain commas" }
    }
    if ($script:Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        Die "-Repo must look like OWNER/REPO"
    }
    if ($script:Release -and $script:Release -notmatch '^[A-Za-z0-9._-]+$') {
        Die "-Release contains invalid characters"
    }

    $script:TargetBridge = $true
    $script:TargetApk = $false
    $script:TargetCommandOnly = $false
    if ($Command -in @("up", "down", "status")) {
        $script:TargetBridge = $false
        $script:TargetApk = $false
        $script:TargetCommandOnly = $true
        return
    }
    if ($Command -eq "setup") { $script:TargetCommandOnly = $false }
    if ($Command -eq "setup") { return }
    if ($Command -eq "uninstall") {
        $script:TargetBridge = $true
        $script:TargetApk = $false
        $script:TargetCommandOnly = $true
        return
    }
    if ($Apk) {
        $script:TargetBridge = $false
        $script:TargetApk = $true
    }
    if ($All) {
        $script:TargetBridge = $true
        $script:TargetApk = $true
    }
    if ($Bridge) {
        $script:TargetBridge = $true
        $script:TargetApk = $false
    }
}

function Show-Help {
    @"
OpenCode Mobile installer for Windows

Usage:
  .\install.ps1 -Command setup [-WorkDir DIR]
  .\install.ps1 -Command up [-CopyPairing]
  .\install.ps1 -Command down | status
  .\install.ps1 -Command install [-Bridge|-Apk|-All] [-WorkDir DIR]
  .\install.ps1 -Command doctor
  .\install.ps1 -Command uninstall [-Purge]

Commands:
  install       Install the bridge (default) and optionally the Android app.
  setup         Install the bridge, protected config, and startup launchers.
  up            Start OpenCode and bridge and create a temporary Cloudflare tunnel.
  down          Explain how to stop the foreground pairing session.
  status        Show whether the local bridge health endpoint responds.
  update        Replace the installed bridge with the latest release.
  doctor        Check dependencies, permissions, and bridge health.
  uninstall     Remove installed files. Add -Purge to remove config and data.
  version       Print the installer version.
  help          Show this help.

Options:
  -Prefix DIR      Install root. Default: %LOCALAPPDATA%\opencode-mobile
  -BinDir DIR      Launcher directory. Default: <prefix>\bin
  -WorkDir DIR     Directory the bridge may access. Default: %TEMP%\opencode-mobile-workspace
  -DataDir DIR     Bridge data directory. Default: <prefix>\data
  -ConfigFile FILE Config path. Default: %APPDATA%\opencode-mobile\bridge.env
  -Repo OWNER/REPO Source repository. Default: Aetherdz/opencode-mobile
  -Release TAG     Release tag. Default: latest release
  -DryRun          Print actions without downloading or writing files.
  -NoColor         Disable colored output.
  -Purge           With uninstall, remove config and data too.
  -Yes             Skips install/update confirmation only. Pairing and destructive actions still prompt.
  -CopyPairing     Copy the connection QR payload to the clipboard when supported.

Examples:
  .\install.ps1 -Command install -WorkDir "$env:USERPROFILE\code"
  .\install.ps1 -Command install -Apk
  .\install.ps1 -Command install -All -DryRun
  .\install.ps1 -Command doctor
  .\install.ps1 -Command uninstall -Purge

The pairing token is displayed only during an explicit foreground up session.
"@
}

function Resolve-Release {
    if ($script:Release) {
        $tag = $script:Release
    } else {
        $headers = @{
            "User-Agent" = "opencode-mobile-installer"
            "Accept" = "application/vnd.github+json"
        }
        try {
            # /releases/latest excludes pre-releases, which would strand beta
            # users on an older bridge. The first public release is newest.
            $releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:Repo)/releases?per_page=1" -Headers $headers)
            $latest = $releases | Select-Object -First 1
        } catch {
            Die "Could not read the latest release for $($script:Repo): $($_.Exception.Message)"
        }
        $tag = [string]$latest.tag_name
    }
    if (-not $tag) { Die "Could not determine the release tag" }
    if ($tag -notmatch '^[A-Za-z0-9._-]+$') { Die "Release tag contains invalid characters: $tag" }

    if ($tag.StartsWith("v")) {
        $version = $tag.Substring(1)
    } else {
        $tag = "v$tag"
        $version = $tag.Substring(1)
    }
    if (-not $version) { Die "Release tag is empty" }
    return [pscustomobject]@{ Tag = $tag; Version = $version }
}

function Get-ReleaseUrl {
    param([string]$Asset)
    return "https://github.com/$($script:Repo)/releases/download/$($script:ReleaseInfo.Tag)/$Asset"
}

function Invoke-Download {
    param([string]$Url, [string]$Destination)
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -Headers @{ "User-Agent" = "opencode-mobile-installer" }
    } catch {
        Die "Download failed: $Url`n$($_.Exception.Message)"
    }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Checksum {
    param([string]$Archive, [string]$Asset, [string]$Temp)
    $sums = Join-Path $Temp "SHA256SUMS"
    Invoke-Download (Get-ReleaseUrl "SHA256SUMS") $sums
    $line = Get-Content -Path $sums | Where-Object { $_ -match "\s+\*?$([regex]::Escape($Asset))$" } | Select-Object -First 1
    if (-not $line) { Die "SHA256SUMS does not list $Asset" }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = Get-Sha256 $Archive
    if ($expected -ne $actual) { Die "Checksum mismatch for $Asset" }
    Write-Ok "Checksum verified"
}

function New-TempDir {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $path = Join-Path ([IO.Path]::GetTempPath()) ("opencode-mobile-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path | Out-Null
    $script:TempDir = $path
    return $path
}

function Ensure-WorkDir {
    if ($script:WorkDir -match '[\r\n]') { Die "Work directory may not contain line breaks" }
    if (Test-Path -LiteralPath $script:WorkDir) {
        $workItem = Get-Item -LiteralPath $script:WorkDir -Force
        if (($workItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to use a workdir reparse point: $($script:WorkDir)" }
    }
    if ($script:DataDir.Contains('"') -or $script:DataDir -match '[\r\n]') { Die "Data directory contains invalid characters" }
    if (-not (Test-Path -LiteralPath $script:WorkDir -PathType Container)) {
        if ($DryRun) {
            Write-Info "Would create workdir: $($script:WorkDir)"
            return
        }
        $parent = Split-Path -Parent $script:WorkDir
        while ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            $parent = Split-Path -Parent $parent
        }
        if ($parent) {
            $parentItem = Get-Item -LiteralPath $parent -Force
            if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to create workdir through a reparse point" }
        }
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    }
    $resolved = (Resolve-Path -LiteralPath $script:WorkDir).Path
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved)) {
        Die "Refusing to use the filesystem root as the workdir"
    }
    $script:WorkDir = $resolved
}

function New-BridgeConfig {
    if (-not (Has-Command "icacls") -or -not $env:USERNAME) { Die "icacls and USERNAME are required to protect the pairing config" }
    if (Test-Path -LiteralPath $script:ConfigFile) {
        $existingConfig = Get-Item -LiteralPath $script:ConfigFile -Force
        if (($existingConfig.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to read a config reparse point: $($script:ConfigFile)" }
        if (-not $DryRun) {
            if (-not (Has-Command "icacls") -or -not $env:USERNAME) { Die "icacls and USERNAME are required to protect the pairing config" }
            $configDir = Split-Path -Parent $script:ConfigFile
            foreach ($path in @($configDir, $script:DataDir)) {
                if (Test-Path -LiteralPath $path) {
                    $dirItem = Get-Item -LiteralPath $path -Force
                    if (($dirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to write through a reparse point: $path" }
                }
            }
            $existingAcl = & icacls $script:ConfigFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" /grant:r "SYSTEM:(R,W)" /grant:r "Administrators:(R,W)"
            if ($LASTEXITCODE -ne 0) { Die "Could not restrict existing config ACL" }
            $dirAcl = & icacls $configDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F" /grant:r "Administrators:(OI)(CI)F"
            if ($LASTEXITCODE -ne 0) { Die "Could not restrict existing config directory ACL" }
        }
        Write-Ok "Keeping existing config: $($script:ConfigFile)"
        return
    }
    if ($DryRun) {
        Write-Info "Would write config: $($script:ConfigFile)"
        return
    }
    if ($script:WorkDir -match '[^\x20-\x7E]') { Die "Work directory must use printable ASCII characters on Windows" }

    $configDir = Split-Path -Parent $script:ConfigFile
    foreach ($path in @($script:BinDir, $script:Prefix, $configDir, $script:DataDir)) {
        if (Test-Path -LiteralPath $path) {
            $dirItem = Get-Item -LiteralPath $path -Force
            if (($dirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to write through a reparse point: $path" }
        }
    }
    $dataDirParent = Split-Path -Parent $script:DataDir
    if (Test-Path -LiteralPath $dataDirParent) {
        $parentItem = Get-Item -LiteralPath $dataDirParent -Force
        if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to create data through a reparse point" }
    }
    if (Test-Path -LiteralPath $configDir) {
        $configDirItem = Get-Item -LiteralPath $configDir -Force
        if (($configDirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to follow a reparse point for config directory: $configDir" }
    }
    foreach ($path in @($configDir, $script:DataDir)) {
        if ($path -eq [IO.Path]::GetPathRoot($path)) { Die "Refusing to write pairing files into a filesystem root: $path" }
    }
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    if (-not (Has-Command "icacls") -or -not $env:USERNAME) { Die "icacls and USERNAME are required to protect the pairing config" }
    & icacls $configDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F" /grant:r "Administrators:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "Could not restrict config directory permissions" }
    $dataDirParent = Split-Path -Parent $script:DataDir
    if (-not (Test-Path -LiteralPath $dataDirParent -PathType Container)) {
        New-Item -ItemType Directory -Path $dataDirParent -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:DataDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }

    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    if (-not $rng) { Die "Secure random generation is unavailable" }
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $token = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
    $lines = @(
        "PORT=8787",
        "HOST=127.0.0.1",
        "AUTH_TOKEN=$token",
        "ALLOWED_WORKDIRS=`"$($script:WorkDir)`"",
        "DATA_DIR=`"$($script:DataDir)`"",
        "LOG_LEVEL=info",
        "PUSH_ENABLED=1"
    )
    $tempConfig = Join-Path $configDir (".bridge.env." + [guid]::NewGuid().ToString("N") + ".tmp")
    if (Test-Path -LiteralPath $tempConfig) { Die "Temporary config path collision" }
    if (Test-Path -LiteralPath $script:ConfigFile) {
        $existingConfig = Get-Item -LiteralPath $script:ConfigFile -Force
        if (($existingConfig.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue
            Die "Refusing to replace a config reparse point: $($script:ConfigFile)"
        }
    }
    [IO.File]::WriteAllText($tempConfig, (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    & icacls $tempConfig /inheritance:r /grant:r "$($env:USERNAME):(R,W)" /grant:r "SYSTEM:(R,W)" /grant:r "Administrators:(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue
        Die "Could not restrict config ACL; refusing to install credentials with inherited permissions"
    }
    Move-Item -LiteralPath $tempConfig -Destination $script:ConfigFile -Force
    Write-Ok "Wrote config: $($script:ConfigFile)"
    Write-Ok "Restricted config permissions"
}

function Install-Bridge {
    Write-Step "Installing the bridge"
    Test-Node
    if ($script:TargetCommandOnly -and $Command -ne "setup") {
        if (-not (Test-Path -LiteralPath $script:WorkDir -PathType Container)) { Die "Configured workdir no longer exists: $($script:WorkDir)" }
    } else {
        Ensure-WorkDir
    }

        if ($DryRun) {
            Write-Info "Would resolve the latest release for $($script:Repo)"
        Write-Info "Would download and verify the bridge zip"
        Write-Info "Would install under $($script:Prefix)\bridge\current"
        Write-Info "Would create launcher: $($script:BinDir)\opencode-mobile-bridge.cmd"
        Write-Info "Would create setup/up/down/status launchers"
        if (-not (Test-Path -LiteralPath $script:ConfigFile)) { Write-Info "Setup requires icacls and the current username to write a protected config" }
        if ($Command -eq "setup" -and (Test-Path -LiteralPath $script:ConfigFile)) {
            Write-Ok "Would keep existing config: $($script:ConfigFile)"
            Write-Info "Pairing requires an explicitly protected config ACL"
        }
        foreach ($path in @($script:Prefix, (Join-Path $script:Prefix "bridge"), (Join-Path $script:Prefix "bridge\current"), $script:BinDir, (Join-Path $script:BinDir "opencode-mobile-bridge.cmd"), (Join-Path $script:BinDir "opencode-mobile-env.ps1"), (Join-Path $script:BinDir "opencode-mobile-installer.ps1"))) {
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to install through a reparse point: $path" }
            }
        }
        Write-Info "Dry run complete. No files were changed."
        return
    }

    $script:ReleaseInfo = Resolve-Release
    $asset = "opencode-mobile-bridge-$($script:ReleaseInfo.Version).zip"
    Write-Info "Release: $($script:ReleaseInfo.Tag)"
    Write-Info "Asset: $asset"

    $temp = New-TempDir
    $zip = Join-Path $temp $asset
    Invoke-Download (Get-ReleaseUrl $asset) $zip
    Assert-Checksum $zip $asset $temp
    if ($script:ReleaseInfo.Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { Die "Release version is not a valid package version" }

    $unpack = Join-Path $temp "unpack"
    Expand-Archive -Path $zip -DestinationPath $unpack -Force
    $src = $unpack
    if (-not (Test-Path (Join-Path $src "package.json"))) {
        $children = @(Get-ChildItem -LiteralPath $src -Directory)
        if ($children.Count -ne 1) { Die "Bridge archive has an ambiguous or unexpected layout" }
        $src = $children[0].FullName
    }
    if (-not (Test-Path (Join-Path $src "package.json"))) { Die "Bridge archive is missing package.json" }
    if (-not (Test-Path (Join-Path $src "dist\index.js"))) { Die "Bridge archive is missing dist\index.js" }
    if (-not (Test-Path (Join-Path $src "node_modules"))) { Die "Bridge archive is missing node_modules" }

    $bridgeRoot = Join-Path $script:Prefix "bridge"
    $dest = Join-Path $bridgeRoot "current"
    foreach ($path in @($script:Prefix, $bridgeRoot, $dest, $script:BinDir, (Join-Path $script:BinDir "opencode-mobile-bridge.cmd"), (Join-Path $script:BinDir "opencode-mobile-env.ps1"), (Join-Path $script:BinDir "opencode-mobile-installer.ps1"), $script:ConfigFile)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to install through a reparse point: $path" }
        }
    }
    $workPrefix = $script:WorkDir.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    $destPrefix = $dest.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if ($workPrefix.StartsWith($destPrefix, [StringComparison]::OrdinalIgnoreCase) -or $destPrefix.StartsWith($workPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Die "Install path and configured workdir must not contain one another"
    }
    New-Item -ItemType Directory -Path $bridgeRoot -Force | Out-Null
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -Path (Join-Path $src "*") -Destination $dest -Recurse -Force
    Write-Ok "Bridge installed at $dest"

    New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
    $launcher = Join-Path $script:BinDir "opencode-mobile-bridge.cmd"
    $launcherContent = @'
@echo off
setlocal
"__POWERSHELL__" -NoProfile -ExecutionPolicy Bypass -File "__ENV_LOADER__" %*
exit /b %ERRORLEVEL%
'@
    $envLoader = Join-Path $script:BinDir "opencode-mobile-env.ps1"
    $envLoaderContent = @'
$ErrorActionPreference = "Stop"
$requiredKeys = @("PORT", "HOST", "AUTH_TOKEN", "ALLOWED_WORKDIRS", "DATA_DIR", "LOG_LEVEL", "PUSH_ENABLED")
$allowedKeys = @($requiredKeys + @("OPENCODE_URL", "OPENCODE_PASSWORD"))
$configValues = @{}
$config = $env:OPENCODE_MOBILE_CONFIG
if (-not $config) { $config = "__CONFIG_PATH__" }
$config = [IO.Path]::GetFullPath($config)
$expectedConfigPath = [IO.Path]::GetFullPath("__CONFIG_PATH__")
if ($config -ine $expectedConfigPath) { throw "OPENCODE_MOBILE_CONFIG must point to the setup-managed config file" }
$bridge = "__BRIDGE_ENTRY__"
$expectedWorkdir = "__WORK_DIR__"
$expectedDataDir = "__DATA_DIR__"
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw "Missing config: $config" }
$configInfo = Get-Item -LiteralPath $config
if ($configInfo.Length -gt 65536) { throw "Config file is unexpectedly large" }
$configItem = Get-Item -LiteralPath $config -Force
if (($configItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to read a config reparse point" }
$configDirectory = Get-Item -LiteralPath (Split-Path -Parent $config) -Force
if (($configDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to read through a config directory reparse point" }
foreach ($line in Get-Content -LiteralPath $config) {
    if ($line -match '^([A-Z_]+)=(.*)$') {
        if ($allowedKeys -notcontains $Matches[1] -or $configValues.ContainsKey($Matches[1])) { throw "Config contains an unsupported or duplicate field" }
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') { $value = $value.Substring(1, $value.Length - 2) }
        $configValues[$Matches[1]] = $value
        [Environment]::SetEnvironmentVariable($Matches[1], $value, "Process")
    } elseif ($line -notmatch '^\s*(#.*)?$') {
        throw "Config contains an invalid line"
    }
}

function Register-McpServer {
    if ($DryRun) {
        Write-Info "Would register the local OpenCode Mobile MCP server without bridge credentials"
        return
    }
    if (-not (Has-Command "opencode")) {
        Write-Warn "OpenCode CLI is not installed; MCP registration was skipped. Rerun setup after installing it."
        return
    }
    $port = "8787"
    if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $script:ConfigFile) {
            if ($line -match '^PORT=(\d{1,5})$') { $port = $Matches[1]; break }
        }
    }
    if ([int]$port -lt 1 -or [int]$port -gt 65535) { Die "Bridge port is invalid; refusing to register MCP." }
    $node = (Get-Command node -ErrorAction Stop).Source
    $bridgeEntry = Join-Path $script:Prefix "bridge\current\dist\index.js"
    if (-not (Test-Path -LiteralPath $bridgeEntry -PathType Leaf)) { Die "Bridge entry point is missing; cannot register MCP." }
    $arguments = @("mcp", "add", "--global", "--env", "PORT=$port", "opencode-mobile", "--", $node, $bridgeEntry, "mcp")
    & opencode @arguments
    if ($LASTEXITCODE -ne 0) { Die "OpenCode MCP registration failed (exit $LASTEXITCODE)." }
    Write-Ok "Registered local OpenCode Mobile MCP server (reload OpenCode to activate it)"
}
foreach ($key in $requiredKeys) { if (-not $configValues.ContainsKey($key)) { throw "Config is missing required fields" } }
if (($configValues.ContainsKey("OPENCODE_URL") -xor $configValues.ContainsKey("OPENCODE_PASSWORD"))) { throw "OPENCODE_URL and OPENCODE_PASSWORD must be set together" }
if ($configValues.AUTH_TOKEN -notmatch '^[a-fA-F0-9]{64}$' -or $configValues.HOST -ne '127.0.0.1' -or $configValues.LOG_LEVEL -notin @('info','debug','warn','error') -or $configValues.PUSH_ENABLED -notin @('0','1')) { throw "Config validation failed" }
if (-not $env:AUTH_TOKEN -or $env:AUTH_TOKEN -notmatch '^[a-fA-F0-9]{64}$' -or $env:HOST -ne '127.0.0.1') { throw "Bridge config failed validation" }
if (-not $env:PORT -or $env:PORT -notmatch '^\d{1,5}$' -or [int]$env:PORT -lt 1 -or [int]$env:PORT -gt 65535) { throw "Bridge port is invalid" }
if (-not $env:ALLOWED_WORKDIRS -or -not (Test-Path -LiteralPath $env:ALLOWED_WORKDIRS -PathType Container)) { throw "Configured workdir is missing or inaccessible" }
if (-not $env:DATA_DIR -or -not (Test-Path -LiteralPath $env:DATA_DIR -PathType Container)) { throw "Configured data directory is missing or inaccessible" }
if ([IO.Path]::GetFullPath($env:ALLOWED_WORKDIRS).TrimEnd('\') -ine [IO.Path]::GetFullPath($expectedWorkdir).TrimEnd('\')) { throw "Config workdir does not match the configured project directory" }
if ([IO.Path]::GetFullPath($env:DATA_DIR).TrimEnd('\') -ine [IO.Path]::GetFullPath($expectedDataDir).TrimEnd('\')) { throw "Config data directory does not match the installer data directory" }
if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) { throw "Installed bridge entry point is missing" }
& node $bridge @args
exit $LASTEXITCODE
'@
    foreach ($replacement in @{
        "__CONFIG_PATH__" = $script:ConfigFile
        "__BRIDGE_ENTRY__" = (Join-Path $script:Prefix "bridge\current\dist\index.js")
        "__WORK_DIR__" = $script:WorkDir
        "__DATA_DIR__" = $script:DataDir
    }.GetEnumerator()) {
        $literal = "'" + $replacement.Value.Replace("'", "''") + "'"
        $envLoaderContent = $envLoaderContent.Replace('"' + $replacement.Key + '"', $literal)
    }
    [IO.File]::WriteAllText($envLoader, $envLoaderContent, [Text.Encoding]::UTF8)
    $powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
    $launcherContent = $launcherContent.Replace("__ENV_LOADER__", $envLoader).Replace("__POWERSHELL__", $powershellExe)
    [IO.File]::WriteAllText($launcher, $launcherContent, [Text.Encoding]::ASCII)
    Write-Ok "Launcher: $launcher"

    $installerCopy = Join-Path $script:BinDir "opencode-mobile-installer.ps1"
    Copy-Item -LiteralPath $PSCommandPath -Destination $installerCopy -Force
    $commands = @{
        "opencode-mobile.cmd" = "up"
        "opencode-mobile-up.cmd" = "up"
        "opencode-mobile-down.cmd" = "down"
        "opencode-mobile-status.cmd" = "status"
    }
    $powershellForCmd = (Get-Command powershell.exe -ErrorAction Stop).Source
    foreach ($entry in $commands.GetEnumerator()) {
            $cmdPath = Join-Path $script:BinDir $entry.Key
            $installerForCmd = $installerCopy
        $cmdText = "@echo off`r`nsetlocal`r`n`"$powershellForCmd`" -NoProfile -ExecutionPolicy Bypass -File `"$installerForCmd`" -Command $($entry.Value) -WorkDirOverride `"$($script:ConfigFile)`" %*`r`nexit /b %ERRORLEVEL%`r`n"
        [IO.File]::WriteAllText($cmdPath, $cmdText, [Text.Encoding]::ASCII)
    }

    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    New-BridgeConfig

    $pathParts = ($env:PATH -split ";")
    if ($pathParts -notcontains $script:BinDir) {
        Write-Warn "$($script:BinDir) is not in PATH. Add it or run $launcher directly."
    }
    Write-Ok "Start with: opencode-mobile.cmd"
}

function Install-Apk {
    Write-Step "Installing the Android app"
    Need-Command "adb"
    if ($DryRun) {
        Write-Info "Would resolve the latest release for $($script:Repo)"
        Write-Info "Would download and verify the APK"
        Write-Info "Would run: adb install -r <apk>"
        Write-Info "Dry run complete. No files were changed."
        return
    }

    $script:ReleaseInfo = Resolve-Release
    $asset = "opencode-mobile-$($script:ReleaseInfo.Version).apk"
    Write-Info "Release: $($script:ReleaseInfo.Tag)"
    Write-Info "Asset: $asset"

    $temp = New-TempDir
    $apk = Join-Path $temp $asset
    Invoke-Download (Get-ReleaseUrl $asset) $apk
    Assert-Checksum $apk $asset $temp
    & adb install -r $apk
    if ($LASTEXITCODE -ne 0) { Die "adb install failed" }
    Write-Ok "APK installed"
}

function Read-BridgeConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) { Die "Config not found: $($script:ConfigFile); run setup first" }
    $configFileItem = Get-Item -LiteralPath $script:ConfigFile -Force
    if (($configFileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to read a config reparse point: $($script:ConfigFile)" }
    $configDirItem = Get-Item -LiteralPath (Split-Path -Parent $script:ConfigFile) -Force
    if (($configDirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to use a config directory reparse point" }
    $config = @{}
    $allowedKeys = @("PORT", "HOST", "AUTH_TOKEN", "ALLOWED_WORKDIRS", "DATA_DIR", "LOG_LEVEL", "PUSH_ENABLED", "OPENCODE_URL", "OPENCODE_PASSWORD")
    $configFile = Get-Item -LiteralPath $script:ConfigFile
    if ($configFile.Length -gt 65536) { Die "Config file is unexpectedly large" }
    $configLines = @(Get-Content -LiteralPath $script:ConfigFile)
    if ($configLines.Count -gt 32) { Die "Config has too many lines" }
    foreach ($line in $configLines) {
        if ($line -match '^([A-Z_]+)=(.*)$') {
            $key = $Matches[1]
            $rawValue = $Matches[2]
            if ($rawValue -match '[`r`n]') { Die "Config field $key contains a line break" }
            $value = $rawValue.Trim()
            if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') {
                $value = $value.Substring(1, $value.Length - 2)
            }
            if ($allowedKeys -notcontains $key) { Die "Config contains an unsupported field: $key" }
            if ($config.ContainsKey($key)) { Die "Config contains a duplicate field: $key" }
            $config[$key] = $value
        } elseif ($line -notmatch '^\s*(#.*)?$') {
            Die "Config contains an invalid line"
        }
    }
    foreach ($required in @("PORT", "HOST", "AUTH_TOKEN", "ALLOWED_WORKDIRS", "DATA_DIR", "LOG_LEVEL", "PUSH_ENABLED")) {
        if (-not $config.ContainsKey($required)) { Die "Config is missing required field: $required" }
    }
    if ($config.LOG_LEVEL -notin @("info", "debug", "warn", "error") -or $config.PUSH_ENABLED -notin @("0", "1")) {
        Die "Config contains an invalid setting"
    }
    if ($config.AUTH_TOKEN -notmatch '^[a-fA-F0-9]{64}$') { Die "Config has no valid AUTH_TOKEN" }
    if ($config.HOST -ne "127.0.0.1") { Die "HOST must be 127.0.0.1 for quickstart" }
    if ($config.PORT -notmatch '^\d{1,5}$' -or [int]$config.PORT -lt 1 -or [int]$config.PORT -gt 65535) { Die "Config PORT is invalid" }
    if (-not $config.ALLOWED_WORKDIRS -or $config.ALLOWED_WORKDIRS.Contains(',') -or $config.ALLOWED_WORKDIRS -match '[\r\n]') { Die "Quickstart requires exactly one valid configured workdir" }
    if ($config.ALLOWED_WORKDIRS -match '^[A-Za-z]:[^\\/]' -or $config.DATA_DIR -match '^[A-Za-z]:[^\\/]') { Die "Config contains a drive-relative path" }
    if (-not $config.DATA_DIR) { Die "Config has no DATA_DIR" }
    if ($config.PORT -ne "8787") { Die "Windows pairing requires port 8787" }
    if ($script:TargetCommandOnly -and -not $WorkDirOverride) {
        $script:WorkDir = [IO.Path]::GetFullPath($config.ALLOWED_WORKDIRS)
        $script:DataDir = [IO.Path]::GetFullPath($config.DATA_DIR)
        $script:Prefix = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $script:ConfigFile)))
        $script:BinDir = [IO.Path]::GetFullPath((Join-Path $script:Prefix "bin"))
    }
    if ($script:TargetCommandOnly) {
        $script:WorkDir = [IO.Path]::GetFullPath($config.ALLOWED_WORKDIRS)
        $script:DataDir = [IO.Path]::GetFullPath($config.DATA_DIR)
    }
    $expectedData = [IO.Path]::GetFullPath($script:DataDir)
    try {
        $expectedWork = [IO.Path]::GetFullPath($script:WorkDir)
        if ([IO.Path]::GetFullPath($config.ALLOWED_WORKDIRS).TrimEnd([char[]]@('\', '/')) -ine $expectedWork.TrimEnd([char[]]@('\', '/'))) { Die "Configured workdir differs from setup; rerun setup with the intended workdir" }
        if ([IO.Path]::GetFullPath($config.DATA_DIR).TrimEnd([char[]]@('\', '/')) -ine $expectedData.TrimEnd([char[]]@('\', '/'))) { Die "Configured DATA_DIR differs from setup; rerun setup" }
    } catch {
        Die "Invalid path in bridge config"
    }
    return $config
}

function Initialize-InstalledContext {
    if (-not $script:TargetCommandOnly) { return }
    if (-not $script:ConfigFile) { Die "Installed config path is unavailable" }
    $config = Read-BridgeConfig
    if (-not $WorkDirOverride) {
        $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME ".local\share" }
        $appData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME ".config" }
        $script:Prefix = [IO.Path]::GetFullPath((Join-Path $localAppData "opencode-mobile"))
        $script:BinDir = [IO.Path]::GetFullPath((Join-Path $script:Prefix "bin"))
        $script:ConfigFile = [IO.Path]::GetFullPath((Join-Path $appData "opencode-mobile\bridge.env"))
    }
    $script:WorkDir = [IO.Path]::GetFullPath($config.ALLOWED_WORKDIRS)
    $script:DataDir = [IO.Path]::GetFullPath($config.DATA_DIR)
    $script:Prefix = [IO.Path]::GetFullPath($Prefix)
    $script:BinDir = [IO.Path]::GetFullPath($script:BinDir)
    $script:TargetCommandOnly = $true
    if ($Command -eq "up") {
        $bridgeEntry = Join-Path $script:Prefix "bridge\current\dist\index.js"
        if (-not (Test-Path -LiteralPath $bridgeEntry -PathType Leaf)) { Die "Bridge installation is missing" }
    }
    if (-not (Test-Path -LiteralPath $script:WorkDir -PathType Container)) { Die "Configured workdir no longer exists" }
}

function Start-MobileSession {
    Initialize-InstalledContext
    $config = Read-BridgeConfig
    if ($config.PORT -ne "8787") { Die "Windows quickstart requires the default bridge port 8787" }
    if (-not (Test-Path -LiteralPath $script:Prefix -PathType Container)) { Die "Install directory is missing; run setup first" }
    foreach ($rootCandidate in @($script:Prefix, $script:BinDir, $script:WorkDir, $script:DataDir)) {
        if ([IO.Path]::GetFullPath($rootCandidate).TrimEnd([char[]]@('\', '/')) -eq [IO.Path]::GetPathRoot($rootCandidate).TrimEnd([char[]]@('\', '/'))) {
            Die "Refusing to use a filesystem root for pairing or installation"
        }
    }
    $configPath = [IO.Path]::GetFullPath($script:ConfigFile)
    if (-not (Has-Command "icacls") -or -not $env:USERNAME) { Die "Cannot verify pairing config ACL; install icacls or run this from a user session" }
    $configFileInfo = Get-Item -LiteralPath $configPath -Force
    if (($configFileInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to adjust ACL on a config reparse point" }
    $configDir = Split-Path -Parent $configPath
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) { Die "Config directory is missing: $configDir" }
    if ($script:TargetCommandOnly) {
        $dirItem = Get-Item -LiteralPath $configDir -Force
        if (($dirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to repair a config directory reparse point" }
    }
    & icacls $configDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F" /grant:r "Administrators:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "Could not repair the pairing config directory ACL" }
    $aclOutput = & icacls $configPath /inheritance:r /grant:r "$($env:USERNAME):(R,W)" /grant:r "SYSTEM:(R,W)" /grant:r "Administrators:(R,W)"
    if ($LASTEXITCODE -ne 0) { Die "Could not repair the pairing config ACL" }
    $fileAclExit = $LASTEXITCODE
    $aclOutput = & icacls $configPath
    $aclText = $aclOutput -join "`n"
    $usernameEscaped = [regex]::Escape($env:USERNAME)
    $hasUserAce = $aclText -match "(?m)^\s+${usernameEscaped}:\(R,W\)" -or $aclText -match "(?m)^\s+${usernameEscaped}:\(OI\)\(CI\)F"
    $hasOtherUserAce = $aclText -match '(?m)^\s+(Everyone|Users|Authenticated Users|BUILTIN\\Users):'
    if (($fileAclExit -ne 0) -or ($LASTEXITCODE -ne 0) -or (-not $hasUserAce) -or $hasOtherUserAce) {
        Die "Pairing config ACL is not verifiably restricted to the current user; rerun setup or repair permissions"
    }
    $workdir = $config.ALLOWED_WORKDIRS
    if (-not (Test-Path -LiteralPath $workdir -PathType Container)) { Die "Configured workdir does not exist: $workdir" }
    if (-not (Test-Path -LiteralPath $config.DATA_DIR -PathType Container)) { Die "Configured DATA_DIR does not exist: $($config.DATA_DIR)" }
    Need-Command "opencode"
    Need-Command "curl.exe"
    if (-not (Has-Command "cloudflared.exe") -and -not (Has-Command "cloudflared")) {
        Die "cloudflared is required for Windows pairing. Install it from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/, then retry."
    }
    $tunnelCommand = if (Has-Command "cloudflared.exe") { "cloudflared.exe" } else { "cloudflared" }
    $port = [int]$config.PORT
    $existingBridge = $false
    if (Has-Command "Get-NetTCPConnection") {
        $existingBridge = [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1)
    } else {
        $probe = New-Object Net.Sockets.TcpClient
        try {
            $connect = $probe.BeginConnect("127.0.0.1", $port, $null, $null)
            $existingBridge = $connect.AsyncWaitHandle.WaitOne(1000) -and $probe.Connected
            $connect.AsyncWaitHandle.Close()
        } finally { $probe.Close() }
    }
    if ($existingBridge) { Die "A bridge is already listening on port $port. Stop it before starting another session." }
    if (Has-Command "Get-NetTCPConnection") {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener) { Die "Port $port is already occupied by PID $($listener.OwningProcess). Stop that process before starting the bridge." }
    } else {
        $probe = New-Object Net.Sockets.TcpClient
        try {
            $connect = $probe.BeginConnect("127.0.0.1", $port, $null, $null)
            if ($connect.AsyncWaitHandle.WaitOne(1000) -and $probe.Connected) { Die "Port $port is occupied; stop the listener before starting the bridge." }
            $connect.AsyncWaitHandle.Close()
        } finally { $probe.Close() }
    }

    Write-Host "Cloudflare Quick Tunnels create a public temporary URL. Anyone holding the pairing URL and token can access the configured workdir."
    if ([Console]::IsInputRedirected) { Die "Pairing requires an interactive terminal for public-tunnel consent" }
    $answer = Read-Host "Create a temporary public tunnel now? [y/N]"
    if ($answer -notmatch '^(y|yes)$') { Die "Cancelled." }
    $bridgeEntry = Join-Path $script:Prefix "bridge\current\dist\index.js"
    if (-not (Test-Path -LiteralPath $bridgeEntry -PathType Leaf)) { Die "Bridge is not installed; run setup first" }
    $nodeVersion = (& node -p "process.versions.node.split('.')[0]").Trim()
    if ($nodeVersion -notmatch '^\d+$' -or [int]$nodeVersion -lt 22) { Die "Node.js 22 or newer is required" }
    $script:ServiceStarted = $true
    & opencode service start
    if ($LASTEXITCODE -ne 0) { Die "Could not start the OpenCode service" }
    $bridge = $null
    $tunnel = $null
    try {
        $bridge = Start-Process -FilePath "node" -ArgumentList @('"' + $bridgeEntry + '"') -PassThru -WindowStyle Hidden
        $ready = $false
        for ($i=0; $i -lt 45; $i++) {
            Start-Sleep -Seconds 1
            if ($bridge.HasExited) { Die "Bridge exited during startup" }
            try {
                $health = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 1
                if ($health.StatusCode -eq 200) { $ready=$true; break }
            } catch { }
        }
        if (-not $ready) { Die "Bridge health check timed out" }

        $tunnelLog = Join-Path ([IO.Path]::GetTempPath()) ("opencode-mobile-tunnel-" + [guid]::NewGuid().ToString("N") + ".log")
        $tunnelErrorLog = "$tunnelLog.stderr"
    $tunnel = Start-Process -FilePath $tunnelCommand -ArgumentList @('tunnel','--no-autoupdate','--url',"http://127.0.0.1:$port") -RedirectStandardOutput $tunnelLog -RedirectStandardError $tunnelErrorLog -PassThru -WindowStyle Hidden
    $url = $null
    $tunnelOutput = ""
    for ($i=0; $i -lt 45; $i++) {
            Start-Sleep -Seconds 1
        if ($tunnel.HasExited) { Die "Cloudflare tunnel exited before providing a URL" }
        foreach ($logPath in @($tunnelLog, $tunnelErrorLog)) {
            if (Test-Path -LiteralPath $logPath) {
                    $tunnelOutput = (Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue)
        $match = [regex]::Match($tunnelOutput, 'https://[a-zA-Z0-9-]+\.trycloudflare\.com')
                    if ($match.Success) { $url = $match.Value; break }
                }
            }
            if ($url) { break }
        }
        if (-not $url) { Die "Timed out waiting for a Cloudflare tunnel URL" }

    $payloadText = "opencode-mobile://connect/?url=$([Uri]::EscapeDataString($url))&token=$([Uri]::EscapeDataString($config.AUTH_TOKEN))"
    $payloadUri = [Uri]::new($payloadText)
        Write-Host "`nOpenCode Mobile pairing ready"
            Write-Host "Bridge URL: $url"
            Write-Host "Pairing token: $($config.AUTH_TOKEN)"
        Write-Host "QR payload: $payloadText"
        if (Has-Command "qrencode.exe") {
            $payloadText | & qrencode.exe -t ANSIUTF8
        } elseif (Has-Command "qrencode") {
            $payloadText | & qrencode -t ANSIUTF8
        } else {
            Write-Warn "qrencode is not installed. Enter the URL and token manually; install it with: winget install QRencode.QRencode"
        }
        if ($CopyPairing) {
            if (-not (Has-Command "Set-Clipboard")) { Die "Clipboard copy is unavailable in this PowerShell session" }
            Set-Clipboard -Value $payloadText
            Write-Ok "Connection payload copied to clipboard"
        }
        Write-Warn "The URL and token grant access to the configured workdir. Do not share the QR, terminal output, or clipboard contents."
        Write-Host "Keep this PowerShell window open. Press Ctrl+C to stop the managed session."
        $script:TunnelProcess = $tunnel
        Wait-Process -Id $tunnel.Id
    } finally {
        if ($tunnel -and -not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
        if ($bridge -and -not $bridge.HasExited) { Stop-Process -Id $bridge.Id -Force -ErrorAction SilentlyContinue }
        if ($script:ServiceStarted) {
            & opencode service stop | Out-Null
            $script:ServiceStarted = $false
        }
        if ($tunnelLog -and (Test-Path $tunnelLog)) { Remove-Item $tunnelLog -Force -ErrorAction SilentlyContinue }
        if ($tunnelErrorLog -and (Test-Path $tunnelErrorLog)) { Remove-Item $tunnelErrorLog -Force -ErrorAction SilentlyContinue }
    }
}

function Get-MobileStatus {
    Initialize-InstalledContext
    try { $config = Read-BridgeConfig } catch { Write-Host "Bridge: config error"; return $false }
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:$($config.PORT)/health" -UseBasicParsing -TimeoutSec 2
        Write-Host "Bridge: running on port $($config.PORT)"
        return $true
    } catch { Write-Host "Bridge: stopped"; return $false }
}

function Invoke-Doctor {
    Write-Step "Doctor"
    $failures = 0

    Write-Host "OS: $([Environment]::OSVersion.VersionString)"
    if (Has-Command "node") {
        Write-Host "Node: $(& node -v)"
        $major = (& node -p "process.versions.node.split('.')[0]").Trim()
        if ($major -match '^\d+$' -and [int]$major -ge 22) {
            Write-Ok "Node version is supported"
        } else {
            Write-Warn "Node 22 or newer is required"
            $failures++
        }
    } else {
        Write-Warn "Node.js is not installed"
        $failures++
    }
    if (Has-Command "npm") { Write-Ok "npm: $(& npm -v)" } else { Write-Warn "npm is not installed"; $failures++ }

    if (Test-Path -LiteralPath $script:ConfigFile) {
        Write-Ok "Config exists: $($script:ConfigFile)"
        if (Has-Command "icacls") {
            $acl = (& icacls $script:ConfigFile) -join "`n"
            if ($acl -match '(?m)^\s+(Everyone|Users|Authenticated Users|BUILTIN\\Users):') {
                Write-Warn "Config grants access to a broad user group"
                $failures++
            }
        }
        $tokenLine = Get-Content -Path $script:ConfigFile | Where-Object { $_ -match '^AUTH_TOKEN=' } | Select-Object -First 1
        $token = if ($tokenLine) { ($tokenLine -split '=', 2)[1] } else { "" }
        if ($token.Length -ge 32) {
            Write-Ok "Token length: $($token.Length) characters"
        } else {
            Write-Warn "Token is shorter than 32 characters"
            $failures++
        }
        $portLine = Get-Content -Path $script:ConfigFile | Where-Object { $_ -match '^PORT=' } | Select-Object -First 1
        $port = if ($portLine) { ($portLine -split '=', 2)[1] } else { "8787" }
        try {
            $health = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 3
            if ($health.StatusCode -eq 200) { Write-Ok "Bridge health endpoint responds on port $port" }
        } catch {
            Write-Warn "Bridge health endpoint did not respond on port $port"
        }
    } else {
        Write-Warn "Config not found: $($script:ConfigFile) (run install first)"
        $failures++
    }

    $launcher = Join-Path $script:BinDir "opencode-mobile-bridge.cmd"
    if (Test-Path -LiteralPath $launcher) {
        Write-Ok "Launcher exists: $launcher"
    } else {
        Write-Warn "Launcher not found: $launcher"
        $failures++
    }

    if (Has-Command "adb") {
        Write-Ok "adb: $((& adb version | Select-Object -First 1))"
    } else {
        Write-Info "adb not installed; APK installation is unavailable"
    }

    if ($failures -eq 0) {
        Write-Ok "No blocking issues found"
        return $true
    }
    Write-Warn "$failures issue(s) found"
    return $false
}

function Uninstall-All {
    Write-Step "Uninstalling"
    if ($Purge -and -not $DryRun) {
        if ([Console]::IsInputRedirected) { Die "Purge requires interactive confirmation" }
        $purgeConfirm = Read-Host "Purge config and runtime data permanently? Type PURGE to continue:"
        if ($purgeConfirm -cne "PURGE") { Write-Info "Purge cancelled; config and data will be kept."; $script:KeepData = $true; return }
    }
    if ($Purge -and -not $DryRun) {
        if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) { Die "Refusing purge because config file is missing" }
        $purgeConfig = Read-BridgeConfig
        $configDataPath = [IO.Path]::GetFullPath($purgeConfig.DATA_DIR).TrimEnd([char[]]@('\', '/'))
        $purgeDataPath = [IO.Path]::GetFullPath($script:DataDir).TrimEnd([char[]]@('\', '/'))
        if ($configDataPath -ine $purgeDataPath) { Die "Purge data path differs from validated config" }
        $configDir = Split-Path -Parent $script:ConfigFile
        foreach ($path in @($configDir, $script:DataDir)) {
            if ($path -eq [IO.Path]::GetPathRoot($path)) { Die "Refusing to purge a filesystem root: $path" }
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to purge through a reparse point: $path" }
            }
        }
    }
    if ($script:TargetBridge -and -not $DryRun) {
        $probe = New-Object Net.Sockets.TcpClient
        try {
            $connect = $probe.BeginConnect("127.0.0.1", 8787, $null, $null)
            $active = $connect.AsyncWaitHandle.WaitOne(1000) -and $probe.Connected
            $connect.AsyncWaitHandle.Close()
        } finally { $probe.Close() }
        if ($active) { Die "A process is listening on the bridge port. Stop the pairing session before uninstalling." }
    }
    if ($DryRun -and $Purge) { $script:KeepData = $false }
    if ($script:TargetApk) {
        if (Has-Command "adb") {
            if ($DryRun) {
                Write-Info "Would run: adb uninstall $($script:PackageId)"
            } else {
                if (-not $Yes) {
                    $apkConfirm = Read-Host "Uninstall OpenCode Mobile from the attached Android device? [y/N]"
                    if ($apkConfirm -notmatch '^(y|yes)$') { Write-Info "APK uninstall cancelled."; return }
                }
                & adb uninstall $script:PackageId
                if ($LASTEXITCODE -ne 0) { Write-Warn "APK was not installed on this device" }
            }
        } else {
            Write-Warn "adb is not installed; skipped APK removal"
        }
    }

    if ($script:TargetBridge) {
        if ($DryRun) {
            Write-Info "Would remove bridge and launcher paths"
        } else {
            $bridgeRoot = Join-Path $script:Prefix "bridge"
            $launcher = Join-Path $script:BinDir "opencode-mobile-bridge.cmd"
        $launchers = @(
            $launcher,
            (Join-Path $script:BinDir "opencode-mobile-installer.ps1"),
            (Join-Path $script:BinDir "opencode-mobile-env.ps1"),
            (Join-Path $script:BinDir "opencode-mobile.cmd"),
            (Join-Path $script:BinDir "opencode-mobile-up.cmd"),
            (Join-Path $script:BinDir "opencode-mobile-down.cmd"),
            (Join-Path $script:BinDir "opencode-mobile-status.cmd")
        )
            foreach ($path in @($bridgeRoot, $script:Prefix, $script:BinDir, $script:ConfigFile, (Split-Path -Parent $script:ConfigFile), $script:DataDir)) {
                if (Test-Path -LiteralPath $path) {
                    $item = Get-Item -LiteralPath $path -Force
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Die "Refusing to uninstall through a reparse point: $path" }
                }
            }
            if (Test-Path -LiteralPath $bridgeRoot) {
                $bridgeChildren = @(Get-ChildItem -LiteralPath $bridgeRoot -Force)
                Remove-Item -LiteralPath $bridgeRoot -Recurse -Force
            }
            foreach ($path in $launchers) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            }
            Write-Ok "Removed bridge files"
        }
    }

    if ($Purge -and $script:KeepData) {
        Write-Info "Config and data were kept."
    } elseif ($Purge) {
        $configDir = Split-Path -Parent $script:ConfigFile
        if ($DryRun) {
            Write-Info "Would remove $configDir"
            Write-Info "Would remove $($script:DataDir)"
        } else {
            # The explicit PURGE confirmation above authorizes removal; -Yes does not bypass it.
            if (Test-Path -LiteralPath $configDir) { Remove-Item -LiteralPath $configDir -Recurse -Force }
            if (Test-Path -LiteralPath $script:DataDir) { Remove-Item -LiteralPath $script:DataDir -Recurse -Force }
            Write-Ok "Removed config and data"
        }
    } else {
        Write-Info "Config and data were kept. Use -Purge to remove them."
    }
}

function Invoke-Main {
    Initialize-Paths

    switch ($Command) {
        "install" {
            if ($script:TargetApk -and -not $DryRun -and -not $Yes) {
                $apkConfirm = Read-Host "Install OpenCode Mobile APK on the attached Android device? [y/N]"
                if ($apkConfirm -notmatch '^(y|yes)$') { Write-Info "APK install cancelled."; return }
            }
            if ($script:TargetBridge -and -not $DryRun -and -not $Yes) {
                $bridgeConfirm = Read-Host "Install the OpenCode Mobile bridge for the current user? [Y/n]"
                if ($bridgeConfirm -match '^(n|no)$') { Write-Info "Bridge install cancelled."; $script:TargetBridge = $false }
            }
            if ($script:TargetBridge) { Install-Bridge }
            if ($script:TargetCommandOnly) { break }
            if ($script:TargetApk) { Install-Apk }
        }
        "setup" {
            $script:TargetCommandOnly = $false
            Ensure-WorkDir
            $script:TargetBridge = $true
            Install-Bridge
            if ($DryRun) { break }
            if (-not (Has-Command "opencode")) {
                Write-Warn "OpenCode CLI is not installed. Install it before running opencode-mobile.cmd."
                break
            }
            Register-McpServer
            Write-Ok "Setup complete. Run opencode-mobile.cmd to start and pair your phone."
        }
        "up" {
            if ($DryRun) {
                Write-Info "Would verify the bridge config and its ACL"
                Write-Info "Would start OpenCode and the local bridge"
                Write-Info "Would ask before creating a temporary public tunnel"
                Write-Info "Would display URL/token/QR and stop child processes on exit"
            } else {
                if ($PSVersionTable.PSVersion.Major -lt 5) { Die "Windows pairing requires PowerShell 5.1 or newer" }
                Start-MobileSession
            }
        }
        "down" {
            if ($DryRun) { Write-Info "Would check local bridge health; the foreground owner stops its child processes on exit." }
            else {
                if (Get-MobileStatus) {
                    Write-Warn "Windows session cleanup is managed by the foreground pairing window. Press Ctrl+C in that window; this command will not kill unrelated user processes."
                } else { Write-Info "No active bridge session detected." }
            }
        }
        "status" {
            if ($DryRun) { Write-Info "Would check local bridge health." }
            elseif (-not (Get-MobileStatus)) { exit 1 }
        }
        "update" {
            if ($script:TargetBridge -and -not $DryRun -and -not $Yes) {
                $answer = Read-Host "Replace the installed bridge with the latest verified release? [y/N]"
                if ($answer -notmatch '^(y|yes)$') { Write-Info "Update cancelled."; return }
            }
            if ($script:TargetBridge) { Install-Bridge }
            if ($script:TargetApk -and -not $DryRun -and -not $Yes) {
                $apkConfirm = Read-Host "Update OpenCode Mobile APK on the attached Android device? [y/N]"
                if ($apkConfirm -notmatch '^(y|yes)$') { Write-Info "APK update skipped."; $script:TargetApk = $false }
            }
            if ($script:TargetApk) { Install-Apk }
        }
        "doctor" {
            if (-not (Invoke-Doctor)) { exit 1 }
        }
        "uninstall" {
            Initialize-InstalledContext
            $script:TargetBridge = $true
            $script:TargetApk = $false
            if ($Apk) { $script:TargetBridge = $false; $script:TargetApk = $true }
            if ($All) { $script:TargetBridge = $true; $script:TargetApk = $true }
            if (-not $DryRun -and -not $Yes -and $script:TargetBridge) {
                if ([Console]::IsInputRedirected) { Die "Uninstall requires interactive confirmation" }
                $confirm = Read-Host "Type REMOVE to delete the bridge installation and launchers:"
                if ($confirm -cne "REMOVE") { Write-Info "Uninstall cancelled."; return }
                $script:BridgeConfirmed = $true
            }
            if ($Purge -and -not $DryRun -and [Console]::IsInputRedirected) { Die "Purge requires an interactive terminal" }
            Uninstall-All
        }
        "version" {
            Write-Host "opencode-mobile-installer $($script:InstallerVersion)"
        }
        "help" {
            Show-Help
        }
        default {
            Die "Unknown command: $Command"
        }
    }
}

try {
    if ($Command -eq "help") {
        Show-Help
        exit 0
    }
    Invoke-Main
} catch [System.Management.Automation.PipelineStoppedException] {
    Write-Host "Pairing session stopped."
    exit 130
} catch {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Die $_.Exception.Message
} finally {
    if ($script:ServiceStarted) {
        & opencode service stop | Out-Null
        $script:ServiceStarted = $false
    }
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
