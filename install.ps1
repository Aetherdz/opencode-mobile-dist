# OpenCode Mobile installer for Windows PowerShell 5.1+.
# The generated token is never printed. The config file is written with a
# restrictive ACL when icacls is available.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "update", "doctor", "uninstall", "version", "help")]
    [string]$Command = "install",

    [switch]$Bridge,
    [switch]$Apk,
    [switch]$All,

    [string]$Prefix = "",
    [string]$BinDir = "",
    [string]$WorkDir = "",
    [string]$DataDir = "",
    [string]$ConfigFile = "",
    [string]$Repo = "zaikabdou1/opencode-mobile",
    [string]$Release = "",

    [switch]$DryRun,
    [switch]$NoColor,
    [switch]$Purge,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:InstallerVersion = "0.1.0"
$script:PackageId = "com.zaikabdou1.opencodemobile"
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
$script:TempDir = ""

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
    if ([int]$raw -lt 20) {
        Die "Node.js 20 or newer is required (found $(& node -v))"
    }
}

function Initialize-Paths {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $homeDir ".local\share" }
    $appData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $homeDir ".config" }

    if (-not $Prefix) { $Prefix = Join-Path $localAppData "opencode-mobile" }
    if (-not $BinDir) { $BinDir = Join-Path $Prefix "bin" }
    if (-not $WorkDir) { $WorkDir = Join-Path $homeDir "projects" }
    if (-not $DataDir) { $DataDir = Join-Path $Prefix "data" }
    if (-not $ConfigFile) { $ConfigFile = Join-Path $appData "opencode-mobile\bridge.env" }

    $script:Prefix = [IO.Path]::GetFullPath($Prefix)
    $script:BinDir = [IO.Path]::GetFullPath($BinDir)
    $script:WorkDir = [IO.Path]::GetFullPath($WorkDir)
    $script:DataDir = [IO.Path]::GetFullPath($DataDir)
    $script:ConfigFile = [IO.Path]::GetFullPath($ConfigFile)

    foreach ($path in @($script:Prefix, $script:BinDir)) {
        if ($path -eq [IO.Path]::GetPathRoot($path)) {
            Die "Refusing to use the filesystem root: $path"
        }
    }

    if ($script:Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        Die "-Repo must look like OWNER/REPO"
    }
    if ($script:Release -and $script:Release -notmatch '^[A-Za-z0-9._-]+$') {
        Die "-Release contains invalid characters"
    }

    $script:TargetBridge = $true
    $script:TargetApk = $false
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
  .\install.ps1 -Command install [-Bridge|-Apk|-All] [-WorkDir DIR]
  .\install.ps1 -Command doctor
  .\install.ps1 -Command uninstall [-Purge]

Commands:
  install       Install the bridge (default) and optionally the Android app.
  update        Replace the installed bridge with the latest release.
  doctor        Check dependencies, permissions, and bridge health.
  uninstall     Remove installed files. Add -Purge to remove config and data.
  version       Print the installer version.
  help          Show this help.

Options:
  -Prefix DIR      Install root. Default: %LOCALAPPDATA%\opencode-mobile
  -BinDir DIR      Launcher directory. Default: <prefix>\bin
  -WorkDir DIR     Directory the bridge may access. Default: %USERPROFILE%\projects
  -DataDir DIR     Bridge data directory. Default: <prefix>\data
  -ConfigFile FILE Config path. Default: %APPDATA%\opencode-mobile\bridge.env
  -Repo OWNER/REPO Source repository. Default: zaikabdou1/opencode-mobile
  -Release TAG     Release tag. Default: latest release
  -DryRun          Print actions without downloading or writing files.
  -NoColor         Disable colored output.
  -Purge           With uninstall, remove config and data too.
  -Yes             Accepted for non-interactive use.

Examples:
  .\install.ps1 -Command install -WorkDir "$env:USERPROFILE\code"
  .\install.ps1 -Command install -Apk
  .\install.ps1 -Command install -All -DryRun
  .\install.ps1 -Command doctor
  .\install.ps1 -Command uninstall -Purge

The installer never prints the generated AUTH_TOKEN.
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
            $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:Repo)/releases/latest" -Headers $headers
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
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $script:TempDir = $path
    return $path
}

function Ensure-WorkDir {
    if (-not (Test-Path -LiteralPath $script:WorkDir -PathType Container)) {
        if ($DryRun) {
            Write-Info "Would create workdir: $($script:WorkDir)"
            return
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
    if (Test-Path -LiteralPath $script:ConfigFile) {
        Write-Ok "Keeping existing config: $($script:ConfigFile)"
        return
    }
    if ($DryRun) {
        Write-Info "Would write config: $($script:ConfigFile)"
        return
    }

    $configDir = Split-Path -Parent $script:ConfigFile
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null

    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
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
        "ALLOWED_WORKDIRS=$($script:WorkDir)",
        "DATA_DIR=$($script:DataDir)",
        "LOG_LEVEL=info",
        "PUSH_ENABLED=1"
    )
    [IO.File]::WriteAllText($script:ConfigFile, (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    Write-Ok "Wrote config: $($script:ConfigFile)"

    if ((Has-Command "icacls") -and $env:USERNAME) {
        try {
            & icacls $script:ConfigFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
            Write-Ok "Restricted config permissions"
        } catch {
            Write-Warn "Could not restrict config ACL; check the file manually"
        }
    }
}

function Install-Bridge {
    Write-Step "Installing the bridge"
    Test-Node
    Ensure-WorkDir

    if ($DryRun) {
        Write-Info "Would resolve the latest release for $($script:Repo)"
        Write-Info "Would download and verify the bridge zip"
        Write-Info "Would install under $($script:Prefix)\bridge\current"
        Write-Info "Would create launcher: $($script:BinDir)\opencode-mobile-bridge.cmd"
        New-BridgeConfig
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

    $unpack = Join-Path $temp "unpack"
    Expand-Archive -Path $zip -DestinationPath $unpack -Force
    $src = $unpack
    if (-not (Test-Path (Join-Path $src "package.json"))) {
        $first = Get-ChildItem -LiteralPath $src -Directory | Select-Object -First 1
        if (-not $first) { Die "Bridge archive has an unexpected layout" }
        $src = $first.FullName
    }
    if (-not (Test-Path (Join-Path $src "package.json"))) { Die "Bridge archive is missing package.json" }
    if (-not (Test-Path (Join-Path $src "dist\index.js"))) { Die "Bridge archive is missing dist\index.js" }
    if (-not (Test-Path (Join-Path $src "node_modules"))) { Die "Bridge archive is missing node_modules" }

    $bridgeRoot = Join-Path $script:Prefix "bridge"
    $dest = Join-Path $bridgeRoot "current"
    New-Item -ItemType Directory -Path $bridgeRoot -Force | Out-Null
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -Path (Join-Path $src "*") -Destination $dest -Recurse -Force
    Write-Ok "Bridge installed at $dest"

    New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
    $launcher = Join-Path $script:BinDir "opencode-mobile-bridge.cmd"
    $launcherContent = @"
@echo off
setlocal
set "CONFIG=$($script:ConfigFile)"
if not exist "%CONFIG%" (
  echo Missing config: %CONFIG% 1>&2
  exit /b 1
)
for /f "usebackq tokens=1,* delims==" %%A in ("%CONFIG%") do (
  if not "%%A"=="" set "%%A=%%B"
)
node "$($script:Prefix)\bridge\current\dist\index.js" %*
"@
    [IO.File]::WriteAllText($launcher, $launcherContent, [Text.Encoding]::ASCII)
    Write-Ok "Launcher: $launcher"

    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    New-BridgeConfig

    $pathParts = ($env:PATH -split ";")
    if ($pathParts -notcontains $script:BinDir) {
        Write-Warn "$($script:BinDir) is not in PATH. Add it or run $launcher directly."
    }
    Write-Ok "Start with: opencode-mobile-bridge.cmd"
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

function Invoke-Doctor {
    Write-Step "Doctor"
    $failures = 0

    Write-Host "OS: $([Environment]::OSVersion.VersionString)"
    if (Has-Command "node") {
        Write-Host "Node: $(& node -v)"
        $major = (& node -p "process.versions.node.split('.')[0]").Trim()
        if ($major -match '^\d+$' -and [int]$major -ge 20) {
            Write-Ok "Node version is supported"
        } else {
            Write-Warn "Node 20 or newer is required"
            $failures++
        }
    } else {
        Write-Warn "Node.js is not installed"
        $failures++
    }
    if (Has-Command "npm") { Write-Ok "npm: $(& npm -v)" } else { Write-Warn "npm is not installed"; $failures++ }

    if (Test-Path -LiteralPath $script:ConfigFile) {
        Write-Ok "Config exists: $($script:ConfigFile)"
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
    if ($script:TargetApk) {
        if (Has-Command "adb") {
            if ($DryRun) {
                Write-Info "Would run: adb uninstall $($script:PackageId)"
            } else {
                & adb uninstall $script:PackageId
                if ($LASTEXITCODE -ne 0) { Write-Warn "APK was not installed on this device" }
            }
        } else {
            Write-Warn "adb is not installed; skipped APK removal"
        }
    }

    if ($script:TargetBridge) {
        $bridgeRoot = Join-Path $script:Prefix "bridge"
        $launcher = Join-Path $script:BinDir "opencode-mobile-bridge.cmd"
        if ($DryRun) {
            Write-Info "Would remove $bridgeRoot"
            Write-Info "Would remove $launcher"
        } else {
            if (Test-Path -LiteralPath $bridgeRoot) { Remove-Item -LiteralPath $bridgeRoot -Recurse -Force }
            if (Test-Path -LiteralPath $launcher) { Remove-Item -LiteralPath $launcher -Force }
            Write-Ok "Removed bridge files"
        }
    }

    if ($Purge) {
        $configDir = Split-Path -Parent $script:ConfigFile
        if ($DryRun) {
            Write-Info "Would remove $configDir"
            Write-Info "Would remove $($script:DataDir)"
        } else {
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
            if ($script:TargetBridge) { Install-Bridge }
            if ($script:TargetApk) { Install-Apk }
        }
        "update" {
            if ($script:TargetBridge) { Install-Bridge }
            if ($script:TargetApk) { Install-Apk }
        }
        "doctor" {
            if (-not (Invoke-Doctor)) { exit 1 }
        }
        "uninstall" {
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
} catch {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Die $_.Exception.Message
} finally {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
