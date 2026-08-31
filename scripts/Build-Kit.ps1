<#
.SYNOPSIS
    Assembles the USB kit at -UsbRoot from this repo's kit\ tree plus a
    freshly-installed Claude Code native binary, checksum-verified tools,
    and (optionally) a Windows install.wim for DISM /Source:.

    Run this on YOUR machine, with internet access, before handing the
    drive to anyone. It never touches a target/repair machine.

.PARAMETER UsbRoot
    Drive root to build into, e.g. E:\. Must exist and have room for the
    kit (~a few GB for tools, ~5-6GB more if -IsoPath is supplied).

.PARAMETER IsoPath
    Optional path to a Windows installation ISO. If supplied, its
    install.wim/install.esd is extracted to $UsbRoot\iso\ for DISM
    /Source: use — see docs/iso-role.md. If omitted, the kit still builds,
    but DISM /RestoreHealth will have no local source on the target
    machine.

.PARAMETER SkipToolFetch
    Skip downloading/verifying tools from scripts\tool-manifest.json.
    Useful for iterating on the kit\ scripts themselves without re-pulling
    every tool binary each time.

.EXAMPLE
    .\scripts\Build-Kit.ps1 -UsbRoot E:\ -IsoPath D:\Win11_24H2_English_x64.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsbRoot,
    [string]$IsoPath,
    [switch]$SkipToolFetch
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-BuildLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$ts] [$Level] $Message"
}

if (-not (Test-Path $UsbRoot)) {
    throw "UsbRoot '$UsbRoot' does not exist. Point this at an already-formatted, mounted drive."
}

# --- 1. Native Claude Code binary -----------------------------------------
Write-BuildLog "Ensuring a native Claude Code install exists on this machine..."
$localClaude = Join-Path $env:USERPROFILE '.local\share\claude'
if (-not (Test-Path $localClaude)) {
    Write-BuildLog 'No local native install found — running the official installer (irm https://claude.ai/install.ps1 | iex).'
    Invoke-Expression (Invoke-RestMethod 'https://claude.ai/install.ps1')
}

$versionsDir = Join-Path $localClaude 'versions'
$latestVersion = Get-ChildItem $versionsDir -Directory -ErrorAction Stop |
    Sort-Object { [version]($_.Name -replace '[^\d.]', '') } -Descending |
    Select-Object -First 1

if (-not $latestVersion) {
    throw "No installed version found under $versionsDir — install may have failed."
}

$destClaudeDir = Join-Path $UsbRoot 'bin\claude'
Write-BuildLog "Copying $($latestVersion.FullName) -> $destClaudeDir"
New-Item -ItemType Directory -Path $destClaudeDir -Force | Out-Null
Copy-Item -Path (Join-Path $latestVersion.FullName '*') -Destination $destClaudeDir -Recurse -Force

if (-not (Test-Path (Join-Path $destClaudeDir 'claude.exe'))) {
    throw "claude.exe not found in $destClaudeDir after copy. See docs/verification-checklist.md step 2 - this copy has not been confirmed to produce a working portable binary."
}
Write-BuildLog "Native binary staged. NOTE: whether this copy actually runs standalone from a non-default path is unverified — see docs/verification-checklist.md."

# --- 2. Copy the kit tree ---------------------------------------------------
Write-BuildLog "Copying kit\ -> $UsbRoot"
Copy-Item -Path (Join-Path $RepoRoot 'kit\*') -Destination $UsbRoot -Recurse -Force -Exclude 'config'
# config\ copied separately so we don't clobber an existing auth.env on rebuild
$destConfigDir = Join-Path $UsbRoot 'config'
New-Item -ItemType Directory -Path $destConfigDir -Force | Out-Null
Copy-Item -Path (Join-Path $RepoRoot 'kit\config\auth.env.example') -Destination $destConfigDir -Force

foreach ($dir in @('state\.claude', 'logs', 'backups', 'iso')) {
    New-Item -ItemType Directory -Path (Join-Path $UsbRoot $dir) -Force | Out-Null
}

# The agent reads docs\tool-invocations.md at repair time for exact command
# lines, and CLAUDE.md cross-references the other design docs. They're small
# markdown files, so ship the whole folder rather than cherry-picking and
# leaving the agent with dangling references.
$destDocsDir = Join-Path $UsbRoot 'docs'
New-Item -ItemType Directory -Path $destDocsDir -Force | Out-Null
Copy-Item -Path (Join-Path $RepoRoot 'docs\*.md') -Destination $destDocsDir -Force
Write-BuildLog "Copied design docs to $destDocsDir"

if (-not (Test-Path (Join-Path $destDocsDir 'tool-invocations.md'))) {
    throw "docs\tool-invocations.md did not reach the drive. CLAUDE.md instructs the agent to read it for exact tool invocations; without it the agent would infer switches on a broken machine."
}

# --- 3. Auth ----------------------------------------------------------------
$authEnvPath = Join-Path $destConfigDir 'auth.env'
if (-not (Test-Path $authEnvPath)) {
    Write-BuildLog 'No config\auth.env on this drive yet.' 'WARN'
    Write-Host ''
    Write-Host 'Run this now on this machine to generate a subscription-bound token:'
    Write-Host '    claude setup-token'
    Write-Host "Then create $authEnvPath with:"
    Write-Host '    CLAUDE_CODE_OAUTH_TOKEN=<the token you were given>'
    Write-Host 'See docs/authentication.md. Build will continue, but Start-Repair.ps1 refuses to launch without this.'
    Write-Host ''
}

# --- 4. Tools ----------------------------------------------------------------
if ($SkipToolFetch) {
    Write-BuildLog 'Skipping tool fetch (-SkipToolFetch).'
} else {
    $manifestPath = Join-Path $PSScriptRoot 'tool-manifest.json'
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

    foreach ($tool in $manifest.tools) {
        if (-not $tool.url -or -not $tool.sha256) {
            Write-BuildLog "Skipping '$($tool.name)': url or sha256 not yet populated in tool-manifest.json. See docs/status.md." 'WARN'
            continue
        }

        # "unpinned" is a deliberate, documented exception for tools whose
        # binary legitimately changes every build — MSERT bundles its own
        # signatures and expires ~10 days after download, so a pinned hash
        # would be wrong by design. Requires a stated reason so this can't
        # become a casual way around checksum verification.
        $unpinned = ($tool.sha256 -eq 'unpinned')
        if ($unpinned -and -not $tool._unpinned_reason) {
            throw "Tool '$($tool.name)' is marked unpinned but has no _unpinned_reason. Refusing to fetch an unverified binary without a documented justification."
        }

        $destDir = Join-Path $UsbRoot $tool.destination
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        $downloadPath = Join-Path $env:TEMP "$($tool.name)-download"

        Write-BuildLog "Downloading $($tool.name) from $($tool.url)"
        Invoke-WebRequest -Uri $tool.url -OutFile $downloadPath -UseBasicParsing

        $actualHash = (Get-FileHash -Path $downloadPath -Algorithm SHA256).Hash
        if ($unpinned) {
            Write-BuildLog "UNPINNED: $($tool.name) fetched without checksum verification. Reason: $($tool._unpinned_reason)" 'WARN'
            Write-BuildLog "  SHA256 of the copy shipped on this drive: $actualHash"
        } elseif ($actualHash -ne $tool.sha256) {
            Remove-Item $downloadPath -Force
            throw "Checksum mismatch for $($tool.name): expected $($tool.sha256), got $actualHash. Refusing to place an unverified binary on the kit."
        } else {
            Write-BuildLog "Checksum verified for $($tool.name)."
        }

        if ($downloadPath -like '*.zip') {
            Expand-Archive -Path $downloadPath -DestinationPath $destDir -Force
        } else {
            Copy-Item -Path $downloadPath -Destination $destDir -Force
        }
        Remove-Item $downloadPath -Force
    }

    # Sysinternals ships as one suite archive, so tools excluded from the
    # whitelist arrive whether we want them or not. Delete them rather than
    # relying on the deny rule alone — see docs/tool-whitelist.md.
    $excludedBinaries = @('sdelete.exe', 'sdelete64.exe', 'sdelete64a.exe')
    foreach ($binary in $excludedBinaries) {
        Get-ChildItem -Path (Join-Path $UsbRoot 'tools') -Filter $binary -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-BuildLog "Removing non-whitelisted binary from kit: $($_.FullName)"
                Remove-Item $_.FullName -Force
            }
    }
}

# --- 5. ISO / WIM extraction -------------------------------------------------
if ($IsoPath) {
    if (-not (Test-Path $IsoPath)) {
        throw "IsoPath '$IsoPath' not found."
    }
    Write-BuildLog "Mounting $IsoPath to extract install.wim for DISM /Source:..."
    $mount = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $driveLetter = ($mount | Get-Volume).DriveLetter
    try {
        $sourceWim = "${driveLetter}:\sources\install.wim"
        if (-not (Test-Path $sourceWim)) {
            $sourceWim = "${driveLetter}:\sources\install.esd"
        }
        if (-not (Test-Path $sourceWim)) {
            throw "Neither install.wim nor install.esd found on the mounted ISO."
        }
        $isoDestDir = Join-Path $UsbRoot 'iso'
        Copy-Item -Path $sourceWim -Destination $isoDestDir -Force
        Write-BuildLog "Copied $(Split-Path -Leaf $sourceWim) to $isoDestDir"
    } finally {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }
} else {
    Write-BuildLog "No -IsoPath supplied - DISM /RestoreHealth will have no local source on the target machine. See docs/iso-role.md." 'WARN'
}

Write-BuildLog "Build complete at $UsbRoot. Run docs/verification-checklist.md before deploying this kit to a real repair."
