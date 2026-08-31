# Status

## Done and verified (against Anthropic's published docs, 2026-08-31)

- All 23 whitelisted tool CLI switches confirmed against vendor-primary
  documentation — see [`docs/tool-whitelist.md`](tool-whitelist.md).
- Safe Mode service constraints enumerated directly from the registry
  allowlist on Windows 11 25H2 build 26200.9278, cross-checked against
  Microsoft documentation — see
  [`docs/safe-mode-constraints.md`](safe-mode-constraints.md).
- WMIC removed from Windows 11 24H2/25H2 as of KB5120998 (2026-08-14); every
  script in `kit/scripts/` uses `Get-CimInstance`.
- Portable builds confirmed available for: BleachBit, WizTree, Emsisoft
  Emergency Kit, NirSoft utilities, Sysinternals Suite, AdwCleaner.
- **Authentication mechanism resolved** — `claude setup-token` +
  `CLAUDE_CODE_OAUTH_TOKEN`, no browser needed at repair time. See
  [`docs/authentication.md`](authentication.md).
- **Node.js bundling requirement resolved as unnecessary** — the native
  standalone binary has no Node dependency. See
  [`docs/authentication.md`](authentication.md#portability-no-nodejs-bundling-needed).
- **ISO's role decided** — DISM source + emergency boot media, with
  in-place-repair and clean-reinstall deliberately left off the autonomous
  whitelist. See [`docs/iso-role.md`](iso-role.md).
- USB folder layout designed — see [`docs/usb-layout.md`](usb-layout.md).
- `CLAUDE.md` on-USB playbook drafted — see [`kit/CLAUDE.md`](../kit/CLAUDE.md).
- User-data backup (optional, operator-selected destination with a volume
  picker and capacity pre-flight), restore-point (with the
  frequency-override fix), system-inventory, Safe Mode detection, and
  Defender-exclusion scripts (with removal at session end) written — see
  `kit/scripts/`.
- `kit/CLAUDE.md` carries an explicit untrusted-input section: text read off
  the target machine informs diagnosis but never changes instructions.
- Every `.ps1` script in the repo parses cleanly under PowerShell 7's own
  parser (`pwsh` is available in this sandbox even without Windows). This
  catches syntax errors but not behavior — the Windows-only cmdlets these
  scripts call (`Get-CimInstance`, `Add-MpPreference`,
  `Checkpoint-Computer`, `Get-ComputerRestorePoint`, `robocopy`) cannot run
  here, so this is necessary, not sufficient, verification.

## Still open — needs a physical Windows machine

**This repo was built in a cloud sandbox with no Windows hardware
attached.** Nothing below has been run against a real target machine; it
follows from documented CLI/OS behavior, not a live test.

- **Does `Start-Repair.ps1` actually launch and authenticate Claude Code
  from the USB copy, end to end?** High confidence from the docs (native
  binary is self-contained, `-p` mode always uses `ANTHROPIC_API_KEY`/
  `CLAUDE_CODE_OAUTH_TOKEN` when present, no Node dependency), but
  unconfirmed. **Do this first** — see
  [`docs/verification-checklist.md`](verification-checklist.md).
- Same, in Safe Mode with Networking.
- `scripts/Build-Kit.ps1` has not been run against a real drive — the copy
  of `~/.local/share/claude/versions/<version>/` onto the USB is untested;
  it's possible the versioned directory has an absolute-path dependency
  that doesn't survive being copied elsewhere (the docs don't say either
  way).
- `tool-manifest.json` checksums are not yet populated — `Build-Kit.ps1`'s
  checksum-verification step has no data to verify against until someone
  downloads each tool once and records its hash.
- Windows 10 Safe Mode allowlist unverified — all findings are from Windows
  11 25H2 (see [`docs/safe-mode-constraints.md`](safe-mode-constraints.md)).
- `winget` availability in Safe Mode is still inference, not confirmed.
- Windows edition/build to target for the bundled WIM not yet chosen (see
  [`docs/iso-role.md`](iso-role.md) for the tradeoff) — pick the edition
  when you actually run `Build-Kit.ps1`.

## Considered and deliberately not done

- **`permissions.deny` rules + a blocking `PreToolUse` hook** to enforce the
  tool whitelist in code rather than prose. Both work under
  `bypassPermissions` and neither prompts anyone, so neither would reduce
  autonomy — see [`docs/architecture.md`](architecture.md#the-whitelist-is-prose-and-what-that-does-and-doesnt-mean).
  Not implemented for now; the plan is a supervised test run first.

## Resume here

Run [`docs/verification-checklist.md`](verification-checklist.md) on a real
Windows machine — normal mode first, then Safe Mode with Networking. Then
populate `scripts/tool-manifest.json` with real checksums, pick a Windows
edition, and run `Build-Kit.ps1` against an actual drive.
