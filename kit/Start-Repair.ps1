<#
.SYNOPSIS
    USB kit entry point. Handles the operator-present steps (backup target
    selection, credentials, Defender exclusions, logging), then launches
    Claude Code unattended against CLAUDE.md in this directory with
    --dangerously-skip-permissions.

.DESCRIPTION
    The split between this script and the agent is drawn at "does a human
    need to be here?" Backup destination selection needs a person — the
    only moment one is reliably present is right now, at plug-in time — so
    the backup runs here, before handoff. Everything after that (diagnosis,
    repair, the whitelisted tools) is the agent's, driven by CLAUDE.md.

    The agent is told what happened here via state\session-context.json,
    which CLAUDE.md instructs it to read first.

.PARAMETER BackupMode
    Prompt (default): interactively pick a destination volume, or skip.
    Skip:             no backup. The restore point becomes the only rollback.
    Auto:             use -BackupDestination without prompting.

.PARAMETER BackupDestination
    Explicit backup destination root. Implies -BackupMode Auto.

.PARAMETER BackupUserName
    Profile to back up. Defaults to the current user. See
    scripts\00-Backup-UserData.ps1 for why this isn't every profile.

.PARAMETER AllProfiles
    Back up every non-system profile rather than one.

.PARAMETER PlaybookPrompt
    Initial prompt for the agent. Defaults to a general diagnose-and-repair
    instruction — override for a specific known complaint.

.EXAMPLE
    .\Start-Repair.ps1
    Prompts for a backup drive, then runs.

.EXAMPLE
    .\Start-Repair.ps1 -BackupDestination D:\Backups -PlaybookPrompt "Wi-Fi drops every few minutes."

.EXAMPLE
    .\Start-Repair.ps1 -BackupMode Skip
#>
[CmdletBinding()]
param(
    [ValidateSet('Prompt', 'Skip', 'Auto')]
    [string]$BackupMode = 'Prompt',

    [string]$BackupDestination,
    [string]$BackupUserName = $env:USERNAME,
    [switch]$AllProfiles,

    [string]$PlaybookPrompt = 'Diagnose and repair this Windows machine. Follow the pipeline and tool whitelist in CLAUDE.md exactly. Read state\session-context.json first to learn what the launcher already did.',

    # Wi-Fi credentials for a target machine with no saved profile. The agent's
    # brain needs the network before it can think, so this is a launcher input.
    [string]$WifiSSID,
    [string]$WifiPassword,

    # Pinned so an unattended run's reasoning quality can't drift with defaults.
    [string]$Model = 'claude-opus-5',
    [string]$FallbackModel = 'claude-sonnet-5'
)

$KitRoot = $PSScriptRoot
. (Join-Path $KitRoot 'scripts\lib\Common.ps1')

$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'start-repair'
Write-KitLog -LogPath $LogPath -Message "PC Repair Kit starting from $KitRoot"

if ($BackupDestination) { $BackupMode = 'Auto' }

# --- Sanity check: are we running from a real assembled kit? ---
$requiredPaths = @('CLAUDE.md', 'scripts\00-Backup-UserData.ps1', 'bin\claude\claude.exe')
$missing = $requiredPaths | Where-Object { -not (Test-Path (Join-Path $KitRoot $_)) }
if ($missing) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Missing expected kit files: $($missing -join ', '). Has scripts\Build-Kit.ps1 been run? Aborting."
    exit 1
}

# --- Elevation: half the whitelist needs it, so say so plainly up front ---
$isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'NOT running elevated. DISM, chkdsk, restore points, and Defender exclusions will all fail. Re-launch from an elevated PowerShell for a full-capability session.'
}

# --- Safe Mode detection ---
$mode = & (Join-Path $KitRoot 'scripts\Test-SafeMode.ps1')
Write-KitLog -LogPath $LogPath -Message "Boot mode detected: $mode"
if ($mode -ne 'Normal') {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'Safe Mode — see docs/safe-mode-constraints.md. Restore points cannot be created here; the reg-export fallback will be used instead.'
}

# --- Backup (operator-present step) ---
$backupResult = [ordered]@{
    mode        = $BackupMode
    requested   = ($BackupMode -ne 'Skip')
    completed   = $false
    destination = $null
    scope       = if ($AllProfiles) { 'all profiles' } else { $BackupUserName }
}

if ($BackupMode -eq 'Skip') {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'Backup skipped by request (-BackupMode Skip).'
} else {
    $backupArgs = @{ UserName = $BackupUserName }
    if ($AllProfiles) { $backupArgs['AllProfiles'] = $true }

    if ($BackupMode -eq 'Prompt') {
        Write-KitLog -LogPath $LogPath -Message 'Measuring user data to size the backup target...'
        $requiredBytes = & (Join-Path $KitRoot 'scripts\00-Backup-UserData.ps1') @backupArgs -MeasureOnly

        $BackupDestination = & (Join-Path $KitRoot 'scripts\Select-BackupTarget.ps1') `
            -RequiredBytes $requiredBytes -ExcludePath $KitRoot

        if (-not $BackupDestination) {
            Write-KitLog -LogPath $LogPath -Level WARN -Message 'Operator chose to skip the backup at the destination prompt.'
            $backupResult.requested = $false
            $backupResult.mode = 'Skip'
        }
    }

    if ($BackupDestination) {
        Write-KitLog -LogPath $LogPath -Message "Starting user-data backup to $BackupDestination (scope: $($backupResult.scope))..."
        & (Join-Path $KitRoot 'scripts\00-Backup-UserData.ps1') @backupArgs -DestinationRoot $BackupDestination
        $backupExit = $LASTEXITCODE

        $backupResult.destination = $BackupDestination
        $backupResult.completed = ($backupExit -eq 0)

        if ($backupExit -ne 0) {
            Write-KitLog -LogPath $LogPath -Level ERROR -Message "Backup FAILED (exit $backupExit). The agent will be told there is no file-level safety net."
            $continue = if ([Environment]::UserInteractive) { Read-Host 'Continue without a backup? (y/N)' } else { 'n' }
            if ($continue -notmatch '^[Yy]') {
                Write-KitLog -LogPath $LogPath -Level ERROR -Message 'Aborting at operator request.'
                exit 1
            }
        } else {
            Write-KitLog -LogPath $LogPath -Message 'Backup completed successfully.'
        }
    }
}

# --- Scrub the inherited environment BEFORE loading our own credential ---
# Two distinct hazards, both from a host we don't trust:
#  1. An inherited ANTHROPIC_API_KEY outranks CLAUDE_CODE_OAUTH_TOKEN in Claude
#     Code's credential precedence, so a leftover key on the target machine
#     would silently shadow the owner's subscription token and misroute billing.
#  2. TLS-weakening variables let a compromised host MITM the agent's uplink —
#     the one channel none of our on-disk guardrails can see. Strip them.
foreach ($risky in @(
    'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
    'NODE_EXTRA_CA_CERTS', 'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_OPTIONS',
    'SSL_CERT_FILE', 'SSL_CERT_DIR', 'REQUESTS_CA_BUNDLE',
    'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY'
)) {
    if (Test-Path "Env:$risky") {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Scrubbed inherited '$risky' from the child environment before launching the agent."
        Remove-Item "Env:$risky" -ErrorAction SilentlyContinue
    }
}

# --- Credentials (loaded AFTER the scrub, so auth.env wins) ---
$authLoaded = Import-KitAuthEnv -KitRoot $KitRoot
if (-not $authLoaded -or (-not $env:CLAUDE_CODE_OAUTH_TOKEN -and -not $env:ANTHROPIC_API_KEY)) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message 'No CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY available (config\auth.env missing or empty). See docs/authentication.md. Aborting.'
    exit 1
}

# --- Keep all Claude Code state on the USB, not the target machine ---
$stateDir = Join-Path $KitRoot 'state\.claude'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$env:CLAUDE_CONFIG_DIR = $stateDir
$env:DISABLE_AUTOUPDATER = '1'
Write-KitLog -LogPath $LogPath -Message "CLAUDE_CONFIG_DIR set to $stateDir"

# Clear any stale backup-needs-scan flag from a prior run on this USB, so a
# leftover flag can't make this run falsely warn that the backup is infected.
# The agent (re)writes it only if it finds malware this session.
Remove-Item (Join-Path $KitRoot 'state\backup-needs-scan.flag') -Force -ErrorAction SilentlyContinue

# --- Hand the agent the facts about what already happened ---
$sessionContext = [ordered]@{
    started_at   = (Get-Date -Format 'o')
    kit_root     = $KitRoot
    boot_mode    = $mode
    elevated     = $isElevated
    backup       = $backupResult
    target_user  = $BackupUserName
}
$contextPath = Join-Path $KitRoot 'state\session-context.json'
$sessionContext | ConvertTo-Json -Depth 5 | Out-File -FilePath $contextPath -Encoding UTF8
Write-KitLog -LogPath $LogPath -Message "Session context written to $contextPath"

# --- Connectivity gate ---
# The agent's brain is a cloud API call, so this must succeed BEFORE handoff.
# Launching an agent that can't reach the model produces nothing but a
# confusing failure on turn 0.
$net = & (Join-Path $KitRoot 'scripts\04-Ensure-Connectivity.ps1') `
    -WifiSSID $WifiSSID -WifiPassword $WifiPassword

foreach ($f in $net.Findings) { Write-KitLog -LogPath $LogPath -Message "Connectivity finding: $f" }

if (-not $net.Online) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message @"
NO PATH TO api.anthropic.com — the repair agent cannot run.

Claude Code is a cloud service: the tools on this drive work offline, but the
agent that drives them does not. Tried: $($net.Attempted -join ', ').

What still happened: your backup and this log. What did NOT happen: any
diagnosis or repair.

You can still use the bundled tools by hand — exact commands are in
docs\tool-invocations.md on this drive.
"@
    & (Join-Path $KitRoot 'scripts\03-Set-DefenderExclusions.ps1') -Remove
    # Give the operator a readable card even on the offline path.
    & (Join-Path $KitRoot 'scripts\Write-RepairReport.ps1') -ExitCode 3 | Out-Null
    # Distinct exit code so "couldn't start" is never mistaken for "nothing to fix".
    exit 3
}
Write-KitLog -LogPath $LogPath -Message "Connectivity confirmed (rung: $($net.Rung))."

# --- Defender exclusions (best-effort; removed again in the finally below) ---
& (Join-Path $KitRoot 'scripts\03-Set-DefenderExclusions.ps1')

# --- Launch ---
$claudeExe = Join-Path $KitRoot 'bin\claude\claude.exe'
$runLogPath = Join-Path $KitRoot "logs\claude-run-$(Get-Date -Format 'yyyyMMdd-HHmmss').jsonl"

Write-KitLog -LogPath $LogPath -Message "Launching Claude Code. Transcript: $runLogPath"
Write-KitLog -LogPath $LogPath -Message "Prompt: $PlaybookPrompt"

$exitCode = 1
Push-Location $KitRoot
try {
    # Model is pinned rather than left to default: an unattended repair run
    # should not silently change reasoning quality because a default moved.
    # --fallback-model keeps the session alive through a capacity blip instead
    # of dying mid-repair on a machine nobody is watching.
    & $claudeExe -p $PlaybookPrompt `
        --dangerously-skip-permissions `
        --model $Model `
        --fallback-model $FallbackModel `
        --output-format stream-json `
        --verbose 2>&1 |
        Tee-Object -FilePath $runLogPath

    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location

    # Never leave the target machine with standing Defender exclusions for
    # a removable drive letter — see 03-Set-DefenderExclusions.ps1.
    Write-KitLog -LogPath $LogPath -Message 'Removing Defender exclusions added for this session...'
    & (Join-Path $KitRoot 'scripts\03-Set-DefenderExclusions.ps1') -Remove

    # Evacuate the audit trail off the USB. The transcript is the only record
    # of what an unattended agent did, and until now it lived only on the
    # same writable USB a compromised host — or the agent itself, steered by
    # injection — could delete or edit. Copying it to the operator-chosen
    # backup drive gives a second copy on separate media. This is a copy, not
    # a guarantee: neither location is tamper-evident (see docs/red-team-review.md).
    if ($backupResult.destination -and (Test-Path $backupResult.destination)) {
        try {
            $auditDir = Join-Path $backupResult.destination "RepairKit-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
            Copy-Item -Path $runLogPath -Destination $auditDir -Force -ErrorAction SilentlyContinue
            Copy-Item -Path $contextPath -Destination $auditDir -Force -ErrorAction SilentlyContinue
            Copy-Item -Path (Join-Path $KitRoot 'logs\*') -Destination $auditDir -Force -ErrorAction SilentlyContinue
            Write-KitLog -LogPath $LogPath -Message "Audit trail copied off-USB to $auditDir"
        } catch {
            Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not copy audit trail off-USB: $_. The on-USB transcript at $runLogPath is still the primary record."
        }
    } else {
        Write-KitLog -LogPath $LogPath -Level WARN -Message 'No off-USB backup drive was chosen, so the run transcript exists only on the USB. Copy logs\ to separate media before reusing this drive.'
    }
}

if ($exitCode -eq 0) {
    Write-KitLog -LogPath $LogPath -Message "Claude Code session completed (exit 0). Full transcript: $runLogPath"
} else {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Claude Code session exited non-zero ($exitCode). Check $runLogPath before assuming any repair completed."
}

# Backup hygiene: an infected source machine can copy infected files into
# the backup, turning the backup drive into a transmission path onto a clean
# machine. The agent drops state\backup-needs-scan.flag when it found malware
# (see CLAUDE.md), so this reminder can name the actual risk instead of a
# boilerplate "maybe scan it". The launcher can't detect malware itself, so
# absent the flag it still cautions — just at a lower volume.
$scanFlag = Join-Path $KitRoot 'state\backup-needs-scan.flag'
if ($backupResult.completed) {
    if (Test-Path $scanFlag) {
        $flagBody = (Get-Content $scanFlag -Raw -ErrorAction SilentlyContinue)
        Write-KitLog -LogPath $LogPath -Level WARN -Message "MALWARE WAS FOUND ON THIS MACHINE and user data was backed up to $($backupResult.destination). That backup MAY CONTAIN INFECTED FILES. Scan it with a clean machine's antivirus BEFORE opening any file from it or plugging the drive into an uninfected computer. Details: $flagBody"
    } else {
        Write-KitLog -LogPath $LogPath -Message "Reminder: user data was backed up to $($backupResult.destination). As a precaution, scan that drive before reusing it on another machine."
    }
} else {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'Reminder: NO user-data backup was taken this session.'
}

# Human-readable report card. This is the deliverable the operator actually
# reads; the jsonl transcript is for the record. Opens automatically when run
# interactively (via Repair-This-PC.cmd).
try {
    $reportPath = & (Join-Path $KitRoot 'scripts\Write-RepairReport.ps1') -ExitCode $exitCode
    Write-KitLog -LogPath $LogPath -Message "Report card written to $reportPath"
} catch {
    Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not generate the report card: $_"
}

exit $exitCode
