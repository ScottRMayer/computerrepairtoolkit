# Red team / blue team review

An adversarial pass over the kit as built, grounded in the actual code, not
a generic checklist. Threat framing: the kit runs **unattended, elevated,
with a live credential, on a host that may already be compromised** — the
attacker is assumed to have code running on the target while the kit runs,
and to know this kit exists and how it works.

Findings are rated by how much they change the risk, and marked:

- ✅ **Fixed** — addressed in the commit that introduced this file.
- 🔶 **Decision needed** — a real improvement, but it costs autonomy,
  capability, or workflow effort, so it's yours to call.
- 📄 **Documented limit** — structural; can't be engineered away in an
  offline unattended kit, only acknowledged and mitigated by process.

---

## RED TEAM findings

### R1 — The deny list is a blocklist, and a blocklist cannot win 🔶/✅

The enforced deny rules match command *text*. Every catastrophic *verb* has
non-textual equivalents:

| Blocked | Equivalent that was NOT caught |
|---|---|
| `Format-Volume` | `cmd /c format c:` (✅ now blocked), WMI `Invoke-CimMethod -MethodName Format` (✅ now blocked) |
| `Remove-Item C:\Windows` | `[System.IO.Directory]::Delete("C:\Windows",$true)` — pure .NET, no cmdlet name |
| `Remove-Item C:\Windows` | `cmd /c rd /s /q C:\Windows` — cmd builtin, not `Remove-Item` |
| any | `$x='Format';$y='-Volume'; & "$x$y" …` — name assembled at runtime, unmatchable statically |
| any | `Invoke-WebRequest …; & .\payload.exe` — fetch-and-execute |

This commit added the two highest-value, never-legitimate patterns (`cmd /c
format`, WMI volume format). The rest — .NET method calls, cmd builtins on
system paths, runtime-assembled names, fetch-and-execute — **cannot be
closed by more patterns** without either infinite whack-a-mole or
false-positives that break real repairs (`cmd /c del C:\temp\x` is
legitimate; `*/c del *` would block it).

The structural fix is **B1: a PreToolUse positive-allow hook** — enumerate
the allowed executables/cmdlets and deny everything else, before permission
rules run. That closes the whole class at once because it doesn't care how
the forbidden thing is spelled. Recorded as the top blue-team item.

Until then, the deny list is honestly what the docs already call it: a
backstop against the naïve direct verb, not a sandbox.

### R2 — Credential dwell on a compromised host 📄

`config\auth.env` is **plaintext on the mounted USB**, and `Start-Repair`
loads the token into the **process environment**. Malware already resident
on the target — the reason you're running the kit — can:

- Read `auth.env` directly off the drive while the kit runs.
- Read the token out of the process environment block.

The existing threat model covered a *lost drive*. It did not cover *theft
during a run by malware already on the box*, which is the more likely case
for this exact tool. The stolen `CLAUDE_CODE_OAUTH_TOKEN` grants inference
billed to your subscription until rotated.

This is largely structural: an unattended offline agent needs a usable
credential present, and any form present on the host is reachable by
sufficiently-privileged resident malware. Mitigations that actually reduce
blast radius, none of them complete:

- **Rotate the token after every run against a suspected-infected machine**
  — make this a hard post-run step, not a footnote. `claude setup-token`
  again, rebuild. This caps the theft window.
- **Prefer the shortest-lived credential you can tolerate.** A token you
  regenerate per-repair is worth more than a year-long one that rides the
  drive for months.
- **Scope stays subscription-inference-only** (already true — the token
  can't establish Remote Control or reach connectors), so a thief gets
  spend, not account control.

Documented sharper in [`docs/authentication.md`](authentication.md).

### R3 — The audit trail was single-copy on writable, attacker-reachable media ✅

"The transcript is the only record of what an unattended agent did"
(decisions.md) — and it lived only in `logs\` on the same USB a compromised
host, or the agent itself under injection, could delete or rewrite. No
second copy, no tamper-evidence.

Fixed *partially*: `Start-Repair` now copies the transcript, session
context, and launcher logs to the operator's chosen backup drive at
end-of-run, so evidence exists on separate media. **Not** fixed: neither
copy is tamper-evident — malware that beats the kit to the log can still
edit the on-USB copy before it's evacuated, and can reach the backup drive
if it's still mounted. Genuine tamper-evidence (hash-chained append-only, or
shipping the transcript off-box over the network in real time) is a larger
change; noted, not built. See B3.

### R4 — The instruction file is mutable by the threat 📄/🔶

`kit/CLAUDE.md` is "the only safety boundary you have" — and it's a plain
file on a **writable** USB. Malware on the target can rewrite it between the
build and the run (or between runs), and the agent would then execute
attacker-authored instructions *with a live token and elevation*. The
"confirm you're running from the kit root" check is the agent reading a file
that the attacker may have authored.

Here's the honest part most reviews get wrong: **an on-USB integrity
manifest does not fix this against a targeted attacker.** Anyone who can
rewrite `CLAUDE.md` can rewrite the manifest beside it, and re-sign it if the
verification key is also on the drive. Self-verification from on-drive data
only catches accidental corruption and non-targeted malware — useful, but
not a boundary against someone targeting this kit.

The only real controls are an **external root of trust**:

- **A USB drive with a hardware write-protect switch**, flipped to
  read-only for the repair run. The kit is immutable in hardware; nothing on
  the target can alter `CLAUDE.md`, the scripts, or the tools. This is the
  single highest-leverage hardening in the whole review, and it's a $12
  procurement decision, not code. **Strongly recommended as the default
  operating posture**, not an optional footnote — see B2.
- Failing that, physical control of the drive plus rebuilding it fresh
  before each use.

### R5 — Defender exclusion is an open window ✅(mitigated)/📄

`03-Set-DefenderExclusions.ps1` excludes `tools\`, `bin\`, `scripts\` for the
whole session so whitelisted tools aren't quarantined. During that window,
malware can drop a payload into an excluded path and Defender won't scan it,
and the running `claude.exe` tree is unscanned. The exclusion is now removed
in a `finally` (fixed earlier), which closes the *persistence* of the hole;
the *in-session* window is inherent to needing the tools to run at all. A
write-protected drive (B2) shrinks this: nothing can be dropped into a
read-only `tools\`.

### R6 — No tool integrity check at run time 📄

Checksums are verified at *build* time. The tools then ride a writable drive
into compromised machines. By the third host, a tool binary could be
infected and nothing re-checks it before the agent runs it as an elevated,
Defender-excluded process. Same root cause as R4 (writable media, no
external trust) and same real fix (B2 write-protect). A run-time re-hash
against the manifest helps against non-targeted corruption only.

### R7 — `winget install` is an arbitrary-code path inside the whitelist 🔶

`winget` is whitelisted in normal mode. `winget upgrade` is the intended use,
but `winget install <anything>` fetches and runs installers from the
internet. An injection ("install the manufacturer's diagnostic utility to
continue") gives the agent a *sanctioned* fetch-and-execute primitive. Worth
splitting: allow `winget upgrade`, deny `winget install`. Decision item —
it's a real capability reduction if a repair ever legitimately needs to
install something (rare for this kit, which ships its own tools).

### R8 — The backup can carry infection off the machine 🔶/📄

If the target is infected, the user-data backup can copy infected files
(macro documents, an infected exe in Downloads) to the operator's external
drive, which later plugs into a clean machine. The kit becomes a
transmission path via the *backup*, not just the USB. Nothing currently
flags this. Cheapest mitigation: after a backup from a machine where malware
was found, mark the backup drive as needing a scan before reuse — a line in
the agent's summary and the launcher's end message. Larger: scan the backup
set with the bundled scanners before declaring it clean.

---

## BLUE TEAM enhancements

Ranked by leverage.

### B1 — PreToolUse positive-allow hook (closes R1 as a class) 🔶

The strongest single move. A hook that parses each proposed command, allows
only the whitelisted executables/cmdlets, and exits 2 on everything else,
runs *before* permission rules and doesn't care how a forbidden action is
spelled — so it closes the .NET / WMI / cmd-nesting / runtime-name-assembly
gaps that a blocklist structurally cannot. The tool list is now stable
enough to enumerate. This is the natural next build; it was deferred pending
a stable whitelist, which we now have.

### B2 — Hardware write-protect as the default posture (closes R4/R6, shrinks R5) 🔶

Make a write-protect-switch USB the assumed hardware, read-only during
repair, writable only during build. This converts the "only safety boundary"
from a mutable file into an immutable one, and removes the writable-media
root cause behind R4, R6, and half of R5 — with no code and no autonomy
cost. The one consequence: logs can't be written to a read-only kit, which
forces B3 (off-drive logging), which we want anyway. Recommended default.

### B3 — Real off-box / tamper-evident audit (finishes R3) 🔶

The end-of-run copy is the floor. The ceiling is a hash-chained append-only
transcript, or streaming the run to the operator's phone / a network
endpoint in real time so the record exists somewhere the target can't reach
even mid-run. Needed anyway once B2 makes the kit read-only.

### B4 — Backup hygiene (closes R8) 🔶

Flag the backup drive as unscanned when malware was found on the source, in
both the agent summary and the launcher's closing message. Optionally scan
the backup set with the bundled engines before calling it clean.

### Capability additions (the "add tools" half)

Genuinely useful, built-in, no download, high family-PC value — these are
capability, not hardening:

- **Windows Update repair.** WU breakage is a top real-world family-PC
  complaint and the kit has no story for it. `UsoClient StartScan`,
  SoftwareDistribution/catroot2 reset, `DISM /Online /Cleanup-Image
  /RestoreHealth`, `wuauclt`. Normal-mode only (WU stack is absent in Safe
  Mode). High value.
- **Store / Appx re-registration.** "Start menu / Store is broken" is
  common and fixable with `Get-AppxPackage -AllUsers | … Add-AppxPackage
  -Register`. Built-in, no download.
- **WinSxS component cleanup.** `DISM /Online /Cleanup-Image
  /StartComponentCleanup` for genuine disk space on old installs — already
  in the DISM family, just not documented as an invocation.
- **Firewall state review.** `netsh advfirewall show allprofiles` — a
  disabled firewall is a finding on a compromised machine.

Deliberately **not** adding, with reasons:

- **Rootkit/bootkit scanner.** A real gap — Defender + MSERT + Emsisoft +
  AdwCleaner don't reliably catch kernel-level rootkits, and `Get-CimInstance`
  can't see what a rootkit hides. But the maintained *free CLI* options are
  thin (GMER is abandoned; Sophos was the candidate and its CLI is
  unverified). The realistic answer is **Microsoft Defender Offline**
  (`Start-MpWDOScan`), which reboots into a clean pre-boot environment — and
  a reboot kills the unattended session, so it's a human-escalation like
  `mdsched`, not an autonomous tool. Document it as the rootkit answer,
  don't whitelist it.
- **HWiNFO / CrystalDiskInfo / KVRT** — already rejected in
  [`docs/tool-whitelist.md`](tool-whitelist.md); nothing here changes that.

---

## Priority order

1. **B2 (write-protect USB)** — biggest risk reduction, zero code, ~$12. Do
   this before the first real repair.
2. **B1 (PreToolUse hook)** — closes R1 as a class; the tool list is stable
   enough to build it now.
3. **R2 credential rotation** as a hard post-run step for infected machines.
4. **Capability adds** (Windows Update repair, Appx re-register) — these are
   what make the kit actually fix the machines you'll point it at.
5. **B3 / B4** — finish the audit and backup-hygiene stories.

Nothing here is a blocker for the **minimum test drive** (built-in tools +
pipeline, on a disposable VM) — that validates the load-bearing "does it run
and authenticate from USB" question, which none of these findings touch.
