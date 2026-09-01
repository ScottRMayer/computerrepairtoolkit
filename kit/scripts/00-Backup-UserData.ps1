<#
.SYNOPSIS
    Backs up user data files ahead of any repair action. Optional — the
    operator decides at launch whether to run it and where it goes (see
    Start-Repair.ps1 and Select-BackupTarget.ps1). Not run by the agent.

.DESCRIPTION
    Copies the well-known user shell folders (Desktop, Documents, Pictures,
    Videos, Music, Downloads, Favorites) to
    <DestinationRoot>\<username>-<timestamp>\, using robocopy for its retry
    logic against locked files.

    Deliberately does NOT attempt a full profile image (AppData, NTUSER
    hives) — large, mostly irrelevant to "the family's files," and likelier
    to fail on locked/in-use files during an unattended run.

    Defaults to the CURRENT user's profile only. On a shared family machine,
    backing up every profile copies several people's private files onto a
    drive that then leaves the house — that should be a deliberate choice,
    so it lives behind -AllProfiles rather than being the default.

.PARAMETER DestinationRoot
    Where to write the backup. Required — there is no default, because
    silently defaulting to the kit's own USB is how you fill a 64GB drive
    with a 200GB photo library halfway through a repair.

.PARAMETER UserName
    Profile to back up. Defaults to the current user.

.PARAMETER AllProfiles
    Back up every non-system profile on the machine instead of one.

.PARAMETER MeasureOnly
    Measure the source size and write the byte count to the pipeline
    without copying anything. Used by Start-Repair.ps1 to size the target
    volume before prompting for a destination.

.PARAMETER Force
    Proceed even when the destination has less free space than the measured
    source (plus margin).

.OUTPUTS
    -MeasureOnly: a [long] byte count.
    Otherwise: exits 0 on success, non-zero on any hard failure.
#>
[CmdletBinding()]
param(
    [string]$DestinationRoot,
    [string]$UserName = $env:USERNAME,
    [switch]$AllProfiles,
    [switch]$MeasureOnly,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$KitRoot = Get-KitRoot
$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'backup'

$shellFolders = @('Desktop', 'Documents', 'Pictures', 'Videos', 'Music', 'Downloads', 'Favorites')
$userProfilesRoot = Join-Path $env:SystemDrive 'Users'
$excludedProfiles = @('Public', 'Default', 'Default User', 'All Users')

# --- Resolve which profiles are in scope ---
if ($AllProfiles) {
    $profiles = Get-ChildItem -Path $userProfilesRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $excludedProfiles -notcontains $_.Name }
} else {
    $singleProfile = Join-Path $userProfilesRoot $UserName
    if (-not (Test-Path $singleProfile)) {
        Write-KitLog -LogPath $LogPath -Level ERROR -Message "Profile '$singleProfile' not found. Pass -UserName explicitly, or -AllProfiles."
        exit 1
    }
    $profiles = @(Get-Item $singleProfile)
}

if (-not $profiles) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "No user profiles found under '$userProfilesRoot'."
    exit 1
}

# --- Measure ---
function Measure-SourceBytes {
    param($Profiles, $Folders)
    $total = 0L
    foreach ($p in $Profiles) {
        foreach ($folder in $Folders) {
            $source = Join-Path $p.FullName $folder
            if (-not (Test-Path $source)) { continue }
            try {
                $sum = (Get-ChildItem -Path $source -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
                if ($sum) { $total += $sum }
            } catch {
                Write-Warning "Could not measure '$source': $_"
            }
        }
    }
    return $total
}

if ($MeasureOnly) {
    # Quiet on the pipeline — the caller wants a number, not a log stream.
    Write-Output (Measure-SourceBytes -Profiles $profiles -Folders $shellFolders)
    return
}

if (-not $DestinationRoot) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message 'No -DestinationRoot given. This script has no default destination by design — see its help text.'
    exit 1
}

Write-KitLog -LogPath $LogPath -Message "Backup scope: $($profiles.Name -join ', ')"
Write-KitLog -LogPath $LogPath -Message "Measuring source size before copying..."
$requiredBytes = Measure-SourceBytes -Profiles $profiles -Folders $shellFolders
Write-KitLog -LogPath $LogPath -Message ("Source measures {0:N1} GB." -f ($requiredBytes / 1GB))

# --- Capacity pre-flight: fail BEFORE copying, not partway through ---
# Split-Path -Qualifier throws on UNC and relative paths rather than
# returning null, so this has to be guarded.
$destQualifier = $null
try {
    $destQualifier = Split-Path -Qualifier $DestinationRoot -ErrorAction Stop
} catch {
    Write-KitLog -LogPath $LogPath -Level WARN -Message "Destination '$DestinationRoot' has no drive letter (UNC or relative path) — cannot check free space."
}

$destVolume = if ($destQualifier) {
    Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceID -eq $destQualifier }
} else { $null }

if ($destVolume) {
    $requiredWithMargin = [long]($requiredBytes * 1.05)
    Write-KitLog -LogPath $LogPath -Message ("Destination {0} has {1:N1} GB free." -f $destQualifier, ($destVolume.FreeSpace / 1GB))
    if ($destVolume.FreeSpace -lt $requiredWithMargin -and -not $Force) {
        Write-KitLog -LogPath $LogPath -Level ERROR -Message (
            "Insufficient space: need {0:N1} GB (incl. margin), have {1:N1} GB on {2}. Aborting before any data is copied. Pick a larger drive, narrow the scope, or pass -Force." -f `
            ($requiredWithMargin / 1GB), ($destVolume.FreeSpace / 1GB), $destQualifier)
        exit 1
    }
} else {
    Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not determine free space for '$destQualifier' — proceeding without a capacity check."
}

# --- Copy ---
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$overallExitCode = 0

foreach ($profile in $profiles) {
    $userDest = Join-Path $DestinationRoot "$($profile.Name)-$timestamp"
    New-Item -ItemType Directory -Path $userDest -Force | Out-Null

    foreach ($folder in $shellFolders) {
        $source = Join-Path $profile.FullName $folder
        if (-not (Test-Path $source)) { continue }

        $dest = Join-Path $userDest $folder
        Write-KitLog -LogPath $LogPath -Message "robocopy '$source' -> '$dest'"

        # /E: all subdirs incl. empty. /R:2 /W:5: don't hang forever on a
        # locked file. /XJ: don't follow junctions (avoids infinite loops
        # and OneDrive placeholder weirdness). /NFL /NDL: keep the console
        # readable; full detail goes to /LOG.
        $robocopyLog = Join-Path $userDest "robocopy-$folder.log"
        robocopy $source $dest /E /R:2 /W:5 /XJ /NFL /NDL /LOG:$robocopyLog | Out-Null
        $rc = $LASTEXITCODE

        if ($rc -ge 8) {
            Write-KitLog -LogPath $LogPath -Level ERROR -Message "robocopy failed for '$source' (exit $rc) — see $robocopyLog"
            $overallExitCode = 1
        } else {
            Write-KitLog -LogPath $LogPath -Message "OK: '$folder' for $($profile.Name) (robocopy exit $rc)"
        }
    }
}

if ($overallExitCode -eq 0) {
    Write-KitLog -LogPath $LogPath -Message "User-data backup completed successfully to $DestinationRoot"
} else {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message 'User-data backup had at least one hard failure.'
}

exit $overallExitCode
