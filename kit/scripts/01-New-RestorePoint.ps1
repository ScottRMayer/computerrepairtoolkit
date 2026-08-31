<#
.SYNOPSIS
    Creates a verified System Restore point (normal mode), or a Safe Mode
    substitute (-SafeModeFallback). See docs/decisions.md for why the
    frequency-override and verification steps here are non-negotiable.

.DESCRIPTION
    Normal mode:
      1. Sets SystemRestorePointCreationFrequency = 0 so Windows doesn't
         silently skip creation because one was made in the last 24h — a
         skip that Checkpoint-Computer reports as *success*, which would
         leave the agent believing it has a rollback it doesn't have.
      2. Calls Checkpoint-Computer.
      3. Re-reads Get-ComputerRestorePoint and confirms a restore point
         with a timestamp after this script started actually exists.
         Exits non-zero if it doesn't, regardless of what step 2 reported.

    Safe Mode (-SafeModeFallback):
      Checkpoint-Computer fails outright in Safe Mode (VSS isn't in the
      Safe Mode service allowlist — see docs/safe-mode-constraints.md).
      This substitutes reg export of the hives most repair actions touch
      (SOFTWARE, SYSTEM, plus the current user's hive) to
      $KitRoot\backups\registry-<timestamp>\, which is restorable by hand
      with `reg import` but is not a one-click System Restore rollback.

.PARAMETER SafeModeFallback
    Switch. Use the reg-export substitute instead of Checkpoint-Computer.
    CLAUDE.md instructs the agent to pass this whenever Test-SafeMode.ps1
    reported anything other than 'Normal'.
#>
[CmdletBinding()]
param(
    [switch]$SafeModeFallback
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$KitRoot = Get-KitRoot
$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'restorepoint'
$startTime = Get-Date

if ($SafeModeFallback) {
    Write-KitLog -LogPath $LogPath -Message 'Safe Mode fallback: exporting registry hives instead of a System Restore point.'

    $regBackupDir = Join-Path $KitRoot "backups\registry-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Path $regBackupDir -Force | Out-Null

    $hives = @{
        'HKLM_SOFTWARE' = 'HKLM\SOFTWARE'
        'HKLM_SYSTEM'   = 'HKLM\SYSTEM'
        'HKCU'          = 'HKCU'
    }

    $failed = $false
    foreach ($name in $hives.Keys) {
        $dest = Join-Path $regBackupDir "$name.reg"
        Write-KitLog -LogPath $LogPath -Message "reg export $($hives[$name]) -> $dest"
        reg export $hives[$name] $dest /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-KitLog -LogPath $LogPath -Level ERROR -Message "reg export failed for $($hives[$name]) (exit $LASTEXITCODE)"
            $failed = $true
        }
    }

    if ($failed) {
        Write-KitLog -LogPath $LogPath -Level ERROR -Message 'Safe Mode registry backup incomplete. Do not treat this as an equivalent rollback point.'
        exit 1
    }

    Write-KitLog -LogPath $LogPath -Message "Safe Mode registry backup complete: $regBackupDir. This is restorable with 'reg import', NOT a System Restore rollback — note that distinction in the run summary."
    exit 0
}

Write-KitLog -LogPath $LogPath -Message 'Normal mode: preparing verified System Restore point.'

$freqKeyPath = 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\SystemRestore'
try {
    if (-not (Test-Path $freqKeyPath)) {
        New-Item -Path $freqKeyPath -Force | Out-Null
    }
    New-ItemProperty -Path $freqKeyPath -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
    Write-KitLog -LogPath $LogPath -Message 'SystemRestorePointCreationFrequency set to 0 (disables the 24h throttle).'
} catch {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Failed to set SystemRestorePointCreationFrequency: $_. Proceeding anyway, but a throttled restore point may silently no-op — verification below is what actually matters."
}

try {
    Checkpoint-Computer -Description 'PC Repair Kit - pre-repair' -RestorePointType 'MODIFY_SETTINGS'
} catch {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Checkpoint-Computer threw: $_"
}

# Verification is the real gate — Checkpoint-Computer succeeding is not
# sufficient evidence, per the frequency-throttle behavior described above.
Start-Sleep -Seconds 3
$newPoints = Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
    Where-Object { $_.CreationTime -ge $startTime }

if ($newPoints) {
    Write-KitLog -LogPath $LogPath -Message "Verified: restore point created at $($newPoints[0].CreationTime)."
    exit 0
} else {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message 'No restore point found with a timestamp after this script started. Do NOT report a restore point as available — none was verified to exist.'
    exit 1
}
