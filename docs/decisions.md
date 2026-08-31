# Decisions

These are settled. Don't re-pitch them.

- **Fully autonomous — no human-approval gate.** The user and family own the
  affected computers and are accepting that risk themselves. `claude -p
  "<task>" --dangerously-skip-permissions` runs unattended; `AskUserQuestion`
  is denied under bypass mode regardless, so the agent cannot pause for
  approval even if it wanted to — the whitelist in `CLAUDE.md` is doing all
  the safety work, not a runtime gate.

- **Vendor guidance conflict, accepted.** Anthropic's docs say
  `bypassPermissions` should only be used in an isolated container/VM "where
  Claude Code cannot damage your host system," and that it "offers no
  protection against prompt injection or unintended actions." Native Windows
  has no Bash sandbox at all (macOS/Linux/WSL2 only — see
  [`docs/architecture.md`](architecture.md)). This kit runs bypass mode
  directly on the bare host by necessity: the task is fixing that host's
  real filesystem, which a container would prevent. This is the scenario the
  vendor guidance warns against, not a variant of the recommended approach.

- **Run in normal mode by default. Safe Mode is the fallback**, used only
  when malware or a broken driver blocks normal operation. Safe Mode
  disables a large slice of what this kit needs — see
  [`docs/safe-mode-constraints.md`](safe-mode-constraints.md) — so
  defaulting to it would break the kit for no benefit on a machine that
  boots normally.

- **Back up user data before any destructive step.** A restore point covers
  system state only, not documents/photos. On a family member's laptop the
  system is the replaceable part; their files aren't. Copying the user
  profile to the USB or an external drive is step zero, ahead of anything
  that removes or modifies. See [`kit/scripts/00-Backup-UserData.ps1`](../kit/scripts/00-Backup-UserData.ps1).

- **Restore point handling.** Create it in **normal mode**, and set
  `HKLM\Software\Microsoft\Windows NT\CurrentVersion\SystemRestore` →
  `SystemRestorePointCreationFrequency` = `0` (DWORD) first — otherwise
  Windows silently skips creation if any restore point was made in the last
  24 hours **and still returns success**, which would leave the agent
  believing it has a rollback it doesn't have. In Safe Mode, substitute
  `reg export` of touched hives plus file-level copies; a restore point
  cannot be created there at all. See
  [`kit/scripts/01-New-RestorePoint.ps1`](../kit/scripts/01-New-RestorePoint.ps1).

- **Defender will interfere with the toolkit.** Real-time protection runs
  even in Safe Mode, and several bundled tools (NirSoft, PsExec, AdwCleaner)
  are routine HackTool/PUA detections. Exclusions for the USB tool directory
  are configured as part of kit startup — see
  [`kit/scripts/03-Set-DefenderExclusions.ps1`](../kit/scripts/03-Set-DefenderExclusions.ps1)
  — or expect binaries to be quarantined mid-run.

- **Tools ship bundled and checksummed on the USB**, fetched fresh from each
  vendor ahead of time — never pulled live at repair time. Doubly important
  in Safe Mode, where `winget` and MSI installs don't work at all. See
  [`docs/usb-layout.md`](usb-layout.md).

- **Treat the USB as contaminated after touching a compromised machine.**
  It's a cross-machine propagation path — scan it before reuse, or use a
  drive with a physical write-protect switch.

- **Log the run to the USB**, not just the target machine's profile — the
  transcript is the only record of what an unattended agent did, and it
  shouldn't live on a machine that may get wiped or handed back. The kit
  redirects `CLAUDE_CONFIG_DIR` to a USB-local folder for exactly this
  reason (session history, credentials, and settings all stay on the drive)
  — see [`docs/authentication.md`](authentication.md).

- **Three tools excluded from the whitelist:**
  - `verifier.exe` — forces a BSOD by design when it finds a driver fault;
    wrong for unattended use.
  - CCleaner — CLI only does disk cleanup (registry cleaner is GUI-only);
    `cleanmgr` + BleachBit cover it; supply-chain-compromise history (2017).
  - FRST — fixlist-driven, meaning whatever drives it generates arbitrary
    registry/file/service edits with no schema constraining it. Manual,
    human-reviewed use only.

- **The ISO's role is DISM repair source plus emergency boot media only —
  not an autonomous in-place repair or reinstall trigger.** See
  [`docs/iso-role.md`](iso-role.md) for the reasoning and for the two
  escalation tiers (in-place repair install, clean reinstall) that are
  deliberately left *out* of the autonomous whitelist pending explicit
  approval.

## Reference

Full 13-category tool landscape survey (includes confirmed scams to avoid —
Restoro, Reimage, PC HealthBoost/"PC Health Check," MyCleanPC):
**https://claude.ai/code/artifact/bcbd8bf0-4418-432d-828c-8d1c8089ee11**
("Repair Tool Manifest")
