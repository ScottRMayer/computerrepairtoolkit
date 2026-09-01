# Tool whitelist

31 tools + 2 pipeline steps. This is the authoritative list — `CLAUDE.md`
restates it for the agent, but this file is what to edit first; keep both in
sync.

**Exact invocations live in [`docs/tool-invocations.md`](tool-invocations.md)** —
including the flags that stop a tool hanging an unattended session on a EULA
dialog. This file says *what* is allowed; that one says *how* to run it.

(The count treats the NirSoft suite as one entry. Earlier revisions of this
doc said "23", inherited from the original survey, whose per-category
arithmetic didn't reconcile — don't treat the total as load-bearing.)

## Pipeline steps (every session, in order)

**Launcher-run, before the agent starts** (needs a person — see
[`docs/decisions.md`](decisions.md)):

0. **User-data backup**, optional, operator-selected destination —
   [`kit/scripts/Select-BackupTarget.ps1`](../kit/scripts/Select-BackupTarget.ps1)
   then [`kit/scripts/00-Backup-UserData.ps1`](../kit/scripts/00-Backup-UserData.ps1)

**Agent-run, per `CLAUDE.md`, before any diagnostic or repair action:**

1. **Read `state\session-context.json`** — what the launcher did, including
   whether a backup exists
2. **Restore point** (normal mode only, frequency override set first; Safe
   Mode uses `-SafeModeFallback`) —
   [`kit/scripts/01-New-RestorePoint.ps1`](../kit/scripts/01-New-RestorePoint.ps1)
3. **`Get-CimInstance` system inventory** —
   [`kit/scripts/02-Get-SystemInventory.ps1`](../kit/scripts/02-Get-SystemInventory.ps1)

## Built-in Windows

No download, no checksum, no Defender exclusion, and available in Safe Mode
unless noted — the cheapest capability in the kit.

**Repair:** `sfc`, `DISM`, `chkdsk` / `Repair-Volume`, `fsutil`
**Windows Update repair:** `UsoClient`, service stop/start + SoftwareDistribution/catroot2 reset *(normal mode only)*
**Store / Start menu:** `Get-AppxPackage` / `Add-AppxPackage` re-registration *(normal mode only)*
**Security:** `MpCmdRun.exe` (Defender)
**Encryption:** `manage-bde` *(status checks — `-off` and `-forcerecovery` are deny-listed)*
**Hardware:** `mdsched` *(prior results only — see below)*
**Drivers:** `pnputil`
**Permissions:** `icacls`
**Network:** `netsh` (incl. `advfirewall`/firewall review), `ipconfig`, `ping`, `tracert`, `nslookup`
**Power:** `powercfg`
**Cleanup:** `cleanmgr`, `DISM /StartComponentCleanup`
**Packages:** `winget` *(normal mode only — see [`docs/safe-mode-constraints.md`](safe-mode-constraints.md))*

Exact procedures for the Windows Update reset, Appx re-registration, and
firewall review are in [`docs/tool-invocations.md`](tool-invocations.md) —
they're multi-step, and the WU reset in particular must stop services before
renaming folders or it fails on in-use files.

Two of these carry constraints that matter more than the tools themselves:

- **`manage-bde -status` should run during inventory, before any repair
  action.** If a volume is BitLocker-encrypted, work touching boot config or
  the system volume can trigger a recovery-key demand at next boot. On a
  family machine where nobody knows where the key is, that turns a repair
  into permanent data loss. `02-Get-SystemInventory.ps1` collects this.
- **`mdsched` requires a reboot, which kills the agent session.** The agent
  may read *prior* memory-diagnostic results from the event log (free, zero
  risk) and recommend a test, but must not trigger one. Failing RAM mimics
  software corruption closely enough that without this the agent will
  "repair" software symptoms of a hardware fault indefinitely.

## Sysinternals

Autoruns/`autorunsc`, Handle, PsList, PsKill, PsService, Streams

(SDelete is part of the Sysinternals suite but is **excluded** — see below.)

## Malware/PUP removal

**Microsoft Safety Scanner** (`msert.exe`) — free, portable single binary
from Microsoft. An independent engine from the Defender already on the
machine, so it's a genuine second opinion. Signatures are bundled into the
binary, which **expires ~10 days after download** — fetch it fresh at build
time, and treat an expired-binary result as no result rather than as clean.

AdwCleaner (a Malwarebytes product — the free half of their offering; the
portable Malwarebytes scanner ships only in their licensed Toolset),
Emsisoft Emergency Kit (`a2cmd.exe`).

**Prefer quarantine over deletion** with both AdwCleaner and `a2cmd` — a
false positive on a family member's file is unrecoverable otherwise. Same
reasoning that removed SDelete.

## Cleanup

BleachBit, WizTree

## Driver recovery

**Snappy Driver Installer Origin** (`sdio.exe`) — offline, scriptable driver
matcher/installer using bundled driverpacks. Fills the "no driver after
repair/reinstall" gap. Added per [`docs/ecosystem-catalog.md`](ecosystem-catalog.md).

## Crash-dump analysis

**`cdb.exe`** (Windows Debugging Tools) — headless `!analyze -v` root-cause on
minidumps, beyond NirSoft BlueScreenView's driver guess.

## Debloat / telemetry (normal mode only)

**Win11Debloat** (reversible, `-CreateRestorePoint`) and optionally **O&O
ShutUp10++** (curated "recommended" `.cfg`). Both apply-once, behind a restore
point. Never the aggressive presets on a family machine.

## Disk health

`smartctl` (smartmontools) — no official portable build; extract from the
NSIS installer at build time (see
[`docs/usb-layout.md`](usb-layout.md#fetching-and-checksumming-tools)).
`smartctl.exe` itself needs no service, so the extracted binary works
standalone.

## Network

Ookla Speedtest CLI (official)

## Crash/log analysis

NirSoft suite (BlueScreenView, etc.)

## Enforced denials

Separate from this whitelist (which is prose the agent is asked to follow),
a short deny list in [`kit/.claude/settings.json`](../kit/.claude/settings.json)
is enforced by the harness in every permission mode. Scope: commands never
used in a repair procedure — disk/volume destruction, destruction of the
kit's own restore point and backups, account deletion, whole-hive registry
deletion, and `Remove-Item` against system directories. Full list and
rationale in [`docs/decisions.md`](decisions.md).

**When editing this whitelist, run
[`scripts/test-deny-rules.py`](../scripts/test-deny-rules.py)** and add the
new tool's invocation to its `MUST_PASS` list — that's what catches a deny
rule accidentally blocking a legitimate repair action.

## Explicitly excluded

| Tool | Why |
|---|---|
| `verifier.exe` | Forces a BSOD by design when it finds a driver fault — wrong for unattended use. |
| SDelete | Its only function is making data irrecoverable, which is not a repair capability. Removed from the whitelist after review — see below. |
| CCleaner | CLI only does disk cleanup (registry cleaner is GUI-only); `cleanmgr` + BleachBit cover it; supply-chain-compromise history (2017). |
| FRST | Fixlist-driven — whatever drives it generates arbitrary registry/file/service edits with no schema constraining it. Manual, human-reviewed use only. |
| `setup.exe /Auto Upgrade` (in-place repair install) | See [`docs/iso-role.md`](iso-role.md) — deliberately left out pending explicit approval, not because it's unsafe in principle. |
| Clean reinstall | Same — an escalation tier, not part of the autonomous whitelist. |
| **Kaspersky KVRT** | Best CLI of anything surveyed (`-silent`, `-accepteula`, `-processlevel`), but the US Commerce Department prohibited Kaspersky from providing antivirus software and services to US persons — sales barred 2024-07-20, all service **including signature updates** barred 2024-09-29, still in force. A scanner that can't update signatures also degrades every month. ([BIS](https://www.bis.gov/kaspersky)) |
| **HWiNFO** | Command-line reporting is a **Pro (paid) feature**; the free build can't do it. ([licenses](https://www.hwinfo.com/licenses/)) |
| **CrystalDiskInfo** | Portable but no native CLI — only a third-party PowerShell wrapper. `smartctl` already covers SMART properly. |
| **Malwarebytes Toolset** | The official portable Malwarebytes scanner (`MBTS.exe /scan:malware`), but it's a licensed technician product, not free. AdwCleaner is the free Malwarebytes tool and is already included. |
| **HitmanPro** | Scanning is free; *removal* requires a license. |
| **Sophos Scan & Clean** | Good candidate — free, no-install, runs from USB. Not added because its CLI switches could not be verified (its KB page returned no content on 2026-08-31). Adding a tool to an unattended kit without a known invocation is the failure mode [`docs/tool-invocations.md`](tool-invocations.md) exists to prevent. Verify and add. |

## Why SDelete was removed

It was originally whitelisted as part of "the Sysinternals suite" rather
than justified individually. On review it fails the same test already
applied to `verifier.exe`: destructive by design, wrong for unattended use.

Every repair task it appears useful for is better served by a tool already
on the list:

| Apparent use | Actually the right tool |
|---|---|
| Deleting stubborn/locked files | **Handle** — find the lock, close it, then delete normally. SDelete does not help with locked files; it's a secure-erase tool, not a force-delete tool. |
| Removing malware files | **AdwCleaner** / **Emsisoft `a2cmd`** — these *quarantine*, which is strictly better, because a false positive stays recoverable. |
| Freeing disk space | **`cleanmgr`** / **BleachBit** |

And it is the one whitelisted tool that defeats the kit's own safety model.
Everything else in this design assumes rollback exists — restore point,
user-data backup, quarantine. SDelete is specifically engineered to make
rollback impossible, and secure-erase framing ("securely clean up these
leftover files") is exactly the shape a prompt injection would take.

Nothing replaces it, because secure deletion isn't a repair function. If a
drive genuinely needs wiping before disposal, that's a separate deliberate
task with a human present, not something an unattended repair agent carries.

Two honest caveats:

- **BleachBit, still whitelisted, has its own shred/overwrite capability.**
  Removing SDelete narrows the irreversible-destruction surface; it doesn't
  eliminate it. BleachBit's *default* operation is ordinary cleanup, where
  SDelete's only operation is destruction — different risk profiles, but not
  zero.
- **The binary still physically ships**, because Sysinternals is fetched as
  a single suite archive. `Build-Kit.ps1` deletes `sdelete*.exe` after
  extracting, and a deny rule blocks it regardless, so removal doesn't
  depend on the delete step having worked.

## Portable builds confirmed available

BleachBit, WizTree, Emsisoft Emergency Kit, NirSoft utilities, Sysinternals
Suite, AdwCleaner. Everything else in the whitelist is either built into
Windows or, for `smartctl`, extracted once at build time.
