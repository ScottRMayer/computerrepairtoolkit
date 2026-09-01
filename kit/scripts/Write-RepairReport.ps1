<#
.SYNOPSIS
    Turns a finished repair session into a plain-English HTML report card that
    a non-technical family member (or the kit owner) can actually read. The
    raw stream-json transcript is the record for machines; THIS is the record
    for people.

.DESCRIPTION
    Reads, all best-effort (any missing input degrades to a clear note, never
    an error):
      - state\session-context.json    what the launcher did (backup, boot mode)
      - state\repair-summary.json      what the AGENT did (it writes this as its
                                       last step, per CLAUDE.md)
      - state\backup-needs-scan.flag   malware-found-so-scan-the-backup warning
    Emits reports\RepairReport-<timestamp>.html and returns its path. Opens it
    in the default browser when the session is interactive.

.PARAMETER ExitCode
    The launcher's exit code, so the badge reflects "couldn't start" vs "ran".
#>
[CmdletBinding()]
param(
    [int]$ExitCode = 0
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$KitRoot = Get-KitRoot
$reportsDir = Join-Path $KitRoot 'reports'
New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return Get-Content $Path -Raw | ConvertFrom-Json } catch { return $null }
}

$ctx     = Read-JsonSafe (Join-Path $KitRoot 'state\session-context.json')
$summary = Read-JsonSafe (Join-Path $KitRoot 'state\repair-summary.json')
$scanFlag = Join-Path $KitRoot 'state\backup-needs-scan.flag'
$scanWarn = if (Test-Path $scanFlag) { (Get-Content $scanFlag -Raw -ErrorAction SilentlyContinue) } else { $null }

# --- Decide the headline badge -------------------------------------------
# Launcher exit code is authoritative for "did it even run"; the agent's
# self-reported outcome refines a run that completed.
$outcome = if ($ExitCode -eq 3) { 'offline' }
           elseif ($ExitCode -ne 0) { 'stopped' }
           elseif ($summary -and $summary.outcome) { $summary.outcome }
           else { 'unknown' }

$badge = switch ($outcome) {
    'fixed'        { @{ text = 'Repairs completed';                 color = '#1a7f37'; bg = '#e6f4ea' } }
    'partial'      { @{ text = 'Some repairs done - more needed';   color = '#9a6700'; bg = '#fff8e1' } }
    'needs_person' { @{ text = 'Needs a person';                    color = '#9a6700'; bg = '#fff8e1' } }
    'nothing_found'{ @{ text = 'Checked - nothing to fix';          color = '#1a7f37'; bg = '#e6f4ea' } }
    'offline'      { @{ text = "Couldn't start - no internet";      color = '#b42318'; bg = '#fdecea' } }
    'stopped'      { @{ text = 'Stopped early';                     color = '#b42318'; bg = '#fdecea' } }
    default        { @{ text = 'Finished - see details';            color = '#57606a'; bg = '#f0f1f2' } }
}

function E([string]$s) { if ($null -eq $s) { return '' } [System.Web.HttpUtility]::HtmlEncode($s) }
# HttpUtility may be unavailable; fall back to a manual encoder.
function Enc([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
}

function List([object[]]$items, [string]$emptyText) {
    if (-not $items -or $items.Count -eq 0) { return "<p class='muted'>$(Enc $emptyText)</p>" }
    return "<ul>" + (($items | ForEach-Object { "<li>$(Enc ([string]$_))</li>" }) -join "") + "</ul>"
}

$when = Get-Date -Format 'dddd, MMMM d yyyy, h:mm tt'
$machine = if ($ctx -and $ctx.target_user) { "user '$($ctx.target_user)'" } else { 'this PC' }
$bootMode = if ($ctx) { $ctx.boot_mode } else { 'unknown' }

# --- Backup + rollback facts (from the launcher, not the agent) -----------
$backupLine = if ($ctx -and $ctx.backup -and $ctx.backup.completed) {
    "A copy of the files was saved to <b>$(Enc $ctx.backup.destination)</b> (covering: $(Enc $ctx.backup.scope))."
} elseif ($ctx -and $ctx.backup -and $ctx.backup.requested -eq $false) {
    "<b>No file backup was taken this session</b> (it was skipped)."
} else {
    "Backup status unknown - check the logs folder."
}

$rollbackLine = if ($summary -and $summary.restore_point) {
    "A Windows restore point named <b>$(Enc $summary.restore_point)</b> was created before changes, so the system can be rolled back."
} elseif ($bootMode -ne 'Normal' -and $bootMode -ne 'unknown') {
    "Running in Safe Mode, so a normal restore point couldn't be made; registry hives were exported to the backups folder instead."
} else {
    "Restore-point status is in the logs folder."
}

# --- Compose HTML ---------------------------------------------------------
$agentBlock = if ($summary) {
@"
    <div class="card">
      <h2>What it found</h2>
      $(List $summary.what_i_found 'Nothing notable was flagged.')
    </div>
    <div class="card">
      <h2>What it changed</h2>
      $(List $summary.what_i_changed 'No changes were made.')
    </div>
    <div class="card needs">
      <h2>What still needs a person</h2>
      $(List $summary.needs_a_person 'Nothing - no follow-up flagged.')
      $(if ($summary.reboot_required) { "<p class='reboot'>&#9888; This PC needs to be <b>restarted</b> to finish some repairs.</p>" })
    </div>
"@
} else {
@"
    <div class="card">
      <h2>Details</h2>
      <p class="muted">The repair assistant did not leave a structured summary
      (it may have been interrupted, or couldn't get online). The complete
      record of the session is in the <b>logs</b> folder on the drive.</p>
    </div>
"@
}

$scanBlock = if ($scanWarn) {
@"
    <div class="card danger">
      <h2>&#9888; Important: scan the backup drive</h2>
      <p>Malware was found on this PC. The backup was copied from the PC and
      <b>may contain infected files</b>. Scan that drive with antivirus on a
      clean computer before opening anything from it.</p>
      <p class="muted">$(Enc $scanWarn)</p>
    </div>
"@
} else { '' }

$html = @"
<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PC Repair Report</title>
<style>
  body { font: 16px/1.5 system-ui, Segoe UI, Arial, sans-serif; color:#1c1e21; background:#f6f7f9; margin:0; padding:24px; }
  .wrap { max-width: 760px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .badge { display:inline-block; padding:8px 16px; border-radius:999px; font-weight:600;
           color:$($badge.color); background:$($badge.bg); margin: 12px 0 20px; }
  .card { background:#fff; border:1px solid #e3e5e8; border-radius:12px; padding:16px 20px; margin:14px 0; }
  .card h2 { font-size:16px; margin:0 0 10px; }
  .needs { border-left:4px solid #d4a72c; }
  .danger { border-left:4px solid #b42318; background:#fdecea; }
  .reboot { color:#9a6700; font-weight:600; }
  .muted { color:#6b7280; }
  ul { margin:6px 0; padding-left:22px; } li { margin:4px 0; }
  .meta { color:#6b7280; font-size:14px; }
  b { color:#111; }
</style></head>
<body><div class="wrap">
  <h1>PC Repair Report</h1>
  <div class="meta">$(Enc $when) &middot; $(Enc $machine) &middot; mode: $(Enc $bootMode)</div>
  <div class="badge">$(Enc $badge.text)</div>

  $(if ($summary -and $summary.headline) { "<div class='card'><p>$(Enc $summary.headline)</p></div>" })

  $scanBlock

  <div class="card">
    <h2>Your files &amp; undo</h2>
    <p>$backupLine</p>
    <p>$rollbackLine</p>
  </div>

  $agentBlock

  <div class="card">
    <h2>Full record</h2>
    <p class="muted">Everything the assistant did was logged to the
    <b>logs</b> folder on the repair drive. Keep it until you're sure the PC
    is behaving.</p>
  </div>
</div></body></html>
"@

$reportPath = Join-Path $reportsDir "RepairReport-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
$html | Out-File -FilePath $reportPath -Encoding UTF8

if ([Environment]::UserInteractive) {
    try { Invoke-Item $reportPath } catch { }
}
Write-Output $reportPath
