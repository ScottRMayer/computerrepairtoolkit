<#
.SYNOPSIS
    USB kit entry point. Sets up environment, logging, and Defender
    exclusions, then launches Claude Code against CLAUDE.md in this
    directory with --dangerously-skip-permissions.

.DESCRIPTION
    This script does the minimum needed to get Claude Code running
    unattended and logged; the actual repair pipeline (backup, restore
    point, inventory, diagnosis, whitelisted repair actions) is driven by
    the agent itself, following CLAUDE.md — see docs/architecture.md for
    why the split is drawn there rather than hard-coding the pipeline here.

    Run this from the USB drive (double-click, or right-click ->
    "Run with PowerShell"). It does not need to be run as Administrator for
    most whitelisted tools, but several (DISM, chkdsk, Defender exclusions,
    restore points) do need elevation — run an elevated PowerShell if you
    can, and the individual scripts under scripts\ log a clear failure
    rather than silently no-op-ing when they can't get the access they need.

.PARAMETER PlaybookPrompt
    The initial prompt handed to Claude Code. Defaults to a generic
    "diagnose and repair, following CLAUDE.md" instruction — override for a
    specific known complaint (e.g. "the machine won't connect to Wi-Fi").
#>
[CmdletBinding()]
param(
    [string]$PlaybookPrompt = 'Diagnose and repair this Windows machine. Follow the pipeline and tool whitelist in CLAUDE.md exactly, starting with the mandatory backup, restore point, and inventory steps before any diagnosis.'
)

$KitRoot = $PSScriptRoot
. (Join-Path $KitRoot 'scripts\lib\Common.ps1')

$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'start-repair'
Write-KitLog -LogPath $LogPath -Message "PC Repair Kit starting from $KitRoot"

# --- Sanity check: are we actually running from a real kit checkout? ---
$requiredPaths = @('CLAUDE.md', 'scripts\00-Backup-UserData.ps1', 'bin\claude\claude.exe')
$missing = $requiredPaths | Where-Object { -not (Test-Path (Join-Path $KitRoot $_)) }
if ($missing) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Missing expected kit files: $($missing -join ', '). Has scripts\Build-Kit.ps1 been run to assemble bin\claude\? Aborting."
    exit 1
}

# --- Safe Mode detection ---
$mode = & (Join-Path $KitRoot 'scripts\Test-SafeMode.ps1')
Write-KitLog -LogPath $LogPath -Message "Boot mode detected: $mode"
if ($mode -ne 'Normal') {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'Running in Safe Mode — see docs/safe-mode-constraints.md for what is and is not available. Restore-point creation will use the reg-export fallback, not Checkpoint-Computer.'
}

# --- Credentials ---
$authLoaded = Import-KitAuthEnv -KitRoot $KitRoot
if (-not $authLoaded -or (-not $env:CLAUDE_CODE_OAUTH_TOKEN -and -not $env:ANTHROPIC_API_KEY)) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message 'No CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY available (config\auth.env missing or empty). See docs/authentication.md. Aborting rather than launching an unauthenticated session.'
    exit 1
}

# --- Keep all Claude Code state on the USB, not the target machine ---
$stateDir = Join-Path $KitRoot 'state\.claude'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$env:CLAUDE_CONFIG_DIR = $stateDir
$env:DISABLE_AUTOUPDATER = '1'

Write-KitLog -LogPath $LogPath -Message "CLAUDE_CONFIG_DIR set to $stateDir"

# --- Defender exclusions (best-effort, never blocks the run) ---
& (Join-Path $KitRoot 'scripts\03-Set-DefenderExclusions.ps1')

# --- Launch, with the run transcript captured to logs\ ---
$claudeExe = Join-Path $KitRoot 'bin\claude\claude.exe'
$runLogPath = Join-Path $KitRoot "logs\claude-run-$(Get-Date -Format 'yyyyMMdd-HHmmss').jsonl"

Write-KitLog -LogPath $LogPath -Message "Launching Claude Code. Transcript: $runLogPath"
Write-KitLog -LogPath $LogPath -Message "Prompt: $PlaybookPrompt"

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
}

if ($exitCode -eq 0) {
    Write-KitLog -LogPath $LogPath -Message "Claude Code session completed (exit 0). Full transcript: $runLogPath"
} else {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Claude Code session exited non-zero ($exitCode). Check $runLogPath for the failure reason before assuming any repair completed."
}

exit $exitCode
