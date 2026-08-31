<#
.SYNOPSIS
    Writes a JSON system inventory snapshot for the agent to read before
    diagnosing anything. Uses Get-CimInstance exclusively — WMIC was
    removed from Windows 11 24H2/25H2 as of KB5120998 (2026-08-14) and will
    not exist on target machines.

.OUTPUTS
    $KitRoot\logs\inventory-<timestamp>.json
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$KitRoot = Get-KitRoot
$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'inventory'

function Get-CimSafe {
    <#
    One bad CIM class shouldn't abort the whole inventory — record the
    failure inline and keep going. Selected properties only: full CIM
    objects carry COM/lazy-eval members that don't serialize to JSON cleanly.
    #>
    param([string]$ClassName, [string[]]$Properties)
    try {
        $result = Get-CimInstance -ClassName $ClassName -ErrorAction Stop
        if ($Properties) {
            return $result | Select-Object $Properties
        }
        return $result | Select-Object *
    } catch {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Get-CimInstance $ClassName failed: $_"
        return @{ error = "$_" }
    }
}

function Get-BitLockerState {
    <#
    Prefers the BitLocker module; falls back to parsing manage-bde, which is
    present on editions where the PowerShell module isn't. Never throws — a
    machine with no BitLocker at all is the common case, not an error.
    #>
    try {
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $volumes = Get-BitLockerVolume -ErrorAction Stop |
                Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage, EncryptionMethod
            return @{
                source  = 'Get-BitLockerVolume'
                volumes = @($volumes)
                any_protected = [bool](@($volumes | Where-Object { $_.ProtectionStatus -eq 'On' }).Count)
            }
        }

        $raw = & manage-bde -status 2>&1 | Out-String
        return @{
            source        = 'manage-bde'
            raw           = $raw
            any_protected = ($raw -match 'Protection\s+On')
        }
    } catch {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not determine BitLocker state: $_"
        return @{ source = 'unavailable'; error = "$_"; any_protected = $null }
    }
}

function Get-MemoryDiagnosticResults {
    try {
        $events = Get-WinEvent -LogName System -MaxEvents 10 -ErrorAction Stop -FilterXPath `
            "*[System[Provider[@Name='Microsoft-Windows-MemoryDiagnostics-Results']]]"
        return @($events | Select-Object TimeCreated, Id, LevelDisplayName, Message)
    } catch {
        # No prior run is the normal case and produces a "no events found"
        # error, so this is informational rather than a warning.
        return @()
    }
}

Write-KitLog -LogPath $LogPath -Message 'Collecting system inventory via Get-CimInstance...'

$inventory = [ordered]@{
    collected_at = (Get-Date -Format 'o')
    safe_mode    = & (Join-Path $PSScriptRoot 'Test-SafeMode.ps1')

    operating_system = Get-CimSafe -ClassName Win32_OperatingSystem -Properties @(
        'Caption', 'Version', 'BuildNumber', 'OSArchitecture', 'InstallDate', 'LastBootUpTime'
    )
    bios = Get-CimSafe -ClassName Win32_BIOS -Properties @('Manufacturer', 'SMBIOSBIOSVersion', 'ReleaseDate')
    computer_system = Get-CimSafe -ClassName Win32_ComputerSystem -Properties @(
        'Manufacturer', 'Model', 'TotalPhysicalMemory', 'SystemType'
    )
    processor = Get-CimSafe -ClassName Win32_Processor -Properties @('Name', 'NumberOfCores', 'LoadPercentage')

    disks = Get-CimSafe -ClassName Win32_DiskDrive -Properties @(
        'Model', 'InterfaceType', 'Size', 'Status', 'MediaType'
    )
    logical_disks = Get-CimSafe -ClassName Win32_LogicalDisk -Properties @(
        'DeviceID', 'FreeSpace', 'Size', 'FileSystem', 'VolumeName'
    )

    # Non-OK PnP device status is the highest-signal "what's actually
    # broken here" field for driver-related repairs.
    problem_devices = (Get-CimSafe -ClassName Win32_PnPEntity -Properties @('Name', 'Status', 'ConfigManagerErrorCode')) |
        Where-Object { $_.ConfigManagerErrorCode -ne 0 }

    services_not_running = (Get-CimSafe -ClassName Win32_Service -Properties @('Name', 'DisplayName', 'StartMode', 'State')) |
        Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' }

    startup_commands = Get-CimSafe -ClassName Win32_StartupCommand -Properties @('Name', 'Command', 'Location', 'User')

    hotfixes = Get-CimSafe -ClassName Win32_QuickFixEngineering -Properties @('HotFixID', 'InstalledOn')

    # BitLocker state, collected BEFORE any repair action. If a volume is
    # encrypted with protection on, boot-config or system-volume work can
    # trigger a recovery-key demand at next boot — which on a family machine
    # where nobody has the key is permanent data loss, not an inconvenience.
    bitlocker = Get-BitLockerState

    # Results of any PRIOR Windows Memory Diagnostic run. Free diagnosis:
    # failing RAM mimics software corruption, and without this signal the
    # agent can spend a whole session "repairing" software symptoms of a
    # hardware fault. Running a new test needs a reboot and is out of scope
    # for an unattended session — see docs/tool-invocations.md.
    memory_diagnostic_results = Get-MemoryDiagnosticResults
}

$outputPath = Join-Path $KitRoot "logs\inventory-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$inventory | ConvertTo-Json -Depth 6 | Out-File -FilePath $outputPath -Encoding UTF8

Write-KitLog -LogPath $LogPath -Message "Inventory written to $outputPath"
Write-Output $outputPath
