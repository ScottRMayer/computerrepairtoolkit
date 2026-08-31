# Portable USB AI PC Repair Kit

A bootable-alongside USB flash drive that carries repair/diagnostic tools, a
Windows installation ISO, and the Claude Code CLI. Plug it into a family
member's (or your own) Windows machine, run the kit, and let Claude Code
autonomously diagnose and repair the machine using a whitelisted set of
tools — fully unattended, no approval prompts.

This repo is the design, instructions, and scripts for building that drive.
It does not ship the USB image itself (tool binaries and the Windows ISO are
too large for source control and must be fetched/verified per
[`docs/usb-layout.md`](docs/usb-layout.md)).

## Who this is for

You, running your own Claude Code subscription, repairing hardware you or
your family own. This is explicitly **not** a general-purpose deployment
tool for other people's machines — see [Decisions](docs/decisions.md) for
why fully-autonomous, no-approval-gate operation is acceptable here and
nowhere else.

## How it works

1. Plug the USB into the target Windows machine.
2. Run `Start-Repair.ps1` from the drive (elevated, ideally — DISM, chkdsk,
   and restore points all need it).
3. **You pick a backup destination**, from a list of available drives with
   their free space, or skip the backup entirely. This is the one step that
   needs a person, so it happens up front while you're still standing there.
   `-BackupDestination D:\Backups` or `-BackupMode Skip` bypass the prompt.
4. The launcher detects normal vs. Safe Mode, sets up logging and Defender
   exclusions, records what it did to `state\session-context.json`, and
   launches:
   ```
   claude -p "<repair playbook prompt>" --dangerously-skip-permissions
   ```
5. Claude Code reads `CLAUDE.md` from the USB (the bundled instructions file
   — see below) plus the session context, creates a restore point, runs
   system inventory, and works through diagnosis and repair unattended using
   only the whitelisted tools.
6. The full run is transcript-logged to the USB, not the target machine, and
   the Defender exclusions are removed again on the way out.

**Claude Code's `--dangerously-skip-permissions` bypass is a real bypass —
a small set of hard-coded refusals survive it, but everything else runs
unprompted.** The tool whitelist in `CLAUDE.md` is a *prompted* boundary,
not a code-enforced sandbox. Read [`docs/architecture.md`](docs/architecture.md)
before treating this kit as safe by construction.

## Repo layout

| Path | What it is |
|---|---|
| `CLAUDE.md` | Root-level instructions Claude Code loads for *this repository* (how to develop this repo itself). Not the same file as the on-USB kit instructions. |
| `kit/` | Everything that gets copied onto the USB drive: the on-target `CLAUDE.md` playbook, the repair scripts, and settings templates. |
| `scripts/` | Build-time tooling that runs on your machine to *assemble* the USB from `kit/` plus fetched binaries — not run on the target machine. |
| `docs/` | Design record: architecture, authentication, USB layout, ISO role, Safe Mode constraints, tool whitelist, decisions, and the manual hardware-verification checklist. |

## Status

See [`docs/status.md`](docs/status.md) for what's done, what's still open, and
what requires a physical Windows machine to verify (this repo was built in a
cloud sandbox with no Windows hardware attached — the load-bearing "does
Claude Code actually run and authenticate from a USB-hosted portable install"
question is answered from Anthropic's documented behavior, not a live test;
[`docs/verification-checklist.md`](docs/verification-checklist.md) is the
script to run that live test yourself before trusting the kit on a real
repair).

## Full tool landscape

A broader survey of repair/diagnostic tools (including scams to avoid) lives
at the published artifact referenced in [`docs/decisions.md`](docs/decisions.md).
This repo implements the 23-tool whitelist drawn from that survey, not the
full survey itself.
