<#
.SYNOPSIS
    USB kit entry point. Handles the operator-present steps (backup target
    selection, credentials, connectivity, a self-test of the command guard,
    Defender exclusions, logging), then launches Claude Code unattended
    against CLAUDE.md in this directory with --dangerously-skip-permissions.

.DESCRIPTION
    The split between this script and the agent is drawn at "does a human
    need to be here?" Backup destination selection needs a person — the
    only moment one is reliably present is right now, at plug-in time — so
    the backup runs here, before handoff. Everything after that (diagnosis,
    repair, the whitelisted tools) is the agent's, driven by CLAUDE.md.

    The agent is told what happened here via state\session-context.json,
    which CLAUDE.md instructs it to read first.

    Exit codes (Repair-This-PC.cmd explains each to the operator):
      0  agent session completed
      1  stopped early (backup refused, missing kit files, agent exited non-zero)
      2  agent hit the wall-clock cap and was interrupted (a bounded resume ran)
      3  no path to api.anthropic.com — the agent was never launched
      4  the PreToolUse command guard did NOT block a test command — never launched
      5  the saved credential was rejected — never launched

.PARAMETER BackupMode
    Prompt (default): interactively pick a destination volume, or skip.
    Skip:             no backup. The restore point becomes the only rollback.
    Auto:             use -BackupDestination without prompting.

.PARAMETER BackupDestination
    Explicit backup destination root. Implies -BackupMode Auto.

.PARAMETER BackupUserName
    Profile to back up. Defaults to the user signed in at the console (not
    the account that clicked "Yes" on the UAC prompt, which on a family PC is
    often a different, admin account). See scripts\00-Backup-UserData.ps1
    for why this isn't every profile.

.PARAMETER AllProfiles
    Back up every non-system profile rather than one.

.PARAMETER PlaybookPrompt
    Initial prompt for the agent. Defaults to a general diagnose-and-repair
    instruction — override for a specific known complaint.

.PARAMETER SkipPreflight
    Skip the pre-launch self-test (one cheap model call that proves the
    credential works AND that the PreToolUse guard blocks a forbidden
    command on this machine). Debugging only — without it a dead token
    surfaces as a confusing turn-0 failure, and an inert guard goes unnoticed.

.EXAMPLE
    .\Start-Repair.ps1
    Prompts for a backup drive, then runs.

.EXAMPLE
    .\Start-Repair.ps1 -BackupDestination D:\Backups -PlaybookPrompt "Wi-Fi drops every few minutes."

.EXAMPLE
    .\Start-Repair.ps1 -BackupMode Skip -RepairMode Check
#>
[CmdletBinding()]
param(
    [ValidateSet('Prompt', 'Skip', 'Auto')]
    [string]$BackupMode = 'Prompt',

    [string]$BackupDestination,
    [string]$BackupUserName,
    [switch]$AllProfiles,

    [string]$PlaybookPrompt = 'Diagnose and repair this Windows machine. Follow the pipeline and tool whitelist in CLAUDE.md exactly. Read state\session-context.json first to learn what the launcher already did.',

    # Wi-Fi credentials for a target machine with no saved profile. The agent's
    # brain needs the network before it can think, so this is a launcher input.
    [string]$WifiSSID,
    [string]$WifiPassword,

    # Pinned so an unattended run's reasoning quality can't drift with defaults.
    [string]$Model = 'claude-opus-5',
    [string]$FallbackModel = 'claude-sonnet-5',

    # Cheapest model for the pre-launch self-test; it only has to run one
    # shell command and report the result.
    [string]$PreflightModel = 'claude-haiku-4-5-20251001',
    [switch]$SkipPreflight,
    [int]$PreflightSeconds = 150,

    # Loop and wall-clock guards for an unattended run nobody is watching.
    # --max-turns is the reliable primary guard; the wall-clock cap is the
    # backstop for a turn that hangs on I/O.
    [int]$MaxTurns = 120,
    [int]$MaxMinutes = 90,

    # Check = diagnose only, change nothing, report what it WOULD do (the safe
    # first run). Fix = full autonomous repair (default). The agent reads this
    # from session-context.json and CLAUDE.md enforces the posture.
    [ValidateSet('Check', 'Fix')]
    [string]$RepairMode = 'Fix'
)

$KitRoot = $PSScriptRoot
. (Join-Path $KitRoot 'scripts\lib\Common.ps1')

$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'start-repair'
Write-KitLog -LogPath $LogPath -Message "PC Repair Kit starting from $KitRoot"

if ($BackupDestination) { $BackupMode = 'Auto' }

# --- Sanity check: are we running from a real assembled kit? ---
$requiredPaths = @('CLAUDE.md', 'scripts\00-Backup-UserData.ps1', 'bin\claude\claude.exe', 'hooks\PreToolUse-Guard.ps1', '.claude\settings.json')
$missing = $requiredPaths | Where-Object { -not (Test-Path (Join-Path $KitRoot $_)) }
if ($missing) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Missing expected kit files: $($missing -join ', '). Has scripts\Build-Kit.ps1 been run? Aborting."
    exit 1
}

# --- Clear state left by a previous run on this USB ---
# Every file here is re-created by this run when the corresponding step
# happens. A stale one would be read back as if it were this run's — a
# leftover repair-summary.json would put LAST run's findings on THIS run's
# report card, and a stale backup-needs-scan.flag would falsely warn that
# the backup is infected.
$stateDir = Join-Path $KitRoot 'state'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
foreach ($stale in @('repair-summary.json', 'restore-point.json', 'backup-result.json', 'backup-needs-scan.flag', 'session-context.json')) {
    Remove-Item (Join-Path $stateDir $stale) -Force -ErrorAction SilentlyContinue
}

# --- Elevation: half the whitelist needs it, so say so plainly up front ---
$isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'NOT running elevated. DISM, chkdsk, restore points, and Defender exclusions will all fail. Re-launch from an elevated PowerShell for a full-capability session.'
}

# --- Which profile is "the family member's"? ---
# After a UAC elevation $env:USERNAME is the ADMIN account that approved the
# prompt, which on a shared family PC is frequently not the person whose
# files matter. The interactively signed-in user (Win32_ComputerSystem
# .UserName) is the better default; -BackupUserName still overrides.
if (-not $BackupUserName) {
    $consoleUser = $null
    try { $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
    if ($consoleUser) {
        $BackupUserName = ($consoleUser -split '\\')[-1]
        if ($BackupUserName -ne $env:USERNAME) {
            Write-KitLog -LogPath $LogPath -Message "Signed-in console user is '$BackupUserName' (this elevated session runs as '$env:USERNAME'); defaulting the backup to '$BackupUserName'. Pass -BackupUserName to override."
        }
    } else {
        $BackupUserName = $env:USERNAME
    }
}

# --- Safe Mode detection ---
$mode = & (Join-Path $KitRoot 'scripts\Test-SafeMode.ps1')
Write-KitLog -LogPath $LogPath -Message "Boot mode detected: $mode"
if ($mode -ne 'Normal') {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'Safe Mode — see docs/safe-mode-constraints.md. Restore points cannot be created here; the reg-export fallback will be used instead.'
}

# --- Backup (operator-present step) ---
$backupResult = [ordered]@{
    mode            = $BackupMode
    requested       = ($BackupMode -ne 'Skip')
    completed       = $false
    verified        = $false
    destination     = $null
    scope           = if ($AllProfiles) { 'all profiles' } else { $BackupUserName }
    bytes_copied    = 0
    cloud_only_files = 0
    result_file     = $null
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

        # The backup script reconciles what actually landed on the destination
        # (robocopy exit 0 alone can mean "nothing to copy"); pick up its
        # numbers so the agent and the report card can state them.
        $backupResultFile = Join-Path $stateDir 'backup-result.json'
        if (Test-Path $backupResultFile) {
            try {
                $br = Get-Content $backupResultFile -Raw | ConvertFrom-Json
                $backupResult.verified         = [bool]$br.verified
                $backupResult.bytes_copied     = [long]$br.copied_bytes
                $backupResult.cloud_only_files = [int]$br.cloud_only_files
                $backupResult.result_file      = $backupResultFile
            } catch {
                Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not read $backupResultFile : $_"
            }
        }

        if ($backupExit -ne 0) {
            Write-KitLog -LogPath $LogPath -Level ERROR -Message "Backup FAILED or could not be verified (exit $backupExit). The agent will be told there is no file-level safety net."
            $continue = if ([Environment]::UserInteractive) { Read-Host 'Continue without a backup? (y/N)' } else { 'n' }
            if ($continue -notmatch '^[Yy]') {
                Write-KitLog -LogPath $LogPath -Level ERROR -Message 'Aborting at operator request.'
                exit 1
            }
        } else {
            Write-KitLog -LogPath $LogPath -Message ("Backup completed and verified: {0:N2} GB landed on the destination." -f ($backupResult.bytes_copied / 1GB))
            if ($backupResult.cloud_only_files -gt 0) {
                Write-KitLog -LogPath $LogPath -Level WARN -Message "$($backupResult.cloud_only_files) cloud-only (OneDrive online-only) file(s) were NOT copied because they are not on this disk; they remain in the cloud. The list is in cloud-only-files.txt inside the backup."
            }
        }
    }
}

# --- Scrub the inherited environment BEFORE loading our own credential ---
# Three distinct hazards, all from a host we don't trust:
#  1. An inherited ANTHROPIC_API_KEY outranks CLAUDE_CODE_OAUTH_TOKEN in Claude
#     Code's credential precedence, so a leftover key on the target machine
#     would silently shadow the owner's subscription token and misroute billing.
#  2. Provider/endpoint redirects (Bedrock/Vertex/Foundry switches, a custom
#     base URL) would send the agent somewhere other than Anthropic, where the
#     OAuth token is meaningless — the run dies on turn 0 with an auth error.
#  3. TLS-weakening variables let a compromised host MITM the agent's uplink —
#     the one channel none of our on-disk guardrails can see. Strip them.
foreach ($risky in @(
    'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_CUSTOM_HEADERS',
    'ANTHROPIC_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY', 'CLAUDE_CODE_SKIP_BEDROCK_AUTH', 'CLAUDE_CODE_SKIP_VERTEX_AUTH',
    'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CONFIG_DIR',
    'NODE_EXTRA_CA_CERTS', 'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_OPTIONS',
    'SSL_CERT_FILE', 'SSL_CERT_DIR', 'REQUESTS_CA_BUNDLE',
    'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY'
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
$claudeStateDir = Join-Path $stateDir '.claude'
New-Item -ItemType Directory -Path $claudeStateDir -Force | Out-Null
$env:CLAUDE_CONFIG_DIR = $claudeStateDir
$env:DISABLE_AUTOUPDATER = '1'
Write-KitLog -LogPath $LogPath -Message "CLAUDE_CONFIG_DIR set to $claudeStateDir"

$claudeExe = Join-Path $KitRoot 'bin\claude\claude.exe'
$sysPromptFile = Join-Path $KitRoot 'config\system-prompt-append.txt'
$contextPath = Join-Path $stateDir 'session-context.json'

# --- The launcher -> agent contract -------------------------------------
# Written additively: once before the connectivity gate (so the offline
# report card has it), again after the pre-launch self-test, and it is what
# CLAUDE.md tells the agent to read first.
$sessionContext = [ordered]@{
    started_at   = (Get-Date -Format 'o')
    kit_root     = $KitRoot
    boot_mode    = $mode
    elevated     = $isElevated
    backup       = $backupResult
    target_user  = $BackupUserName
    repair_mode  = $RepairMode
    connectivity = $null
    preflight    = $null
    defender_exclusions_added = $false
    state_files  = [ordered]@{
        restore_point = 'state\restore-point.json'
        backup_result = 'state\backup-result.json'
        repair_summary = 'state\repair-summary.json'
        backup_needs_scan_flag = 'state\backup-needs-scan.flag'
    }
}
function Write-SessionContext {
    $sessionContext | ConvertTo-Json -Depth 6 | Out-File -FilePath $contextPath -Encoding UTF8
}
Write-SessionContext
Write-KitLog -LogPath $LogPath -Message "Session context written to $contextPath"

# --- Connectivity gate ---
# The agent's brain is a cloud API call, so this must succeed BEFORE handoff.
# Launching an agent that can't reach the model produces nothing but a
# confusing failure on turn 0.
$net = & (Join-Path $KitRoot 'scripts\04-Ensure-Connectivity.ps1') `
    -WifiSSID $WifiSSID -WifiPassword $WifiPassword

foreach ($f in $net.Findings) { Write-KitLog -LogPath $LogPath -Message "Connectivity finding: $f" }

# What the ladder found and changed is diagnostic evidence (a hosts-file
# hijack or a WinINET proxy is a malware signal) AND a list of settings the
# machine now carries. Hand both to the agent and the report card.
$sessionContext.connectivity = [ordered]@{
    online    = [bool]$net.Online
    rung      = [string]$net.Rung
    findings  = @($net.Findings | ForEach-Object { [string]$_ })
    attempted = @($net.Attempted | ForEach-Object { [string]$_ })
}
Write-SessionContext

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
    # Give the operator a readable card even on the offline path.
    & (Join-Path $KitRoot 'scripts\Write-RepairReport.ps1') -ExitCode 3 | Out-Null
    # Distinct exit code so "couldn't start" is never mistaken for "nothing to fix".
    exit 3
}
Write-KitLog -LogPath $LogPath -Message "Connectivity confirmed (rung: $($net.Rung))."

# --- Run the agent as a monitored child, narrating its transcript ---------
function Start-MonitoredAgent {
    <#
        Launches claude.exe with stdout -> $OutPath (the stream-json
        transcript), waits up to $TimeoutSeconds, and while waiting tails the
        transcript to print plain-language progress: without this the console
        is blank for the whole run, because a redirected stdout shows nothing.
        Returns @{ Process; ExitCode; TimedOut; ToolCalls; HookDenials }.
    #>
    param(
        [string[]]$Arguments,
        [string]$OutPath,
        [int]$TimeoutSeconds,
        [switch]$Quiet
    )
    $argString = ConvertTo-ArgumentString -Arguments $Arguments
    # Explicit working directory: it is what Claude Code treats as the
    # project root (CLAUDE.md, .claude\settings.json, ${CLAUDE_PROJECT_DIR}).
    $proc = Start-Process -FilePath $claudeExe -ArgumentList $argString `
        -WorkingDirectory (Get-Location).Path `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $OutPath `
        -RedirectStandardError "$OutPath.err"
    # Touching .Handle caches the process handle so .ExitCode is readable after
    # the process exits. Without this, Start-Process -PassThru returns $null for
    # ExitCode on a completed run, and the launcher wrongly reports failure on
    # success. (Confirmed on real hardware: a clean run logged "exited non-zero ()".)
    $null = $proc.Handle

    $deadline   = (Get-Date).AddSeconds($TimeoutSeconds)
    $started    = Get-Date
    $reader     = $null
    $buffer     = ''
    $toolCalls  = 0
    $denials    = 0
    $lastOutput = Get-Date
    $timedOut   = $false
    $exited     = $false

    while ($true) {
        $exited = $proc.WaitForExit(2000)

        if (-not $reader -and -not $Quiet -and (Test-Path $OutPath)) {
            try {
                $fs = [System.IO.File]::Open($OutPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            } catch {
                $Quiet = $true
                Write-Host "  (live progress unavailable: $_ — the transcript is still being written to $OutPath)"
            }
        }
        if ($reader) {
            $chunk = $reader.ReadToEnd()
            if ($chunk) {
                $buffer += $chunk
                $parts = $buffer -split "`n"
                $buffer = $parts[$parts.Count - 1]
                if ($parts.Count -gt 1) {
                    foreach ($line in $parts[0..($parts.Count - 2)]) {
                        if ($line -match '"type"\s*:\s*"tool_use"') { $toolCalls++ }
                        if ($line -match 'PreToolUse guard') { $denials++ }
                        foreach ($msg in (Format-TranscriptEvent -Line $line)) {
                            Write-Host $msg
                            $lastOutput = Get-Date
                        }
                    }
                }
            }
        }
        if ($exited) { break }
        if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
        if (-not $Quiet -and ((Get-Date) - $lastOutput).TotalSeconds -ge 60) {
            $elapsed = [int]((Get-Date) - $started).TotalMinutes
            Write-Host ("  ... still working ({0} min elapsed, {1} tool call(s) so far) {2}" -f $elapsed, $toolCalls, (Get-Date -Format 'HH:mm:ss'))
            $lastOutput = Get-Date
        }
    }
    if ($reader) {
        try {
            $tail = $reader.ReadToEnd()
            foreach ($line in (($buffer + $tail) -split "`n")) {
                if ($line -match '"type"\s*:\s*"tool_use"') { $toolCalls++ }
                if ($line -match 'PreToolUse guard') { $denials++ }
                foreach ($msg in (Format-TranscriptEvent -Line $line)) { Write-Host $msg }
            }
        } catch { }
        $reader.Dispose()
    }
    return [pscustomobject]@{
        Process     = $proc
        ExitCode    = if ($exited) { $proc.ExitCode } else { $null }
        TimedOut    = $timedOut
        ToolCalls   = $toolCalls
        HookDenials = $denials
    }
}

# --- Pre-launch self-test: does the credential work, and does the guard bite? -
function Invoke-AgentPreflight {
    <#
        One cheap Haiku call from a scratch project directory that carries a
        copy of the kit's .claude\settings.json and hooks\, and no CLAUDE.md
        (so the model has no reason to refuse). It is asked to run a harmless
        Invoke-WebRequest to 127.0.0.1:9, which the PreToolUse guard must deny.
        Outcomes:
          auth_ok  - a result event came back, so TCP+TLS+token+subscription work
          hook     - 'verified' (the guard's deny reason is in the transcript),
                     'inert' (the command demonstrably executed — the guard
                     did NOT block it), or 'inconclusive' (the model never
                     attempted the command, or the outcome could not be read)
        A run costs a few seconds and a fraction of a cent, and replaces a
        confusing turn-0 failure with a plain answer. The canary URL is a
        closed local port, so even an inert guard changes nothing.
    #>
    $canaryDir = Join-Path $stateDir 'canary'
    Remove-Item $canaryDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path (Join-Path $canaryDir '.claude') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $canaryDir 'hooks') -Force | Out-Null
    Copy-Item (Join-Path $KitRoot '.claude\settings.json') (Join-Path $canaryDir '.claude\settings.json') -Force
    Copy-Item (Join-Path $KitRoot 'hooks\PreToolUse-Guard.ps1') (Join-Path $canaryDir 'hooks\PreToolUse-Guard.ps1') -Force

    $canaryCmd = 'Invoke-WebRequest -Uri http://127.0.0.1:9/repair-kit-hook-canary -UseBasicParsing -TimeoutSec 3'
    $prompt = "Automated self-test. Using your shell tool, run exactly this one command and then reply with a single line quoting the tool's output or error verbatim. Do not explain, do not ask, and do not run anything else: $canaryCmd"
    $outPath = Join-Path $KitRoot "logs\preflight-$(Get-Date -Format 'yyyyMMdd-HHmmss').jsonl"

    $result = [ordered]@{ ran = $true; auth_ok = $false; hook = 'inconclusive'; detail = ''; transcript = $outPath; exit_code = $null }
    Push-Location $canaryDir
    try {
        $run = Start-MonitoredAgent -Quiet -TimeoutSeconds $PreflightSeconds -OutPath $outPath -Arguments @(
            '-p', $prompt,
            '--dangerously-skip-permissions',
            '--model', $PreflightModel,
            '--max-turns', '4',
            '--output-format', 'stream-json',
            '--verbose'
        )
    } finally { Pop-Location }

    if ($run.TimedOut) {
        try { Stop-Process -Id $run.Process.Id -Force -ErrorAction SilentlyContinue } catch { }
        $result.detail = "preflight did not finish within $PreflightSeconds s"
        return $result
    }
    $result.exit_code = $run.ExitCode

    $text = ''
    try { $text = Get-Content $outPath -Raw -ErrorAction Stop } catch { }
    $err = ''
    try { $err = Get-Content "$outPath.err" -Raw -ErrorAction Stop } catch { }
    $all = "$text`n$err"

    $gotResult = ($text -match '"type"\s*:\s*"result"')
    $result.auth_ok = ($run.ExitCode -eq 0 -and $gotResult)
    if (-not $result.auth_ok) {
        if ($all -match '(?i)(401|403|unauthori[sz]ed|invalid api key|authentication|oauth|not logged in|token.*(expired|invalid|revoked)|please run /login)') {
            $result.detail = 'auth: ' + (Limit-Text (($err + ' ' + $text) -replace '\s+', ' ').Trim() 300)
        } elseif ($all -match '(?i)(ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|fetch failed|network|certificate)') {
            $result.detail = 'network: ' + (Limit-Text (($err + ' ' + $text) -replace '\s+', ' ').Trim() 300)
        } else {
            $result.detail = 'unknown: exit ' + $run.ExitCode + ' ' + (Limit-Text (($err + ' ' + $text) -replace '\s+', ' ').Trim() 300)
        }
        return $result
    }

    $attempted = ($text -match 'repair-kit-hook-canary' -and $text -match '"type"\s*:\s*"tool_use"')
    $denied    = ($all -match 'Agent-initiated network downloads are blocked' -or $all -match 'PreToolUse guard')
    $executed  = ($all -match '(?i)(unable to connect|actively refused|connection refused|ECONNREFUSED|No connection could be made|Failed to connect|remote server returned)')

    if ($denied) {
        $result.hook = 'verified'
        $result.detail = 'guard denied the canary command'
    } elseif ($attempted -and $executed) {
        $result.hook = 'inert'
        $result.detail = 'the canary command executed — the PreToolUse guard did not block it'
    } elseif ($attempted) {
        $result.detail = 'the model attempted the canary but neither a denial nor an execution could be read from the transcript'
    } else {
        $result.detail = 'the model never attempted the canary command'
    }
    return $result
}

if ($SkipPreflight) {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'Pre-launch self-test SKIPPED (-SkipPreflight). Neither the credential nor the command guard has been proven on this machine.'
    $sessionContext.preflight = [ordered]@{ ran = $false; auth_ok = $null; hook = 'skipped'; detail = '-SkipPreflight' }
} else {
    Write-KitLog -LogPath $LogPath -Message "Pre-launch self-test: proving the credential and the command guard with one $PreflightModel call..."
    $pf = Invoke-AgentPreflight
    $sessionContext.preflight = $pf
    Write-SessionContext

    if (-not $pf.auth_ok) {
        if ($pf.detail -like 'auth:*') {
            Write-KitLog -LogPath $LogPath -Level ERROR -Message "The saved credential was REJECTED ($($pf.detail)). Rebuild the drive on your own PC to refresh config\auth.env (see BUILD.md / docs\authentication.md). Nothing on this PC was changed."
            & (Join-Path $KitRoot 'scripts\Write-RepairReport.ps1') -ExitCode 5 | Out-Null
            exit 5
        }
        if ($pf.detail -like 'network:*') {
            Write-KitLog -LogPath $LogPath -Level ERROR -Message "The connectivity probe passed but the agent could not reach the API ($($pf.detail)). Treating as offline."
            & (Join-Path $KitRoot 'scripts\Write-RepairReport.ps1') -ExitCode 3 | Out-Null
            exit 3
        }
        Write-KitLog -LogPath $LogPath -Level ERROR -Message "Pre-launch self-test failed ($($pf.detail)). See $($pf.transcript) and its .err file. Re-run with -SkipPreflight only if you have read them and understand why."
        & (Join-Path $KitRoot 'scripts\Write-RepairReport.ps1') -ExitCode 1 | Out-Null
        exit 1
    }
    Write-KitLog -LogPath $LogPath -Message 'Credential accepted (API reachable, token valid).'

    switch ($pf.hook) {
        'verified' { Write-KitLog -LogPath $LogPath -Message 'PreToolUse guard verified: it blocked the canary command on this machine.' }
        'inert' {
            Write-KitLog -LogPath $LogPath -Level ERROR -Message "PreToolUse guard is NOT enforcing: $($pf.detail). Refusing to run an unattended agent without its argument-level guard. See $($pf.transcript). Nothing on this PC was changed."
            & (Join-Path $KitRoot 'scripts\Write-RepairReport.ps1') -ExitCode 4 | Out-Null
            exit 4
        }
        default {
            Write-KitLog -LogPath $LogPath -Level WARN -Message "PreToolUse guard could not be verified ($($pf.detail)). Continuing — the deny list still applies — but treat guard enforcement as UNPROVEN for this run and check $($pf.transcript)."
        }
    }
}

# --- Defender exclusions (best-effort; removed again in the finally below) ---
& (Join-Path $KitRoot 'scripts\03-Set-DefenderExclusions.ps1')
$sessionContext.defender_exclusions_added = $true
Write-SessionContext

# --- Launch ---
$runLogPath = Join-Path $KitRoot "logs\claude-run-$(Get-Date -Format 'yyyyMMdd-HHmmss').jsonl"

Write-KitLog -LogPath $LogPath -Message "Launching Claude Code. Transcript: $runLogPath"
Write-KitLog -LogPath $LogPath -Message "Prompt: $PlaybookPrompt"

# A deterministic session id lets us --resume the exact session if the
# wall-clock watchdog has to interrupt it (e.g. to let it write its summary).
$SessionId = [guid]::NewGuid().ToString()

# Shared argument set. --append-system-prompt-file injects the untrusted-content
# policy at the SYSTEM-PROMPT level (stronger than CLAUDE.md, and necessary
# because bypass mode forfeits Manual-mode's built-in injection screens).
$sysPromptArgs = @()
if (Test-Path $sysPromptFile) {
    $sysPromptArgs = @('--append-system-prompt-file', $sysPromptFile)
} else {
    Write-KitLog -LogPath $LogPath -Level WARN -Message "system-prompt-append.txt missing — running without the system-level injection policy."
}
$claudeArgs = @(
    '-p', $PlaybookPrompt,
    '--dangerously-skip-permissions',
    '--model', $Model,
    '--fallback-model', $FallbackModel,
    '--max-turns', "$MaxTurns",
    '--session-id', $SessionId,
    '--output-format', 'stream-json',
    '--verbose'
) + $sysPromptArgs

$exitCode = 1
Push-Location $KitRoot
try {
    Write-Host ''
    Write-Host '  --- Live progress (the full transcript is in the logs folder) ---'
    # NOTE: Windows has no SIGTERM; Stop-Process is the available control, and
    # exact interrupt/resume semantics on Windows are unverified in this repo
    # (authored without Windows hardware) — see docs/verification-checklist.md.
    $run = Start-MonitoredAgent -Arguments $claudeArgs -OutPath $runLogPath -TimeoutSeconds ($MaxMinutes * 60)

    if ($run.TimedOut) {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Agent exceeded the $MaxMinutes-minute wall-clock cap. Interrupting, then resuming once to let it finish and write its summary."
        try { $run.Process.CloseMainWindow() | Out-Null } catch { }
        Start-Sleep -Seconds 5
        if (-not $run.Process.HasExited) { Stop-Process -Id $run.Process.Id -Force -ErrorAction SilentlyContinue }

        # One bounded resume so the agent can wrap up + write repair-summary.json.
        # Same system-prompt policy and its own (short) wall clock, so a second
        # hang cannot hold the machine either.
        $resumeArgs = @(
            '--resume', $SessionId,
            '-p', 'You were interrupted at a time limit. Do not start new work. Finish only what is safely in progress, then write state\repair-summary.json as instructed and stop.',
            '--dangerously-skip-permissions',
            '--model', $FallbackModel,
            '--max-turns', '8',
            '--output-format', 'stream-json',
            '--verbose'
        ) + $sysPromptArgs
        $resume = Start-MonitoredAgent -Arguments $resumeArgs -OutPath "$runLogPath.resume" -TimeoutSeconds 600
        if ($resume.TimedOut) {
            Write-KitLog -LogPath $LogPath -Level ERROR -Message 'The bounded resume also hit its 10-minute cap; stopping it.'
            if (-not $resume.Process.HasExited) { Stop-Process -Id $resume.Process.Id -Force -ErrorAction SilentlyContinue }
        }
        $exitCode = 2
    } else {
        $exitCode = $run.ExitCode
        if ($run.HookDenials -gt 0) {
            Write-KitLog -LogPath $LogPath -Level WARN -Message "The PreToolUse guard denied $($run.HookDenials) command(s) during the run — see the transcript; each one is either an out-of-scope action or an injection attempt worth reading."
        }
    }
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
            Copy-Item -Path (Join-Path $KitRoot 'logs\*') -Destination $auditDir -Force -ErrorAction SilentlyContinue
            Copy-Item -Path (Join-Path $stateDir '*.json') -Destination $auditDir -Force -ErrorAction SilentlyContinue
            Copy-Item -Path (Join-Path $stateDir '*.flag') -Destination $auditDir -Force -ErrorAction SilentlyContinue
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
} elseif ($exitCode -eq 2) {
    Write-KitLog -LogPath $LogPath -Level WARN -Message "Claude Code session was stopped at the time limit (exit 2). Whatever it wrote to state\repair-summary.json is partial by definition. Transcript: $runLogPath"
} else {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Claude Code session exited non-zero ($exitCode). Check $runLogPath and $runLogPath.err before assuming any repair completed."
}

# Backup hygiene: an infected source machine can copy infected files into
# the backup, turning the backup drive into a transmission path onto a clean
# machine. The agent drops state\backup-needs-scan.flag when it found malware
# (see CLAUDE.md), so this reminder can name the actual risk instead of a
# boilerplate "maybe scan it". The launcher can't detect malware itself, so
# absent the flag it still cautions — just at a lower volume.
$scanFlag = Join-Path $stateDir 'backup-needs-scan.flag'
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
