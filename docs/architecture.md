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

`Start-Repair.ps1`:

1. Detects Safe Mode vs. normal mode
   (`HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Option`, absent in
   normal mode).
2. Sets `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`,
   `DISABLE_AUTOUPDATER=1`.
3. Runs `03-Set-DefenderExclusions.ps1` for the USB tool directory (best
   effort — Defender itself may not be reachable to modify from Safe Mode
   in every configuration; the script logs and continues rather than
   blocking on failure).
4. Starts a PowerShell transcript to `logs/`.
5. Invokes:
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
6. `CLAUDE.md` itself directs the agent through the pipeline steps (backup →
   restore point → inventory) before anything else, and confines it to the
   tool whitelist — see [`docs/tool-whitelist.md`](tool-whitelist.md).

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
