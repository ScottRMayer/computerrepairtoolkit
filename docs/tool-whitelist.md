# Tool whitelist

23 tools + 2 pipeline steps. This is the authoritative list — `CLAUDE.md`
restates it for the agent, but this file is what to edit first; keep both in
sync.

## Pipeline steps (every session, in order)

1. **User-data backup** — [`kit/scripts/00-Backup-UserData.ps1`](../kit/scripts/00-Backup-UserData.ps1)
2. **Restore point** (normal mode only, frequency override set first) —
   [`kit/scripts/01-New-RestorePoint.ps1`](../kit/scripts/01-New-RestorePoint.ps1)
3. **`Get-CimInstance` system inventory** —
   [`kit/scripts/02-Get-SystemInventory.ps1`](../kit/scripts/02-Get-SystemInventory.ps1)

`CLAUDE.md` instructs the agent to treat these as non-negotiable prerequisites,
run in this order, before any diagnostic or repair action.

## Built-in Windows

`sfc`, `DISM`, `chkdsk`, `MpCmdRun.exe` (Defender), `winget` *(normal mode
only — see [`docs/safe-mode-constraints.md`](safe-mode-constraints.md))*,
`cleanmgr`, `netsh`, `powercfg`

## Sysinternals

Autoruns/`autorunsc`, Handle, PsList, PsKill, PsService, SDelete, Streams

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

## Explicitly excluded

| Tool | Why |
|---|---|
| `verifier.exe` | Forces a BSOD by design when it finds a driver fault — wrong for unattended use. |
| CCleaner | CLI only does disk cleanup (registry cleaner is GUI-only); `cleanmgr` + BleachBit cover it; supply-chain-compromise history (2017). |
| FRST | Fixlist-driven — whatever drives it generates arbitrary registry/file/service edits with no schema constraining it. Manual, human-reviewed use only. |
| `setup.exe /Auto Upgrade` (in-place repair install) | See [`docs/iso-role.md`](iso-role.md) — deliberately left out pending explicit approval, not because it's unsafe in principle. |
| Clean reinstall | Same — an escalation tier, not part of the autonomous whitelist. |

## Portable builds confirmed available

BleachBit, WizTree, Emsisoft Emergency Kit, NirSoft utilities, Sysinternals
Suite, AdwCleaner. Everything else in the whitelist is either built into
Windows or, for `smartctl`, extracted once at build time.
