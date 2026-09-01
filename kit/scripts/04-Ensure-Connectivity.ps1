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
    try { & $Action } catch {
        Write-KitLog -LogPath $LogPath -Level WARN -Message "Rung '$Name' errored: $_"
    }
    return (Test-AnthropicReachable)
}

function New-Result {
    param([bool]$Online, [string]$Rung)
    [PSCustomObject]@{
        Online    = $Online
        Rung      = $Rung
        Findings  = @($findings)
        Attempted = @($attempted)
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
            $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$WifiSSID</name>
  <SSIDConfig><SSID><name>$WifiSSID</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType><connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$WifiPassword</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>
"@
            $tmp = Join-Path $env:TEMP 'kit-wifi.xml'
            $xml | Out-File -FilePath $tmp -Encoding utf8
            & netsh wlan add profile filename="$tmp" 2>&1 | Out-Null
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        & netsh wlan connect name="$WifiSSID" 2>&1 | Out-Null
        Start-Sleep -Seconds 6
    }
}
if ($online) { return (New-Result -Online $true -Rung 'R1-adapter-wifi') }

# --- R2: DNS --------------------------------------------------------------
$online = Invoke-Rung 'R2-dns' {
    & ipconfig /flushdns 2>&1 | Out-Null
    if (-not (Resolve-DnsName 'api.anthropic.com' -QuickTimeout -ErrorAction SilentlyContinue)) {
        [void]$findings.Add('DNS could not resolve api.anthropic.com; set public resolvers (1.1.1.1 / 8.8.8.8) on active adapters.')
        Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object Status -eq 'Up' |
            ForEach-Object {
                Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex `
                    -ServerAddresses '1.1.1.1', '8.8.8.8' -ErrorAction SilentlyContinue
            }
        & ipconfig /flushdns 2>&1 | Out-Null
    }
}
if ($online) { return (New-Result -Online $true -Rung 'R2-dns') }

# --- R3: hosts-file hijack ------------------------------------------------
$online = Invoke-Rung 'R3-hosts-hijack' {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path $hosts) {
        $lines = Get-Content $hosts -ErrorAction SilentlyContinue
        # Only touch lines that redirect Anthropic/Claude. Everything else in
        # this file may be deliberate and is none of our business.
        $bad = $lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '(anthropic|claude)' }
        if ($bad) {
            Copy-Item $hosts "$hosts.repairkit.bak" -Force -ErrorAction SilentlyContinue
            [void]$findings.Add("hosts file redirected Anthropic/Claude domains (likely malware). Commented out $($bad.Count) line(s); original saved as hosts.repairkit.bak.")
            $patched = $lines | ForEach-Object {
                if ($_ -notmatch '^\s*#' -and $_ -match '(anthropic|claude)') { "# [repair-kit] $_" } else { $_ }
            }
            $patched | Set-Content $hosts -Encoding ASCII -ErrorAction SilentlyContinue
            & ipconfig /flushdns 2>&1 | Out-Null
        }
    }
}
if ($online) { return (New-Result -Online $true -Rung 'R3-hosts-hijack') }

# --- R4: proxy (WinHTTP *and* WinINET) ------------------------------------
$online = Invoke-Rung 'R4-proxy' {
    $winhttp = (& netsh winhttp show proxy 2>&1 | Out-String)
    if ($winhttp -notmatch 'Direct access') {
        [void]$findings.Add('A WinHTTP proxy was configured; reset to direct access.')
        & netsh winhttp reset proxy 2>&1 | Out-Null
    }
    # Consumer and malware proxy hijacks live in WinINET, which the netsh
    # command above does not touch at all.
    $ie = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $cur = Get-ItemProperty -Path $ie -ErrorAction SilentlyContinue
    if ($cur -and $cur.ProxyEnable -eq 1) {
        [void]$findings.Add("A user-level (WinINET) proxy was enabled: '$($cur.ProxyServer)'. Disabled it; this is a common browser-hijack symptom.")
        Set-ItemProperty -Path $ie -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
    }
}
if ($online) { return (New-Result -Online $true -Rung 'R4-proxy') }

# --- Exhausted ------------------------------------------------------------
Write-KitLog -LogPath $LogPath -Level ERROR -Message 'Connectivity ladder exhausted; api.anthropic.com still unreachable.'
[void]$findings.Add('Could not establish a path to api.anthropic.com. `netsh winsock reset` and `netsh int ip reset` may fix a wedged TCP/IP stack, but both require a REBOOT and were deliberately not applied automatically.')
return (New-Result -Online $false -Rung 'none')
