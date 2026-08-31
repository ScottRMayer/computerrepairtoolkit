# Safe Mode constraints

Only relevant when the kit falls back to Safe Mode; everything works
normally in normal mode (the default — see [`docs/decisions.md`](decisions.md)).

Verified directly from the registry service allowlists on Windows 11 25H2
build 26200.9278:

```
HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal
HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network
```

cross-checked against Microsoft documentation. **Not yet verified on
Windows 10** — if any target machine runs Windows 10, run
```powershell
reg query "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network"
```
on it before relying on any row below.

| Capability | Safe Mode w/ Networking | Note |
|---|---|---|
| `Checkpoint-Computer` (create restore point) | **FAILS** | VSS not in allowlist; MS docs: "This function cannot be called in safe mode" |
| Restoring an *existing* restore point | Works | But cannot be undone when done from Safe Mode |
| `sfc /scannow` | **Works** | Microsoft explicitly recommends running it here |
| `DISM /RestoreHealth` | **Needs `/Source:`** | Windows Update path unavailable — point it at the WIM on the USB with `/LimitAccess` |
| `DISM /ScanHealth`, `/CheckHealth` | Works | |
| Defender on-demand scan (`MpCmdRun -Scan`) | **Works** | `WinDefend` is in both allowlists |
| Defender **real-time protection** | **Also runs** | Filter driver is `Start=0`, loads before allowlist is consulted — plan Defender exclusions accordingly |
| Defender signature update | **FAILS** | Needs the WU stack — bundle the offline definition installer if signature freshness matters |
| Wi-Fi | **Works** | But use `netsh wlan connect name="SSID"` — the network flyout UI won't render (`NlaSvc` absent, expect false "no internet" indicators) |
| `winget` | **FAILS** (high-confidence inference, not directly confirmed) | AppX/ClipSVC/TokenBroker all absent |
| Windows Update, BITS | **FAIL** | Absent from allowlist |
| Windows Installer (MSI) | **FAILS** | Error 1084 |
| Task Scheduler | **FAILS** | Use `RunOnce`, not `schtasks`, for anything post-reboot |
| WMI / `Get-CimInstance` | **Works** | |
| Event Log / `Get-WinEvent` | **Works** | |
| Tools that load a kernel driver on demand (Procmon, Process Explorer) | **Likely fail** (inference, not confirmed) | Autoruns, handle, sigcheck, streams need no driver and are fine |
| Claude Code CLI itself | **Works** (by inference from its dependencies — see below) | No VSS/WU/MSI/Task Scheduler dependency; only needs a working shell + outbound HTTPS |

## Why Claude Code should work in Safe Mode

The CLI's only two runtime dependencies are a shell (PowerShell, present in
both Safe Mode variants) and outbound HTTPS to the Anthropic API. Neither
depends on anything in the "FAILS" rows above. This is an inference from the
allowlist, not a live test — confirm it as step one of
[`docs/verification-checklist.md`](verification-checklist.md) before relying
on the kit unattended in Safe Mode.

## Open verification items carried over from the original survey

- `winget` in Safe Mode is inference, not confirmed by a primary source.
  Verifiable in ~30 seconds by booting a VM into Safe Mode and running
  `winget --version`. Doesn't block the kit — `winget` is normal-mode-only
  in the tool whitelist anyway (see
  [`docs/tool-whitelist.md`](tool-whitelist.md)).
- Whether kernel-driver-dependent Sysinternals tools fail in Safe Mode is
  also inference. None of them are in the 23-tool whitelist, so this
  doesn't block the kit either — noted here only so it isn't silently
  forgotten if the whitelist is ever expanded.
