# Getting the bundled tools (for the full build)

The kit's *built-in* Windows tools (sfc, DISM, chkdsk, Defender, manage-bde,
pnputil, netsh, powercfg, winget…) need nothing — they're on every target
machine. The **bundled** third-party tools below add the malware, cleanup,
disk-health, driver, and crash-analysis capabilities.

**Most of them now download automatically.** `Build-Kit.ps1` fetches them from
verified direct URLs in [`scripts/tool-manifest.json`](scripts/tool-manifest.json)
(following redirects, sending a browser user-agent), so for a normal full build
you don't have to stage anything — just run the build with an internet
connection. Only **three** tools can't be auto-fetched and must be staged by
hand; they're listed at the bottom.

## What auto-fetches (nothing to do)

| Tool | Version behavior | Checksum |
|---|---|---|
| **Sysinternals Suite** | rolling (stable URL) | TOFU — hash logged at build |
| **Microsoft Safety Scanner (MSERT)** | rolling, expires ~10 days | TOFU — fetch fresh near deploy |
| **AdwCleaner** | rolling (stable URL) | TOFU — hash logged |
| **BleachBit 6.0.2 (portable)** | version-pinned | **pinned** (matches vendor sha256sum) |
| **WizTree 4.32 (portable)** | version-pinned | **pinned** |
| **Ookla Speedtest CLI 1.2.0** | version-pinned | **pinned** |
| **BlueScreenView (x64)** | rolling (stable URL) | TOFU — hash logged |
| **Snappy Driver Installer Origin 2.0.3.886** | version-pinned | **pinned** |
| **Win11Debloat (tag 2026.08.24)** | pinned tag | TOFU — GitHub archives aren't byte-stable |
| **O&O ShutUp10++** | rolling (stable URL) | TOFU — hash logged |

*Checksum rule:* a **version-pinned** URL carries a real pinned SHA-256 — when
the vendor bumps the version the old URL 404s and the build skips it gracefully,
so the pin never causes a false abort. A **rolling** URL (or a GitHub archive,
which GitHub regenerates and isn't byte-stable) uses "unpinned" TOFU: the bytes
change in place under a fixed URL, so a pin would hard-fail the build on the
vendor's next refresh. Build-Kit always logs the actual SHA-256 it shipped.

**When a version-pinned URL 404s** (BleachBit / WizTree / Speedtest / SDIO /
Win11Debloat after a new release): the build just skips that one tool with a
warning. Either bump its `url` (and `sha256` for the pinned ones) in
`tool-manifest.json` to the current release, or stage the file yourself (below).
Staging always overrides the URL.

## Optional overrides / add-ons

- **Any tool:** drop a matching file into your staging folder and it wins over
  the URL — use this to pin a specific AdwCleaner/OOSU10 build, or to supply a
  tool when its pinned URL has rotated.
- **SDIO offline NIC recovery:** the auto-fetch gets the SDIO *tool* only. For
  offline network-driver recovery, also drop the **network** driverpack
  (`drivers\DP_*LAN*` / `*WLAN*`) into `staging\SDIO\` yourself — full packs are
  tens of GB; network-only is a few hundred MB.
- **O&O ShutUp10 profile:** add your curated `recommended.cfg` to staging to
  ship a default profile.

## What you must still stage by hand (3 tools)

These have no scriptable direct download to the shape the kit needs — each is an
installer or self-extractor that requires unpacking Build-Kit doesn't do. Make a
staging folder, e.g. `C:\Users\Scott\kit-staging`, prepare these into it, and
pass `-StagingDir` to the build. **All three are optional for a first full
build** — anything missing is simply skipped, and the agent is told (by
`CLAUDE.md`) to stop and report if a repair needs a tool that isn't present.

| Tool | Get it from | Prepare into staging as | How |
|---|---|---|---|
| **Emsisoft Emergency Kit** | `https://dl.emsisoft.com/EmsisoftEmergencyKit.exe` (~319 MB) | folder named `emsisoft` | It's a 7-Zip SFX; the kit needs the *extracted* tree. Run `7z x EmsisoftEmergencyKit.exe -oC:\EEK -y` (or run it once — unpacks to `C:\EEK`), then copy the `EEK` folder into staging renamed `emsisoft` (must contain `Run\a2cmd.exe`). `a2cmd.exe` needs `a2cmd /u` once online to update signatures. |
| **smartmontools** | `https://sourceforge.net/projects/smartmontools/files/smartmontools/7.5/smartmontools-7.5.win32-setup.exe/download` | `smartctl.exe` (+ its DLLs) | No portable build exists — only the NSIS installer. Extract it: `7z x smartmontools-7.5.win32-setup.exe` → `bin\smartctl.exe`, or silent-install `...setup.exe /S` then copy from `%ProgramFiles%\smartmontools\bin\`. Stage `smartctl.exe` and the DLLs beside it. |
| **cdb / Debugging Tools** | Windows SDK bootstrapper `https://go.microsoft.com/fwlink/?linkid=2376217` | folder named `windbg` | No direct `cdb.exe`. Run `winsdksetup.exe /features OptionId.WindowsDesktopDebuggers /quiet` (or `/layout <dir>` offline), then copy `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\` (cdb.exe + `dbgeng.dll`/`dbghelp.dll`…) into staging renamed `windbg`. Heaviest/optional — skip for a first full build. |

## The Windows ISO

The full build also wants a Windows install ISO, whose `install.wim` becomes
the offline `/Source:` for `DISM /RestoreHealth` (see `docs/iso-role.md`).
Download the current Windows 11 ISO from Microsoft
(microsoft.com/software-download/windows11) and note its path.

## Then build

```powershell
git pull
# Simplest full build — everything auto-fetches, no staging:
.\scripts\Build-Kit.ps1 -UsbRoot D:\ -IsoPath C:\path\to\Windows11.iso

# Or add the three staging-only tools (and any overrides):
.\scripts\Build-Kit.ps1 -UsbRoot D:\ -StagingDir C:\Users\Scott\kit-staging -IsoPath C:\path\to\Windows11.iso
```

Build-Kit will: fetch each tool with a URL (logging SHA-256, verifying the
pinned ones), prefer any staged copy, skip anything unavailable with a warning,
extract the ISO's `install.wim` into `iso\`, then run the build gate
(`claude.exe --version` from the USB). The tail tells you how many tools were
staged vs fetched vs skipped.
