# Symptom-first repair playbook

The agent is handed a *complaint* ("it's slow", "Start menu won't open", "no
printer"), not a tool. This playbook is how a good technician reasons:
**symptom → cheapest safe test → fix → escalate**, with the reversible option
first and a STOP-to-human at the end of every ladder. `kit/CLAUDE.md` carries a
condensed version and points here; exact commands live in
[`docs/tool-invocations.md`](tool-invocations.md).

## Rules that apply to every class

1. **Two mandatory gates run first, after inventory, before any deep repair:**
   - **Malware-indicator gate.** Malware causes slowness, crashes, WU failure,
     and network death, and re-breaks fixes the instant you apply them. Sweep
     first: `Get-MpThreatDetection`, `autorunsc` unsigned/unverified entries,
     hosts/proxy/DNS hijack, firewall/RTP off. If indicators are found, run the
     malware class before anything else.
   - **Disk-health gate.** `smartctl -H` the system drive. A write-heavy repair
     (`chkdsk /r`, DISM, defrag) on a SMART-failing drive can finish killing it
     and lose data that was still readable. If the drive is failing, STOP —
     image first, repair never.
2. **Reversible first, always:** quarantine over delete, disable over remove,
   rename over delete (`.old`), targeted over blanket. The residue (`.old`
   folders, quarantine, disabled items) *is* the rollback path.
3. **Never reboot mid-session** — a reboot ends the cloud session. Queue
   reboot-requiring fixes, apply them last where they don't sever the run, and
   report "reboot required". Use `RunOnce`, never `schtasks`, for post-reboot.
4. **Connectivity-affecting network fixes go last** and never the ones that cut
   the agent's own uplink (winsock/IP-stack resets are reboot-queued).
5. **Hardware tripwire — STOP and name the hardware, don't keep repairing in
   software:** SMART FAIL or climbing reallocated/pending/uncorrectable
   sectors; bugcheck `0x124`/WHEA events; a prior Windows Memory Diagnostic
   failure; or corruption/crashes that recur after a clean SFC/DISM. Failing
   RAM and dying disks imitate software rot perfectly — the signature failure
   of unattended repair is chasing them forever.

## Check-only vs. Check-and-fix

The launcher's `-RepairMode` sets the posture (in `session-context.json`):
- **Check** — diagnose fully, change nothing, report what you *would* do and
  why. The safe first run. Backup and restore point may still be taken.
- **Fix** — the full autonomous repair (default).
In Check mode, run every "detect" step below and none of the "fix" steps.

---

## The classes

### 1. General slowness
- **Detect:** `Get-CimInstance Win32_Processor` load; top processes by CPU/RAM;
  `autorunsc` startup bloat; disk free space (`Win32_LogicalDisk`); `powercfg
  /energy`; is it a HDD not SSD (`smartctl`/`MediaType`); Windows Search /
  SysMain thrash; pending WU churn.
- **Fix (reversible):** disable (not remove) heavy startup items; `cleanmgr`
  + BleachBit `--preview`→`--clean`; DISM `/StartComponentCleanup`; set high-
  performance power plan; Win11Debloat `-RunDefaults -CreateRestorePoint` if
  bloatware-laden. Malware gate first — slowness is often infection.
- **Escalate:** HDD → recommend SSD; SMART weak → hardware tripwire.

### 2. Malware / adware / PUPs / browser hijack
- **Detect:** `Get-MpThreatDetection`; MSERT `/f /q`; `a2cmd` scan; AdwCleaner;
  `autorunsc` unsigned; hosts file, WinINET+WinHTTP proxy, DNS servers; browser
  shortcuts appended with a URL; unexpected browser extensions; scheduled tasks
  with odd names.
- **Fix (reversible):** **quarantine, never delete** (AdwCleaner `/eula /clean
  /noreboot`, `a2cmd /quarantine=`); clear proxy/hosts/DNS hijack (connectivity
  ladder already does the anthropic-specific part); reset browser shortcut
  targets; disable malicious extensions/tasks. **Write the
  backup-needs-scan.flag** — the pre-repair backup may carry infected files.
- **Escalate:** rootkit signs (detections reappear, OS/observed mismatch) →
  recommend Defender Offline (reboots; human step). Ransomware note in progress
  → STOP, don't touch, preserve evidence.

### 3. Windows Update broken
- **Detect:** `Get-WinEvent` WindowsUpdateClient errors; last successful update;
  stuck `wuauserv`; `DISM /ScanHealth`.
- **Fix:** DISM `/RestoreHealth` (+`/Source:` if WU unreachable) then `sfc`;
  then the SoftwareDistribution/catroot2 reset (stop services → rename → start →
  `UsoClient StartScan`). Normal mode only. See tool-invocations.md.
- **Escalate:** repeated component-store corruption after a clean pass →
  possible disk/RAM (tripwire).

### 4. No/failed boot
→ [`docs/offline-repair-playbook.md`](offline-repair-playbook.md). Not an
autonomous class — the agent can't run on a machine that won't boot.

### 5. Disk errors / full disk / failing drive
- **Detect:** `smartctl -a` (health, reallocated/pending sectors, wear); `fsutil
  dirty query`; free space; `chkdsk` read-only scan.
- **Fix:** if SMART healthy — `cleanmgr`, BleachBit, WinSxS cleanup, WizTree to
  find space hogs, move/queue `chkdsk /f` (reboot). If SMART failing — **STOP**,
  hardware tripwire, recommend imaging + replacement. Never `chkdsk /r` a dying
  drive.

### 6. Driver problems
- **Detect:** `Get-CimInstance Win32_PnPEntity` with `ConfigManagerErrorCode ≠ 0`;
  driver error events; Code 28 (no driver) / Code 43 (device reported failure).
- **Fix:** `pnputil /enum-drivers`; for a known-bad package `pnputil
  /delete-driver oemNN.inf /uninstall` (confirm the OEM number); SDIO
  `-script:` against the offline driverpack for missing drivers (great after a
  reinstall with no NIC/GPU driver). Queue reboot if required.
- **Escalate:** Code 43 that survives a driver reinstall → likely failing
  device (hardware).

### 7. Start menu / Store / built-in apps broken
- **Detect:** which package is broken; `Get-AppxPackage` state; relevant event
  logs.
- **Fix:** targeted Appx re-register (StartMenuExperienceHost etc.) before the
  noisy blanket re-register; `sfc`/`DISM` if system files implicated. Normal
  mode. See tool-invocations.md.

### 8. Network dead
- **Detect:** `Test-NetConnection`; adapter status; DNS resolve; proxy/hosts;
  driver present (Code 28 NIC).
- **Fix (connectivity-last, non-self-severing):** `ipconfig /flushdns`, release/
  renew, fix DNS/proxy/hosts hijack, re-enable adapter, SDIO for a missing NIC
  driver. **Queue** (never run live) `netsh winsock reset` / `netsh int ip
  reset` — both need reboot and can cut the agent's own uplink.

### 9. Frequent crashes / BSOD
- **Detect:** `Get-WinEvent` BugCheck 1001 + Kernel-Power 41; WHEA events
  17/18/19; enumerate `%SystemRoot%\Minidump\*.dmp`; **`cdb.exe -z <dmp> -c
  "!analyze -v"`** for the faulting module; NirSoft BlueScreenView for a quick
  culprit.
- **Fix:** if a driver is named — update/roll back that driver (class 6); if
  system files — `sfc`/`DISM`. If `0x124`/WHEA or crashes survive a clean SFC/
  DISM — **hardware tripwire** (CPU/RAM/PSU/thermal), recommend MemTest86+
  (boot ISO) and stop chasing software.

### 10. Peripherals — printer / audio / webcam / Bluetooth
*(Added per the design-workshop completeness critic — the most common
bread-and-butter complaints, and previously unaddressed.)*
- **Printer detect/fix:** spooler service state (`Get-Service Spooler`);
  restart spooler; clear stuck queue (`%SystemRoot%\System32\spool\PRINTERS\*`
  with spooler stopped — reversible, it's just queued jobs); driver present;
  `Get-Printer`/`Get-PrinterPort`. Escalate a genuinely dead print subsystem to
  a driver reinstall (class 6).
- **Audio:** `Get-Service Audiosrv,AudioEndpointBuilder` running; restart them;
  default playback device present (`Get-PnpDevice -Class AudioEndpoint`); driver
  Code check. Reversible restarts first.
- **Webcam / Bluetooth:** `Get-PnpDevice -Class Camera`/`Bluetooth` status &
  error codes; **privacy toggle** (camera/mic access disabled in Settings is a
  frequent false "broken camera" — a registry/Settings read, reversible fix);
  driver reinstall if Code 28/43.

### 11. Bad / corrupt user profile
- **Detect:** `ProfileList` registry for `.bak`/`TEMP` profile entries;
  temp-profile logon events.
- **Fix:** this is high-risk — prefer **diagnosis + recommendation** over
  autonomous surgery. Renaming/rebuilding a profile risks data; do it only with
  the user-data backup confirmed and generally flag for a human.

### 12. Bloatware / telemetry (only if that's the complaint)
- **Fix:** Win11Debloat `-Silent -RunDefaults -CreateRestorePoint` (reversible,
  GP-based); optionally O&O ShutUp10 "recommended" cfg. Never aggressive presets
  on a family machine — see tool-invocations.md.

### 13. Post-repair verification (every session)
- Re-run the cheap diagnostics that flagged the original complaint and confirm
  the change took. Note what needs a reboot to fully apply. Write
  `repair-summary.json` honestly (`outcome`, what changed, needs_a_person).

---

## What the agent must not turn into

- A stress-test rig (Prime95/FurMark/OCCT) on a possibly-failing PC — those can
  cause thermal damage; out of the autonomous path.
- A reinstaller — no wipe/repair-install without explicit human decision (see
  [`docs/iso-role.md`](iso-role.md)).
- A persistence author — the PreToolUse guard blocks Defender-disable, exclusion
  adds, and Run/IFEO writes; if you reach for one, the fix is out of scope.
