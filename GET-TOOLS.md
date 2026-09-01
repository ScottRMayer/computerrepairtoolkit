# Getting the bundled tools (for the full build)

The kit's *built-in* Windows tools (sfc, DISM, chkdsk, Defender, manage-bde,
pnputil, netsh, powercfg, winget…) need nothing — they're on every target
machine. The **bundled** third-party tools below add the malware, cleanup,
disk-health, driver, and crash-analysis capabilities. Most of these vendors
don't publish stable download URLs, so the reliable way to source them is:

1. Download each from its vendor page (you get the current, authentic build).
2. Drop it into one **staging folder** with the filename/shape shown below.
3. Run the full build pointing at that folder — Build-Kit copies/extracts each
   onto the drive and records its SHA-256.

Make a staging folder, e.g. `C:\Users\Scott\kit-staging`, and put these in it.

| Tool | Get it from | Put in staging as | Notes |
|---|---|---|---|
| **Sysinternals** | download.sysinternals.com/files/SysinternalsSuite.zip | `SysinternalsSuite.zip` | Or skip — it auto-fetches from that stable URL. |
| **Microsoft Safety Scanner** | microsoft.com/wdsi/products/scanner (64-bit) | `msert.exe` | Or skip — auto-fetches. Expires ~10 days, so fetch fresh near deploy. |
| **AdwCleaner** | malwarebytes.com/adwcleaner | `adwcleaner.exe` | Single portable exe. |
| **Emsisoft Emergency Kit** | emsisoft.com/en/emergency-kit/ | folder named `emsisoft` | Run the downloaded EEK once; it self-extracts (default `C:\EEK`). Copy that `EEK` folder into staging and rename it `emsisoft` (must contain `Run\a2cmd.exe`). |
| **BleachBit (portable)** | bleachbit.org/download → "portable" zip | `BleachBit-*-portable.zip` | Has `bleachbit_console.exe`. |
| **WizTree (portable)** | diskanalyzer.com → portable zip | `wiztree_*_portable.zip` | Has `WizTree64.exe`. |
| **smartctl** | builds.smartmontools.org (or install smartmontools) | `smartctl.exe` (+ any DLLs beside it) | No portable build. Easiest: install smartmontools on your PC, copy `bin\smartctl.exe` from its install dir into staging. |
| **Ookla Speedtest CLI** | speedtest.net/apps/cli → Windows | `ookla-speedtest-*-win64.zip` | Version-specific; stage the current zip. |
| **BlueScreenView (NirSoft)** | nirsoft.net/utils/blue_screen_view.html | `bluescreenview*.zip` | Just this one utility. |
| **Snappy Driver Installer Origin** | glenn.delahoy.com/snappy-driver-installer-origin | `SDIO_*.zip` | For offline NIC recovery, also drop the network driverpack under `staging\SDIO\drivers\` (network-only, a few hundred MB). |
| **Win11Debloat** | github.com/Raphire/Win11Debloat/releases (a pinned release) | `Win11Debloat-*.zip` | Source zip of a release tag. |
| **O&O ShutUp10++** | oo-software.com/en/shutup10 | `OOSU10.exe` | Optional: add your `recommended.cfg` to staging too. |
| **cdb / Debugging Tools** | Windows SDK → "Debugging Tools for Windows" | folder named `windbg` | Heaviest/optional. Install the SDK feature, copy the x64 Debugging Tools folder, rename it `windbg`. Skip for a first full build. |

You do **not** need all of them for a first full build — anything missing is
simply skipped, and the agent is told (by `CLAUDE.md`) to stop and report if a
repair needs a tool that isn't present. Start with the malware + cleanup set
(AdwCleaner, Emsisoft, BleachBit, MSERT, Sysinternals) and add the rest later.

## The Windows ISO

The full build also wants a Windows install ISO, whose `install.wim` becomes
the offline `/Source:` for `DISM /RestoreHealth` (see `docs/iso-role.md`).
Download the current Windows 11 ISO from Microsoft
(microsoft.com/software-download/windows11) and note its path.

## Then build

```powershell
git pull
.\scripts\Build-Kit.ps1 -UsbRoot D:\ -StagingDir C:\Users\Scott\kit-staging -IsoPath C:\path\to\Windows11.iso
```

Build-Kit will: stage each tool it finds (logging SHA-256), skip any you
didn't download, extract the ISO's `install.wim` into `iso\`, then run the
build gate (`claude.exe --version` from the USB). The tail tells you how many
tools were staged vs skipped.
