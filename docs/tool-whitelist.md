# Tool whitelist

22 tools + 2 pipeline steps. This is the authoritative list — `CLAUDE.md`
restates it for the agent, but this file is what to edit first; keep both in
sync.

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

`sfc`, `DISM`, `chkdsk`, `MpCmdRun.exe` (Defender), `winget` *(normal mode
only — see [`docs/safe-mode-constraints.md`](safe-mode-constraints.md))*,
`cleanmgr`, `netsh`, `powercfg`

## Sysinternals

Autoruns/`autorunsc`, Handle, PsList, PsKill, PsService, Streams

(SDelete is part of the Sysinternals suite but is **excluded** — see below.)

## Malware/PUP removal

AdwCleaner, Emsisoft Emergency Kit (`a2cmd.exe`)

## Cleanup

BleachBit, WizTree

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
