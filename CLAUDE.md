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
  remove a tool from one, update the other in the same change — and run
  `python3 scripts/test-deny-rules.py`, adding the new tool's invocation to
  its `MUST_PASS` list. That test is what catches an enforced deny rule
  accidentally blocking a legitimate repair action.
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
manual procedure to run on real hardware.

Three automated checks exist and must pass before any push:

- `python3 scripts/test-deny-rules.py` — the deny list vs. the whitelist.
- `pwsh -File scripts/test-pretooluse-guard.ps1` — the guard hook's
  must-deny / must-allow cases (it insists on BOTH the deny JSON and exit
  code 2, because only exit 2 blocks under bypass mode).
- A parse of every `.ps1` via
  `[System.Management.Automation.Language.Parser]::ParseFile()`.

`pwsh` (PowerShell 7, cross-platform) is **not guaranteed to be installed**
in the sandbox. If `which pwsh` is empty, download the Linux x64 tarball of
a PowerShell 7 release from GitHub into the scratchpad directory, extract
it, and `chmod +x pwsh` — it runs without installation. A clean parse is
not enough on its own: it accepts malformed `-f` format strings that throw
at runtime, so runtime-test any format string you touch (paste it into
`pwsh` with sample values). It cannot execute Windows-only cmdlets
(`Get-CimInstance`, `Add-MpPreference`, `Checkpoint-Computer`, etc.), so a
clean parse is necessary, not sufficient — nothing here has been
execution-tested end to end. Remember the real target runs **Windows
PowerShell 5.1**, not 7: no `??`, no `&&`/`||` pipeline chains, no
ternary, `Start-Process -ArgumentList` does not quote array elements
(use `ConvertTo-ArgumentString` from `kit/scripts/lib/Common.ps1`), and
WMI/CIM date fields come back as DMTF strings, not `DateTime`.

Every `.ps1` under `kit/` and `scripts/` is saved as UTF-8 **with BOM**
(Windows PowerShell 5.1 otherwise misreads non-ASCII characters in the
scripts). When rewriting a file wholesale, preserve the BOM; check with
`head -c3 file | od -An -tx1` (expect `ef bb bf`).
