<#
.SYNOPSIS
    Backs up user data files ahead of any repair action. Optional — the
    operator decides at launch whether to run it and where it goes (see
    Start-Repair.ps1 and Select-BackupTarget.ps1). Not run by the agent.

.DESCRIPTION
    Copies the user's known folders (Desktop, Documents, Pictures, Videos,
    Music, Downloads, Favorites) to <DestinationRoot>\<username>-<timestamp>\,
    using robocopy for its retry logic against locked files.

    WHERE those folders are is resolved, not assumed. On a default Windows
    11 install OneDrive "Known Folder Move" redirects Desktop, Documents and
    Pictures into %USERPROFILE%\OneDrive\..., and the literal
    %USERPROFILE%\Documents is then an empty stub — a naive copy of it exits
    0 having backed up nothing. So each folder is resolved from the user's
    "User Shell Folders" registry values (HKCU for the signed-in user, or
    that user's loaded HKU hive), and the OneDrive folder(s) under the
    profile are scanned as well; every distinct real location found is
    copied.

    Cloud-only files (OneDrive "online-only" placeholders, which carry the
    Offline attribute) are NOT copied: they are not on this disk, copying
    them would download the whole library through the family's connection
    mid-repair, and they remain safe in the cloud. They are counted and
    listed in cloud-only-files.txt inside the backup so nobody mistakes the
    copy for complete.

    Success is VERIFIED by reconciling what landed on the destination
    against what was measured at the source, not by robocopy's exit code
    (0 means "nothing needed copying", which is also what an empty stub
    produces). The result is written to state\backup-result.json for the
    launcher, the agent and the report card.

    Deliberately does NOT attempt a full profile image (AppData, NTUSER
    hives) — large, mostly irrelevant to "the family's files," and likelier
    to fail on locked/in-use files during an unattended run.

    Defaults to ONE profile. On a shared family machine, backing up every
    profile copies several people's private files onto a drive that then
    leaves the house — that should be a deliberate choice, so it lives
    behind -AllProfiles rather than being the default.

.PARAMETER DestinationRoot
    Where to write the backup. Required — there is no default, because
    silently defaulting to the kit's own USB is how you fill a 64GB drive
    with a 200GB photo library halfway through a repair.

.PARAMETER UserName
    Profile to back up. Defaults to the current user.

.PARAMETER AllProfiles
    Back up every non-system profile on the machine instead of one.

.PARAMETER MeasureOnly
    Measure the source size (local files only, cloud-only placeholders
    excluded) and write the byte count to the pipeline without copying
    anything. Used by Start-Repair.ps1 to size the target volume before
    prompting for a destination.

.PARAMETER Force
    Proceed even when the destination has less free space than the measured
    source (plus margin).

.OUTPUTS
    -MeasureOnly: a [long] byte count.
    Otherwise: exits 0 when the copy completed AND reconciled, non-zero on
    any hard failure or when nothing verifiably landed.
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

# Known folder -> registry value name under "User Shell Folders". Downloads
# has no classic name; it is stored under its KNOWNFOLDERID GUID.
$knownFolders = [ordered]@{
    'Desktop'   = 'Desktop'
    'Documents' = 'Personal'
    'Pictures'  = 'My Pictures'
    'Videos'    = 'My Video'
    'Music'     = 'My Music'
    'Downloads' = '{374DE290-123F-4565-9164-39C4925E467B}'
    'Favorites' = 'Favorites'
}
$userProfilesRoot = Join-Path $env:SystemDrive 'Users'
$excludedProfiles = @('Public', 'Default', 'Default User', 'All Users')

# FILE_ATTRIBUTE_OFFLINE (0x1000) is what cloud sync engines set on a
# dehydrated placeholder; FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (0x400000)
# is the Windows 10 1709+ cloud-files marker. Either means "not on this disk".
$CloudOnlyMask = 0x1000 -bor 0x400000

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

# --- Resolve where each known folder REALLY lives for a profile ---
function Get-ProfileRegistryRoot {
    <#
        Registry key holding this profile's User Shell Folders, if its hive is
        loaded: HKCU: for the current user, HKU:\<SID> for another signed-in
        user. $null when the hive isn't loaded (that user is signed out) —
        the filesystem heuristics below still cover the common layouts.
    #>
    param($Profile)
    $me = Join-Path $userProfilesRoot $env:USERNAME
    if ($Profile.FullName -ieq $me) { return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' }
    try {
        $sid = (Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
            Where-Object { $_.LocalPath -ieq $Profile.FullName } | Select-Object -First 1).SID
        if ($sid) {
            if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction Stop | Out-Null
            }
            $key = "HKU:\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
            if (Test-Path $key) { return $key }
        }
    } catch { }
    return $null
}

function Get-ProfileKnownFolders {
    <#
        Returns one entry per DISTINCT real location: @{ Name; Path }.
        Sources, in order: the registry value (authoritative when the hive is
        loaded), then <profile>\<Folder>, then <profile>\OneDrive*\<Folder>.
        Two locations for the same folder (a local stub AND a OneDrive copy)
        are both kept and land under distinct names.
    #>
    param($Profile)
    $regRoot = Get-ProfileRegistryRoot -Profile $Profile
    $regKey = $null
    if ($regRoot) { try { $regKey = Get-Item -Path $regRoot -ErrorAction Stop } catch { $regKey = $null } }

    $oneDriveRoots = @(Get-ChildItem -Path $Profile.FullName -Directory -Filter 'OneDrive*' -Force -ErrorAction SilentlyContinue)

    $seen = @{}
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($name in $knownFolders.Keys) {
        $candidates = New-Object System.Collections.Generic.List[string]

        # Registry (User Shell Folders) is authoritative when the hive is loaded.
        if ($regKey) {
            try {
                # Read RAW so %USERPROFILE% can be expanded for THAT profile, not
                # for whoever is running this script.
                $raw = $regKey.GetValue($knownFolders[$name], $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($raw) {
                    $expanded = [string]$raw -replace '(?i)%USERPROFILE%', $Profile.FullName
                    $expanded = [Environment]::ExpandEnvironmentVariables($expanded)
                    $candidates.Add($expanded)
                }
            } catch { }
        }
        # The profile-local folder is listed FIRST so that it keeps the plain
        # name in the backup and a OneDrive location lands as
        # "<Folder> (OneDrive)" — the layout the checklist describes.
        $candidates.Insert(0, (Join-Path $Profile.FullName $name))
        foreach ($od in $oneDriveRoots) { $candidates.Add((Join-Path $od.FullName $name)) }

        foreach ($c in $candidates) {
            if (-not $c) { continue }
            $full = $null
            try { $full = [System.IO.Path]::GetFullPath($c).TrimEnd('\') } catch { continue }
            if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
            $k = $full.ToLowerInvariant()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            $result.Add([pscustomobject]@{ Name = $name; Path = $full })
        }
    }
    return $result.ToArray()
}

# --- Measure ---
function Measure-Folder {
    <#
        Bytes and counts for one folder: local (copyable now) vs cloud-only
        (placeholders that would have to be downloaded first).
    #>
    param([string]$Path)
    $local = 0L; $cloud = 0L; $cloudCount = 0; $cloudFiles = New-Object System.Collections.Generic.List[string]
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if (([int]$_.Attributes -band $CloudOnlyMask) -ne 0) {
                $cloud += $_.Length; $cloudCount++; $cloudFiles.Add($_.FullName)
            } else {
                $local += $_.Length
            }
        }
    } catch {
        Write-Warning "Could not measure '$Path': $_"
    }
    [pscustomobject]@{ LocalBytes = $local; CloudBytes = $cloud; CloudCount = $cloudCount; CloudFiles = $cloudFiles }
}

$plan = New-Object System.Collections.Generic.List[object]
foreach ($p in $profiles) {
    foreach ($f in (Get-ProfileKnownFolders -Profile $p)) {
        $m = Measure-Folder -Path $f.Path
        $plan.Add([pscustomobject]@{
            Profile = $p; Name = $f.Name; Source = $f.Path
            LocalBytes = $m.LocalBytes; CloudBytes = $m.CloudBytes; CloudCount = $m.CloudCount; CloudFiles = $m.CloudFiles
        })
    }
}
$requiredBytes = ($plan | Measure-Object -Property LocalBytes -Sum).Sum
if (-not $requiredBytes) { $requiredBytes = 0L }
$cloudOnlyTotal = ($plan | Measure-Object -Property CloudCount -Sum).Sum
if (-not $cloudOnlyTotal) { $cloudOnlyTotal = 0 }

if ($MeasureOnly) {
    # Quiet on the pipeline — the caller wants a number, not a log stream.
    Write-Output ([long]$requiredBytes)
    return
}

if (-not $DestinationRoot) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message 'No -DestinationRoot given. This script has no default destination by design — see its help text.'
    exit 1
}

Write-KitLog -LogPath $LogPath -Message "Backup scope: $(($profiles | ForEach-Object { $_.Name }) -join ', ')"
foreach ($item in $plan) {
    Write-KitLog -LogPath $LogPath -Message ("  {0,-10} {1}  ({2:N2} GB local{3})" -f $item.Name, $item.Source, ($item.LocalBytes / 1GB),
        $(if ($item.CloudCount) { ", $($item.CloudCount) cloud-only file(s) skipped" } else { '' }))
}
if ($plan.Count -eq 0) {
    Write-KitLog -LogPath $LogPath -Level WARN -Message 'None of the known folders exist for the selected profile(s) — there is nothing to back up. Check -UserName.'
}
Write-KitLog -LogPath $LogPath -Message ("Source measures {0:N2} GB of local files." -f ($requiredBytes / 1GB))

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
$folderResults = New-Object System.Collections.Generic.List[object]
$copiedBytes = 0L

foreach ($profile in $profiles) {
    $userDest = Join-Path $DestinationRoot "$($profile.Name)-$timestamp"
    New-Item -ItemType Directory -Path $userDest -Force | Out-Null

    $items = @($plan | Where-Object { $_.Profile.FullName -eq $profile.FullName })
    $usedNames = @{}
    $cloudList = New-Object System.Collections.Generic.List[string]

    foreach ($item in $items) {
        # Distinct destination per distinct source: "Documents", then
        # "Documents (OneDrive)" for a second location of the same folder.
        $destName = $item.Name
        if ($usedNames.ContainsKey($destName)) {
            $parent = Split-Path -Leaf (Split-Path -Parent $item.Source)
            $safeParent = ($parent -replace '[\\/:*?"<>|]', '_')
            $destName = "$($item.Name) ($safeParent)"
            $n = 2
            while ($usedNames.ContainsKey($destName)) { $destName = "$($item.Name) ($safeParent $n)"; $n++ }
        }
        $usedNames[$destName] = $true
        $dest = Join-Path $userDest $destName
        Write-KitLog -LogPath $LogPath -Message "robocopy '$($item.Source)' -> '$dest'"

        # /E: all subdirs incl. empty. /R:2 /W:5: don't hang forever on a
        # locked file. /XJ: don't follow junctions (avoids infinite loops
        # and OneDrive placeholder weirdness). /XA:O: skip cloud-only
        # placeholders (Offline attribute) rather than pulling them down.
        # /NFL /NDL: keep the console readable; full detail goes to /LOG.
        $robocopyLog = Join-Path $userDest "robocopy-$($destName -replace '[^A-Za-z0-9._-]', '_').log"
        robocopy $item.Source $dest /E /R:2 /W:5 /XJ /XA:O /NFL /NDL /LOG:$robocopyLog | Out-Null
        $rc = $LASTEXITCODE

        $landed = 0L
        try {
            $landed = (Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if (-not $landed) { $landed = 0L }
        } catch { }
        $copiedBytes += $landed

        if ($rc -ge 8) {
            Write-KitLog -LogPath $LogPath -Level ERROR -Message "robocopy failed for '$($item.Source)' (exit $rc) — see $robocopyLog"
            $overallExitCode = 1
        } elseif ($item.LocalBytes -gt 0 -and $landed -lt [long]($item.LocalBytes * 0.9)) {
            # robocopy said fine but far less landed than was measured: treat
            # as a failure of this folder, not a quiet success.
            Write-KitLog -LogPath $LogPath -Level ERROR -Message ("'{0}': expected ~{1:N2} GB, only {2:N2} GB landed (robocopy exit {3}) — see {4}" -f $item.Name, ($item.LocalBytes / 1GB), ($landed / 1GB), $rc, $robocopyLog)
            $overallExitCode = 1
        } else {
            Write-KitLog -LogPath $LogPath -Message ("OK: '{0}' for {1} ({2:N2} GB landed, robocopy exit {3})" -f $destName, $profile.Name, ($landed / 1GB), $rc)
        }
        foreach ($cf in $item.CloudFiles) { $cloudList.Add($cf) }

        $folderResults.Add([ordered]@{
            profile = $profile.Name; name = $item.Name; source = $item.Source; destination = $dest
            expected_bytes = [long]$item.LocalBytes; landed_bytes = [long]$landed
            cloud_only_files = [int]$item.CloudCount; robocopy_exit = $rc
        })
    }

    if ($cloudList.Count -gt 0) {
        $listPath = Join-Path $userDest 'cloud-only-files.txt'
        @("# Files that were ONLINE-ONLY (not on this PC's disk) at backup time and were NOT copied.",
          "# They remain in the user's cloud storage (OneDrive). Count: $($cloudList.Count)", '') + $cloudList |
            Set-Content -Path $listPath -Encoding UTF8
        Write-KitLog -LogPath $LogPath -Level WARN -Message "$($cloudList.Count) cloud-only file(s) for $($profile.Name) were not copied (still in the cloud) — listed in $listPath"
    }
}

# --- Reconcile and record ---
# A backup is verified only when bytes actually landed. An EMPTY source is
# not a backup either: it almost always means the wrong profile was chosen
# (or a signed-out user's OneDrive folders could not be resolved), and the
# launcher must not tell the agent a file-level safety net exists.
$verified = ($overallExitCode -eq 0) -and ($copiedBytes -gt 0)
if ($overallExitCode -eq 0 -and -not $verified) {
    if ($requiredBytes -eq 0) {
        Write-KitLog -LogPath $LogPath -Level ERROR -Message "Nothing to back up: the selected profile(s) have no local files in any known folder. Check -UserName (is this the right person?) — this is NOT being recorded as a backup."
    } else {
        Write-KitLog -LogPath $LogPath -Level ERROR -Message ("Nothing verifiably landed on the destination although {0:N2} GB was measured at the source. Do NOT treat this as a backup." -f ($requiredBytes / 1GB))
    }
    $overallExitCode = 1
}

$resultPath = Join-Path (Join-Path $KitRoot 'state') 'backup-result.json'
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $resultPath) -Force | Out-Null
    [ordered]@{
        completed_at     = (Get-Date -Format 'o')
        destination_root = $DestinationRoot
        profiles         = @($profiles | ForEach-Object { $_.Name })
        source_bytes     = [long]$requiredBytes
        copied_bytes     = [long]$copiedBytes
        cloud_only_files = [int]$cloudOnlyTotal
        verified         = [bool]$verified
        folders          = @($folderResults)
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $resultPath -Encoding UTF8
} catch {
    Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not write $resultPath : $_"
}

if ($overallExitCode -eq 0) {
    Write-KitLog -LogPath $LogPath -Message ("User-data backup completed and verified: {0:N2} GB on {1}" -f ($copiedBytes / 1GB), $DestinationRoot)
} else {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message 'User-data backup had at least one hard failure or could not be verified.'
}

exit $overallExitCode
