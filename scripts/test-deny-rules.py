#!/usr/bin/env python3
"""Regression test for the deny rules in kit/.claude/settings.json.

Run from the repo root:  python3 scripts/test-deny-rules.py

Deny rules are the kit's only *enforced* boundary (they block in every
permission mode, bypassPermissions included), so a rule that's too broad
silently breaks a legitimate repair and one that's too narrow silently
lets a catastrophic command through. Both failure modes are invisible
until they happen on someone's machine, which is why this exists.

Matching semantics, per code.claude.com/docs/en/permissions:
  - wildcards `*` match at any position
  - a pattern with no leading `*` is anchored at the start of the command
  - matching is case-insensitive
  - PowerShell aliases are canonicalized before matching, so a rule naming
    Remove-Item also catches ri/rm/del/rd. That canonicalization is NOT
    modeled here, so this test is stricter than reality on alias forms.
  - compound commands are AST-split and each subcommand checked separately

Add a case to MUST_PASS whenever you add a tool to the whitelist, and to
MUST_BLOCK whenever you add a deny rule.
"""

import fnmatch
import json
import pathlib
import sys

SETTINGS = pathlib.Path(__file__).resolve().parent.parent / "kit" / ".claude" / "settings.json"

# Legitimate repair actions. Every one of these must survive the deny list.
# Keep in sync with docs/tool-whitelist.md.
MUST_PASS = [
    ("PowerShell", "sfc /scannow"),
    ("PowerShell", r"DISM /Online /Cleanup-Image /RestoreHealth /Source:E:\iso\install.wim /LimitAccess"),
    ("PowerShell", "chkdsk C: /f"),
    ("PowerShell", "cleanmgr /sagerun:1"),
    ("PowerShell", 'netsh wlan connect name="Home"'),
    ("PowerShell", "powercfg /energy"),
    ("PowerShell", "Get-Date -Format 'o'"),
    ("PowerShell", "Get-CimInstance Win32_LogicalDisk | Format-Table"),
    ("PowerShell", r"Remove-Item C:\Users\x\AppData\Local\Temp\bad.exe -Force"),
    ("PowerShell", r"Remove-Item 'C:\ProgramData\malware\dropper.dll'"),
    ("PowerShell", r"reg delete HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run /v Evil /f"),
    ("PowerShell", r"E:\tools\sysinternals\autorunsc.exe -accepteula -a *"),
    ("PowerShell", r"E:\tools\sysinternals\handle.exe -accepteula -p 1234"),
    ("PowerShell", "MpCmdRun.exe -Scan -ScanType 2"),
    ("PowerShell", "Checkpoint-Computer -Description 'pre-repair'"),
    ("PowerShell", r"Enable-ComputerRestore -Drive 'C:\'"),
    ("PowerShell", r"E:\tools\adwcleaner\adwcleaner.exe /eula /clean"),
    ("PowerShell", r"E:\tools\emsisoft\a2cmd.exe /f=C:\ /quarantine"),
    ("Bash", "sfc /scannow"),
    ("Bash", "rm -rf /tmp/scratch"),
    ("Bash", "rm -rf /c/Users/x/AppData/Local/Temp/junk"),
]

# Never part of a repair procedure. Every one must be denied.
MUST_BLOCK = [
    ("PowerShell", "Format-Volume -DriveLetter C -Force"),
    ("PowerShell", "Get-Disk 0 | Clear-Disk -RemoveData -Confirm:$false"),
    ("PowerShell", "Get-Process; Format-Volume -DriveLetter D"),
    ("PowerShell", "diskpart /s script.txt"),
    ("PowerShell", "Remove-Partition -DiskNumber 0 -PartitionNumber 2"),
    ("PowerShell", "Initialize-Disk -Number 1"),
    ("PowerShell", "vssadmin delete shadows /all /quiet"),
    ("PowerShell", "wbadmin delete catalog -quiet"),
    ("PowerShell", r"Disable-ComputerRestore -Drive 'C:\'"),
    ("PowerShell", "cipher /w:C"),
    ("PowerShell", r"E:\tools\sysinternals\sdelete.exe -p 1 C:\Users\x\Documents"),
    ("PowerShell", "sdelete64.exe -c -z C:"),
    ("PowerShell", "Remove-LocalUser -Name Dad"),
    ("PowerShell", "net user Dad /delete"),
    ("PowerShell", r"reg delete HKLM\SYSTEM /f"),
    ("PowerShell", r"Remove-Item C:\Windows\System32 -Recurse -Force"),
    ("PowerShell", r"Remove-Item -Path C:\Program Files -Recurse"),
    ("PowerShell", r"Remove-Item HKLM:\SOFTWARE -Recurse"),
    ("Bash", "diskpart"),
    ("Bash", "vssadmin delete shadows /all"),
    ("Bash", "format C:"),
    ("Bash", "rm -rf /c/Windows/System32"),
]


def load_rules():
    settings = json.loads(SETTINGS.read_text())
    parsed = []
    for rule in settings["permissions"]["deny"]:
        if "(" not in rule or not rule.endswith(")"):
            # A tool-name-only rule such as "Write" matches at the tool level.
            parsed.append((rule, "*"))
            continue
        tool, body = rule.split("(", 1)
        parsed.append((tool, body[:-1]))
    return parsed


def matching_rules(rules, tool, command):
    return [
        f"{t}({p})"
        for t, p in rules
        if t == tool and fnmatch.fnmatch(command.lower(), p.lower())
    ]


def main():
    rules = load_rules()
    failures = 0

    print(f"{len(rules)} deny rules loaded from {SETTINGS.relative_to(SETTINGS.parents[2])}\n")

    print("Legitimate repair actions (must NOT be denied):")
    for tool, command in MUST_PASS:
        hits = matching_rules(rules, tool, command)
        if hits:
            failures += 1
            print(f"  FALSE POSITIVE  {command}\n                  caught by {hits}")
        else:
            print(f"  ok              {command[:70]}")

    print("\nCatastrophic actions (must be denied):")
    for tool, command in MUST_BLOCK:
        hits = matching_rules(rules, tool, command)
        if not hits:
            failures += 1
            print(f"  GAP - ALLOWED   {command}")
        else:
            print(f"  blocked         {command[:70]}")

    if failures:
        print(f"\n{failures} problem(s). Fix kit/.claude/settings.json before shipping.")
        return 1

    print("\nAll checks pass.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
