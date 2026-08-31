<#
.SYNOPSIS
    Detects whether Windows booted into Safe Mode, and if so, which variant.

.DESCRIPTION
    Reads HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option, which only
    exists while Windows is actually running in Safe Mode. Absent entirely
    in normal mode. See docs/safe-mode-constraints.md for what each mode
    does and doesn't support.

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

$optionValue = (Get-ItemProperty -Path $safeBootKey -ErrorAction SilentlyContinue).'(default)'
# The (default) value under \Option is 'Minimal' or 'Network'.
if ($optionValue -match 'Network') {
    Write-Output 'Network'
} elseif ($optionValue -match 'Minimal') {
    Write-Output 'Minimal'
} else {
    # Key exists but value didn't match either known string — Safe Mode is
    # certainly active (the key only exists while booted into it), so fail
    # toward the more restrictive assumption rather than 'Normal'.
    Write-Warning "SafeBoot\Option key present but value unrecognized ('$optionValue') — assuming Minimal (most restrictive)."
    Write-Output 'Minimal'
}
