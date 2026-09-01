<#
.SYNOPSIS
    PreToolUse guard hook. Denies argument-level dangerous actions that the
    permissions.deny string rules structurally cannot catch, on every shell
    tool call, before the permission-mode check — so it holds even under
    --dangerously-skip-permissions.

.DESCRIPTION
    Why this exists (docs/ecosystem-catalog.md, §4): deny rules match command
    TEXT and split on shell operators, but they cannot reliably constrain
    ARGUMENTS, and native Windows has no OS sandbox. This hook closes the
    class of "living off the allowlist" abuse: a dual-use tool the agent is
    allowed to run (reg, Set-ItemProperty, a download cmdlet) pointed at a
    security-critical target.

    Contract (Claude Code hooks): reads a JSON event on stdin with tool_name
    and tool_input; to BLOCK, prints a permissionDecision:"deny" object and
    exits 0. Silence + exit 0 means "no opinion" — normal permission
    evaluation (including the deny rules) then proceeds. This hook only ever
    DENIES or stays silent; it never emits "allow" (which would wrongly
    short-circuit ask rules).

    FAIL-CLOSED: any parse error, or a shell command we cannot read, is
    denied — because a guard that fails open on malformed input is not a
    guard. (Note: the harness fails a hook *timeout* open; we cannot change
    that, so keep this fast and dependency-free.)

    This is defense in depth, not a sandbox. A child process the agent spawns
    is still unconstrained on native Windows — least privilege does what no
    rule here can.
#>

$ErrorActionPreference = 'Stop'

function Deny([string]$reason) {
    $out = @{
        hookSpecificOutput = @{
            hookEventName          = 'PreToolUse'
            permissionDecision     = 'deny'
            permissionDecisionReason = $reason
        }
    }
    $out | ConvertTo-Json -Depth 5 -Compress
    exit 0
}

function Allow { exit 0 }   # stay silent; let deny rules + mode decide

# --- Read and parse the event (fail closed) ------------------------------
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { Allow }          # nothing to inspect
    $event = $raw | ConvertFrom-Json
} catch {
    Deny "PreToolUse guard could not parse the tool event; blocking as a precaution."
}

$tool = [string]$event.tool_name

# Only shell tools carry a command to inspect. For everything else, defer.
if ($tool -notin @('Bash', 'PowerShell')) { Allow }

$cmd = [string]$event.tool_input.command
if (-not $cmd) { Allow }              # no command string → nothing to gate

# Normalize for matching: single line, collapsed whitespace, lowercase copy
# for case-insensitive checks (patterns are written case-insensitive anyway).
$flat = ($cmd -replace '\s+', ' ')

# --- Argument-level denials — each is NEVER part of a legitimate repair ---
# Matching is deliberately over the WHOLE command string, so wrapping the
# payload in `cmd /c`, `powershell -c "..."`, env-runners, etc. does not
# evade it — the dangerous substring is still present.
$rules = @(
    # Fetch-and-execute / remote code — the kit fetches NOTHING at repair
    # time by design, so any agent-initiated download or dynamic-exec is
    # either an injection escalation or a violation of the offline principle.
    @{ Re = '(?i)\b(iex|invoke-expression)\b';                         Why = 'Invoke-Expression / iex (dynamic code execution) is a classic injection vector and is never needed for a repair.' }
    @{ Re = '(?i)(downloadstring|downloadfile|downloaddata|net\.webclient|start-bitstransfer|bitsadmin\b|certutil.*(-urlcache|-split))'; Why = 'Downloading and running remote content is blocked — the kit ships every tool it needs; nothing is fetched at repair time.' }
    @{ Re = '(?i)\b(invoke-webrequest|iwr|invoke-restmethod|irm|curl|wget)\b'; Why = 'Agent-initiated network downloads are blocked; the kit runs offline-first and fetches nothing at repair time. (The launcher, not the agent, handles connectivity.)' }

    # Defender tampering — disabling AV or adding exclusions on the TARGET is
    # how malware persists; a repair never does it. (The launcher adds a
    # scan exclusion for the USB tool dir and removes it — that is not the
    # agent, and not on C:.)
    @{ Re = '(?i)set-mppreference.*-disable';                          Why = 'Disabling Microsoft Defender settings is blocked — that is malware behavior, not repair.' }
    @{ Re = '(?i)(add|set)-mppreference.*exclusion';                   Why = 'Adding a Defender exclusion is blocked — it is a common malware-persistence step and is never part of an autonomous repair.' }
    @{ Re = '(?i)disableantispyware|disablerealtimemonitoring|disablebehaviormonitoring'; Why = 'Turning off Defender protection is blocked.' }
    @{ Re = '(?i)tamperprotection';                                    Why = 'Touching Defender Tamper Protection is blocked.' }

    # Registry persistence / boot-integrity keys — writing these is an
    # infection technique, not a fix. (Reading/enumerating them is fine.)
    @{ Re = '(?i)(new|set)-itemproperty.*(image file execution options|\\winlogon\\|\\lsa\\|\\currentversion\\run(once)?\\?)'; Why = 'Writing to IFEO / Winlogon / LSA / Run(Once) registry keys is blocked — these are persistence and privilege targets, not repair surfaces.' }
    @{ Re = '(?i)reg(\.exe)?\s+add\s+.*(image file execution options|\\winlogon|\\lsa\b|\\currentversion\\run)'; Why = 'reg add to IFEO / Winlogon / LSA / Run keys is blocked (persistence targets).' }

    # Boot configuration destruction — deleting a boot entry can brick the
    # machine. NOTE: `/deletevalue ... safeboot` is NOT matched, because
    # clearing the safeboot flag is the legitimate way to LEAVE Safe Mode.
    @{ Re = '(?i)bcdedit(\.exe)?\s+.*/delete(?!value)';                Why = 'bcdedit /delete (removing a boot entry) is blocked — it can render Windows unbootable. Toggling safeboot with /set and /deletevalue is still allowed.' }

    # UNC / WebDAV network paths — per the documented Windows WebDAV warning,
    # a \\host\ path can trigger outbound network access that sidesteps the
    # permission system. Device paths \\?\ and \\.\ are allowed.
    @{ Re = '\\\\(?![?.])[A-Za-z0-9._-]+\\';                           Why = 'Accessing a UNC network path (\\server\share) is blocked — on Windows it can trigger WebDAV requests that bypass the permission system. Local device paths (\\?\, \\.\) are fine.' }
)

foreach ($r in $rules) {
    if ($flat -match $r.Re) { Deny $r.Why }
}

Allow
