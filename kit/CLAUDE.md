# PC Repair Kit — instructions

You are running unattended, with `--dangerously-skip-permissions`, directly
on the bare Windows host of a machine owned by the user or their family.
There is no human watching this session and no approval gate — `AskUserQuestion`
is denied by the harness regardless of what you pass it, so do not attempt to
pause and wait for one. **This file is the only safety boundary you have.**
Stay inside it.

## Before anything else

1. Confirm you are running from the USB kit root (this file, `scripts\`,
   `tools\`, `config\` should all be siblings of wherever you were invoked).
   If they aren't, stop — you are not running the kit correctly and should
   not proceed with any repair action.
2. Run `scripts\Test-SafeMode.ps1`. It tells you whether this is normal mode
   or Safe Mode with Networking. Remember the answer — several steps below
   branch on it.
3. Run the three pipeline steps below, in order, before any diagnosis or
   repair action. Do not skip any of them, and do not reorder them.

## Pipeline (mandatory, every session)

### 1. Back up user data

Run `scripts\00-Backup-UserData.ps1`. This copies the current user's
profile (Documents, Desktop, Pictures, Downloads — see the script for the
exact list) to `backups\` on this USB. Wait for it to complete and check its
exit code before continuing. If it fails, **stop and do not proceed to any
destructive step** — report the failure in the run transcript and end the
session. A restore point covers system state only; this backup is the only
protection for the family's actual files, and nothing below is worth
running without it having succeeded.

### 2. Restore point (normal mode only)

If `Test-SafeMode.ps1` reported normal mode, run
`scripts\01-New-RestorePoint.ps1`. It sets the
`SystemRestorePointCreationFrequency` registry override to `0` first — this
is required, because Windows silently skips restore-point creation if one
was made in the last 24 hours **and still reports success**, which would
otherwise leave you believing you have a rollback path you don't have. The
script verifies the restore point actually appears in
`Get-ComputerRestorePoint` afterward and reports failure if it doesn't —
trust that verification, not just the exit code.

If `Test-SafeMode.ps1` reported Safe Mode, **do not attempt
`Checkpoint-Computer`** — it fails by design in Safe Mode (VSS isn't in the
Safe Mode service allowlist). Instead run the same script with
`-SafeModeFallback`, which exports the registry hives you're likely to touch
and copies any config files you're about to modify, as a substitute you can
actually restore from by hand.

### 3. System inventory

Run `scripts\02-Get-SystemInventory.ps1`. It writes a JSON snapshot (OS
build, installed updates, drivers, disk health via CIM, running services,
startup items) to `logs\inventory-<timestamp>.json`. Read this before
diagnosing — it's cheaper and more reliable than re-deriving the same facts
tool-by-tool. **Use `Get-CimInstance`, never `wmic`** — WMIC was removed
from Windows 11 24H2/25H2 as of KB5120998 (2026-08-14) and will not be
present on any target machine you're likely to see.

## Tool whitelist — the only tools you may run

Everything below is bundled under `tools\` on this USB, fetched fresh from
each vendor and checksum-verified at build time — never download or install
anything else, even if it seems like it would help. If a repair genuinely
needs a tool that isn't on this list, that repair is out of scope for this
session: say so in the transcript and stop, rather than reaching for
`winget install` or a browser download.

**Built-in Windows:** `sfc`, `DISM`, `chkdsk`, `MpCmdRun.exe` (Defender),
`winget` (**normal mode only** — absent from the Safe Mode allowlist),
`cleanmgr`, `netsh`, `powercfg`

**Sysinternals** (`tools\sysinternals\`): Autoruns/`autorunsc`, Handle,
PsList, PsKill, PsService, SDelete, Streams

**Malware/PUP removal:** AdwCleaner (`tools\adwcleaner\`), Emsisoft
Emergency Kit / `a2cmd.exe` (`tools\emsisoft\`)

**Cleanup:** BleachBit (`tools\bleachbit\`), WizTree (`tools\wiztree\`)

**Disk health:** `smartctl` (`tools\smartmontools\smartctl.exe`)

**Network:** Ookla Speedtest CLI (`tools\speedtest\`)

**Crash/log analysis:** NirSoft suite (`tools\nirsoft\`) — BlueScreenView
etc.

### Explicitly forbidden, regardless of what seems useful in the moment

- **`verifier.exe`** — forces a BSOD by design when it finds a driver fault.
  Never run this unattended.
- **CCleaner** — not bundled. Use `cleanmgr` + BleachBit instead.
- **FRST** — not bundled. It's fixlist-driven and generates arbitrary
  registry/file/service edits with no schema constraining it; it exists for
  manual, human-reviewed use only, which this session is not.
- **`setup.exe /Auto Upgrade`** (in-place repair install) and **clean
  reinstall** — the bundled Windows ISO/WIM under `iso\` exists only as a
  `DISM /Source:` for `/RestoreHealth`. Do not use it to trigger a repair
  install or reinstall, even if `sfc`/`DISM` can't fully fix what's wrong.
  That's the ceiling of this session's authority — report what you found
  and stop.
- Anything not on the whitelist above, full stop — including any tool you
  might otherwise reach for from PATH, another drive, or the internet.

## Safe Mode operating notes

- Wi-Fi: use `netsh wlan connect name="<SSID>"` — the network flyout UI
  won't render (`NlaSvc` is absent), so a "no internet" indicator in the UI
  does not mean you're actually offline. Verify with
  `Test-NetConnection <host> -Port 443` instead of trusting the tray icon.
- `DISM /RestoreHealth` needs `/Source:<mounted iso\...wim> /LimitAccess` —
  Windows Update is unreachable.
- Do not attempt `winget`, Windows Update, MSI installs, or `schtasks` —
  none work in Safe Mode. If you need something to run after a reboot back
  into normal mode, use `RunOnce`, not Task Scheduler.
- Defender real-time protection is running even here. If a whitelisted tool
  gets quarantined, that's `scripts\03-Set-DefenderExclusions.ps1` not
  having covered it — note it in the transcript rather than trying to
  disable Defender outright.

## Logging

Everything you do is being transcript-logged to `logs\` on this USB by the
launcher — you don't need to duplicate that yourself. Do write a clear
narrative in your own output as you go (what you found, what you ran, what
changed) since the transcript is the only record a family member or the
USB's owner will have of what happened here.

## When you're done

Summarize: what was backed up and where, whether a restore point (or Safe
Mode fallback) exists and where, what you diagnosed, what you fixed, and
anything you found but explicitly did not act on because it was outside the
whitelist. End the session cleanly rather than leaving background tasks
running.
