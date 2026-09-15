<#
.SYNOPSIS
    Detects whether Windows booted into Safe Mode, and if so, which variant.

.DESCRIPTION
    Reads HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option, which only
    exists while Windows is actually running in Safe Mode. Absent entirely
    in normal mode. The mode is recorded in its DWORD value OptionValue
    (1 = Minimal, 2 = Network — the same values GetSystemMetrics(SM_CLEANBOOT)
    returns); the key's (default) string is checked only as a fallback.
    See docs/safe-mode-constraints.md for what each mode does and doesn't
    support.

.OUTPUTS
    A string: 'Normal', 'Minimal', or 'Network'.
#>
[CmdletBinding()]
param()

$safeBootKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option'

if (-not (Test-Path $safeBootKey)) {
    Write-Output 'Normal'
    return
}

$props = Get-ItemProperty -Path $safeBootKey -ErrorAction SilentlyContinue
$optionValue = $null
if ($props -and $null -ne $props.OptionValue) { $optionValue = [int]$props.OptionValue }
$defaultText = if ($props) { [string]$props.'(default)' } else { '' }

if ($optionValue -eq 2 -or ($null -eq $optionValue -and $defaultText -match 'Network')) {
    Write-Output 'Network'
} elseif ($optionValue -eq 1 -or ($null -eq $optionValue -and $defaultText -match 'Minimal')) {
    Write-Output 'Minimal'
} else {
    # Key exists but neither value is recognizable — Safe Mode is certainly
    # active (the key only exists while booted into it), so fail toward the
    # more restrictive assumption rather than 'Normal'.
    Write-Warning "SafeBoot\Option key present but unrecognized (OptionValue='$optionValue', default='$defaultText') — assuming Minimal (most restrictive)."
    Write-Output 'Minimal'
}
