# Authentication — resolved

The handoff listed this as unresolved and load-bearing: does the kit
authenticate on a target machine at all, especially in Safe Mode where
browser/UI behavior is degraded? Answered from Anthropic's documented
authentication precedence (verified against `code.claude.com/docs` on
2026-08-31) — no browser OAuth flow is needed at repair time.

## The mechanism: a pre-generated long-lived OAuth token

Run this once, ahead of time, on a trusted machine you already use Claude
Code on (**not** the target machine, and not as part of the kit's unattended
run):

```powershell
claude setup-token
```

This opens a browser authorization flow against **your** Claude subscription
(Pro/Max/Team/Enterprise) and prints a token to the terminal — it does not
save it anywhere itself. That token is valid for one year and authenticates
against your subscription, not pay-per-token API billing. Store it as
`CLAUDE_CODE_OAUTH_TOKEN` in the kit's env file (`kit/config/auth.env`,
gitignored — see below) rather than checking it into this repo or leaving it
in shell history.

At kit launch, `Start-Repair.ps1` sets `CLAUDE_CODE_OAUTH_TOKEN` from that
file before invoking `claude`. No browser opens on the target machine, and
nothing about Safe Mode's degraded shell/UI matters — the CLI reads the
token from the environment like any other headless CI credential.

**Fallback: `ANTHROPIC_API_KEY`.** If a subscription-bound token isn't
available (e.g. you want per-repair usage isolated to a Console API key),
set `ANTHROPIC_API_KEY` instead. Confirmed from the docs: "In non-interactive
mode (`-p`), the key is always used when present" — no approval prompt, no
browser. The tradeoff is billing: this is metered API usage, not your
subscription plan. A lost or stolen drive exposes whichever credential it
carries either way — see **Threat model** below.

Do **not** use `--bare` mode. It's tempting for a scripted/CI-style
invocation, but it does two things that break this kit specifically: it
skips auto-loading `CLAUDE.md` (the whole point of the on-USB instructions
file), and it "doesn't use your subscription login" — bare mode only reads
`ANTHROPIC_API_KEY`/`apiKeyHelper`, not `CLAUDE_CODE_OAUTH_TOKEN`. Run full
mode.

## Why this resolves the Safe Mode question

The handoff's worry was that Safe Mode's degraded network/UI stack (no
`NlaSvc`, network flyout doesn't render) might also break Claude Code's
auth. It doesn't, because auth here never depends on interactive browser
redirect or the OS network UI — only on outbound HTTPS to the Anthropic API,
which Safe Mode with Networking provides (see
[`docs/safe-mode-constraints.md`](safe-mode-constraints.md)). Confirm
connectivity with `netsh wlan connect name="SSID"` first if Wi-Fi is
involved, per the existing Safe Mode findings.

## Portability: no Node.js bundling needed

This also resolves a second open item. The handoff assumed Node.js would
need to be bundled portable because a broken target machine likely won't
have it and MSI installs don't work in Safe Mode. That assumption was based
on the npm-based install path. It doesn't apply: Anthropic's **native
installer** (`irm https://claude.ai/install.ps1 | iex`) installs a
self-contained `claude.exe` that "does not itself invoke Node" — there is no
Node.js runtime dependency at all for the native binary, on any platform.

The native installer still writes into the *build* machine's user profile
(`~/.local/share/claude/versions/<version>/`, symlinked from
`~/.local/bin/claude.exe`), so it isn't portable as installed. The build
script (`scripts/Build-Kit.ps1`) runs the installer on your machine once,
then copies the resulting versioned binary directory straight onto the USB
(`kit/bin/claude/`) rather than the symlink launcher, and `Start-Repair.ps1`
invokes that copy directly by path. `DISABLE_AUTOUPDATER=1` is set in the
kit's env so it doesn't try to self-update against whatever network the
target machine has; refresh the kit by re-running the build script on your
machine before the next deployment.

## Keeping everything on the USB, not the target machine

`CLAUDE_CONFIG_DIR` (confirmed in the docs) redirects where Claude Code
keeps `.credentials.json`, settings, and session history — normally under
`~/.claude` on the target machine's Windows profile. `Start-Repair.ps1` sets
it to a USB-local path (`kit/state/.claude`) before launch, so:

- The token/API key never gets written into the target machine's user
  profile, even transiently.
- Session history and the run transcript live on the USB, satisfying the
  "log to USB" decision in `docs/decisions.md`.
- Re-running the kit on a different machine doesn't leak state between
  households.

## Threat model for the stored credential

The USB carries a working credential at rest. Mitigations, in order of
how load-bearing they are:

1. **Physical control.** This kit is handed directly to family, not mailed
   or left unattended — the primary control is who holds the drive.
2. **Scope the credential.** A `claude setup-token` OAuth token can only
   make model requests — per the docs it "can't establish Remote Control
   sessions or fetch claude.ai connectors" — so a stolen drive doesn't hand
   over account control, only inference spend against your subscription.
3. **Rotation.** Treat the token like any other long-lived secret: if the
   drive is lost, run `/logout` + re-`setup-token` on your trusted machine
   and rebuild the kit; the old token keeps working until you do.
4. **`kit/config/auth.env` is gitignored** — never commit a real token to
   this repo. `kit/config/auth.env.example` is the template.

## What ships in this repo vs. what doesn't

| Artifact | In repo? |
|---|---|
| `kit/config/auth.env.example` | Yes — template with placeholder values |
| A real `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` | **Never** |
| `scripts/Build-Kit.ps1` (runs the installer, copies the binary) | Yes |
| The installed `claude.exe` binary itself | No — fetched by the build script, not vendored |
