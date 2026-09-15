<#
.SYNOPSIS
    PreToolUse guard hook. Denies argument-level dangerous actions that the
    permissions.deny string rules structurally cannot catch, on every shell
    tool call, before the permission-mode check — so it holds even under
    --dangerously-skip-permissions.

.DESCRIPTION
    Why this exists (docs/ecosystem-catalog.md, §4): deny rules match command
    TEXT and split on shell operators, but they cannot reliably constrain
    ARGUMENTS, cannot express "this path and nothing under it", and see only
    one spelling. Native Windows has no OS sandbox. This hook closes the
    class of "living off the allowlist" abuse: a dual-use tool the agent is
    allowed to run (reg, Set-ItemProperty, a download cmdlet) pointed at a
    security-critical target — and it re-checks the deny list's catastrophic
    verbs against a NORMALIZED copy of the command (quotes and backticks
    stripped, HKEY_LOCAL_MACHINE folded to HKLM), because `cmd /c "format d:"`
    and `reg delete HKEY_LOCAL_MACHINE\SOFTWARE /f` are the same action in a
    different coat.

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
    an empty event, a shell event with no command, or a shell command we
    cannot read, is denied — because a guard that fails open on malformed
    input is not a guard. The settings.json wiring additionally wraps this
    file so that a missing/unreadable script also exits 2 (any exit code
    other than 2 is NON-blocking per the docs).
    (Note: the harness fails a hook *timeout* open; we cannot change that,
    so keep this fast and dependency-free.)

    Limits, stated plainly: this inspects the TEXT of one command. A payload
    written to a script file earlier and run later, or built by string
    concatenation, is not visible here; -EncodedCommand is denied outright
    because no repair needs it. This is defense in depth, not a sandbox. A
    child process the agent spawns is still unconstrained on native
    Windows — least privilege does what no rule here can.
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
    if ([string]::IsNullOrWhiteSpace($raw)) { Deny 'PreToolUse guard received no event on stdin; blocking as a precaution.' }
    $event = $raw | ConvertFrom-Json
    if ($null -eq $event) { Deny 'PreToolUse guard received an empty tool event; blocking as a precaution.' }
} catch {
    Deny "PreToolUse guard could not parse the tool event; blocking as a precaution."
}

$tool = [string]$event.tool_name
if (-not $tool) { Deny 'PreToolUse guard received an event with no tool name; blocking as a precaution.' }

# Only shell tools carry a command to inspect. For everything else, defer.
if ($tool -notin @('Bash', 'PowerShell', 'Monitor')) { Allow }

$cmd = [string]$event.tool_input.command
if ([string]::IsNullOrWhiteSpace($cmd)) { Deny "A $tool call with no command text cannot be inspected; blocking as a precaution." }

# Normalize for matching: single line, collapsed whitespace; backticks
# removed (PowerShell's escape character, otherwise `S`et-MpPreference slips
# past every rule). Patterns are written case-insensitive.
$flat = (($cmd -replace '`', '') -replace '\s+', ' ')

# A second, more aggressive normalization for the catastrophic-verb re-check:
# quotes stripped, HKEY_LOCAL_MACHINE folded to HKLM, Registry:: prefix
# dropped, whitespace re-collapsed. Path rules that need exact spellings
# (UNC, escaped separators) run against $flat, not this.
$norm = (((($flat -replace '[''"]', '') -replace '(?i)hkey_local_machine', 'HKLM') -replace '(?i)registry::', '') -replace '\s+', ' ')

# Delete verbs: the harness canonicalizes aliases for its own deny rules but
# this hook sees raw text, so every alias is spelled out here.
$Del = '(remove-item|ri|rm|rmdir|rd|del|erase)'
# A path that is the ROOT of a protected tree (optionally quoted, with a
# trailing separator or \*), followed by whitespace or end of command.
$SysRoot = '(\$env:(systemroot|windir)|\$\{env:(systemroot|windir)\}|%(systemroot|windir)%|[a-z]:[\\/]+windows([\\/]+system32)?|[a-z]:[\\/]+program files( \(x86\))?)'
$RootTail = '[\\/]*\*?(\s|$)'

# --- Argument-level denials — each is NEVER part of a legitimate repair ---
# Matching is deliberately over the WHOLE command string, so wrapping the
# payload in `cmd /c`, `powershell -c "..."`, env-runners, etc. does not
# evade it — the dangerous substring is still present.
$rules = @(
    # Encoded commands hide their payload from every text rule; no repair
    # needs one. All abbreviations PowerShell honors for -EncodedCommand.
    @{ Re = '(?i)\b(powershell|pwsh)(\.exe)?\b[^|;]*\s[-/](e|ec|en|enc|enco|encod|encode|encoded|encodedc|encodedco|encodedcom|encodedcomm|encodedcomma|encodedcomman|encodedcommand)(\s+|:)[A-Za-z0-9+/=]{16,}'; Why = 'powershell -EncodedCommand is blocked — an encoded payload cannot be inspected and no repair needs one.' }

    # Fetch-and-execute / remote code — the kit fetches NOTHING at repair
    # time by design, so any agent-initiated download or dynamic-exec is
    # either an injection escalation or a violation of the offline principle.
    @{ Re = '(?i)\b(iex|invoke-expression)\b';                         Why = 'Invoke-Expression / iex (dynamic code execution) is a classic injection vector and is never needed for a repair.' }
    @{ Re = '(?i)(downloadstring|downloadfile|downloaddata|net\.webclient|net\.webrequest|net\.httpwebrequest|net\.http\.httpclient|msxml2\.(server)?xmlhttp|winhttp\.winhttprequest|start-bitstransfer|bitsadmin\b|certutil[^|;]*(-urlcache|-split|-decode)|\bmsiexec(\.exe)?\b[^|;]*https?://|\bnet(\.exe)?\s+use\b[^|;]*https?://|\bmshta(\.exe)?\b|\bregsvr32(\.exe)?\b[^|;]*/i:)'; Why = 'Downloading and running remote content is blocked — the kit ships every tool it needs; nothing is fetched at repair time.' }
    @{ Re = '(?i)\b(invoke-webrequest|invoke-restmethod)\b|(^|[\s;|&(])(iwr|irm|curl|wget)(\.exe)?(\s|$)'; Why = 'Agent-initiated network downloads are blocked; the kit runs offline-first and fetches nothing at repair time. (The launcher, not the agent, handles connectivity.)' }

    # Defender tampering — disabling AV or adding exclusions on the TARGET is
    # how malware persists; a repair never does it. (The launcher adds a
    # scan exclusion for the USB tool dir and removes it — that is not the
    # agent, and not on C:.) Anchored on WRITES only:
    # (Get-MpPreference).DisableRealtimeMonitoring and Get-MpComputerStatus
    # are how the malware sweep READS this state and must pass.
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

    # Registry persistence / boot-integrity keys — writing these is an
    # infection technique, not a fix. (Reading/enumerating them is fine.)
    # Lookahead form: the path may be in a variable assigned on the same
    # line, spelled with / instead of \, or come after the -Name argument.
    @{ Re = '(?i)^(?=.*\b(new|set)-itemproperty\b)(?=.*(image file execution options|[\\/]winlogon\b|[\\/]lsa\b|[\\/]currentversion[\\/]run(once)?\b))'; Why = 'Writing to IFEO / Winlogon / LSA / Run(Once) registry keys is blocked — these are persistence and privilege targets, not repair surfaces.' }
    @{ Re = '(?i)\breg(\.exe)?\s+add\s+.*(image file execution options|[\\/]winlogon\b|[\\/]lsa\b|[\\/]currentversion[\\/]run(once)?\b)'; Why = 'reg add to IFEO / Winlogon / LSA / Run keys is blocked (persistence targets).' }

    # Boot configuration destruction — deleting a boot entry can brick the
    # machine. NOTE: `/deletevalue ... safeboot` is NOT matched, because
    # clearing the safeboot flag is the legitimate way to LEAVE Safe Mode.
    @{ Re = '(?i)bcdedit(\.exe)?\s+.*[/-]delete(?!value)';             Why = 'bcdedit /delete (removing a boot entry) is blocked — it can render Windows unbootable. Toggling safeboot with /set and /deletevalue is still allowed.' }

    # A reboot mid-run kills the launcher: the Defender exclusions would
    # never be removed and the report never written. The kit promises the
    # operator it will not restart the PC on its own.
    @{ Re = '(?i)\b(restart-computer|stop-computer|psshutdown(64)?(\.exe)?)\b|(^|[\s;|&(])shutdown(\.exe)?\s+(/|-)(r|s|g|p|h|hybrid)\b'; Why = 'Restarting or shutting down the machine is blocked — it kills this session before cleanup runs. Say a restart is needed in your summary instead.' }


    # UNC / WebDAV network paths — per the documented Windows WebDAV warning,
    # a \\host\ path can trigger outbound network access that sidesteps the
    # permission system. Device paths \\?\ and \\.\ are allowed.
    #
    # Structural shape only: a plain UNC is TWO leading backslashes, a host,
    # and ONE separator; a once-escaped Bash spelling is FOUR and TWO. The
    # lookbehind refuses a match when the run is preceded by a drive colon or
    # a path character (a Bash command spells a LOCAL path as
    # "C:\\Windows\\Logs\\CBS\\CBS.log"), and a regex literal such as
    # '\\Windows\\System32' (2 lead, 2 separators) is not a UNC either.
    # The forward-slash spelling (//server/share) that Git Bash accepts is
    # matched separately; "http://host/" is excluded by the colon.
    @{ Re = '(?<![A-Za-z0-9_:\\])(?:\\{2}(?![?.\\])[A-Za-z0-9._-]+\\(?!\\)|\\{4}(?![?.\\])[A-Za-z0-9._-]+\\{2}(?!\\))';  Why = 'Accessing a UNC network path (\\server\share) is blocked — on Windows it can trigger WebDAV requests that bypass the permission system. Local device paths (\\?\, \\.\) are fine.' }
    @{ Re = '(?<![A-Za-z0-9_:/.])//(?![?.])[A-Za-z0-9._-]+/';                Why = 'Accessing a UNC network path (//server/share) is blocked — on Windows it can trigger WebDAV requests that bypass the permission system.' }
)

# --- The deny list's catastrophic verbs, re-checked on the NORMALIZED text ---
# permissions.deny sees quoted and alias spellings differently from this
# hook; each layer catches what the other structurally cannot.
$normRules = @(
    # Whole-drive deletion and deletion of a protected ROOT (the tree itself,
    # not a file under it): Remove-Item C:\* / C:\ / C:\Windows / HKLM:\SOFTWARE
    # in any alias, quoting or argument order. Files UNDER those trees (a
    # malware DLL in System32, a stuck print job in spool\PRINTERS, a malware
    # Run value) are legitimate repair targets and pass.
    @{ Re = "(?i)(^|[\s;|&(])$Del\b(?!property)[^|;]*?\s[a-z]:$RootTail";           Why = 'Deleting a whole drive is blocked.' }
    @{ Re = "(?i)(^|[\s;|&(])$Del\b(?!property)[^|;]*?\s$SysRoot$RootTail";        Why = 'Deleting the Windows or Program Files tree itself is blocked. Deleting a specific file under it is not.' }
    @{ Re = "(?i)(^|[\s;|&(])$Del\b(?!property)[^|;]*?\shklm:?[\\/]*(software|system|sam|security)?$RootTail";  Why = 'Deleting a whole registry hive is blocked. Deleting a specific malware key or value is not.' }
    @{ Re = '(?i)\breg(\.exe)?\s+delete\s+hklm[\\/]*(software|system|sam|security)?\s*(/f|/va|$)';  Why = 'reg delete of a whole registry hive is blocked.' }
    @{ Re = '(?i)(^|[\s;|&(])format(\.com)?\s+[a-z]:';                   Why = 'Formatting a volume is blocked.' }
    @{ Re = '(?i)\b(format-volume|clear-disk|initialize-disk|remove-partition)\b|-methodname\s+format\b';  Why = 'Disk/volume destruction is blocked.' }
    @{ Re = '(?i)(^|[\s;|&(])diskpart(\.exe)?(\s|$)';                    Why = 'diskpart is blocked.' }
    @{ Re = '(?i)\bvssadmin(\.exe)?\s+(delete|resize)\b|\bwbadmin(\.exe)?\s+delete\b|\bdisable-computerrestore\b|\bcipher(\.exe)?\s+/w'; Why = 'Destroying restore points / shadow copies or wiping free space is blocked.' }
    @{ Re = '(?i)\bsdelete(64|64a)?(\.exe)?\b';                          Why = 'sdelete (secure delete) is blocked — it is not on the whitelist and its only function is making data irrecoverable.' }
    @{ Re = '(?i)\bmanage-bde(\.exe)?\b[^|;]*\s-(off|forcerecovery)\b|\bdisable-bitlocker\b';  Why = 'Turning BitLocker off or forcing recovery is blocked.' }
    @{ Re = '(?i)\bremove-localuser\b|\bnet(\.exe)?\s+user\s+\S+\s+/del(ete)?\b';  Why = 'Deleting a user account is blocked.' }
    @{ Re = '(?i)(^|[\s;|&(\\/])psexec(64)?(\.exe)?(\s|$)';                 Why = 'PsExec is not whitelisted (lateral-movement tool) and is blocked.' }
)

foreach ($r in $rules) {
    if ($flat -match $r.Re) { Deny $r.Why }
}
foreach ($r in $normRules) {
    if ($norm -match $r.Re) { Deny $r.Why }
}

Allow
