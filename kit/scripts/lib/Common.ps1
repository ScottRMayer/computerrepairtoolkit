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

    switch ($Level) {
        'WARN'  { Write-Warning $line }
        'ERROR' { Write-Error $line -ErrorAction Continue }
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
