<#
.SYNOPSIS
    Offline boot-repair for a Windows install that WON'T boot. Run from a WinPE
    recovery environment (booted via Ventoy from this same USB), NOT from a
    running Windows. See docs/offline-repair-playbook.md.

.DESCRIPTION
    The autonomous Claude agent cannot help here — no booted OS means no
    cloud brain. This is a deterministic PowerShell procedure a human (or the
    agent, later, once the machine boots again) runs to get Windows bootable.

    Assessment-first: with no switch it only inspects and reports. It changes
    nothing unless you pass -Fix, and even then it runs only the SAFE, standard,
    reversible-ish sequence (BCD rebuild, offline SFC/DISM). It deliberately
    does NOT automate offline registry-hive edits — that step bricks boot when
    wrong and stays manual (playbook §3).

.PARAMETER WindowsVolume
    Drive letter of the broken Windows volume as seen FROM WinPE (e.g. 'C').
    Omit to auto-detect by scanning for \Windows\System32\config\SYSTEM — WinPE
    reassigns letters, so auto-detect is usually more reliable than guessing.

.PARAMETER SourceWim
    Path to a matching-version install.wim for offline DISM /RestoreHealth
    (e.g. 'E:\ISO\install.wim' or a mounted ISO). Optional; without it, DISM
    ScanHealth still runs but RestoreHealth is skipped with a note.

.PARAMETER Fix
    Actually apply repairs. Without it, this is a read-only assessment.

.PARAMETER LogDir
    Where to write the log. Defaults to the kit's logs\ if resolvable, else the
    current directory (WinPE often has no persistent profile).
#>
[CmdletBinding()]
param(
    [string]$WindowsVolume,
    [string]$SourceWim,
    [switch]$Fix,
    [string]$LogDir
)

$ErrorActionPreference = 'Continue'

# WinPE may not have the kit's Common.ps1 resolvable the same way; keep this
# script self-contained rather than dot-sourcing, so it runs standalone.
if (-not $LogDir) {
    $LogDir = if ($PSScriptRoot -and (Test-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'))) {
        Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
    } else { (Get-Location).Path }
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $LogDir "offline-repair-$stamp.log"

function Say {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch { }
}

Say "Offline repair starting. Mode: $(if ($Fix) {'FIX (will make changes)'} else {'ASSESS ONLY (read-only)'})."
Say "Log: $log"

# --- Locate the broken Windows volume ------------------------------------
function Find-WindowsVolume {
    foreach ($d in [char[]]([char]'C'..[char]'Z')) {
        $probe = "${d}:\Windows\System32\config\SYSTEM"
        if (Test-Path $probe) { return "${d}:" }
    }
    return $null
}

$winVol = if ($WindowsVolume) { "$($WindowsVolume.TrimEnd(':')):" } else { Find-WindowsVolume }
if (-not $winVol -or -not (Test-Path "$winVol\Windows\System32\config\SYSTEM")) {
    Say "Could not find a Windows installation (no \Windows\System32\config\SYSTEM on any volume). If the disk isn't detected at all, this is a hardware/disk problem, not a boot-config one." 'ERROR'
    exit 1
}
Say "Target Windows volume: $winVol"

# --- BitLocker guard ------------------------------------------------------
# Touching an encrypted volume offline can trigger a recovery-key prompt on
# next boot. Refuse to make changes to a locked volume without the key.
try {
    $mb = (& manage-bde -status $winVol 2>&1 | Out-String)
    if ($mb -match 'Percentage Encrypted\s*:\s*(?!0\.0)') {
        Say "Volume $winVol appears BitLocker-encrypted. Offline changes can force a recovery-key prompt at next boot." 'WARN'
        if ($Fix) {
            Say "Refusing to modify an encrypted volume without confirmation of the recovery key. Unlock it first (manage-bde -unlock) or run assessment-only. Aborting fixes." 'ERROR'
            exit 2
        }
    }
} catch { Say "Could not query BitLocker state ($_). Proceeding with caution." 'WARN' }

# --- Assess: what does the boot situation look like? ---------------------
Say "--- Assessment ---"
Say "Windows folder present: $(Test-Path "$winVol\Windows")"
$regback = "$winVol\Windows\System32\config\RegBack"
if (Test-Path $regback) {
    $rbSize = (Get-ChildItem $regback -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Say "RegBack present, ~$([math]::Round(($rbSize/1MB),1)) MB (0 MB = the modern default; no usable hive backup)."
}
$minidump = "$winVol\Windows\Minidump"
if (Test-Path $minidump) {
    $dumps = @(Get-ChildItem $minidump -Filter *.dmp -ErrorAction SilentlyContinue)
    Say "Found $($dumps.Count) crash minidump(s) — a bugcheck loop is a likely cause; analyze once booted (cdb !analyze -v)."
}

if (-not $Fix) {
    Say "Assessment complete. Re-run with -Fix to apply the standard boot-repair sequence (BCD rebuild + offline SFC/DISM). Registry-hive repair stays manual — see docs/offline-repair-playbook.md." 'INFO'
    exit 0
}

# --- Fix: the safe, standard sequence ------------------------------------
Say "--- Applying repairs ---"

# 1. Boot configuration. bootrec is a WinRE tool; bcdboot is the portable
#    WinPE equivalent and is the robust UEFI rebuild. Try bootrec if present,
#    always follow with bcdboot which regenerates boot files non-destructively.
if (Get-Command bootrec -ErrorAction SilentlyContinue) {
    Say "Running bootrec /scanos, /fixmbr, /fixboot, /rebuildbcd"
    & bootrec /scanos      2>&1 | ForEach-Object { Say "  bootrec: $_" }
    & bootrec /fixmbr      2>&1 | ForEach-Object { Say "  bootrec: $_" }
    & bootrec /fixboot     2>&1 | ForEach-Object { Say "  bootrec: $_" }
    'Yes' | & bootrec /rebuildbcd 2>&1 | ForEach-Object { Say "  bootrec: $_" }
} else {
    Say "bootrec not available in this environment; relying on bcdboot." 'WARN'
}

# Mount the EFI System Partition and regenerate UEFI boot files.
$efi = 'S:'
try {
    & mountvol $efi /S 2>&1 | Out-Null
    Say "Running bcdboot $winVol\Windows /s $efi /f UEFI"
    & bcdboot "$winVol\Windows" /s $efi /f UEFI 2>&1 | ForEach-Object { Say "  bcdboot: $_" }
} catch {
    Say "EFI mount/bcdboot step failed ($_). On a legacy BIOS machine this is expected; bootrec above covers MBR." 'WARN'
}

# 2. Offline system-file integrity.
Say "Running offline SFC (this can take a while)..."
& sfc "/scannow" "/offbootdir=$winVol\" "/offwindir=$winVol\Windows" 2>&1 | ForEach-Object { Say "  sfc: $_" }

Say "Running offline DISM ScanHealth..."
& DISM "/Image:$winVol\" /Cleanup-Image /ScanHealth 2>&1 | ForEach-Object { Say "  dism: $_" }

if ($SourceWim -and (Test-Path $SourceWim)) {
    Say "Running offline DISM RestoreHealth from $SourceWim"
    & DISM "/Image:$winVol\" /Cleanup-Image /RestoreHealth "/Source:WIM:${SourceWim}:1" /LimitAccess 2>&1 | ForEach-Object { Say "  dism: $_" }
} else {
    Say "No -SourceWim given (or not found), so DISM /RestoreHealth was skipped — offline DISM needs a matching install.wim as its source. See docs/offline-repair-playbook.md." 'WARN'
}

Say "--- Done ---"
Say "Standard boot-repair sequence applied. Remove the USB and try booting normally."
Say "If it boots: STOP here and run Repair-This-PC from Windows so the agent can finish the job (root cause, restore point, RegBack re-enable)."
Say "If it still won't boot: the cause is likely a bad driver/service/hive (manual reg-load, playbook §3) or failing hardware — not something this sequence fixes."
exit 0
