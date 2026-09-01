# Building the smoke-test drive

The one-page manual for proving the kit's load-bearing assumption before
investing in a full build: **does the copied `claude.exe` launch and
authenticate from a USB path on a machine that never had Claude installed?**

Everything else in this repo rests on that. Answer it for ~300 MB and 20
minutes before downloading 8 GB of tools and an ISO.

## The shape: build here, test there

- **Build machine** — your own Windows PC. It needs Claude Code installed
  (the build copies the binary *from* it), so it is NOT a valid test machine.
- **Test machine** — a *separate* Windows 10/11 box that has **never had
  Claude installed**. A throwaway VM with a snapshot is ideal (you can revert
  it). This is where the smoke test actually means something.

You also need: a USB stick (any size for the smoke drive — even 1 GB), and a
Claude Pro/Max subscription.

---

## Part A — on your build machine

### A1. Get the repo

```powershell
git clone https://github.com/ScottRMayer/computerrepairtoolkit
cd computerrepairtoolkit
```

### A2. Install Claude Code and mint a subscription token

```powershell
irm https://claude.ai/install.ps1 | iex     # skip if already installed
claude setup-token
```

`setup-token` opens a browser, you approve, and it prints a token starting
with `sk-ant-oat...`. **Copy it.** It's a ~1-year, model-only token bound to
your subscription (it can't touch your account). Keep it like a password.

### A3. Build the smoke drive

Plug in the USB, note its drive letter (say `E:`), then:

```powershell
.\scripts\Build-Kit.ps1 -UsbRoot E:\ -Minimal
```

What this does: copies the freshly-installed `claude.exe` and the kit tree to
`E:\`, skips all tools/ISO, then runs `claude.exe --version` **from the USB
path** as a build gate. If that gate fails, it refuses to finish — that
failure is itself the answer (the copy didn't produce a working binary) and
means stop and tell me.

Expected tail: `SMOKE-TEST DRIVE BUILT`.

### A4. Put your token on the drive

The build placed `E:\config\auth.env.example` but not the secret. Create the
real file (Notepad is fine), containing exactly one line:

```
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-...your token...
```

Save it as `E:\config\auth.env` (no `.txt`).

### A5. Sanity-check what landed (30 seconds, catches silent copy bugs)

```powershell
Test-Path E:\bin\claude\claude.exe          # True
Test-Path E:\.claude\settings.json          # True  <- deny rules + hook config
Test-Path E:\hooks\PreToolUse-Guard.ps1     # True
Test-Path E:\CLAUDE.md                       # True
Test-Path E:\docs\tool-invocations.md        # True
Test-Path E:\config\auth.env                 # True
```

Any `False` here is a real finding — especially `.claude\settings.json`,
because if it didn't copy, the safety rules silently aren't there. Tell me if
any come back False.

Eject the drive.

---

## Part B — on the clean test machine (ideally a VM snapshot)

Plug the drive in. Note its letter (may differ, say `E:`). Open **PowerShell
as Administrator** (right-click → Run as administrator) and `cd` to the drive:

```powershell
E:
cd \
```

### B1. The atomic test — does the portable binary even run here?

```powershell
.\bin\claude\claude.exe --version
```

Expect a version number. If you get "not recognized" or a DLL error, that's
the load-bearing assumption failing — **stop and report the exact error.**
This is the single most important line in the whole test.

### B2. Does it authenticate headlessly with the token, no browser?

```powershell
$env:CLAUDE_CODE_OAUTH_TOKEN = (Get-Content .\config\auth.env | Where-Object {$_ -match 'OAUTH'}) -replace '.*=',''
$env:CLAUDE_CONFIG_DIR = "E:\state\.claude"
.\bin\claude\claude.exe -p "reply with the single word: online" --dangerously-skip-permissions
```

Expect `online`, with **no browser window** opening. If it opens a browser or
errors about auth, the headless-token path is the problem — report it.

### B3. The full launcher, as a safe dry run

This exercises the whole chain — connectivity gate, config dir, `CLAUDE.md`
load, the guard hook, model pin, and the report card — but changes **nothing**
(`-RepairMode Check`) and takes **no backup** (`-BackupMode Skip`, so you don't
need a second drive):

```powershell
.\Repair-This-PC.cmd -BackupMode Skip -RepairMode Check
```

(or `.\Start-Repair.ps1 -BackupMode Skip -RepairMode Check` if you prefer no
elevation prompt). Let it run. Expect: it confirms connectivity, launches the
agent, the agent reads `CLAUDE.md`, diagnoses in check-only mode, and a
**report card HTML opens** at the end (also in `E:\reports\`).

### B4. Confirm the safety layer actually loaded

```powershell
.\bin\claude\claude.exe doctor
```

Look for the settings file validating with no error and the PreToolUse hook
listed. A hook that didn't load enforces nothing.

---

## What to tell me back

- B1: version string, or the exact error.
- B2: did it print `online` with no browser?
- B3: did it reach the report card? Anything it got stuck on?
- B5 (A5): were any `Test-Path` checks False?

If B1–B3 pass, the concept is **proven** and I'll build the full drive
(tools + ISO) and the last roadmap items with confidence. If any fail, the
error text tells us exactly what to fix — that's the whole point of doing this
for 300 MB first.

## Known risky spots (where hardware may surprise us)

- **The binary copy** — `Build-Kit` assumes the installed layout is
  `%USERPROFILE%\.local\share\claude\versions\<v>\`. If A3 errors that no
  version was found, run `dir $env:USERPROFILE\.local\share\claude` and send
  me the layout; it's a one-line fix.
- **`.claude\settings.json` not copying** (A5) — dot-prefixed folder; if it's
  missing, the safety rules aren't on the drive.
- **The wall-clock watchdog / resume** (not exercised by this smoke test) uses
  Windows process control whose exact behavior I couldn't verify without
  hardware — that's checklist step 9c, for the full drive, not now.
