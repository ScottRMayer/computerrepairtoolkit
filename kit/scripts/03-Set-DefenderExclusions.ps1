<#
.SYNOPSIS
    Excludes the USB kit's tool/bin directories from Defender scanning, so
    NirSoft/PsExec/AdwCleaner-style HackTool/PUA detections don't quarantine
    a whitelisted tool mid-run. Runs even in Safe Mode, since Defender
    real-time protection is active there too (see
    docs/safe-mode-constraints.md).

.DESCRIPTION
    Best-effort by design: this must never be the reason a repair session
    aborts. Failures are logged and the script exits 0 regardless, so
    Start-Repair.ps1 (and CLAUDE.md) can treat "exclusions may not have
    applied" as a known-degraded-mode rather than a hard stop — the
    alternative (blocking the whole session on Defender config succeeding)
    is worse than occasionally losing a tool to quarantine.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$KitRoot = Get-KitRoot
$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'defender'

$pathsToExclude = @(
    (Join-Path $KitRoot 'tools'),
    (Join-Path $KitRoot 'bin'),
    (Join-Path $KitRoot 'scripts')
)

if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'Add-MpPreference not available (Defender PowerShell module missing) — skipping exclusions. Continuing session regardless.'
    exit 0
}

foreach ($path in $pathsToExclude) {
    try {
        Add-MpPreference -ExclusionPath $path -ErrorAction Stop
        Write-KitLog -LogPath $LogPath -Message "Excluded from Defender scanning: $path"
    } catch {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not add Defender exclusion for '$path': $_. Continuing — a whitelisted tool may get quarantined; note that in the run summary if it happens."
    }
}

exit 0
