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
    [string]$LogDir,

    # The BitLocker guard below parses manage-bde's ENGLISH output. On a
    # localized WinPE it cannot tell, and then fails CLOSED (refuses -Fix).
    # Pass this only when you have confirmed by other means that the volume
    # is not encrypted, or you hold the recovery key.
    [switch]$IgnoreBitLockerCheck,

    # Index inside -SourceWim to use for DISM /RestoreHealth. Multi-edition
    # images put Home at index 1; a Pro machine needs the Pro index or DISM
    # fails with 0x800f081f. iso\image-info.json on the kit lists them.
    [int]$SourceIndex = 1
)

$ErrorActionPreference = 'Continue'

# WinPE may not have the kit's Common.ps1 resolvable the same way; keep this
# script self-contained rather than dot-sourcing, so it runs standalone.
if (-not $LogDir) {
    # Prefer the kit's logs\ folder (create it if this is a fresh build) —
    # WinPE's current directory is the X: RAM disk and vanishes at reboot.
    $LogDir = (Get-Location).Path
    if ($PSScriptRoot) {
        try {
            $kitLogs = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
            New-Item -ItemType Directory -Path $kitLogs -Force -ErrorAction Stop | Out-Null
            $LogDir = $kitLogs
        } catch { }
    }
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
    # Never WinPE's own boot volume ($env:SystemDrive, normally X:), and
    # require a marker WinPE lacks (explorer.exe) — otherwise a machine whose
    # real Windows volume is BitLocker-locked, unlettered or RAW would be
    # "repaired" by running bcdboot/sfc/DISM against the WinPE RAM disk.
    foreach ($d in [char[]]([char]'C'..[char]'Z')) {
        if ("${d}:" -ieq $env:SystemDrive) { continue }
        if ((Test-Path "${d}:\Windows\System32\config\SYSTEM") -and (Test-Path "${d}:\Windows\explorer.exe")) { return "${d}:" }
    }
    return $null
}

$winVol = if ($WindowsVolume) { "$($WindowsVolume.TrimEnd(':')):" } else { Find-WindowsVolume }
if ($winVol -and ($winVol -ieq $env:SystemDrive)) {
    Say "$winVol is this WinPE's own boot volume, not the machine's Windows. Refusing." 'ERROR'
    exit 1
}
if (-not $winVol -or -not (Test-Path "$winVol\Windows\System32\config\SYSTEM")) {
    Say "Could not find a Windows installation (no \Windows\System32\config\SYSTEM plus \Windows\explorer.exe on any volume other than this WinPE's own)." 'ERROR'
    try {
        $locked = (& manage-bde -status 2>&1 | Out-String)
        if ($locked -match '(?i)locked') { Say "manage-bde reports a LOCKED volume: the Windows volume is probably BitLocker-protected. Unlock it first (manage-bde -unlock <letter>: -RecoveryPassword <key>) and re-run." 'WARN' }
    } catch { }
    Say "If the disk isn't detected at all, this is a hardware/disk problem, not a boot-config one." 'ERROR'
    exit 1
}
Say "Target Windows volume: $winVol"

# --- BitLocker guard ------------------------------------------------------
# Touching an encrypted volume offline can trigger a recovery-key prompt on
# next boot. Refuse to make changes to a locked volume without the key.
$bitlockerState = 'unknown'
try {
    $mb = (& manage-bde -status $winVol 2>&1 | Out-String)
    # Capture the NUMBER: a negative lookahead against "0.0" matched every
    # volume (the regex could backtrack into the whitespace), so every
    # decrypted disk was reported encrypted and -Fix always aborted.
    if ($mb -match '(?i)Percentage Encrypted\s*:\s*([\d.,]+)\s*%') {
        $pct = 0.0
        try { $pct = [double]($Matches[1] -replace ',', '.') } catch { $pct = -1 }
        if ($pct -gt 0 -or $pct -lt 0) { $bitlockerState = 'encrypted' } else { $bitlockerState = 'clear' }
        if ($mb -match '(?i)Protection Status\s*:\s*Protection On|Lock Status\s*:\s*Locked') { $bitlockerState = 'encrypted' }
    } else {
        # No English "Percentage Encrypted" line at all: localized WinPE, or
        # manage-bde absent. We cannot tell — treat as encrypted.
        $bitlockerState = 'unknown'
    }
} catch { $bitlockerState = 'unknown' }

switch ($bitlockerState) {
    'encrypted' {
        Say "Volume $winVol appears BitLocker-encrypted. Offline changes can force a recovery-key prompt at next boot." 'WARN'
        if ($Fix -and -not $IgnoreBitLockerCheck) {
            Say "Refusing to modify an encrypted volume without confirmation of the recovery key. Unlock it first (manage-bde -unlock) or run assessment-only. Aborting fixes." 'ERROR'
            exit 2
        }
    }
    'unknown' {
        Say "Could not determine the BitLocker state of $winVol (manage-bde unavailable or non-English output). Failing CLOSED: treating it as encrypted." 'WARN'
        if ($Fix -and -not $IgnoreBitLockerCheck) {
            Say "Refusing to modify a volume whose encryption state is unknown. Confirm it is not BitLocker-protected, then re-run with -IgnoreBitLockerCheck. Aborting fixes." 'ERROR'
            exit 2
        }
    }
    default { Say "BitLocker: $winVol is not encrypted." }
}
if ($IgnoreBitLockerCheck -and $bitlockerState -ne 'clear') { Say "-IgnoreBitLockerCheck given: proceeding despite BitLocker state '$bitlockerState'." 'WARN' }

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
$stepResults = New-Object System.Collections.Generic.List[string]
function Note-Step([string]$name, [int]$code) {
    $stepResults.Add(("{0}: {1}" -f $name, $(if ($code -eq 0) { 'ok' } else { "exit $code" })))
    if ($code -ne 0) { Say "$name returned exit code $code" 'WARN' }
}

# 1. Boot configuration. bootrec is a WinRE tool; bcdboot is the portable
#    WinPE equivalent and is the robust UEFI rebuild. Try bootrec if present,
#    always follow with bcdboot which regenerates boot files non-destructively.
$isUefi = $false
try { $isUefi = [bool](Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') -or ($env:firmware_type -eq 'UEFI') } catch { }
if (Get-Command bootrec -ErrorAction SilentlyContinue) {
    Say "Running bootrec /scanos, /fixmbr, /fixboot, /rebuildbcd"
    & bootrec /scanos      2>&1 | ForEach-Object { Say "  bootrec: $_" }
    & bootrec /fixmbr      2>&1 | ForEach-Object { Say "  bootrec: $_" }
    & bootrec /fixboot     2>&1 | ForEach-Object { Say "  bootrec: $_" }
    # /rebuildbcd asks Y/N/A per installation found; 'A' (all) is the
    # unattended answer. Whether bootrec reads stdin at all is unverified —
    # if it stops at a prompt, press A on the keyboard.
    'A' | & bootrec /rebuildbcd 2>&1 | ForEach-Object { Say "  bootrec: $_" }
    Note-Step 'bootrec' $LASTEXITCODE
} else {
    Say "bootrec not available in this environment (generic WinPE); relying on bcdboot." 'WARN'
    if (-not $isUefi) {
        Say "Legacy BIOS firmware and no bootrec: MBR boot code cannot be repaired here. Use a WinRE image (Ventoy menu) which includes bootrec." 'WARN'
        $stepResults.Add('bootrec: unavailable (legacy BIOS boot code NOT repaired)')
    }
}

# Mount the EFI System Partition on a FREE letter and regenerate UEFI boot
# files. Only when the mount succeeded and the ESP looks like one — bcdboot
# against whatever S: already was would write a BCD to the wrong place.
$efi = $null
foreach ($letter in [char[]]([char]'S'..[char]'Z')) {
    if (-not (Test-Path "${letter}:\")) { $efi = "${letter}:"; break }
}
if ($efi) {
    & mountvol $efi /S 2>&1 | Out-Null
    $mounted = ($LASTEXITCODE -eq 0) -and (Test-Path "$efi\EFI")
    if ($mounted) {
        Say "Running bcdboot $winVol\Windows /s $efi /f UEFI"
        & bcdboot "$winVol\Windows" /s $efi /f UEFI 2>&1 | ForEach-Object { Say "  bcdboot: $_" }
        Note-Step 'bcdboot (UEFI)' $LASTEXITCODE
        & mountvol $efi /D 2>&1 | Out-Null
    } else {
        Say "No EFI System Partition could be mounted (mountvol exit $LASTEXITCODE). On a legacy BIOS machine this is expected; bootrec above covers MBR." 'WARN'
        $stepResults.Add('bcdboot: skipped (no ESP mounted)')
    }
} else {
    Say 'No free drive letter S:-Z: to mount the EFI partition; skipping bcdboot.' 'WARN'
    $stepResults.Add('bcdboot: skipped (no free drive letter)')
}

# 2. Offline system-file integrity.
Say "Running offline SFC (this can take a while)..."
& sfc "/scannow" "/offbootdir=$winVol\" "/offwindir=$winVol\Windows" 2>&1 | ForEach-Object { Say "  sfc: $_" }
Note-Step 'sfc' $LASTEXITCODE

Say "Running offline DISM ScanHealth..."
& DISM "/Image:$winVol\" /Cleanup-Image /ScanHealth 2>&1 | ForEach-Object { Say "  dism: $_" }
Note-Step 'DISM ScanHealth' $LASTEXITCODE

if ($SourceWim -and (Test-Path $SourceWim)) {
    $prefix = if ($SourceWim -like '*.esd') { 'ESD:' } else { 'WIM:' }
    Say "Running offline DISM RestoreHealth from $SourceWim (index $SourceIndex)"
    & DISM "/Image:$winVol\" /Cleanup-Image /RestoreHealth "/Source:${prefix}${SourceWim}:$SourceIndex" /LimitAccess 2>&1 | ForEach-Object { Say "  dism: $_" }
    Note-Step 'DISM RestoreHealth' $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { Say "If DISM reported 0x800f081f, the image index does not match this Windows edition — see iso\image-info.json on the kit and pass -SourceIndex." 'WARN' }
} else {
    Say "No -SourceWim given (or not found), so DISM /RestoreHealth was skipped — offline DISM needs a matching install.wim as its source. See docs/offline-repair-playbook.md." 'WARN'
    $stepResults.Add('DISM RestoreHealth: skipped (no source image)')
}

Say "--- Done ---"
foreach ($r in $stepResults) { Say "  $r" }
if ($stepResults -join ' ' -match 'exit \d|NOT repaired') {
    Say "At least one step FAILED (see above). The boot-repair sequence is NOT complete." 'WARN'
} else {
    Say "Standard boot-repair sequence applied."
}
Say "Remove the USB and try booting normally."
Say "If it boots: STOP here and run Repair-This-PC from Windows so the agent can finish the job (root cause, restore point, RegBack re-enable)."
Say "If it still won't boot: the cause is likely a bad driver/service/hive (manual reg-load, playbook §3) or failing hardware — not something this sequence fixes."
exit 0
