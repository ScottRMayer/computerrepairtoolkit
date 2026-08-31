<#
.SYNOPSIS
    Step zero: back up the current user's data files before any repair
    action runs. See docs/decisions.md — this is the mandatory prerequisite
    for everything else in the kit.

.DESCRIPTION
    Copies the well-known user shell folders (Desktop, Documents, Pictures,
    Videos, Music, Downloads, Favorites) for every real user profile on the
    machine to $KitRoot\backups\<username>-<timestamp>\, using robocopy for
    resumability and its own retry logic against locked files.

    This deliberately does NOT attempt a full profile image (AppData, NTUSER
    hives) — that's large, mostly irrelevant to "family member's files", and
    likelier to fail on locked/in-use files during an unattended run. It
    covers what a family member would actually be upset to lose.

.PARAMETER DestinationRoot
    Backup destination. Defaults to $KitRoot\backups. Override to point at
    an external drive instead of the USB kit itself if the kit's own drive
    doesn't have room for the backup alongside the tools/ISO.

.OUTPUTS
    Exits non-zero if backup of any user's folders failed outright (not
    merely "some locked files skipped" — robocopy exit codes 0-7 are
    success-with-info, 8+ is failure). CLAUDE.md instructs the agent to
    treat a non-zero exit here as a hard stop.
#>
[CmdletBinding()]
param(
    [string]$DestinationRoot
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$KitRoot = Get-KitRoot
if (-not $DestinationRoot) {
    $DestinationRoot = Join-Path $KitRoot 'backups'
}
$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'backup'

Write-KitLog -LogPath $LogPath -Message "Starting user-data backup to '$DestinationRoot'"

$shellFolders = @('Desktop', 'Documents', 'Pictures', 'Videos', 'Music', 'Downloads', 'Favorites')
$userProfilesRoot = 'C:\Users'
$excludedProfiles = @('Public', 'Default', 'Default User', 'All Users')

$profiles = Get-ChildItem -Path $userProfilesRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $excludedProfiles -notcontains $_.Name }

if (-not $profiles) {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message "No user profiles found under '$userProfilesRoot' — nothing to back up. Treat as a hard stop, not a pass."
    exit 1
}

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
        # output readable; full detail still goes to /LOG.
        $robocopyLog = Join-Path $DestinationRoot "robocopy-$($profile.Name)-$folder-$timestamp.log"
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
    Write-KitLog -LogPath $LogPath -Message 'User-data backup completed successfully for all profiles.'
} else {
    Write-KitLog -LogPath $LogPath -Level ERROR -Message 'User-data backup had at least one hard failure — do not proceed to destructive repair steps.'
}

exit $overallExitCode
