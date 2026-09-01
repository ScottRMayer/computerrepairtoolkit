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

$cmdletName = if ($Remove) { 'Remove-MpPreference' } else { 'Add-MpPreference' }
if (-not (Get-Command $cmdletName -ErrorAction SilentlyContinue)) {
    Write-KitLog -LogPath $LogPath -Level WARN -Message "$cmdletName not available (Defender PowerShell module missing) — skipping. Continuing regardless."
    exit 0
}

foreach ($path in $pathsToExclude) {
    try {
        if ($Remove) {
            Remove-MpPreference -ExclusionPath $path -ErrorAction Stop
            Write-KitLog -LogPath $LogPath -Message "Removed Defender exclusion: $path"
        } else {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            Write-KitLog -LogPath $LogPath -Message "Excluded from Defender scanning: $path"
        }
    } catch {
        $verb = if ($Remove) { 'remove' } else { 'add' }
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not $verb Defender exclusion for '$path': $_"
        if ($Remove) {
            Write-KitLog -LogPath $LogPath -Level WARN -Message "This machine may be left with a standing exclusion for '$path'. Remove it by hand: Remove-MpPreference -ExclusionPath '$path'"
        }
    }
}

exit 0
