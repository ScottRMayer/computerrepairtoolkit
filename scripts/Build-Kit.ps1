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
    [switch]$SkipToolFetch,

    # Build the ~300MB smoke-test drive: claude.exe + the kit tree, no tool
    # binaries and no Windows image. This exists so the ONE load-bearing
    # assumption — does the copied native claude.exe launch and authenticate
    # from a USB path on a machine that never had Claude installed — gets
    # answered before anyone downloads 8GB of tools and an ISO to find out the
    # binary didn't survive the copy. Run this first, always.
    [switch]$Minimal,

    # Optional recovery ISO(s) to stage into \ISO\ for the Ventoy boot menu
    # (WinPE recovery image, MemTest86+, etc.). Ventoy itself is installed to
    # the USB separately with its own installer BEFORE this build — see
    # docs/offline-repair-playbook.md. This only copies ISOs into place and
    # checksums them.
    [string[]]$RecoveryIso,

    # Folder where you've downloaded the bundled tools from their vendor pages
    # (see GET-TOOLS.md). Build-Kit ingests each tool from here by filename
    # pattern — copying or extracting it onto the drive and recording its
    # SHA-256 — which sidesteps the unstable/redirecting vendor download URLs.
    # Tools with a stable direct URL in the manifest are still fetched
    # automatically; staging takes precedence when a matching file is present.
    [string]$StagingDir
)

if ($Minimal) { $SkipToolFetch = $true }

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 (the default host on the build PC) renders a
# Write-Progress bar for Invoke-WebRequest -OutFile and Expand-Archive that
# throttles large downloads/extractions badly (PowerShell/PowerShell#2138).
$ProgressPreference = 'SilentlyContinue'
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

$destClaudeDir = Join-Path $UsbRoot 'bin\claude'
New-Item -ItemType Directory -Path $destClaudeDir -Force | Out-Null

# The installed layout differs by platform, so detect it rather than assume:
#   - Windows native: a single self-contained claude.exe (~200MB) in
#     .local\bin\, and .local\share\claude\versions\ is EMPTY.
#   - macOS/Linux (and possibly future Windows): a versioned payload dir
#     under .local\share\claude\versions\<version>\ that must be copied whole.
$versionsDir = Join-Path $localClaude 'versions'
$latestVersion = if (Test-Path $versionsDir) {
    Get-ChildItem $versionsDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Name -replace '[^\d.]', '') } -Descending |
        Select-Object -First 1
} else { $null }

if ($latestVersion) {
    Write-BuildLog "Copying versioned payload $($latestVersion.FullName) -> $destClaudeDir"
    Copy-Item -Path (Join-Path $latestVersion.FullName '*') -Destination $destClaudeDir -Recurse -Force
} else {
    # Single-file layout: find the real binary. Prefer the known install path,
    # fall back to whatever `claude` resolves to on PATH.
    $binExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (-not (Test-Path $binExe)) {
        $binExe = (Get-Command claude -ErrorAction SilentlyContinue).Source
    }
    if (-not $binExe -or -not (Test-Path $binExe)) {
        throw "Could not locate claude.exe to stage. Looked for a versions\ payload under '$versionsDir' (none) and a single binary at '$env:USERPROFILE\.local\bin\claude.exe' (none). Run: dir `$env:USERPROFILE\.local\bin"
    }
    Write-BuildLog "Copying self-contained binary $binExe -> $destClaudeDir\claude.exe ($([math]::Round((Get-Item $binExe).Length/1MB)) MB)"
    Copy-Item -Path $binExe -Destination (Join-Path $destClaudeDir 'claude.exe') -Force
}

if (-not (Test-Path (Join-Path $destClaudeDir 'claude.exe'))) {
    throw "claude.exe not found in $destClaudeDir after copy. See docs/verification-checklist.md step 2."
}
Write-BuildLog "Native binary staged. The build gate below is the real check that this copy runs."

# --- 2. Copy the kit tree ---------------------------------------------------
Write-BuildLog "Copying kit\ -> $UsbRoot"
# Exclude every build-output / runtime directory: a developer checkout that
# has run Start-Repair.ps1 (or any kit script) carries kit\logs, kit\state
# (session transcripts, a credential store!), kit\reports etc., and a naive
# copy would ship them to the drive.
Copy-Item -Path (Join-Path $RepoRoot 'kit\*') -Destination $UsbRoot -Recurse -Force `
    -Exclude 'config', 'state', 'logs', 'bin', 'tools', 'iso', 'backups', 'reports'
# config\ copied separately, file by file, so we ship every template and policy
# file (auth.env.example, system-prompt-append.txt, settings, etc.) WITHOUT
# clobbering a real auth.env that a prior build already placed on the drive.
$destConfigDir = Join-Path $UsbRoot 'config'
New-Item -ItemType Directory -Path $destConfigDir -Force | Out-Null
Get-ChildItem -Path (Join-Path $RepoRoot 'kit\config') -File |
    Where-Object { $_.Name -ne 'auth.env' } |
    ForEach-Object { Copy-Item -Path $_.FullName -Destination $destConfigDir -Force }

# tools\ is created even for -Minimal: CLAUDE.md's sanity check expects the
# kit's directories to be siblings, and an absent folder reads as "wrong
# directory" rather than "no bundled tools".
foreach ($dir in @('state\.claude', 'logs', 'backups', 'reports', 'iso', 'tools')) {
    New-Item -ItemType Directory -Path (Join-Path $UsbRoot $dir) -Force | Out-Null
}

# The agent reads docs\tool-invocations.md at repair time for exact command
# lines, and CLAUDE.md cross-references a few other design docs. Ship ONLY
# those: docs\spec.md declares itself authoritative over other docs and
# describes a design target the code does not fully implement (a different
# result file name, scripts that do not exist) — an agent that consulted it
# on the target would follow the wrong contract.
$destDocsDir = Join-Path $UsbRoot 'docs'
New-Item -ItemType Directory -Path $destDocsDir -Force | Out-Null
$shipDocs = @('tool-invocations.md', 'repair-playbook.md', 'safe-mode-constraints.md', 'offline-repair-playbook.md',
              'tool-whitelist.md', 'iso-role.md', 'authentication.md', 'usb-layout.md', 'verification-checklist.md')
Get-ChildItem -Path $destDocsDir -Filter '*.md' -ErrorAction SilentlyContinue |
    Where-Object { $shipDocs -notcontains $_.Name } |
    ForEach-Object { Remove-Item $_.FullName -Force }   # a previous build shipped everything
foreach ($doc in $shipDocs) {
    Copy-Item -Path (Join-Path $RepoRoot "docs\$doc") -Destination $destDocsDir -Force
}
Write-BuildLog "Copied the agent-facing docs ($($shipDocs.Count) files) to $destDocsDir"

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
    $why = if ($Minimal) { '-Minimal' } else { '-SkipToolFetch' }
    Write-BuildLog "Skipping tool fetch ($why)."
    if ($StagingDir) { Write-BuildLog "Ignoring -StagingDir '$StagingDir' because $why was specified." 'WARN' }
} else {
    $manifestPath = Join-Path $PSScriptRoot 'tool-manifest.json'
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $staged = 0; $fetched = 0; $skipped = 0
    $shipped = New-Object System.Collections.Generic.List[object]
    $missingRequired = New-Object System.Collections.Generic.List[string]

    foreach ($tool in $manifest.tools) {
        $destDir = Join-Path $UsbRoot $tool.destination

        # Place a source artifact (a downloaded file/folder) into $destDir,
        # extracting a .zip or copying anything else, and log its SHA-256.
        function Publish-Artifact([string]$src, [string]$name) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            if ((Get-Item $src).PSIsContainer) {
                Copy-Item -Path (Join-Path $src '*') -Destination $destDir -Recurse -Force
                Write-BuildLog "  staged folder '$name' -> $($tool.destination)"
            } elseif ($src -like '*.zip') {
                # Extract into a fresh temp directory so the wrapper-folder
                # hoist below is deterministic: on a REBUILD the destination
                # already holds last time's files, and a hoist that inspects
                # the destination would see more than one root and leave the
                # new binary nested one level down beside the stale one.
                $tmp = Join-Path $env:TEMP ("kit-extract-" + [guid]::NewGuid().ToString('N'))
                try {
                    Expand-Archive -Path $src -DestinationPath $tmp -Force
                    # Some portable zips wrap everything in a single versioned
                    # top-level folder (e.g. BleachBit-Portable\, Win11Debloat-<tag>\).
                    # Hoist it so the binary lands at tools\<name>\<binary> as the
                    # playbook and docs expect. Only fires when the archive has
                    # exactly one root entry and it's a directory; flat zips (WizTree,
                    # Speedtest, SDIO, NirSoft, Sysinternals) are left untouched.
                    $roots = @(Get-ChildItem -LiteralPath $tmp -Force)
                    $from = $tmp
                    if ($roots.Count -eq 1 -and $roots[0].PSIsContainer) {
                        $from = $roots[0].FullName
                        Write-BuildLog "  flattened wrapper folder '$($roots[0].Name)' in $($tool.destination)"
                    }
                    Copy-Item -Path (Join-Path $from '*') -Destination $destDir -Recurse -Force
                } finally {
                    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
                }
                Write-BuildLog "  extracted '$name' -> $($tool.destination) (SHA256 $((Get-FileHash $src -Algorithm SHA256).Hash))"
            } else {
                Copy-Item -Path $src -Destination $destDir -Force
                Write-BuildLog "  copied '$name' -> $($tool.destination) (SHA256 $((Get-FileHash $src -Algorithm SHA256).Hash))"
            }
        }

        # Extra staged files (a config profile) and an extra staged folder (a
        # driverpack tree) that ride along with the tool. Both are optional
        # and only ever come from -StagingDir.
        function Publish-Extras {
            if (-not $StagingDir -or -not (Test-Path $StagingDir)) { return }
            foreach ($glob in @($tool.staging_extra)) {
                if (-not $glob) { continue }
                Get-ChildItem -Path $StagingDir -Filter $glob -File -ErrorAction SilentlyContinue | ForEach-Object {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                    Copy-Item -Path $_.FullName -Destination $destDir -Force
                    Write-BuildLog "  staged extra file '$($_.Name)' -> $($tool.destination)"
                }
            }
            if ($tool.staging_extra_dir) {
                $extra = Join-Path $StagingDir $tool.staging_extra_dir
                if (Test-Path $extra -PathType Container) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                    Copy-Item -Path (Join-Path $extra '*') -Destination $destDir -Recurse -Force
                    Write-BuildLog "  staged extra folder '$($tool.staging_extra_dir)\*' -> $($tool.destination)"
                }
            }
        }
        function Record-Shipped([string]$source, [string]$hash) {
            $shipped.Add([ordered]@{ name = $tool.name; destination = $tool.destination; present = $true; source = $source; sha256 = $hash })
        }

        # 1) Prefer a staged download (robust against dead vendor URLs).
        $stagedHit = $null
        if ($StagingDir -and $tool.staging_glob -and (Test-Path $StagingDir)) {
            $stagedHit = Get-ChildItem -Path $StagingDir -Filter $tool.staging_glob -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        if ($stagedHit) {
            Write-BuildLog "Staging '$($tool.name)' from $($stagedHit.Name)"
            Publish-Artifact $stagedHit.FullName $stagedHit.Name
            Publish-Extras
            $h = if ($stagedHit.PSIsContainer) { 'folder' } else { (Get-FileHash $stagedHit.FullName -Algorithm SHA256).Hash }
            Record-Shipped "staging:$($stagedHit.Name)" $h
            $staged++
            continue
        }

        # 2) Otherwise fetch from a stable URL if one is pinned (or unpinned).
        if (-not $tool.url -or -not $tool.sha256) {
            $level = if ($tool.required) { 'ERROR' } else { 'WARN' }
            Write-BuildLog "Skipping '$($tool.name)': not found in staging and no pinned url/sha256. Download it per GET-TOOLS.md into -StagingDir." $level
            if ($tool.required) { $missingRequired.Add($tool.name) }
            $shipped.Add([ordered]@{ name = $tool.name; destination = $tool.destination; present = $false; source = 'skipped: staging only, not staged' })
            $skipped++
            continue
        }

        # "unpinned" is a deliberate, documented exception for a binary that
        # legitimately changes every build (e.g. MSERT bundles its own
        # signatures and expires ~10 days out). Requires a stated reason so it
        # can't become a casual way around checksum verification.
        $unpinned = ($tool.sha256 -eq 'unpinned')
        if ($unpinned -and -not $tool._unpinned_reason) {
            throw "Tool '$($tool.name)' is marked unpinned but has no _unpinned_reason. Refusing to fetch an unverified binary without a documented justification."
        }

        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        # Pick a local filename that carries the right extension so Publish-Artifact
        # can tell a .zip (extract) from a bare .exe (copy). Some vendor URLs have
        # no usable extension (e.g. AdwCleaner's .../file/adwcleaner serves the name
        # via Content-Disposition), so the manifest may set an explicit "filename".
        $dlName = if ($tool.filename) { $tool.filename }
                  elseif ($tool.url -like '*.zip') { "$($tool.name).zip" }
                  else { $tool.name }
        $downloadPath = Join-Path $env:TEMP $dlName
        Write-BuildLog "Downloading $($tool.name) from $($tool.url)"
        # A browser UA matters: NirSoft (and some CDNs) reject empty/scripted
        # agents. Follow redirects (Malwarebytes/WizTree bounce through a CDN).
        try {
            Invoke-WebRequest -Uri $tool.url -OutFile $downloadPath -UseBasicParsing `
                -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -MaximumRedirection 5
        } catch {
            # A dead/rotated URL (version-pinned links 404 on the next release)
            # must not abort the whole build - skip this tool and tell the
            # operator to stage it instead.
            Write-BuildLog "Skipping '$($tool.name)': download failed from $($tool.url) - $($_.Exception.Message). Stage it per GET-TOOLS.md into -StagingDir." 'WARN'
            if (Test-Path $downloadPath) { Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue }
            $shipped.Add([ordered]@{ name = $tool.name; destination = $tool.destination; present = $false; source = "skipped: download failed ($($_.Exception.Message))" })
            $skipped++
            continue
        }

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
        Publish-Artifact $downloadPath $tool.name
        Publish-Extras
        Record-Shipped "url:$($tool.url)" $actualHash
        Remove-Item $downloadPath -Force
        $fetched++
    }
    Write-BuildLog "Tools: $staged staged, $fetched fetched, $skipped skipped."

    # What actually landed, for the agent (CLAUDE.md: a tool absent here is
    # a capability that is unavailable, not a reason to go looking for it).
    $shippedPath = Join-Path $UsbRoot 'tools\shipped-tools.json'
    [ordered]@{ built_at = (Get-Date -Format 'o'); tools = @($shipped) } | ConvertTo-Json -Depth 4 | Set-Content -Path $shippedPath -Encoding UTF8
    Write-BuildLog "Wrote $shippedPath"

    if ($missingRequired.Count -gt 0) {
        throw "REQUIRED tool(s) missing from the build: $($missingRequired -join ', '). smartctl is the disk-health gate every write-heavy repair depends on; stage it per GET-TOOLS.md (or build with -Minimal for the smoke-test drive). Refusing to print FULL DRIVE BUILT for a drive that cannot run its own safety gate."
    }

    # Sysinternals ships as one suite archive, so tools excluded from the
    # whitelist arrive whether we want them or not. Delete them rather than
    # relying on the deny rule alone — see docs/tool-whitelist.md. PsExec is
    # a lateral-movement tool with no repair use in this kit; it must not
    # ship in a directory the launcher excludes from Defender.
    $excludedBinaries = @('sdelete.exe', 'sdelete64.exe', 'sdelete64a.exe', 'PsExec.exe', 'PsExec64.exe')
    foreach ($binary in $excludedBinaries) {
        Get-ChildItem -Path (Join-Path $UsbRoot 'tools') -Filter $binary -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-BuildLog "Removing non-whitelisted binary from kit: $($_.FullName)"
                Remove-Item $_.FullName -Force
            }
    }
}

# --- 5. ISO / WIM extraction -------------------------------------------------
if ($Minimal -and $IsoPath) {
    Write-BuildLog 'Ignoring -IsoPath because -Minimal was specified (smoke-test drive carries no Windows image).' 'WARN'
    $IsoPath = $null
}

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
        New-Item -ItemType Directory -Path $isoDestDir -Force | Out-Null

        # Pre-flight: a Windows install.wim is routinely >4GB. A FAT32 USB
        # cannot hold a single file that big (Windows reports the 4GB overflow
        # as "not enough space on disk", which is misleading), and any drive
        # too small rejects the copy with a raw IOException after writing GBs.
        # Fail early with an actionable message instead.
        $wimBytes = (Get-Item $sourceWim).Length
        $wimGB = [math]::Round($wimBytes / 1GB, 2)
        $destLetter = (Split-Path -Qualifier $isoDestDir).TrimEnd(':')
        $destVol = Get-Volume -DriveLetter $destLetter -ErrorAction SilentlyContinue
        if ($destVol) {
            if ($destVol.FileSystem -eq 'FAT32' -and $wimBytes -ge 4GB) {
                throw "$(Split-Path -Leaf $sourceWim) is $wimGB GB, but drive ${destLetter}: is FAT32 (4GB max per file - Windows reports this as 'not enough space'). Reformat the drive as NTFS (recommended for a Windows repair drive) or exFAT, then re-run the build; the tools re-fetch quickly. e.g.  Format-Volume -DriveLetter $destLetter -FileSystem NTFS"
            }
            if ($null -ne $destVol.SizeRemaining -and $destVol.SizeRemaining -lt $wimBytes) {
                $freeGB = [math]::Round($destVol.SizeRemaining / 1GB, 2)
                throw "Not enough free space on ${destLetter}: for $(Split-Path -Leaf $sourceWim): need $wimGB GB, have $freeGB GB free. Use a larger drive or free space, then re-run."
            }
        }

        Copy-Item -Path $sourceWim -Destination $isoDestDir -Force
        Write-BuildLog "Copied $(Split-Path -Leaf $sourceWim) ($wimGB GB) to $isoDestDir"

        # Record what landed so the agent can build the right DISM /Source:
        # an .esd needs the ESD: prefix, and index 1 of a multi-edition image
        # is usually Home, not the target's edition. iso\image-info.json lists
        # every index with its edition name; the launcher copies it into
        # session-context.json.
        $imageFile = Join-Path $isoDestDir (Split-Path -Leaf $sourceWim)
        $indexes = New-Object System.Collections.Generic.List[object]
        try {
            $info = & dism.exe /Get-WimInfo "/WimFile:$imageFile" 2>&1 | Out-String
            $cur = $null
            foreach ($line in ($info -split "`r?`n")) {
                if ($line -match '^\s*Index\s*:\s*(\d+)') { $cur = [ordered]@{ index = [int]$Matches[1]; name = ''; description = '' } ; $indexes.Add($cur) }
                elseif ($cur -and $line -match '^\s*Name\s*:\s*(.+)$') { $cur.name = $Matches[1].Trim() }
                elseif ($cur -and $line -match '^\s*Description\s*:\s*(.+)$') { $cur.description = $Matches[1].Trim() }
            }
        } catch {
            Write-BuildLog "Could not read the image index table (dism /Get-WimInfo): $_" 'WARN'
        }
        $imageInfo = [ordered]@{
            file          = "iso\$(Split-Path -Leaf $sourceWim)"
            format        = if ($imageFile -like '*.esd') { 'ESD' } else { 'WIM' }
            source_prefix = if ($imageFile -like '*.esd') { 'ESD:' } else { 'WIM:' }
            indexes       = @($indexes)
            note          = 'DISM /Source: is <source_prefix><drive>:\<file>:<index>; pick the index whose name matches the target edition (Win32_OperatingSystem.Caption). Index 1 is usually Home.'
        }
        $imageInfo | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $isoDestDir 'image-info.json') -Encoding UTF8
        Write-BuildLog "Wrote iso\image-info.json ($($indexes.Count) index(es))"
    } finally {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }
} else {
    Write-BuildLog "No -IsoPath supplied - DISM /RestoreHealth will have no local source on the target machine. See docs/iso-role.md." 'WARN'
}

# --- 5b. Stage recovery ISOs for the Ventoy boot menu ------------------------
# boot-images\, not ISO\: Windows file systems are case-insensitive, so ISO\
# and the iso\ that holds install.wim are the SAME folder, and the docs used
# to draw them as siblings. Ventoy scans every directory for bootable
# images, so the name is free.
if ($RecoveryIso -and $Minimal) {
    Write-BuildLog 'Ignoring -RecoveryIso because -Minimal was specified (smoke-test drive carries no boot images).' 'WARN'
}
if ($RecoveryIso -and -not $Minimal) {
    $isoDir = Join-Path $UsbRoot 'boot-images'
    New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
    foreach ($iso in $RecoveryIso) {
        if (-not (Test-Path $iso)) {
            Write-BuildLog "RecoveryIso '$iso' not found — skipping." 'WARN'
            continue
        }
        $name = Split-Path $iso -Leaf
        Write-BuildLog "Staging recovery ISO $name into \boot-images\ (Ventoy will offer it at boot)..."
        Copy-Item -Path $iso -Destination (Join-Path $isoDir $name) -Force
        $h = (Get-FileHash -Path (Join-Path $isoDir $name) -Algorithm SHA256).Hash
        Write-BuildLog "  $name SHA256: $h"
    }
    Write-BuildLog "NOTE: Ventoy must already be installed to this USB (separate manual step) for these ISOs to be bootable. See docs/offline-repair-playbook.md."
}

# --- 6. Build gate: prove the copied binary actually runs from the USB path ---
# This is the cheapest possible check of the kit's load-bearing assumption. It
# runs on the BUILD machine (which has Claude installed), so a pass here is
# necessary but NOT sufficient — the real test is a machine that never had
# Claude. It still catches a broken copy immediately instead of at the bedside.
Write-BuildLog 'Build gate: launching claude.exe from the USB path...'
$usbClaude = Join-Path $destClaudeDir 'claude.exe'
try {
    # Scoped 'Continue': under Windows PowerShell 5.1 the script-wide
    # ErrorActionPreference = Stop turns the FIRST stderr line a native
    # command writes into a terminating NativeCommandError, which would fail
    # this gate on a binary that merely printed a warning.
    $ver = & {
        $ErrorActionPreference = 'Continue'
        & $usbClaude --version 2>&1 | ForEach-Object { [string]$_ }
    } | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $ver.Trim()) {
        throw "claude.exe from $usbClaude produced no version output (exit $LASTEXITCODE)."
    }
    Write-BuildLog "Build gate PASSED: $($ver.Trim())"
} catch {
    throw "BUILD GATE FAILED: the copied claude.exe does not run from '$usbClaude'. $_`nThis is the kit's load-bearing assumption. Do not ship this drive; see docs/verification-checklist.md step 2."
}

Write-Host ''
if ($Minimal) {
    Write-Host '  SMOKE-TEST DRIVE BUILT' -ForegroundColor Green
    Write-Host '  ----------------------'
    Write-Host "  Location: $UsbRoot   (no tools, no Windows image - that's intentional)"
    Write-Host ''
    Write-Host '  Do this NEXT, before building the full drive:'
    Write-Host '    1. Put this drive in a Windows machine that has NEVER had Claude Code installed.'
    Write-Host '       A disposable VM is ideal.'
    Write-Host '    2. Work through steps 1-6 of docs\verification-checklist.md on that machine.'
    Write-Host '    3. Only if those pass, come back and run the full build:'
    Write-Host "         .\scripts\Build-Kit.ps1 -UsbRoot $UsbRoot -IsoPath <path to Windows ISO>"
    Write-Host ''
    Write-Host '  Why: everything else in this kit rests on the copied claude.exe running and'
    Write-Host '  authenticating from a USB path on a machine that never had it. Prove that for'
    Write-Host '  ~300MB before spending 8GB on tools and an ISO.' -ForegroundColor Yellow
} else {
    Write-Host '  FULL DRIVE BUILT' -ForegroundColor Green
    Write-Host "  Location: $UsbRoot"
    Write-Host ''
    Write-Host '  Before using it on a machine you care about:'
    Write-Host '    - Work through docs\verification-checklist.md (all 10 steps).'
    Write-Host '    - Rebuild before each repair trip: MSERT expires ~10 days after download.'
    Write-Host '    - If your drive has a write-protect switch, set it to read-only now.'
}
Write-Host ''
