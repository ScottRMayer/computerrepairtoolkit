<#
.SYNOPSIS
    Shared helpers for the PC Repair Kit's PowerShell scripts.

.DESCRIPTION
    Dot-source this from any kit script:
        . (Join-Path $PSScriptRoot 'lib\Common.ps1')
    Every kit script assumes it's running from $KitRoot\scripts\ (or
    $KitRoot\scripts\lib for this file) so that Get-KitRoot resolves
    correctly relative to $PSScriptRoot.
#>

function Get-KitRoot {
    <#
    .SYNOPSIS
        Resolves the USB kit root from any script under $KitRoot\scripts\.
    #>
    param(
        [string]$From = $PSScriptRoot
    )
    # Common.ps1 lives at $KitRoot\scripts\lib\Common.ps1 — walk up two levels.
    $scriptsDir = Split-Path -Parent $From
    return Split-Path -Parent $scriptsDir
}

function Write-KitLog {
    <#
    .SYNOPSIS
        Timestamped, leveled log line to both the console and the kit's
        run log, so every script's output ends up in the USB transcript
        even when invoked directly rather than through Start-Repair.ps1.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$LogPath
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    # ERROR uses red Write-Host rather than Write-Error on purpose: Write-Error
    # wraps the message in a "Write-KitLog : ... WriteErrorException" stack that
    # reads like the script itself crashed. For an operator-facing repair tool,
    # a plain red line is clearer.
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }

    if ($LogPath) {
        try {
            Add-Content -Path $LogPath -Value $line -Encoding UTF8
        } catch {
            Write-Warning "Could not write to log file '$LogPath': $_"
        }
    }
}

function Get-DefaultLogPath {
    <#
    .SYNOPSIS
        Standard per-run log file path under $KitRoot\logs\.
    #>
    param([string]$KitRoot, [string]$Prefix = 'run')
    $logsDir = Join-Path $KitRoot 'logs'
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return Join-Path $logsDir "$Prefix-$timestamp.log"
}

function Import-KitAuthEnv {
    <#
    .SYNOPSIS
        Loads KEY=VALUE pairs from config\auth.env into the process
        environment. Silently no-ops if the file doesn't exist yet (build
        step not done) rather than throwing, so scripts can be developed
        and tested independently of a real credential being present.
    #>
    param([string]$KitRoot)
    $authFile = Join-Path $KitRoot 'config\auth.env'
    if (-not (Test-Path $authFile)) {
        Write-KitLog -Message "No config\auth.env found at '$authFile' — see config\auth.env.example." -Level WARN
        return $false
    }
    Get-Content $authFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        $parts = $line.Split('=', 2)
        if ($parts.Count -eq 2) {
            $name = $parts[0].Trim()
            $value = $parts[1].Trim()
            # Tolerate the common .env spelling KEY="value" / KEY='value':
            # the quotes are not part of the token.
            if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
            if ($value) {
                Set-Item -Path "Env:$name" -Value $value
            }
        } elseif ($line -match '^sk-ant-') {
            # Tolerate a bare token line with no KEY= prefix. Pasting just the
            # token (without CLAUDE_CODE_OAUTH_TOKEN=) is an easy hand-entry
            # mistake; a lone sk-ant-... value can only be the OAuth token.
            Set-Item -Path 'Env:CLAUDE_CODE_OAUTH_TOKEN' -Value $line
        } elseif ($line -match '^sk-') {
            # Any other Anthropic-style key on its own line -> treat as API key.
            Set-Item -Path 'Env:ANTHROPIC_API_KEY' -Value $line
        }
    }
    return $true
}

function Get-BitLockerState {
    <#
    .SYNOPSIS
        BitLocker state for every volume, failing CLOSED: when it cannot be
        positively read, any_protected is $null and callers must treat the
        machine as encrypted (see kit/CLAUDE.md). Shared by the launcher
        (session-context.json) and 02-Get-SystemInventory.ps1.

        Prefers the BitLocker module's structured ProtectionStatus enum; the
        manage-bde fallback is a text parse of English output and is marked
        as such so a localized machine is not misread as unprotected.
    #>
    try {
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $volumes = @(Get-BitLockerVolume -ErrorAction Stop |
                Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage, EncryptionMethod |
                ForEach-Object {
                    [ordered]@{
                        mount_point           = [string]$_.MountPoint
                        volume_status         = [string]$_.VolumeStatus
                        protection_status     = [string]$_.ProtectionStatus
                        encryption_percentage = $_.EncryptionPercentage
                        encryption_method     = [string]$_.EncryptionMethod
                    }
                })
            return [ordered]@{
                source        = 'Get-BitLockerVolume'
                volumes       = $volumes
                any_protected = [bool](@($volumes | Where-Object { $_.protection_status -eq 'On' }).Count)
                reliable      = $true
            }
        }

        $raw = & manage-bde -status 2>&1 | Out-String
        if (-not $raw -or $LASTEXITCODE -ne 0) { throw "manage-bde -status failed (exit $LASTEXITCODE)" }
        return [ordered]@{
            source        = 'manage-bde (English text parse)'
            raw           = $raw
            any_protected = ($raw -match 'Protection\s+On')
            reliable      = ($raw -match 'Protection\s+(On|Off)')   # false on a localized machine
        }
    } catch {
        return [ordered]@{ source = 'unavailable'; error = "$_"; any_protected = $null; reliable = $false }
    }
}

function ConvertTo-ArgumentString {
    <#
    .SYNOPSIS
        Joins an argument array into ONE command line with Windows quoting
        rules, for Start-Process -ArgumentList.

        Windows PowerShell 5.1's Start-Process joins an -ArgumentList array
        with plain spaces and does not quote elements, so a prompt like
        "Diagnose and repair this machine" would reach the child as five
        separate arguments. This quotes any element containing whitespace
        or a double quote, escaping embedded quotes the CommandLineToArgvW
        way (\") that Node/Bun-based binaries such as claude.exe parse.
    #>
    param($Arguments)
    $quoted = foreach ($a in @($Arguments)) {
        if ($null -eq $a) { continue }
        $a = [string]$a
        if ($a -eq '' -or $a -match '[\s"]') {
            # Escape backslashes that precede a quote, then the quote itself.
            $escaped = $a -replace '(\\*)"', '$1$1\"'
            $escaped = $escaped -replace '(\\+)$', '$1$1'
            '"' + $escaped + '"'
        } else {
            $a
        }
    }
    return ($quoted -join ' ')
}

function Limit-Text {
    param([string]$Text, [int]$Max = 200)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 3) + '...'
}

function Get-ToolUseSummary {
    <#
        One readable line for a stream-json tool_use block, so the operator
        can see WHAT the agent is doing (not just that it is doing something).
    #>
    param($Block)
    $name = [string]$Block.name
    $in = $Block.input
    $detail = $null
    if ($in) {
        if ($in.command)        { $detail = [string]$in.command }
        elseif ($in.file_path)  { $detail = [string]$in.file_path }
        elseif ($in.pattern)    { $detail = [string]$in.pattern }
        elseif ($in.description){ $detail = [string]$in.description }
        else {
            try { $detail = ($in | ConvertTo-Json -Compress -Depth 3) } catch { $detail = '' }
        }
    }
    $detail = ($detail -replace '\s+', ' ').Trim()
    if ($detail) { return "running $name`: $(Limit-Text $detail 160)" }
    return "running $name"
}

function Get-TranscriptToolResults {
    <#
    .SYNOPSIS
        The tool_result blocks in one stream-json line (type=user), as
        objects with Text and IsError, or an empty array. Used to recognise a
        guard denial from the tool RESULT that carries it — never from
        assistant prose, which may merely mention the guard.
    #>
    param([string]$Line)
    if (-not $Line) { return @() }
    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith('{') -or $trimmed -notmatch '"tool_result"') { return @() }
    $ev = $null
    try { $ev = $trimmed | ConvertFrom-Json } catch { return @() }
    if (-not $ev -or $ev.type -ne 'user') { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($block in @($ev.message.content)) {
        if ($null -eq $block -or $block.type -ne 'tool_result') { continue }
        $txt = if ($block.content -is [string]) { $block.content }
               else { (@($block.content) | ForEach-Object { if ($_.text) { $_.text } }) -join ' ' }
        $out.Add([pscustomobject]@{ Text = [string]$txt; IsError = [bool]$block.is_error })
    }
    return $out.ToArray()
}

function Test-TranscriptGuardDenial {
    # $true when this line is a tool RESULT reporting a PreToolUse guard denial.
    param([string]$Line)
    foreach ($r in (Get-TranscriptToolResults -Line $Line)) {
        if ($r.Text -match '\[PreToolUse guard\]') { return $true }
    }
    return $false
}

function Format-TranscriptEvent {
    <#
    .SYNOPSIS
        Turns one line of Claude Code's --output-format stream-json
        transcript into zero or more plain-language progress lines for the
        console. Anything unparseable is skipped silently — the transcript
        file itself remains the record.
    .OUTPUTS
        [string[]] (possibly empty)
    #>
    param([string]$Line)
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $Line) { return @() }
    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith('{')) { return @() }
    $ev = $null
    try { $ev = $trimmed | ConvertFrom-Json } catch { return @() }
    if (-not $ev) { return @() }

    switch ([string]$ev.type) {
        'system' {
            if ($ev.subtype -eq 'init') {
                $model = if ($ev.model) { " (model: $($ev.model))" } else { '' }
                $out.Add("Assistant session started$model.")
            }
        }
        'assistant' {
            foreach ($block in @($ev.message.content)) {
                if ($null -eq $block) { continue }
                if ($block.type -eq 'text' -and $block.text) {
                    $t = ([string]$block.text -replace '\s+', ' ').Trim()
                    if ($t) { $out.Add("  > " + (Limit-Text $t 400)) }
                } elseif ($block.type -eq 'tool_use') {
                    $out.Add("  * " + (Get-ToolUseSummary $block))
                }
            }
        }
        'user' {
            foreach ($block in @($ev.message.content)) {
                if ($null -eq $block -or $block.type -ne 'tool_result' -or -not $block.is_error) { continue }
                $txt = if ($block.content -is [string]) { $block.content }
                       else { (@($block.content) | ForEach-Object { if ($_.text) { $_.text } }) -join ' ' }
                $txt = ([string]$txt -replace '\s+', ' ').Trim()
                if ($txt) { $out.Add("  ! tool error: " + (Limit-Text $txt 240)) }
            }
        }
        'result' {
            $turns = if ($null -ne $ev.num_turns) { " after $($ev.num_turns) turn(s)" } else { '' }
            $out.Add("Assistant finished: $($ev.subtype)$turns.")
        }
    }
    return $out.ToArray()
}
