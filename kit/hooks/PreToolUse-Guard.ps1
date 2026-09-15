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

    Contract (Claude Code hooks, https://code.claude.com/docs/en/hooks):
    reads a JSON event on stdin with tool_name and tool_input. To BLOCK, it
    prints a permissionDecision:"deny" object on stdout, the reason on
    stderr, and exits 2. Exit 2 blocks the call regardless of permission
    mode and regardless of how the JSON is interpreted, and the harness
    shows the JSON's permissionDecisionReason as the blocking message —
    so both channels are used deliberately. (A deny signalled by exit 0
    plus JSON alone is documented for the normal permission flow; under
    bypassPermissions only exit 2 is unambiguous.) Silence + exit 0 means
    "no opinion" — normal permission evaluation (including the deny rules)
    then proceeds. This hook only ever DENIES or stays silent; it never
    emits "allow" (which would wrongly short-circuit ask rules).

    FAIL-CLOSED: any parse error, any uncaught exception (the trap below),
    or a shell command we cannot read, is denied — because a guard that
    fails open on malformed input is not a guard. The settings.json wiring
    additionally wraps this file so that a missing/unreadable script also
    exits 2 (any exit code other than 2 is NON-blocking per the docs).
    (Note: the harness fails a hook *timeout* open; we cannot change that,
    so keep this fast and dependency-free.)

    This is defense in depth, not a sandbox. A child process the agent spawns
    is still unconstrained on native Windows — least privilege does what no
    rule here can.
#>

$ErrorActionPreference = 'Stop'

# Any error this script did not anticipate must block, not fall through.
trap {
    try { [Console]::Error.WriteLine("PreToolUse guard hit an unexpected error and is blocking as a precaution: $_") } catch { }
    exit 2
}

function Deny([string]$reason) {
    # Uniform prefix: the launcher counts denials in the transcript and the
    # pre-launch canary looks for it, so every reason must carry it.
    $reason = "[PreToolUse guard] $reason"
    $out = @{
        hookSpecificOutput = @{
            hookEventName          = 'PreToolUse'
            permissionDecision     = 'deny'
            permissionDecisionReason = $reason
        }
    }
    $out | ConvertTo-Json -Depth 5 -Compress
    [Console]::Error.WriteLine($reason)
    exit 2
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
    # Anchored on WRITES only: (Get-MpPreference).DisableRealtimeMonitoring
    # and Get-MpComputerStatus are how the malware sweep READS this state and
    # must pass; a bare property-name match denied them.
    @{ Re = '(?i)set-mppreference\b.*-disable';                        Why = 'Disabling Microsoft Defender settings is blocked — that is malware behavior, not repair.' }
    @{ Re = '(?i)(add|set)-mppreference\b.*exclusion';                 Why = 'Adding a Defender exclusion is blocked — it is a common malware-persistence step and is never part of an autonomous repair.' }
    # Value-aware: writing Disable* = 1 (or true) is disabling; writing it
    # back to 0, or removing the value, is how you UNDO what malware did.
    @{ Re = '(?i)^(?=.*\b(new|set)-itemproperty\b)(?=.*(disableantispyware|disablerealtimemonitoring|disablebehaviormonitoring|disableioavprotection|disableonaccessprotection))(?=.*-value\s+[''"]?(1|0x1|\$true|true)\b)'; Why = 'Writing a Defender-disabling policy value (DisableAntiSpyware, DisableRealtimeMonitoring, ...) is blocked. Setting it back to 0 or removing it is allowed.' }
    @{ Re = '(?i)^(?=.*\breg(\.exe)?\s+add\b)(?=.*(disableantispyware|disablerealtimemonitoring|disablebehaviormonitoring|disableioavprotection|disableonaccessprotection))(?=.*/d\s+[''"]?(1|0x1)\b)'; Why = 'reg add of a Defender-disabling policy value is blocked. Setting it to 0 or deleting it is allowed.' }
    @{ Re = '(?i)((new|set)-itemproperty|reg(\.exe)?\s+add)\b.*?tamperprotection';   Why = 'Writing the Defender Tamper Protection value is blocked.' }
    # The security service must be the verb's ARGUMENT — "sense" is also an
    # English word, and a comment on a wuauserv restart must not trip this.
    @{ Re = '(?i)\b(sc(\.exe)?\s+(config|stop|delete|pause)|stop-service|suspend-service|net(\.exe)?\s+stop|psservice(64)?(\.exe)?\s+(stop|setconfig|pause))\s+(-name\s+|-inputobject\s+)?[''"]?(windefend|wdnissvc|wdfilter|wdboot|sense|mpssvc|securityhealthservice)[''"]?(\s|$|;|\||&)'; Why = 'Stopping, pausing or reconfiguring a Defender / firewall / Security Center service is blocked — that is malware behavior, not repair. Querying or re-enabling them is fine.' }
    @{ Re = '(?i)^(?=.*\bset-service\b)(?=.*[''"\s](windefend|wdnissvc|wdfilter|wdboot|sense|mpssvc|securityhealthservice)\b)(?=.*-startuptype\s+[''"]?disabled\b)'; Why = 'Disabling a Defender / firewall / Security Center service is blocked. Setting it back to Automatic is fine.' }
    @{ Re = '(?i)set-mppreference\b.*tamperprotection|(uninstall|remove)-windowsfeature\b.*defender|dism(\.exe)?\s+.*(/remove-capability|/disable-feature).*defender'; Why = 'Touching Defender Tamper Protection or removing Defender is blocked.' }

    # Registry persistence / boot-integrity keys — writing these is an
    # infection technique, not a fix. (Reading/enumerating them is fine.)
    # \b, not a trailing backslash: the classic writes target the key itself
    # (...\Winlogon -Name Shell, ...\Control\Lsa -Name ...), with no subkey.
    @{ Re = '(?i)(new|set)-itemproperty.*(image file execution options|\\winlogon\b|\\lsa\b|\\currentversion\\run(once)?\b)'; Why = 'Writing to IFEO / Winlogon / LSA / Run(Once) registry keys is blocked — these are persistence and privilege targets, not repair surfaces.' }
    @{ Re = '(?i)reg(\.exe)?\s+add\s+.*(image file execution options|\\winlogon|\\lsa\b|\\currentversion\\run)'; Why = 'reg add to IFEO / Winlogon / LSA / Run keys is blocked (persistence targets).' }

    # Boot configuration destruction — deleting a boot entry can brick the
    # machine. NOTE: `/deletevalue ... safeboot` is NOT matched, because
    # clearing the safeboot flag is the legitimate way to LEAVE Safe Mode.
    @{ Re = '(?i)bcdedit(\.exe)?\s+.*/delete(?!value)';                Why = 'bcdedit /delete (removing a boot entry) is blocked — it can render Windows unbootable. Toggling safeboot with /set and /deletevalue is still allowed.' }

    # UNC / WebDAV network paths — per the documented Windows WebDAV warning,
    # a \\host\ path can trigger outbound network access that sidesteps the
    # permission system. Device paths \\?\ and \\.\ are allowed.
    #
    # The leading run must start a path token: the lookbehind refuses a match
    # when the backslashes are preceded by a drive colon, a path character or
    # another backslash, because a Bash-tool command routinely spells a LOCAL
    # path with escaped separators ("C:\\Windows\\Logs\\CBS\\CBS.log") and the
    # naive pattern denied every such read as a "UNC path". An escaped UNC
    # ("\\\\server\\share", four leading backslashes) is still caught by the
    # optional second pair. The forward-slash spelling (//server/share) that
    # Git Bash accepts is matched separately; "http://host/" is excluded by
    # the colon in the lookbehind.
    @{ Re = '(?<![A-Za-z0-9_:\\])\\{2}(?:\\{2})?(?![?.])[A-Za-z0-9._-]+\\';  Why = 'Accessing a UNC network path (\\server\share) is blocked — on Windows it can trigger WebDAV requests that bypass the permission system. Local device paths (\\?\, \\.\) are fine.' }
    @{ Re = '(?<![A-Za-z0-9_:/.])//(?![?.])[A-Za-z0-9._-]+/';                Why = 'Accessing a UNC network path (//server/share) is blocked — on Windows it can trigger WebDAV requests that bypass the permission system.' }
)

foreach ($r in $rules) {
    if ($flat -match $r.Re) { Deny $r.Why }
}

Allow
