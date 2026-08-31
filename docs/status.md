# Status

## Done and verified (against Anthropic's published docs, 2026-08-31)

- Tool whitelist expanded to 31 entries — see
  [`docs/tool-whitelist.md`](tool-whitelist.md). Added Microsoft Safety
  Scanner (free, portable, independent engine from Defender) plus nine
  built-in Windows tools that need no download at all: `manage-bde`,
  `mdsched` (prior results only), `pnputil`, `icacls`, `fsutil`,
  `ipconfig`, `ping`, `tracert`, `nslookup`.
- **Exact invocations documented** in
  [`docs/tool-invocations.md`](tool-invocations.md), with per-tool
  confidence markers. The prior session's switch research was never
  committed and was lost; this replaces it. Verified against vendor docs:
  Sysinternals `-accepteula`, MSERT `/f /q`, AdwCleaner
  `/eula /clean /noreboot`, Emsisoft `a2cmd /quarantine=`, BleachBit
  `--preview` / `--clean`. Still marked unverified: WizTree, smartctl
  device naming, Speedtest flag spelling, NirSoft export switches.
- **EULA-blocking flags identified** — several tools show a consent dialog
  on first run and would hang an unattended session indefinitely rather
  than fail. Documented as its own section since it's the most likely way a
  first real run dies.
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
- **Enforced deny list** in `kit/.claude/settings.json` covering commands
  that are never part of a repair — blocks in every permission mode
  including `bypassPermissions`, costs no autonomy. Validated by
  `scripts/test-deny-rules.py`, which asserts every whitelisted repair
  action survives it and every catastrophic command is caught.
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
  downloads each tool once and records its hash. Six of nine entries have
  no URL either, because those vendors don't publish stable download links
  (AdwCleaner, Emsisoft, BleachBit, WizTree, smartmontools, NirSoft).
  MSERT is deliberately `"sha256": "unpinned"` — its binary changes every
  build because signatures are baked in and it expires in ~10 days.
- **Sophos Scan & Clean not added** — good candidate (free, no-install,
  runs from USB) but its CLI switches couldn't be verified; its KB page
  returned no content. Verify [Sophos KB 124061](https://community.sophos.com/kb/en-us/124061)
  and it's a straightforward addition.
- The four unverified invocations above (WizTree, smartctl, Speedtest,
  NirSoft) should be confirmed with `--help` on the build machine before a
  real repair — a wrong switch either does nothing or does something
  unintended, unattended.
- Windows 10 Safe Mode allowlist unverified — all findings are from Windows
  11 25H2 (see [`docs/safe-mode-constraints.md`](safe-mode-constraints.md)).
- `winget` availability in Safe Mode is still inference, not confirmed.
- Windows edition/build to target for the bundled WIM not yet chosen (see
  [`docs/iso-role.md`](iso-role.md) for the tradeoff) — pick the edition
  when you actually run `Build-Kit.ps1`.

## Considered and deliberately not done

- **A blocking `PreToolUse` hook** to enforce the tool whitelist positively
  rather than as a blocklist. Works under `bypassPermissions` (exit code 2
  blocks a call before permission rules are evaluated) and wouldn't reduce
  autonomy. The deny list covers the catastrophic verbs; the hook is what
  would close the path-based gaps described in
  [`docs/decisions.md`](decisions.md). Revisit if those gaps matter in
  practice.
- **`bcdedit`, `Set-Partition`, `Clear-RecycleBin` in the deny list** —
  excluded because each has a plausible repair use. See
  [`docs/decisions.md`](decisions.md).

## Resume here

Run [`docs/verification-checklist.md`](verification-checklist.md) on a real
Windows machine — normal mode first, then Safe Mode with Networking. Then
populate `scripts/tool-manifest.json` with real checksums, pick a Windows
edition, and run `Build-Kit.ps1` against an actual drive.
