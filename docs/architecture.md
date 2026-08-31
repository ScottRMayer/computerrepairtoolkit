# Architecture

## Summary

Claude Code CLI has native bash/file-system access by design. Fully
autonomous mode is confirmed: `claude -p "<task>" --dangerously-skip-permissions`
(headless `-p`/`--print` mode plus the bypass flag). A small set of
hard-coded refusals survive bypass mode regardless (`rm -rf /`, `rm -rf ~`,
`rm -rf $HOME`, explicit `permissions.ask` rules, `AskUserQuestion` always
denied) — everything else runs unprompted.

`CLAUDE.md` (in `kit/`, shipped to the USB root) is the scope of what the
agent is *told* to use — a prompted boundary, not a code-enforced sandbox.
That instructions file is doing the safety work; it's written accordingly
(see [`docs/tool-whitelist.md`](tool-whitelist.md)).

`permissions.defaultMode: "bypassPermissions"` in `settings.json` is the
config-file equivalent of the CLI flag, but there are reported cases where
it doesn't suppress prompts on some CLI versions while the flag reliably
does — so the launcher passes `--dangerously-skip-permissions` explicitly
rather than relying on the settings file alone. `kit/config/settings.json`
still sets `bypassPermissions` as a belt-and-suspenders default, and layers
`DISABLE_AUTOUPDATER` / `autoUpdatesChannel` pinning underneath it.

## Vendor guidance conflict — noted and accepted

Anthropic's own docs state `bypassPermissions` should only be used in an
isolated container/VM "where Claude Code cannot damage your host system,"
and that it "offers no protection against prompt injection or unintended
actions." Native Windows has **no sandboxing support at all** (confirmed in
the setup docs: sandboxing is available on WSL2, not on native Windows or
WSL1). This kit runs bypass mode directly on the bare host by necessity —
the task is fixing that host's real filesystem, which a container would
prevent. This is the scenario Anthropic's guidance warns against, not a
variant of the recommended approach. See
[`docs/decisions.md`](decisions.md) — this is accepted, not open.

## Execution model

```
USB drive
├── Start-Repair.ps1          entry point, double-clickable / run from PS
├── CLAUDE.md                 repair playbook + tool whitelist (loaded automatically)
├── .claude/settings.json     bypassPermissions default, disabled auto-update
├── bin/claude/                the native binary + its bundled ripgrep, copied whole
├── scripts/                  numbered pipeline steps (PowerShell, run before the agent starts)
├── tools/                    the 23 whitelisted tool binaries, vendor-fresh + checksummed
├── config/auth.env           CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY (gitignored, not in repo)
├── state/.claude/            CLAUDE_CONFIG_DIR target — credentials, session history, transcripts
├── iso/                      matching-version Windows WIM for DISM /Source:, boot media
└── logs/                     per-run transcript, separate from state/.claude session history
```

### Where the human/agent line is drawn

At "does this step need a person?" Backup destination selection does — the
only moment an operator is reliably present is at plug-in time — so the
backup runs in the launcher, before handoff. Everything after that is the
agent's. The launcher records what it did in `state/session-context.json`,
and `CLAUDE.md` makes reading that file the agent's first instruction, so
the agent knows whether a safety net exists rather than assuming one.

`Start-Repair.ps1`:

1. Detects Safe Mode vs. normal mode
   (`HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Option`, absent in
   normal mode), and whether the session is elevated (half the whitelist —
   DISM, chkdsk, restore points, Defender exclusions — needs it, so this is
   surfaced loudly rather than discovered as confusing failures later).
2. Runs the optional user-data backup: measures the source, offers a volume
   picker (`Select-BackupTarget.ps1`) that flags volumes too small, the
   kit's own drive, and the system drive, then copies with a capacity
   pre-flight. `-BackupMode Skip` or `-BackupDestination <path>` bypass the
   prompt.
3. Sets `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`,
   `DISABLE_AUTOUPDATER=1`.
4. Writes `state/session-context.json` — boot mode, elevation, backup
   status/destination/scope.
5. Runs `03-Set-DefenderExclusions.ps1` for the USB tool directory (best
   effort — Defender may not be reachable to modify from Safe Mode in every
   configuration; the script logs and continues rather than blocking), and
   removes those exclusions again in a `finally` block so the machine isn't
   left permanently weakened.
6. Invokes:
   ```powershell
   & "$KitRoot\bin\claude\claude.exe" -p $PlaybookPrompt `
       --dangerously-skip-permissions `
       --output-format stream-json --verbose
   ```
   from a working directory containing `CLAUDE.md`, piping
   `stream-json` output into the run's log file as it goes, so a crash
   mid-run still leaves a usable partial transcript on the USB (see
   headless-mode docs: exit code is non-zero on failure, and the failure
   reason prints as the result on stdout even for auth failures).
7. `CLAUDE.md` then directs the agent: read `session-context.json` → restore
   point → inventory, before anything else, and confines it to the tool
   whitelist — see [`docs/tool-whitelist.md`](tool-whitelist.md).

## The whitelist is prose, and what that does and doesn't mean

`CLAUDE.md` also carries an explicit untrusted-input section, because a
repair agent reads attacker-controlled text by definition — see
[`docs/decisions.md`](decisions.md). Both that and the tool whitelist are
model instructions, so they're mitigations rather than guarantees.

Two enforced mechanisms exist and are currently unused, recorded here so the
choice stays visible: `permissions.deny` rules block in every mode including
`bypassPermissions` ("Deny rules block in every mode" — permission-modes
docs), and a `PreToolUse` hook exiting with code 2 stops a call before
permission rules are evaluated. Neither prompts anyone, so neither would
reduce the kit's autonomy. Worth noting that the built-in hard-coded
refusals that survive bypass mode (`rm -rf /`, `rm -rf ~`) and the
critical-path circuit breaker (scoped to `rm`/`rmdir`) are Unix-shaped — on
native Windows the agent drives PowerShell, so `Remove-Item -Recurse -Force`,
`Format-Volume`, `Clear-Disk`, and `diskpart` plausibly hit none of them.

No `--bare`: the kit depends on `CLAUDE.md` auto-loading, and bare mode
skips it (see [`docs/authentication.md`](authentication.md) for the other
reason: bare mode ignores the subscription OAuth token).

## Safe Mode support

Enumerated directly from the registry allowlists
(`HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\{Minimal,Network}`) on
Windows 11 25H2 build 26200.9278, cross-checked against Microsoft docs — see
[`docs/safe-mode-constraints.md`](safe-mode-constraints.md) for the full
table. Claude Code itself only needs outbound HTTPS and a working shell,
both of which Safe Mode with Networking provides once Wi-Fi is connected via
`netsh` (the network flyout UI won't render — `NlaSvc` is absent — so expect
false "no internet" indicators; connectivity is fine).

## WMIC → CIM

WMIC was removed from Windows 11 24H2/25H2 as of KB5120998 (2026-08-14).
Every inventory/diagnostic step in this kit uses `Get-CimInstance`, not
`wmic`. WMI itself (`Winmgmt`) is available in Safe Mode, so CIM diagnostics
work there too.

## What's untested

This repo was authored in a cloud sandbox with no Windows hardware attached.
Everything above follows directly from Anthropic's published CLI behavior
and from the registry-verified Safe Mode allowlist, but nobody has actually
run `Start-Repair.ps1` end-to-end on a physical machine yet. See
[`docs/verification-checklist.md`](verification-checklist.md) before trusting
this kit unattended on a real repair.
