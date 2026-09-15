<#
.SYNOPSIS
    Gets the target machine a working path to api.anthropic.com before the
    agent is launched. Deterministic PowerShell only — this CANNOT be the
    agent's job, because every Claude Code turn is an HTTPS call, so with the
    network down the agent fails on turn 0 having produced nothing.

.DESCRIPTION
    A ladder of cheap, reversible rungs, each followed by a re-probe. Stops at
    the first rung that restores connectivity.

      R0  Clock skew   - a wrong system clock fails TLS certificate validation
                         and masquerades as "the internet is broken". This is
                         the one outage a cloud-brained agent is uniquely
                         vulnerable to, and a dead CMOS battery on an aging
                         desktop is a common cause. Read a trusted time from a
                         plain-HTTP Date header (no TLS needed, so it works
                         even when the clock is what's breaking TLS).
      R1  Adapter/Wi-Fi
      R2  DNS          - flush, then fall back to public resolvers
      R3  hosts hijack - comment out ONLY anthropic/claude lines
      R4  Proxy        - clear WinHTTP *and* WinINET (consumer/malware proxy
                         hijacks live in WinINET, which netsh winhttp misses)

    Deliberately NOT attempted: `netsh winsock reset` and `netsh int ip reset`.
    Both need a reboot to take effect and both can sever the agent's own
    uplink mid-run. They're reported as recommendations instead.

.PARAMETER WifiSSID / WifiPassword
    Optional. Build a Wi-Fi profile on a machine that has none.

.PARAMETER SkipRemediation
    Probe only; change nothing. Used by the report/offline path.

.OUTPUTS
    A PSCustomObject: Online (bool), Rung (which rung fixed it, or 'none'),
    Findings (hardware/config findings worth reporting), Attempted (string[]).
#>
[CmdletBinding()]
param(
    [string]$WifiSSID,
    [string]$WifiPassword,
    [switch]$SkipRemediation
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$KitRoot = Get-KitRoot
$LogPath = Get-DefaultLogPath -KitRoot $KitRoot -Prefix 'connectivity'

$findings = [System.Collections.ArrayList]@()
$attempted = [System.Collections.ArrayList]@()
# Settings this script changed and how to put them back (also handed to the
# agent via session-context.json so it never "re-diagnoses" them).
$reverts = [System.Collections.ArrayList]@()

# Probe the way the agent connects: claude.exe is a Node/Bun binary that
# does NOT use the WinINET/system proxy (and the launcher scrubs HTTPS_PROXY),
# whereas Windows PowerShell's Invoke-WebRequest does by default. A probe
# that succeeded through a proxy the agent cannot use would be a false
# "online". Direct it is.
try { [System.Net.WebRequest]::DefaultWebProxy = $null } catch { }

function Test-AnthropicReachable {
    <#
    Treats ANY real HTTP status from the API as transport-OK — a 401/403 means
    we reached Anthropic and TLS validated, which is exactly what this probe is
    for. Auth is proven separately by the launcher's preflight ping.

    A captive portal typically returns 200 with an HTML login page, so a bare
    200 with non-JSON content is treated as NOT reachable.
    #>
    try {
        $r = Invoke-WebRequest -Uri 'https://api.anthropic.com/v1/models' `
            -Method Get -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
        if ($r.Headers['Content-Type'] -notmatch 'json') {
            Write-KitLog -LogPath $LogPath -Level WARN -Message 'Probe got a non-JSON 200 — likely a captive portal, not real connectivity.'
            return $false
        }
        return $true
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and $resp.StatusCode.value__ -ge 400) {
            # Reached Anthropic and TLS validated; an auth error is fine here.
            return $true
        }
        return $false
    }
}

function Invoke-Rung {
    param([string]$Name, [scriptblock]$Action)
    if ($SkipRemediation) { return $false }
    [void]$attempted.Add($Name)
    Write-KitLog -LogPath $LogPath -Message "Connectivity rung: $Name"
    # Discard whatever the action emits. Set-Date returns a DateTime,
    # Enable-NetAdapter and friends can emit objects too; anything left on
    # the pipeline here would be returned alongside the probe result and make
    # "$online" truthy regardless of the re-probe.
    try { $null = & $Action } catch {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Rung '$Name' errored: $_"
    }
    return [bool](Test-AnthropicReachable)
}

function New-Result {
    param([bool]$Online, [string]$Rung)
    [PSCustomObject]@{
        Online    = $Online
        Rung      = $Rung
        Findings  = @($findings)
        Attempted = @($attempted)
        Reverts   = @($reverts)
    }
}

# --- Baseline probe -------------------------------------------------------
if (Test-AnthropicReachable) {
    Write-KitLog -LogPath $LogPath -Message 'api.anthropic.com reachable on first probe.'
    return (New-Result -Online $true -Rung 'none-needed')
}
Write-KitLog -LogPath $LogPath -Level WARN -Message 'api.anthropic.com NOT reachable. Walking the connectivity ladder.'

# --- R0: clock skew -------------------------------------------------------
# Do this first: if the clock is wrong, TLS fails and every later rung's probe
# fails too, sending us down a diagnostic path that will never converge.
$online = Invoke-Rung 'R0-clock-skew' {
    $trusted = $null
    try {
        $head = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' `
            -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        if ($head.Headers['Date']) { $trusted = [datetime]::Parse($head.Headers['Date']) }
    } catch {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Could not read a trusted time over plain HTTP: $_"
    }

    if ($trusted) {
        $skew = [math]::Abs(((Get-Date).ToUniversalTime() - $trusted.ToUniversalTime()).TotalMinutes)
        Write-KitLog -LogPath $LogPath -Message ("System clock differs from trusted time by {0:N1} minutes." -f $skew)
        if ($skew -gt 5) {
            [void]$findings.Add("System clock was off by $([math]::Round($skew)) minutes — this breaks HTTPS certificate validation and looks like 'no internet'. Corrected. If it recurs after power-off, the motherboard (CMOS) battery is dead and needs replacing.")
            Set-Date -Date $trusted.ToLocalTime() -ErrorAction SilentlyContinue
            Start-Service w32time -ErrorAction SilentlyContinue
            & w32tm /resync /force 2>&1 | Out-Null
        }
    }
}
if ($online) { return (New-Result -Online $true -Rung 'R0-clock-skew') }

# --- R1: adapter / Wi-Fi --------------------------------------------------
$online = Invoke-Rung 'R1-adapter-wifi' {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object Status -eq 'Disabled' |
        ForEach-Object {
            [void]$findings.Add("Network adapter '$($_.Name)' was disabled; re-enabled it.")
            Enable-NetAdapter -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue
        }

    if ($WifiSSID) {
        if ($WifiPassword) {
            # Build a profile from scratch when the machine has none.
            # XML-escape both values: an SSID or passphrase containing & < > "
            # would otherwise produce a profile netsh silently rejects.
            $ssidX = [System.Security.SecurityElement]::Escape($WifiSSID)
            $pskX  = [System.Security.SecurityElement]::Escape($WifiPassword)
            $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssidX</name>
  <SSIDConfig><SSID><name>$ssidX</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType><connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$pskX</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>
"@
            $tmp = Join-Path $env:TEMP 'kit-wifi.xml'
            $xml | Out-File -FilePath $tmp -Encoding utf8
            $addOut = (& netsh wlan add profile filename="$tmp" 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                [void]$findings.Add("Could not add the Wi-Fi profile for '$WifiSSID': $addOut")
            }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        & netsh wlan connect name="$WifiSSID" 2>&1 | Out-Null
        Start-Sleep -Seconds 6
    }
}
if ($online) { return (New-Result -Online $true -Rung 'R1-adapter-wifi') }

# --- R2: DNS --------------------------------------------------------------
# Only touch resolvers when the LINK works (a default gateway exists): if the
# cable is out or the router is down, static DNS fixes nothing and just
# leaves a permanent change behind. Prior servers are recorded and, if the
# rung does not get us online, restored.
$script:dnsLedger = @()
$online = Invoke-Rung 'R2-dns' {
    & ipconfig /flushdns 2>&1 | Out-Null
    $hasGateway = [bool](Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' })
    if (-not $hasGateway) {
        [void]$findings.Add('No default gateway: the network link itself is down (cable, Wi-Fi, or router), so DNS settings were left alone.')
        return
    }
    if (-not (Resolve-DnsName 'api.anthropic.com' -QuickTimeout -ErrorAction SilentlyContinue)) {
        $changed = @()
        Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object Status -eq 'Up' |
            ForEach-Object {
                $prior = (Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                $script:dnsLedger += [pscustomobject]@{ ifIndex = $_.ifIndex; name = $_.Name; prior = @($prior) }
                Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex `
                    -ServerAddresses '1.1.1.1', '8.8.8.8' -ErrorAction SilentlyContinue
                $changed += "$($_.Name) (was: $(if ($prior) { $prior -join ', ' } else { 'DHCP/none' }))"
            }
        & ipconfig /flushdns 2>&1 | Out-Null
        if ($changed) {
            [void]$findings.Add("DNS could not resolve api.anthropic.com; set public resolvers (1.1.1.1 / 8.8.8.8) on: $($changed -join '; ').")
            [void]$reverts.Add("DNS servers were changed to 1.1.1.1/8.8.8.8 on: $($changed -join '; '). Revert with Set-DnsClientServerAddress -InterfaceIndex <n> -ResetServerAddresses (DHCP) or the prior addresses listed.")
        }
    }
}
if ($online) { return (New-Result -Online $true -Rung 'R2-dns') }
if ($script:dnsLedger.Count -gt 0) {
    # It did not help: put the resolvers back rather than leave a change that
    # fixed nothing.
    foreach ($entry in $script:dnsLedger) {
        try {
            if ($entry.prior -and $entry.prior.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $entry.ifIndex -ServerAddresses $entry.prior -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $entry.ifIndex -ResetServerAddresses -ErrorAction Stop
            }
        } catch {
            [void]$findings.Add("Could not restore the previous DNS servers on $($entry.name): $_")
        }
    }
    [void]$findings.Add('Public DNS resolvers did not restore connectivity; the previous DNS settings were put back.')
    $reverts.Clear()
}

# --- R3: hosts-file hijack ------------------------------------------------
$online = Invoke-Rung 'R3-hosts-hijack' {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path $hosts) {
        $lines = Get-Content $hosts -ErrorAction SilentlyContinue
        # Only touch lines that redirect Anthropic/Claude. Everything else in
        # this file may be deliberate and is none of our business.
        $bad = $lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '(anthropic|claude)' }
        if ($bad) {
            $bad = @($bad)
            $patched = $lines | ForEach-Object {
                if ($_ -notmatch '^\s*#' -and $_ -match '(anthropic|claude)') { "# [repair-kit] $_" } else { $_ }
            }
            try {
                Copy-Item $hosts "$hosts.repairkit.bak" -Force -ErrorAction Stop
                # Malware commonly sets the file read-only; clear it so the write
                # can succeed, and write UTF-8 without BOM (the hosts parser is
                # ASCII-compatible and this keeps any non-ASCII comment intact,
                # where -Encoding ASCII would have replaced it with '?').
                $attrs = (Get-Item $hosts -Force).Attributes
                if ($attrs -band [System.IO.FileAttributes]::ReadOnly) {
                    Set-ItemProperty -Path $hosts -Name Attributes -Value ($attrs -bxor [System.IO.FileAttributes]::ReadOnly) -ErrorAction Stop
                }
                [System.IO.File]::WriteAllLines($hosts, [string[]]$patched, (New-Object System.Text.UTF8Encoding $false))
                # Verify before claiming success.
                $after = Get-Content $hosts -ErrorAction Stop | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '(anthropic|claude)' }
                if ($after) { throw "hosts file still contains $(@($after).Count) redirecting line(s) after the rewrite" }
                [void]$findings.Add("hosts file redirected Anthropic/Claude domains (likely malware). Commented out $($bad.Count) line(s); original saved as hosts.repairkit.bak.")
                & ipconfig /flushdns 2>&1 | Out-Null
            } catch {
                [void]$findings.Add("hosts file redirects Anthropic/Claude domains ($($bad.Count) line(s), likely malware) and could NOT be repaired: $_")
            }
        }
    }
}
if ($online) { return (New-Result -Online $true -Rung 'R3-hosts-hijack') }

# --- R4: proxy (WinHTTP *and* WinINET) ------------------------------------
$online = Invoke-Rung 'R4-proxy' {
    # Machine-wide (WinHTTP) proxy: read the registry blob's STRUCTURE, not
    # netsh's localized text ("Direct access" is English only; a German
    # machine prints "Direkter Zugriff" and a text match would have reset
    # the proxy and recorded a false hijack finding on every run).
    # Serialized WINHTTP proxy struct: DWORD@8 = access flags (1 = direct,
    # bit 2 = named proxy), DWORD@12 = proxy string length, ASCII string @16.
    # Layout inferred from public analyses of WinHttpSettings and untested on
    # hardware (docs/verification-checklist.md); on any parse doubt no
    # finding is recorded and nothing is reset.
    $winhttpProxy = $null
    try {
        $blob = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -Name WinHttpSettings -ErrorAction SilentlyContinue).WinHttpSettings
        if ($blob -and $blob.Length -ge 16) {
            $flags = [BitConverter]::ToUInt32($blob, 8)
            $len   = [BitConverter]::ToUInt32($blob, 12)
            if (($flags -band 2) -and $len -gt 0 -and (16 + $len) -le $blob.Length) {
                $winhttpProxy = [System.Text.Encoding]::ASCII.GetString($blob, 16, [int]$len)
            }
        }
    } catch { }
    if ($winhttpProxy) {
        [void]$findings.Add("A machine-wide (WinHTTP) proxy was configured: '$winhttpProxy'. Reset to direct access.")
        [void]$reverts.Add("WinHTTP proxy '$winhttpProxy' was reset to direct access. Re-apply with: netsh winhttp set proxy $winhttpProxy")
        & netsh winhttp reset proxy 2>&1 | Out-Null
    }

    # Consumer and malware proxy hijacks live in WinINET, which netsh does
    # not touch at all. This script runs elevated, so HKCU is the ADMIN's
    # hive — check the signed-in family member's hive too (loaded under
    # HKU\<SID> while they are logged on).
    $hives = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings')
    try {
        $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($consoleUser) {
            $sid = (New-Object System.Security.Principal.NTAccount($consoleUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction Stop | Out-Null
            }
            $hives += "HKU:\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        }
    } catch { }
    foreach ($ie in ($hives | Select-Object -Unique)) {
        $cur = Get-ItemProperty -Path $ie -ErrorAction SilentlyContinue
        if ($cur -and $cur.ProxyEnable -eq 1) {
            [void]$findings.Add("A user-level (WinINET) proxy was enabled in $ie`: '$($cur.ProxyServer)'. Disabled it; this is a common browser-hijack symptom.")
            [void]$reverts.Add("WinINET proxy '$($cur.ProxyServer)' was disabled (ProxyEnable=0) under $ie. Re-enable by setting ProxyEnable back to 1.")
            Set-ItemProperty -Path $ie -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
        }
    }
    # Windows PowerShell caches the system proxy at process start; refresh it
    # so the re-probe observes the change (the probe itself runs direct).
    try { [System.Net.WebRequest]::DefaultWebProxy = $null } catch { }
}
if ($online) { return (New-Result -Online $true -Rung 'R4-proxy') }

# --- Exhausted ------------------------------------------------------------
Write-KitLog -LogPath $LogPath -Level ERROR -Message 'Connectivity ladder exhausted; api.anthropic.com still unreachable.'
[void]$findings.Add('Could not establish a path to api.anthropic.com. `netsh winsock reset` and `netsh int ip reset` may fix a wedged TCP/IP stack, but both require a REBOOT and were deliberately not applied automatically.')
return (New-Result -Online $false -Rung 'none')
