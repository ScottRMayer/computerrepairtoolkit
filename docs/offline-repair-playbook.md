# Offline / won't-boot repair playbook

The single biggest structural limit of this kit (per
[`docs/ecosystem-catalog.md`](ecosystem-catalog.md)): **it runs on a booted
Windows.** The Claude agent is a cloud client — it needs a running OS that can
reach `api.anthropic.com`. If the target won't boot, the autonomous agent
cannot run at all. This tier is what you fall back to then.

## The honest shape of "won't boot"

There is no autonomous fix here, for a hard reason: no OS → no `claude.exe` →
no agent. So this tier is:

1. A **bootable recovery environment** carried on the same USB (via Ventoy), so
   you can get *a* shell and *a* toolset on a dead machine.
2. A **deterministic offline-repair procedure** (this document + the script
   `Invoke-OfflineRepair.ps1`) that a human runs from that environment — or
   that the agent runs *later*, once the machine boots into normal Windows
   again and Claude can drive it.

The division of labor: **offline layer gets the machine bootable again;
the autonomous agent takes over once it boots.** Don't expect the agent to
repair a machine it can't run on.

## Making the USB bootable (Ventoy)

[Ventoy](https://github.com/ventoy/Ventoy) (GPL-3.0) turns the USB into a
multiboot drive: you drop `.iso`/`.wim` files onto it and pick one at boot,
while the rest of the drive stays a normal data partition holding the kit.

Build-time (on the owner's machine, once):

1. Install Ventoy to the USB with its official installer (this is a manual,
   interactive step — Ventoy formats the drive, so do it **before**
   `Build-Kit.ps1`, then build the kit onto the resulting exFAT/NTFS data
   partition).
2. Drop a **WinPE recovery ISO** into `\ISO\` on the Ventoy partition. Use a
   legitimate, free one — **Hiren's BootCD PE** (freeware; redistributes only
   freeware/OSS) is the standard choice. Do **not** use Sergei Strelec's or
   Medicat images — they bundle pirated software and/or carry malware reports
   (see [`docs/ecosystem-catalog.md`](ecosystem-catalog.md)).
3. Optionally drop a **MemTest86+** ISO (GPLv2) for offline RAM testing, and a
   matching **Windows install ISO** (its `install.wim` is the `/Source:` for
   offline DISM — see below and [`docs/iso-role.md`](iso-role.md)).

At the bedside, if the machine won't boot: boot it from the USB (F12/F2/Del
boot menu varies by maker), pick the WinPE ISO in the Ventoy menu, and you land
in a WinPE desktop with a command prompt and disk tools.

## The offline-repair procedure

Run from the WinPE command prompt. `Invoke-OfflineRepair.ps1` (on the kit
partition) automates the safe, standard sequence below with logging; this
section is what it does and the manual fallback if you'd rather drive it by
hand. **Assessment first, changes only with `-Fix`.**

Throughout, `C:` is used for the broken Windows volume and `S:` for its EFI
system partition, but **in WinPE the drive letters are usually different** —
always confirm which volume actually holds `\Windows\System32\config` first
(the script auto-detects this; by hand, check each letter).

### 1. Boot configuration (BCD) — the most common "won't boot"

Standard, well-established sequence (from WinRE these are the classic `bootrec`
steps; from generic WinPE, `bcdboot` is the portable equivalent):

```
bootrec /scanos          # find Windows installs (WinRE)
bootrec /fixmbr          # legacy BIOS/MBR boot code
bootrec /fixboot         # write a new boot sector (may need EFI mount first)
bootrec /rebuildbcd      # rebuild the boot store from detected installs
```

For UEFI machines, the robust rebuild is:

```
bcdboot C:\Windows /s S: /f UEFI
```

where `S:` is the mounted EFI System Partition (`mountvol S: /S` if needed).
This regenerates the boot files without wiping a working install.

### 2. System-file integrity — offline SFC and DISM

```
sfc /scannow /offbootdir=C:\ /offwindir=C:\Windows
DISM /Image:C:\ /Cleanup-Image /RestoreHealth /Source:WIM:D:\sources\install.wim:1 /LimitAccess
```

Offline DISM **needs a matching-version `install.wim`** as `/Source:` — Windows
Update is unreachable here. Point it at the Windows install ISO on the Ventoy
partition (`D:` in the example). A version mismatch makes DISM reject the
source; that's a no-op to detect and report, not a hard failure.

### 3. Registry — a bad driver/service/hive blocking boot

Loading a bad software/hardware config or a corrupt hive is a frequent boot
killer. **This is the most dangerous step and is NOT automated** — a wrong
edit here bricks boot harder. Manual, human-reviewed only:

```
reg load HKLM\OFF C:\Windows\System32\config\SYSTEM
# inspect/disable the suspect driver or service under HKLM\OFF\...
reg unload HKLM\OFF
```

If the whole hive is corrupt, Windows keeps recent backups in
`C:\Windows\System32\config\RegBack\` (may be empty on modern builds — the
automatic backup was disabled by default since Win10 1803; re-enabling it is a
normal-mode task the agent can do preventively). Restoring a RegBack hive is a
copy-over-the-broken-one operation done only with a file backup in hand.

### 4. Recent-change rollback

If a bad update/driver preceded the failure, WinRE's built-in **Startup Repair**
and **System Restore** (if a restore point exists) are the safest first moves —
try them from the recovery ISO's menu before hand-editing anything.

## After it boots again

Once these get the machine into normal Windows, **stop the manual work and run
the kit normally** (`Repair-This-PC`). The autonomous agent picks up from a
booting system: it can create a proper restore point, re-enable RegBack, finish
DISM against Windows Update, chase the root cause, and produce the report card.
The offline layer's job is done the moment Windows boots.

## What stays a human/hardware call

- **No POST / no display / no disk detected** — hardware; the USB can't help
  beyond MemTest86+ for RAM.
- **BitLocker-encrypted volume with no key** — offline edits will trigger a
  recovery prompt; you need the recovery key first. The kit checks BitLocker
  state during normal-mode inventory precisely so this is known *before* a
  drive is touched.
- **A failing disk** (SMART FAIL / reallocated sectors climbing) — image the
  drive off first; repair-in-place can finish killing it. Replacement, not
  repair.
