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
         leave the agent believing it has a rollback it doesn't have. The
         previous value is restored afterwards so the machine isn't left
         with the throttle permanently disabled.
      2. Calls Checkpoint-Computer.
      3. Re-reads Get-ComputerRestorePoint and confirms a restore point
         with a timestamp after this script started actually exists.
         Exits non-zero if it doesn't, regardless of what step 2 reported.

         Get-ComputerRestorePoint returns CreationTime as a WMI (DMTF) date
         STRING such as 20260915133500.000000-000, not a DateTime
         (https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-computerrestorepoint).
         It must be converted before comparing — a direct string-vs-date
         comparison always succeeds and would make this check meaningless.

      On success writes state\restore-point.json so the launcher's report
      card and the agent's summary can name the exact restore point
      (description + sequence number) without re-deriving it.

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
$Description = 'PC Repair Kit - pre-repair'

$stateDir = Join-Path $KitRoot 'state'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$statePath = Join-Path $stateDir 'restore-point.json'

function Write-RestorePointState {
    param([hashtable]$State)
    try {
        ([ordered]@{
            written_at = (Get-Date -Format 'o')
        } + $State) | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath -Encoding UTF8
    } catch {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not write $statePath : $_"
    }
}

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
        Write-RestorePointState @{ kind = 'registry-export'; verified = $false; path = $regBackupDir }
        exit 1
    }

    Write-KitLog -LogPath $LogPath -Message "Safe Mode registry backup complete: $regBackupDir. This is restorable with 'reg import', NOT a System Restore rollback — note that distinction in the run summary."
    Write-RestorePointState @{ kind = 'registry-export'; verified = $true; path = $regBackupDir }
    exit 0
}

Write-KitLog -LogPath $LogPath -Message 'Normal mode: preparing verified System Restore point.'

# --- 1. Lift the 24h throttle, remembering what was there so it can be put back ---
$freqKeyPath = 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$freqName = 'SystemRestorePointCreationFrequency'
$priorFreq = $null      # $null = value did not exist before we touched it
$freqChanged = $false
try {
    if (-not (Test-Path $freqKeyPath)) {
        New-Item -Path $freqKeyPath -Force | Out-Null
    }
    $existing = Get-ItemProperty -Path $freqKeyPath -Name $freqName -ErrorAction SilentlyContinue
    if ($existing) { $priorFreq = [int]$existing.$freqName }
    New-ItemProperty -Path $freqKeyPath -Name $freqName -Value 0 -PropertyType DWord -Force | Out-Null
    $freqChanged = $true
    Write-KitLog -LogPath $LogPath -Message "$freqName set to 0 (disables the 24h throttle; previous value: $(if ($null -eq $priorFreq) { '<absent>' } else { $priorFreq }))."
} catch {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Failed to set ${freqName}: $_. Proceeding anyway, but a throttled restore point may silently no-op — verification below is what actually matters."
}

# --- 2. Create ---
try {
    Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS'
} catch {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "Checkpoint-Computer threw: $_"
}

# --- 3. Put the throttle back the way it was ---
if ($freqChanged) {
    try {
        if ($null -eq $priorFreq) {
            Remove-ItemProperty -Path $freqKeyPath -Name $freqName -Force -ErrorAction Stop
            Write-KitLog -LogPath $LogPath -Message "$freqName removed again (it did not exist before this run)."
        } else {
            Set-ItemProperty -Path $freqKeyPath -Name $freqName -Value $priorFreq -ErrorAction Stop
            Write-KitLog -LogPath $LogPath -Message "$freqName restored to $priorFreq."
        }
    } catch {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not restore ${freqName}: $_. The machine is left with the 24h restore-point throttle disabled (harmless, but note it)."
    }
}

# --- 4. Verify — this is the real gate ---
# Checkpoint-Computer succeeding is not sufficient evidence, per the
# frequency-throttle behavior described above. Convert the DMTF timestamp
# to a real DateTime before comparing; see the header for why.
function ConvertFrom-DmtfDate {
    param($Value)
    if ($Value -is [datetime]) { return $Value }
    $text = [string]$Value
    try { return [System.Management.ManagementDateTimeConverter]::ToDateTime($text) } catch { }
    # Manual fallback: yyyyMMddHHmmss.ffffff+UUU  (UUU = offset from UTC in minutes)
    if ($text -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\.(\d{6})([+-])(\d{3})$') {
        try {
            $utc = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3],
                                   [int]$Matches[4], [int]$Matches[5], [int]$Matches[6],
                                   [int]([int]$Matches[7] / 1000), [System.DateTimeKind]::Utc)
            $offsetMinutes = [int]$Matches[9]
            if ($Matches[8] -eq '+') { $utc = $utc.AddMinutes(-$offsetMinutes) } else { $utc = $utc.AddMinutes($offsetMinutes) }
            return $utc.ToLocalTime()
        } catch { return $null }
    }
    return $null
}

Start-Sleep -Seconds 3
$newPoints = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | ForEach-Object {
    $created = ConvertFrom-DmtfDate $_.CreationTime
    if ($created -and $created -ge $startTime.AddMinutes(-1)) {
        [pscustomobject]@{
            SequenceNumber = $_.SequenceNumber
            Description    = $_.Description
            CreationTime   = $created
        }
    }
})

if ($newPoints.Count -gt 0) {
    $rp = $newPoints | Sort-Object CreationTime -Descending | Select-Object -First 1
    Write-KitLog -LogPath $LogPath -Message "Verified: restore point '$($rp.Description)' (sequence $($rp.SequenceNumber)) created at $($rp.CreationTime)."
    Write-RestorePointState @{
        kind            = 'system-restore'
        verified        = $true
        description     = [string]$rp.Description
        sequence_number = [int]$rp.SequenceNumber
        creation_time   = $rp.CreationTime.ToString('o')
    }
    exit 0
} else {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message 'No restore point found with a timestamp after this script started. Do NOT report a restore point as available — none was verified to exist.'
    Write-RestorePointState @{ kind = 'system-restore'; verified = $false }
    exit 1
}
