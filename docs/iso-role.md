# ISO role — resolved

The handoff left this undefined, with three candidate roles: repair-install
source, `DISM /Source:` for the offline-servicing path, or full clean
reinstall.

## Decision: DISM source + emergency boot media only

The ISO's role in the **autonomous** whitelist is narrow:

1. **`DISM /RestoreHealth /Source:<mounted WIM> /LimitAccess`** — this is
   already load-bearing per [`docs/safe-mode-constraints.md`](safe-mode-constraints.md):
   Windows Update is unreachable in Safe Mode, and may be unreachable in
   normal mode too on a badly broken machine, so `DISM /RestoreHealth`
   needs a local source to do anything at all. The WIM must match the
   target's Windows version/edition/build — a mismatch makes DISM reject
   the source outright. This is why carrying *a* WIM is genuinely
   necessary, not optional, for the tool whitelist to work as designed.
2. **Emergency boot media** — if the machine won't boot, the ISO is what
   you boot from to get a repair environment at all (Windows RE, or a
   manual boot to run `bootrec`/`bcdboot` by hand). This is a **human-driven
   fallback**, not something `CLAUDE.md` scripts — if the machine can't boot
   Windows, Claude Code can't run on it either, so this tier is inherently
   outside the autonomous kit.

## Deliberately excluded from the autonomous whitelist

**In-place repair install** (`setup.exe /Auto Upgrade /Quiet /NoReboot`)
keeps apps/files/settings while replacing system files — a genuinely useful
escalation above `sfc`/`DISM` for a Windows install that's corrupted beyond
what offline servicing fixes. It is **not** in the tool whitelist. Reasoning:
it's a substantially more invasive action than anything else on the list
(replaces the entire OS image in place), and adding it changes the risk
profile of "fully autonomous, no approval gate" enough that it deserves an
explicit decision of its own rather than inheriting approval from this ISO
write-up. Flagged here as a candidate for a future, deliberate whitelist
addition — not added silently.

**Clean reinstall** is excluded for the same reason, more so: it is
data-destructive on the system volume even with the user-data backup step
having run (backup covers the user profile, not arbitrary paths a family
member might have used — Desktop shortcuts to app configs, unusual install
locations, etc.). This stays a manual, human-decided action regardless of
how autonomous the rest of the kit is.

## Practical consequence for drive size and edition selection

Only one WIM needs to be carried, matching the most likely target Windows
version (current Windows 11 24H2/25H2 at time of writing). Carrying multiple
editions to hedge against version mismatch trades drive space (~5-6GB per
ISO) against a feature (`DISM /Source:`) that degrades gracefully anyway —
`DISM /ScanHealth` and `/CheckHealth` still work without a source, and
`/RestoreHealth` without a matching source is a no-op you can detect and
skip rather than a hard failure. Recommendation: carry one current-edition
ISO, re-derive the WIM whenever you rebuild the kit
(`scripts/Build-Kit.ps1`), and accept degraded (not broken) DISM repair on a
target running a different Windows version. Plan for a 64GB+ USB 3.0 drive
either way, per the original survey.
