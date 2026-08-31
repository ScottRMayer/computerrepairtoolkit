# computerrepairtoolkit

Design and build tooling for a portable USB AI PC Repair Kit — see
[`README.md`](README.md) for the project overview and
[`docs/status.md`](docs/status.md) for current state and open items.

**This file is instructions for developing this repository.** It is not the
same file as [`kit/CLAUDE.md`](kit/CLAUDE.md), which is the instructions file
that ships *on the USB* and governs the autonomous repair agent running on a
target Windows machine — don't confuse edits to one for the other.

## Before making changes

- Read [`docs/decisions.md`](docs/decisions.md) first. Several
  architectural choices there (fully autonomous, no approval gate; running
  `bypassPermissions` on the bare host) are explicitly settled and marked
  "don't re-pitch this" — don't revisit them without the user raising it.
- The tool whitelist in [`docs/tool-whitelist.md`](docs/tool-whitelist.md)
  and [`kit/CLAUDE.md`](kit/CLAUDE.md) must stay in sync. If you add or
  remove a tool from one, update the other in the same change.
- This repo was authored without access to real Windows hardware. Anything
  that claims a behavior on Windows should cite what it's based on
  (Microsoft/Anthropic docs, a registry dump, etc.) — see
  [`docs/verification-checklist.md`](docs/verification-checklist.md) for
  what's still unverified. Don't upgrade an inference to a confirmed fact
  without an actual test.

## Repo layout

- `kit/` — everything that ships on the USB drive itself (playbook, repair
  scripts, settings template). PowerShell, targets the target machine.
- `scripts/` — build-time tooling that runs on the kit-builder's own
  machine to assemble `kit/` plus fetched binaries into a real USB drive.
  Never run against a target/repair machine.
- `docs/` — design record. Keep it current as the source of truth; code
  comments reference it rather than restating it.

## Testing

There is no CI here and no Windows machine in this environment. The closest
thing to a test suite is
[`docs/verification-checklist.md`](docs/verification-checklist.md), a
manual procedure to run on real hardware. `pwsh` (PowerShell 7, cross-platform)
is available in this sandbox and is enough to catch syntax errors via
`[System.Management.Automation.Language.Parser]::ParseFile()` — do that for
any `.ps1` change. It cannot execute Windows-only cmdlets
(`Get-CimInstance`, `Add-MpPreference`, `Checkpoint-Computer`, etc.), so a
clean parse is necessary, not sufficient — nothing here has been
execution-tested end to end.
