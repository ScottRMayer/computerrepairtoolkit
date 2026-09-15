<#
.SYNOPSIS
    Adds (or removes, with -Remove) Defender scan exclusions for the USB
    kit's tool/bin directories, so NirSoft/PsExec/AdwCleaner-style
    HackTool/PUA detections don't quarantine a whitelisted tool mid-run.
    Runs even in Safe Mode, since Defender real-time protection is active
    there too (see docs/safe-mode-constraints.md).

.DESCRIPTION
    Best-effort by design: this must never be the reason a repair session
    aborts. Failures are logged and the script exits 0 regardless.

    IMPORTANT — these exclusions are persistent machine settings. They
    survive reboot and they survive the USB being unplugged, which means a
    path like 'E:\tools' stays excluded and is inherited by whatever device
    gets drive letter E: next. Start-Repair.ps1 calls this with -Remove in
    a finally block so the target machine isn't left permanently weakened
    by a repair session. If a session is killed hard (power loss, forced
    reboot), run this manually with -Remove afterwards.

.PARAMETER Remove
    Remove the exclusions this script previously added, instead of adding
    them.
#>
[CmdletBinding()]
param(
    [switch]$Remove
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$KitRoot = Get-KitRoot
$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'defender'

$pathsToExclude = @(
    (Join-Path $KitRoot 'tools'),
    (Join-Path $KitRoot 'bin'),
    (Join-Path $KitRoot 'scripts')
)

# What this script actually did, for the launcher (session-context.json) and
# the report card — "added" is not assumed, it is recorded.
$statePath = Join-Path $KitRoot 'state\defender-exclusions.json'
function Write-ExclusionState([string[]]$Present, [string[]]$Failed) {
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
        [ordered]@{ written_at = (Get-Date -Format 'o'); mode = $(if ($Remove) { 'remove' } else { 'add' }); present = @($Present); failed = @($Failed) } |
            ConvertTo-Json -Depth 3 | Set-Content -Path $statePath -Encoding UTF8
    } catch { }
}

$cmdletName = if ($Remove) { 'Remove-MpPreference' } else { 'Add-MpPreference' }
if (-not (Get-Command $cmdletName -ErrorAction SilentlyContinue)) {
    Write-KitLog -LogPath $LogPath -Level WARN -Message "$cmdletName not available (Defender PowerShell module missing) — skipping. Continuing regardless."
    Write-ExclusionState @() @()
    exit 0
}

function Get-CurrentExclusions {
    try { return @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ }) } catch { return $null }
}

$failed = @()
if ($Remove) {
    # Only remove what is actually there: Remove-MpPreference on a path that
    # was never added errors, and that error used to be reported as "the
    # machine may be left with a standing exclusion" — the opposite of the truth.
    $current = Get-CurrentExclusions
    foreach ($path in $pathsToExclude) {
        $present = ($null -eq $current) -or (@($current | Where-Object { $_ -ieq $path }).Count -gt 0)
        if (-not $present) {
            Write-KitLog -LogPath $LogPath -Message "No Defender exclusion for $path was present; nothing to remove."
            continue
        }
        try {
            Remove-MpPreference -ExclusionPath $path -ErrorAction Stop
            Write-KitLog -LogPath $LogPath -Message "Removed Defender exclusion: $path"
        } catch {
            Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not remove Defender exclusion for '$path': $_"
        }
    }
    $after = Get-CurrentExclusions
    $standing = @()
    if ($null -ne $after) {
        $standing = @($pathsToExclude | Where-Object { $p = $_; @($after | Where-Object { $_ -ieq $p }).Count -gt 0 })
    }
    foreach ($p in $standing) {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "This machine is left with a standing Defender exclusion for '$p'. Remove it by hand: Remove-MpPreference -ExclusionPath '$p'"
    }
    Write-ExclusionState $standing @()
} else {
    $added = @()
    foreach ($path in $pathsToExclude) {
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            Write-KitLog -LogPath $LogPath -Message "Excluded from Defender scanning: $path"
            $added += $path
        } catch {
            Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not add Defender exclusion for '$path': $_ (a bundled tool may get quarantined mid-run)"
            $failed += $path
        }
    }
    Write-ExclusionState $added $failed
}

exit 0
