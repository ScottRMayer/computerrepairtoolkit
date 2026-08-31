# Tool invocations

Exact command lines for every whitelisted tool. `kit/CLAUDE.md` points the
agent here so it runs known-good invocations instead of inferring them from
`--help` on a machine that's already broken.

**Confidence markers:**

- ✅ **Verified** — checked against vendor documentation, with the source
  linked. Date checked in the section heading.
- ⚠️ **Unverified** — plausible but not confirmed in this repo. Run the tool
  with `--help` / `/?` on the build machine and correct this file before
  trusting it unattended.

## The unattended killers — read this first

Several tools show a EULA or consent dialog on first run. An unattended
agent doesn't fail on these, it **hangs forever**, holding the session open
with nobody to click OK. These flags are not optional:

| Tool | Required flag | What happens without it |
|---|---|---|
| Every Sysinternals tool | `-accepteula` | EULA dialog, blocks indefinitely |
| Ookla Speedtest | `--accept-license --accept-gdpr` | License prompt, blocks |
| AdwCleaner | `/eula` | EULA prompt, blocks |

A second class of hazard is tools that **reboot on completion**. A reboot
kills the agent mid-session and may orphan the transcript:

| Tool | Required flag |
|---|---|
| AdwCleaner | `/noreboot` |

---

## Built-in Windows

No download, no checksum, no Defender exclusion, and available in Safe Mode
unless noted. See [`docs/safe-mode-constraints.md`](safe-mode-constraints.md).

### System file and image repair

```powershell
sfc /scannow
DISM /Online /Cleanup-Image /ScanHealth
DISM /Online /Cleanup-Image /CheckHealth
DISM /Online /Cleanup-Image /RestoreHealth /Source:WIM:E:\iso\install.wim:1 /LimitAccess
```

`/Source:` + `/LimitAccess` is **required in Safe Mode** (Windows Update is
unreachable) and advisable in normal mode on a broken machine. The `:1`
suffix is the image index within the WIM. Without a matching-version source
`/RestoreHealth` is a no-op — detect that and report it rather than
believing the repair succeeded.

### Disk

```powershell
chkdsk C:                        # read-only check, safe any time
chkdsk C: /scan                  # online scan, no dismount
Repair-Volume -DriveLetter C -Scan
fsutil dirty query C:            # is the dirty bit set?
```

`chkdsk /f` and `/r` require a dismount or reboot on the system volume.
**Do not schedule a boot-time chkdsk unattended** — it can run for hours
with no way to observe or interrupt it, and the agent won't survive the
reboot to report on it. Report the need instead.

### BitLocker — check before touching anything

```powershell
manage-bde -status
manage-bde -status C:
```

⚠️ Read-only. **Run this during inventory, before any repair action.** If a
volume is encrypted and protection is on, boot-config or system-volume work
can trigger a recovery-key demand at next boot. On a family machine where
nobody knows where the key is, that converts a repair into permanent data
loss. If BitLocker is on, say so prominently and treat anything touching
boot configuration as out of scope.

`manage-bde -off` (decrypt) and `-forcerecovery` are **deny-listed** — see
[`docs/decisions.md`](decisions.md).

### Memory

```powershell
# Read results of any PRIOR memory diagnostic - free, zero risk:
Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Microsoft-Windows-MemoryDiagnostics-Results']]]" -MaxEvents 10
```

⚠️ `mdsched.exe` schedules the Windows Memory Diagnostic, **but it requires
a reboot to run**, which kills the agent session. Do not trigger it
unattended. Read prior results with the command above, and if a memory test
is warranted, recommend it in the summary for a human to run.

Failing RAM produces crashes and file corruption that look exactly like
software rot. If inventory shows unexplained corruption, flag memory as a
candidate rather than repeatedly "repairing" software symptoms.

### Drivers

```powershell
pnputil /enum-drivers                     # list third-party driver packages
pnputil /delete-driver oemNN.inf /uninstall   # remove a bad driver package
```

⚠️ Removing a driver package is a legitimate repair for a known-bad driver.
Confirm the OEM number from `/enum-drivers` first — the numbering is
machine-specific and not stable across machines.

### Permissions

```powershell
icacls "C:\path\to\thing"                 # view current ACLs
icacls "C:\path\to\thing" /reset          # reset to inherited
```

⚠️ Scope this **narrowly**. `icacls C:\ /reset /T` recursively rewrites ACLs
across the entire system volume and can leave a machine less secure or
unbootable. Target specific paths you have evidence about.

### Network

```powershell
ipconfig /all
ipconfig /flushdns
ping -n 4 1.1.1.1
nslookup example.com
tracert -h 15 1.1.1.1
Test-NetConnection api.anthropic.com -Port 443
netsh wlan show profiles
netsh wlan connect name="SSID"
netsh int ip reset                        # requires reboot to fully apply
netsh winsock reset                       # requires reboot to fully apply
```

In Safe Mode the network flyout UI doesn't render (`NlaSvc` absent), so
tray indicators lie. Trust `Test-NetConnection`, not the icon.

### Defender

```powershell
& "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -Scan -ScanType 1   # quick
& "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -Scan -ScanType 2   # full
& "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -SignatureUpdate
Get-MpThreatDetection
Get-MpComputerStatus
```

`-SignatureUpdate` **fails in Safe Mode** (needs the Windows Update stack).

### Power, cleanup, packages

```powershell
powercfg /batteryreport /output C:\Temp\battery.html
powercfg /energy /output C:\Temp\energy.html /duration 60
powercfg /sleepstudy /output C:\Temp\sleep.html
cleanmgr /sagerun:1                       # requires prior /sageset
winget upgrade --all --silent --accept-package-agreements --accept-source-agreements
```

`winget` is **normal mode only** — AppX/ClipSVC/TokenBroker are absent from
the Safe Mode allowlist.

---

## Sysinternals — ✅ verified (2026-08-31)

**Every one of these needs `-accepteula`** or it blocks on a dialog.

```powershell
autorunsc.exe -accepteula -a * -c -h -s -nobanner    # all entries, CSV, hashes, verify signatures
handle.exe   -accepteula -nobanner -p <pid>          # what a process has open
handle.exe   -accepteula -nobanner "C:\locked\file"  # who holds this file
pslist.exe   -accepteula -nobanner
pskill.exe   -accepteula -nobanner <pid|name>
psservice.exe -accepteula query <servicename>
streams.exe  -accepteula -nobanner -s "C:\path"      # alternate data streams
```

`handle.exe` is the correct tool for a **locked or in-use file**: identify
the holding process, deal with that, then delete normally. SDelete is *not*
a force-delete tool and is deliberately excluded — see
[`docs/tool-whitelist.md`](tool-whitelist.md#why-sdelete-was-removed).

---

## Malware and PUP removal

### Microsoft Safety Scanner (MSERT) — ✅ verified (2026-08-31)

```powershell
msert.exe /f /q
# Log: %SYSTEMROOT%\debug\msert.log  -- the ONLY output with /q
```

`/f` = full scan, `/q` = quiet (no window, no summary). Source:
[Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/safety-scanner-download).

Microsoft doesn't publish a complete CLI reference; only `/Q` and `/F` are
reliably attested. **The binary expires ~10 days after download** because
signatures are bundled into it — this is why it's fetched fresh at build
time. If a scan reports the binary as expired, say so rather than treating
a stale result as clean.

Independent engine from the Defender already on the machine, so it's a
genuine second opinion rather than a repeat of the same verdict.

### AdwCleaner — ✅ verified (2026-08-31)

```powershell
adwcleaner.exe /eula /clean /noreboot
# Logs:      C:\AdwCleaner\Logs
# Quarantine: C:\AdwCleaner\Quarantine
```

Source: [Malwarebytes Help Center](https://help.malwarebytes.com/hc/en-us/articles/31589247152027-Command-line-options-for-AdwCleaner).

**Do not use `/preinstalled`.** It removes OEM preinstalled software, which
on a family machine may include things they actually use. That's a judgment
call for a human, not an unattended agent.

`/noreboot` is required — without it AdwCleaner restarts the machine on
completion and the session dies mid-run.

### Emsisoft Emergency Kit — ✅ verified (2026-08-31)

```powershell
a2cmd.exe /f="C:\" /quarantine="E:\logs\quarantine"    # scan, quarantine detections
a2cmd.exe /quarantinelist                              # list quarantined items
a2cmd.exe /quarantinerestore=<n>                       # restore by index (0-based)
```

Source: [Emsisoft Commandline Scanner](https://www.emsisoft.com/en/commandline-scanner/).

**Prefer `/quarantine=` over `/d` / `/delete`.** Quarantine is reversible;
deletion isn't, and a false positive on a family member's file is
unrecoverable. This is the same reasoning that removed SDelete from the
whitelist. `/quarantinerestore` is what makes a mistake fixable — note the
quarantine path in your summary so a human can use it.

Run `a2cmd.exe` with no parameters to print the full option list.

---

## Cleanup

### BleachBit — ✅ verified (2026-08-31)

```powershell
bleachbit_console.exe --list-cleaners        # what's available on this machine
bleachbit_console.exe --preview <cleaner.option>   # dry run - ALWAYS do this first
bleachbit_console.exe --clean <cleaner.option>     # actually delete
```

Source: [BleachBit CLI docs](https://docs.bleachbit.org/doc/command-line-interface.html).

**Always `--preview` before `--clean`** and report what it would remove.
Note that BleachBit includes shred/overwrite options — those make deletion
unrecoverable, so prefer ordinary cleaners and don't reach for shredding.

### WizTree

```powershell
wiztree.exe <drive> /export="E:\logs\wiztree.csv" /admin=1
```

⚠️ Unverified. Confirm with `wiztree.exe /?` on the build machine.

---

## Disk health

### smartctl

```powershell
smartctl.exe --scan                  # enumerate devices
smartctl.exe -a /dev/sda             # full SMART data
smartctl.exe -H /dev/sda             # health summary only
```

⚠️ Unverified on Windows device naming — smartctl uses `/dev/sdX` style
names on Windows too, but confirm with `--scan` first rather than assuming
a mapping. Needs no service to run.

---

## Network throughput

### Ookla Speedtest CLI

```powershell
speedtest.exe --accept-license --accept-gdpr -f json
```

⚠️ Unverified flag spelling, but the accept flags are required — without
them the tool prompts on first run and blocks.

---

## Crash and log analysis

### NirSoft

```powershell
BlueScreenView.exe /scomma "E:\logs\bluescreens.csv"
```

⚠️ Unverified. NirSoft tools share a convention of `/stext`, `/scomma`, and
`/shtml` for text, CSV, and HTML export respectively. Confirm per-utility.

NirSoft binaries are routine HackTool/PUA detections — this is why
`03-Set-DefenderExclusions.ps1` exists.

---

## Candidates not yet added

**Sophos Scan & Clean** — free, no-install, portable second-opinion scanner
that runs from USB. Its command-line parameters are documented at
[Sophos KB 124061](https://community.sophos.com/kb/en-us/124061), which
returned no readable content when checked on 2026-08-31. Deliberately **not
whitelisted** until its switches are verified: adding a tool to an
unattended kit without knowing how to invoke it is the exact failure this
document exists to prevent. Verify the KB and it's a good addition.

Explicitly rejected, with reasons, in
[`docs/tool-whitelist.md`](tool-whitelist.md): Kaspersky KVRT (US Commerce
Department prohibition), HWiNFO (CLI reporting is a paid feature),
CrystalDiskInfo (no native CLI), Malwarebytes Toolset (licensed product).
