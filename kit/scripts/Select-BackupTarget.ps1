<#
.SYNOPSIS
    Interactive volume picker for the user-data backup destination. Run by
    Start-Repair.ps1 at launch, while a human is still present — the agent
    itself never chooses where backups go.

.DESCRIPTION
    Enumerates fixed and removable volumes via Get-CimInstance
    Win32_LogicalDisk (deliberately not Get-Volume, which depends on the
    Storage WMI provider and isn't confirmed available in Safe Mode — see
    docs/safe-mode-constraints.md; plain WMI is).

    Prints each volume with its free space, flags the ones too small to
    hold $RequiredBytes, and returns the selected root path. Returns $null
    if the operator chooses to skip the backup.

.PARAMETER RequiredBytes
    Measured size of what's about to be copied. Volumes with less free
    space than this (plus a 5% margin) are shown but marked as too small,
    and selecting one requires confirmation.

.PARAMETER ExcludePath
    A path whose volume should be flagged as "this is the kit's own drive."
    Backing up onto the USB is allowed but is usually the wrong choice —
    it's small, and it's the drive that leaves the house.

.OUTPUTS
    String path to the chosen destination root, or $null to skip.
#>
[CmdletBinding()]
param(
    [long]$RequiredBytes = 0,
    [string]$ExcludePath
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not [Environment]::UserInteractive) {
    Write-Warning 'Not an interactive session — cannot prompt for a backup target. Pass -BackupDestination to Start-Repair.ps1 explicitly, or -BackupMode Skip.'
    return $null
}

# Guarded: Split-Path -Qualifier throws rather than returning null when the
# path has no drive letter (kit run from a UNC path, say).
$kitVolume = $null
if ($ExcludePath) {
    try { $kitVolume = Split-Path -Qualifier $ExcludePath -ErrorAction Stop } catch { }
}
$requiredWithMargin = [long]($RequiredBytes * 1.05)

# DriveType 2 = Removable, 3 = Local Fixed Disk. Network drives are
# deliberately excluded: an unattended multi-hour copy to a share that may
# drop is a worse failure mode than not backing up at all.
$volumes = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
    Where-Object { $_.DriveType -in 2, 3 -and $_.FreeSpace -ne $null }

if (-not $volumes) {
    Write-Warning 'No fixed or removable volumes found to back up to.'
    return $null
}

Write-Host ''
Write-Host '  Select a backup destination' -ForegroundColor Cyan
Write-Host '  ---------------------------'
if ($RequiredBytes -gt 0) {
    Write-Host ("  Need approximately {0:N1} GB (plus 5% margin)." -f ($RequiredBytes / 1GB))
}
Write-Host ''

$index = 0
$choices = @{}
foreach ($vol in ($volumes | Sort-Object DeviceID)) {
    $index++
    $choices["$index"] = $vol

    $freeGB = $vol.FreeSpace / 1GB
    $sizeGB = $vol.Size / 1GB
    $label = if ($vol.VolumeName) { $vol.VolumeName } else { '(no label)' }
    $type = if ($vol.DriveType -eq 2) { 'Removable' } else { 'Fixed' }

    $flags = @()
    if ($RequiredBytes -gt 0 -and $vol.FreeSpace -lt $requiredWithMargin) {
        $flags += 'TOO SMALL'
    }
    if ($kitVolume -and $vol.DeviceID -eq $kitVolume) {
        $flags += "THIS IS THE KIT'S OWN DRIVE"
    }
    if ($vol.DeviceID -eq $env:SystemDrive) {
        $flags += 'SYSTEM DRIVE - a backup here does not survive a reinstall'
    }

    $flagText = if ($flags) { '  << ' + ($flags -join '; ') } else { '' }
    $color = if ($flags) { 'Yellow' } else { 'Green' }

    Write-Host ("  [{0}] {1}  {2,-20} {3,-10} {4,8:N1} GB free of {5,8:N1} GB{6}" -f `
        $index, $vol.DeviceID, $label, $type, $freeGB, $sizeGB, $flagText) -ForegroundColor $color
}

Write-Host ''
Write-Host '  [S] Skip the backup entirely' -ForegroundColor DarkYellow
Write-Host ''

while ($true) {
    $answer = Read-Host '  Selection'
    $answer = $answer.Trim()

    if ($answer -match '^[Ss]$') {
        Write-Host ''
        Write-Warning 'Backup will be SKIPPED. The restore point will be the only rollback available, and it does not cover documents, photos, or any other user file.'
        $confirm = Read-Host '  Type SKIP to confirm'
        if ($confirm -eq 'SKIP') { return $null }
        continue
    }

    if (-not $choices.ContainsKey($answer)) {
        Write-Host '  Not a valid selection.' -ForegroundColor Red
        continue
    }

    $chosen = $choices[$answer]

    if ($RequiredBytes -gt 0 -and $chosen.FreeSpace -lt $requiredWithMargin) {
        Write-Warning ("{0} has {1:N1} GB free but roughly {2:N1} GB is needed. The copy will fail partway through." -f `
            $chosen.DeviceID, ($chosen.FreeSpace / 1GB), ($requiredWithMargin / 1GB))
        $confirm = Read-Host '  Use it anyway? (y/N)'
        if ($confirm -notmatch '^[Yy]') { continue }
    }

    $destination = Join-Path "$($chosen.DeviceID)\" 'RepairKitBackups'
    Write-Host "  Backing up to: $destination" -ForegroundColor Green
    Write-Host ''
    return $destination
}
