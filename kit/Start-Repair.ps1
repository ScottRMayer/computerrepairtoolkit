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

    [string]$PlaybookPrompt = 'Diagnose and repair this Windows machine. Follow the pipeline and tool whitelist in CLAUDE.md exactly. Read state\session-context.json first to learn what the launcher already did.'
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

# --- Credentials ---
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
    & $claudeExe -p $PlaybookPrompt `
        --dangerously-skip-permissions `
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
}

if ($exitCode -eq 0) {
    Write-KitLog -LogPath $LogPath -Message "Claude Code session completed (exit 0). Full transcript: $runLogPath"
} else {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Claude Code session exited non-zero ($exitCode). Check $runLogPath before assuming any repair completed."
}

if ($backupResult.completed) {
    Write-KitLog -LogPath $LogPath -Message "Reminder: user data was backed up to $($backupResult.destination). Scan that drive before reusing it elsewhere."
} else {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'Reminder: NO user-data backup was taken this session.'
}

exit $exitCode
