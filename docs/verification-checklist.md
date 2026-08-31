# Manual hardware verification checklist

Run this on a real Windows machine before trusting the kit on an actual
family repair. Nothing here has been run by the agent that authored this
repo — it had no Windows hardware available.

## 1. Native install sanity check (any Windows machine, normal mode)

```powershell
irm https://claude.ai/install.ps1 | iex
claude --version
```

Expect a version string. If this fails, stop — nothing downstream works
either.

## 2. Portable copy works from a non-standard path

```powershell
Copy-Item -Recurse "$env:USERPROFILE\.local\share\claude\versions\*" C:\Temp\claude-portable\
$env:CLAUDE_CONFIG_DIR = "C:\Temp\claude-state"
& "C:\Temp\claude-portable\claude.exe" --version
```

If this errors (missing DLL, absolute-path assumption, anything), that's
the "possible undocumented dependency" risk flagged in
[`docs/status.md`](status.md) — file it before building a real drive.

## 3. Headless auth with a pre-generated token, no browser

On your trusted machine:

```powershell
claude setup-token
```

Copy the printed token. On a **different** shell (simulating the target
machine — clear any existing `/login` session state first, or use a fresh
user account, so you're testing the token path and not a leftover login):

```powershell
$env:CLAUDE_CODE_OAUTH_TOKEN = "<token>"
$env:CLAUDE_CONFIG_DIR = "C:\Temp\claude-state"
& "C:\Temp\claude-portable\claude.exe" -p "say hello" --dangerously-skip-permissions
```

Expect a response with no browser window opening. Confirm
`C:\Temp\claude-state` now holds `.credentials.json` and not the default
`%USERPROFILE%\.claude`.

## 4. Bypass mode actually skips prompts

```powershell
& "C:\Temp\claude-portable\claude.exe" -p "create a file called test.txt with the word hello in it" --dangerously-skip-permissions
```

Expect no permission prompt and the file created, with no terminal sitting
there waiting for input.

## 5. `CLAUDE.md` auto-loads

Run from a directory containing this repo's `kit/CLAUDE.md`:

```powershell
& "C:\Temp\claude-portable\claude.exe" -p "what tools are you allowed to use on this machine, per your instructions?" --dangerously-skip-permissions
```

Expect the response to reflect the whitelist from `CLAUDE.md`, confirming it
loaded (and confirming you're *not* accidentally in `--bare` mode).

## 6. Safe Mode with Networking

Boot the same machine into Safe Mode with Networking
(`msconfig` → Boot → Safe boot → Network, or `bcdedit /set {current}
safeboot network` + reboot — remember to `bcdedit /deletevalue {current}
safeboot` afterward or the machine keeps booting into Safe Mode).

Repeat steps 1–5. Also run:

```powershell
netsh wlan connect name="<your test SSID>"
Test-NetConnection api.anthropic.com -Port 443
```

before the `claude` calls, since the network flyout UI won't show a working
connection even when one exists (see
[`docs/safe-mode-constraints.md`](safe-mode-constraints.md)).

## 7. End-to-end `Start-Repair.ps1`

Only after 1–6 pass. Point it at a disposable VM snapshot first, not a
family member's actual machine — confirm the full pipeline (backup →
restore point → inventory → playbook) runs and produces a transcript in
`logs\` before ever running it unattended on hardware someone depends on.

## Record results

Update [`docs/status.md`](status.md)'s "Still open" section with whatever
you find — pass, fail, or "works but X is different from what the docs
say" all belong there.
