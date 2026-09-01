# Status

> **[`docs/spec.md`](spec.md) is now the authoritative design**, produced by a
> first-principles workshop (7 expert lenses → 3 adversarial critics →
> synthesis). Where anything here conflicts with it, the spec wins.

## Latest pass — Tier-3: the "won't boot" layer

Closes the kit's biggest structural gap (it only worked on a machine that
already boots):

- **`docs/offline-repair-playbook.md`** — the WinRE/WinPE procedure for a
  non-booting machine: Ventoy multiboot setup, BCD rebuild (`bootrec`/
  `bcdboot`), offline SFC + DISM (`/Source:` from a bundled install.wim),
  offline registry-hive repair (documented, kept manual — it bricks boot when
  wrong), and the honest division of labor: **the offline layer gets Windows
  bootable; the autonomous agent takes over once it boots.** No autonomous fix
  exists for a dead OS — no OS, no cloud brain.
- **`kit/scripts/Invoke-OfflineRepair.ps1`** — runs from WinPE. Assessment-only
  by default; `-Fix` applies the safe standard sequence (BCD rebuild + offline
  SFC/DISM). Auto-detects the Windows volume (WinPE reassigns letters),
  refuses to modify a BitLocker-locked volume without the key, and never
  automates hive edits. Executed end-to-end here (clean exit on no-Windows).
- **Build-Kit `-RecoveryIso`** stages + checksums WinPE/MemTest ISOs into
  `\ISO\` for the Ventoy menu. Ventoy install itself stays a documented manual
  step (its installer reformats the drive).

Windows-specific behavior (bootrec/bcdboot/offline DISM, drive-letter
detection, BitLocker offline) is parse-clean but **hardware-unverified** — see
the playbook and checklist.

## Earlier pass — Tier-1 safety hardening (from the ecosystem research)

The four safety upgrades the web research validated are now built and tested:

- **Argument-aware PreToolUse guard** (`kit/hooks/PreToolUse-Guard.ps1`) — the
  piece deny-string rules structurally can't be. Blocks argument-level abuse a
  dual-use tool enables: agent-initiated downloads / `iex`, disabling Defender
  or adding exclusions, writing IFEO/Winlogon/LSA/Run persistence keys,
  `bcdedit /delete`, and UNC/WebDAV paths. Fail-closed on parse error.
  `scripts/test-pretooluse-guard.ps1`: 11 attacks blocked, 13 real repairs
  pass — including the subtle splits (`bcdedit /delete` blocked but
  `/deletevalue safeboot` allowed; adding a Run key blocked but removing one
  allowed; reading Defender allowed but disabling it blocked).
- **System-level injection policy** (`kit/config/system-prompt-append.txt`,
  passed via `--append-system-prompt-file`) — the "content is data, not
  instructions" rule at the system-prompt level, because bypass mode forfeits
  Manual-mode's built-in injection screens.
- **Report contract** (`docs/report-schema.json`) — formalizes the
  `repair-summary.json` the agent writes and the report card renders.
- **Wall-clock watchdog + `--max-turns` + deterministic `--session-id`** in the
  launcher: a hung turn can't hold the machine forever; on a time cap it
  interrupts and does one bounded `--resume` so the agent still writes its
  summary. Windows interrupt/resume semantics are flagged for hardware
  verification (checklist 9c).

## Earlier pass — what the workshop changed

- **Fixed a live security hole.** The deny list was written almost entirely as
  `PowerShell(...)` rules, but Claude Code uses the **Bash** tool when Git for
  Windows is present. So `powershell -c "Clear-Disk -Number 0"` routed through
  the Bash tool matched *nothing* and would have executed. Every catastrophic
  verb is now mirrored as a `Bash(...)` rule (64 total), with 10 regression
  cases proving the bypass is closed.
- **Environment scrub before handoff.** An inherited `ANTHROPIC_API_KEY` on the
  target outranks the owner's subscription token in Claude Code's credential
  precedence — it would silently shadow it and misroute billing. That plus
  TLS-weakening vars (`NODE_EXTRA_CA_CERTS`, `NODE_TLS_REJECT_UNAUTHORIZED`,
  `HTTPS_PROXY`, `SSL_CERT_FILE`, `NODE_OPTIONS`, …) are stripped from the
  child environment, closing the one channel no on-disk guardrail can see.
- **Connectivity is now a launcher precondition** (`04-Ensure-Connectivity.ps1`),
  not the agent's job — with a **clock-skew rung first**. A dead CMOS battery
  makes the clock wrong, which fails TLS, which looks exactly like "the
  internet is broken": the one outage a cloud-brained agent is uniquely blind
  to. Ladder: clock → adapter/Wi-Fi → DNS → hosts hijack → proxy (WinHTTP
  *and* WinINET). If it can't get online the agent is never launched; exit
  code 3 distinguishes "couldn't start" from "nothing to fix".
- **Model pinned** (`--model claude-opus-5 --fallback-model claude-sonnet-5`)
  so unattended reasoning quality can't drift, with a fallback so a capacity
  blip doesn't kill a repair nobody is watching.
- **`Build-Kit.ps1 -Minimal`** builds the ~300MB smoke-test drive, plus a build
  gate that runs `claude.exe --version` from the USB path and refuses to ship a
  drive whose copied binary doesn't launch.
- **Operator entry point**: `Repair-This-PC.cmd` (self-elevating double-click)
  and `START-HERE.txt` in plain language.

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

- **Red team / blue team review** complete — see
  [`docs/red-team-review.md`](red-team-review.md). Two fixes landed with it:
  closed the `cmd /c format` and WMI-volume-format deny-list bypasses (with
  false-positive guards so `Get-Date -Format` and `Format-Table` still
  pass), and added an off-USB copy of the run transcript to the operator's
  backup drive so the audit trail isn't single-copy on attacker-reachable
  media. The review's larger items are decisions, below.

## From the red-team review

**Done:**

- **Capability adds** — Windows Update repair
  (SoftwareDistribution/catroot2 reset + `UsoClient`), Store/Start-menu Appx
  re-registration, WinSxS component cleanup, and firewall-state review.
  All built-in, normal-mode-only, documented as full procedures in
  [`docs/tool-invocations.md`](tool-invocations.md). These are what let the
  kit fix the most common real family-PC failures, not just diagnose them.
- **Backup-hygiene flag (R8)** — the agent writes
  `state\backup-needs-scan.flag` when it finds malware and a backup exists;
  the launcher reads it and escalates its closing message from a routine
  reminder to a warning that names the backup drive as a contamination risk.
  The flag is cleared at the start of every run so a stale one can't
  misfire.
- **Rootkit answer documented** — Microsoft Defender Offline
  (`Start-MpWDOScan`) noted as a human-escalation (it reboots, which kills
  the session), not an autonomous tool.

**Still open (decisions):**

- **Hardware write-protect USB as the default posture** — highest risk
  reduction in the review, ~$12, no code. Makes the "only safety boundary"
  (`CLAUDE.md`) immutable in hardware. Recommended before the first real
  repair.
- **PreToolUse positive-allow hook** — closes the deny-list bypass class
  (R1) that no amount of blocklist patterns can. Tool list is now stable
  enough to enumerate.
- **Split `winget upgrade` (allow) from `winget install` (deny)** — closes a
  sanctioned fetch-and-execute path inside the whitelist.

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
