<#
.SYNOPSIS
    Build-NetworkDiagSteps.ps1 — Generates DiagSteps\NetworkDiagSteps.json
.DESCRIPTION
    Define each diagnostic step below as a native PowerShell hashtable.
    DetectionScript and ResolutionScript are written as real scriptblocks so
    they get full syntax highlighting, IntelliSense, and no JSON escaping.

    Run this script to regenerate NetworkDiagSteps.json.  The output file is
    what TroubleshootWizard.ps1 consumes — never edit the JSON directly.
.NOTES
    Add, remove, or reorder steps here, then re-run to rebuild the JSON.
    Set Enabled = $false to exclude a step without deleting it.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE in the repository root for full license terms (MIT).
#>

#region ── Step definitions ────────────────────────────────────────────────────

$Steps = @()

# ── 1. DNS Resolution ─────────────────────────────────────────────────────────
$Steps += @{
    Name         = 'DNS Resolution'
    Description  = 'Verifies that DNS servers are configured and can resolve external hostnames.'
    Enabled      = $true
    Order        = 1
    UserFeedback = 'Checking DNS server configuration and resolution...'

    DetectionScript = {
        $dns = (Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = 1' -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty DNSServerSearchOrder | Select-Object -Unique) -join ', '
        if (-not $dns) { return @{ Status = 'Failed'; Message = 'No DNS servers found' } }
        try {
            $null = Resolve-DnsName -Name 'google.com' -ErrorAction Stop
            return @{ Status = 'Passed'; Message = "DNS working ($dns)" }
        } catch {
            return @{ Status = 'Failed'; Message = 'DNS resolution failed' }
        }
    }

    ResolutionScript = { ipconfig /flushdns | Out-Null; ipconfig /renew | Out-Null }

    ResolutionText = @{
        Failed = "1. Open Network Adapter Settings and set DNS to 8.8.8.8 (Primary) and 8.8.4.4 (Secondary)`n2. Run 'ipconfig /flushdns' from an elevated command prompt`n3. Run 'ipconfig /renew' to refresh your network lease"
    }
    TestResultText = @{
        Passed  = 'DNS servers are responding and resolving external hostnames correctly.'
        Failed  = 'DNS servers are not configured or unable to resolve hostnames. Internet access may be broken.'
        Warning = 'DNS may be partially functional. Some name resolutions could fail intermittently.'
    }
}

# ── 2. Default Gateway ────────────────────────────────────────────────────────
$Steps += @{
    Name         = 'Default Gateway'
    Description  = 'Confirms the default gateway is configured and reachable via ICMP ping.'
    Enabled      = $true
    Order        = 2
    UserFeedback = 'Pinging your default gateway to confirm network path...'

    DetectionScript = {
        $gw = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = 1' -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty DefaultIPGateway | Select-Object -First 1
        if (-not $gw) { return @{ Status = 'Failed'; Message = 'No gateway configured' } }
        if (Test-Connection -ComputerName $gw -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return @{ Status = 'Passed'; Message = "Gateway reachable ($gw)" }
        }
        return @{ Status = 'Failed'; Message = "Gateway unreachable ($gw)" }
    }

    ResolutionScript = { ipconfig /release | Out-Null; ipconfig /renew | Out-Null }

    ResolutionText = @{
        Failed = "1. Run 'ipconfig /release' then 'ipconfig /renew' to request a new DHCP lease`n2. Restart your router or managed switch`n3. Verify the network cable is connected or WiFi is turned on"
    }
    TestResultText = @{
        Passed  = 'Default gateway is reachable. Layer-3 routing to the local network is healthy.'
        Failed  = 'Default gateway cannot be reached. You may be disconnected from the local network.'
        Warning = 'Gateway response was inconsistent. Network performance may be degraded.'
    }
}

# ── 3. Proxy Configuration ────────────────────────────────────────────────────
$Steps += @{
    Name         = 'Proxy Configuration'
    Description  = 'Checks whether a WinHTTP proxy is configured, which may be required in corporate environments.'
    Enabled      = $true
    Order        = 3
    UserFeedback = 'Inspecting WinHTTP proxy settings...'

    DetectionScript = {
        $proxy = netsh winhttp show proxy 2>$null
        if ($proxy -match 'No proxy') { return @{ Status = 'Warning'; Message = 'No proxy configured (may be required)' } }
        return @{ Status = 'Passed'; Message = 'Proxy configured' }
    }

    ResolutionScript = { Start-Process 'ms-settings:network-proxy' }

    ResolutionText = @{
        Warning = "1. If a corporate proxy is required, configure it via Settings > Network and Internet > Proxy`n2. Or run (as Admin): netsh winhttp set proxy proxy-server='proxyserver:port'`n3. Contact IT support for the correct proxy address and port"
    }
    TestResultText = @{
        Passed  = 'A proxy server is configured. Corporate traffic should route correctly.'
        Failed  = 'Proxy configuration query failed unexpectedly.'
        Warning = 'No proxy is configured. This may be expected on home networks, but required in corporate environments.'
    }
}

# ── 4. Network Adapters ───────────────────────────────────────────────────────
$Steps += @{
    Name         = 'Network Adapters'
    Description  = 'Checks for at least one active physical network adapter.'
    Enabled      = $true
    Order        = 4
    UserFeedback = 'Enumerating active physical network adapters...'

    DetectionScript = {
        $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        if ($adapters.Count -eq 0) { return @{ Status = 'Failed'; Message = 'No active adapters' } }
        return @{ Status = 'Passed'; Message = "$($adapters.Count) active adapter(s)" }
    }

    ResolutionScript = { Start-Process 'devmgmt.msc' }

    ResolutionText = @{
        Failed = "1. Open Device Manager (devmgmt.msc) and check for disabled or error-flagged adapters`n2. Right-click the adapter and choose Enable or Update Driver`n3. Verify the network cable is connected or the WiFi radio is enabled"
    }
    TestResultText = @{
        Passed  = 'One or more physical network adapters are active and ready.'
        Failed  = 'No active physical adapters found. The device may be disconnected or drivers may need attention.'
        Warning = 'Adapter state is indeterminate. Review Device Manager for details.'
    }
}

# ── 5. Firewall Status ────────────────────────────────────────────────────────
$Steps += @{
    Name         = 'Firewall Status'
    Description  = 'Verifies that at least one Windows Firewall profile is enabled.'
    Enabled      = $true
    Order        = 5
    UserFeedback = 'Reviewing Windows Firewall profile status...'

    DetectionScript = {
        $fw = Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object { $_.Enabled }
        if ($fw.Count -eq 0) { return @{ Status = 'Warning'; Message = 'Firewall disabled' } }
        return @{ Status = 'Passed'; Message = 'Firewall active' }
    }

    ResolutionScript = { Set-NetFirewallProfile -All -Enabled True }

    ResolutionText = @{
        Warning = "1. Open Windows Security > Firewall and Network Protection and enable for each profile`n2. Or run (as Admin): Set-NetFirewallProfile -All -Enabled True`n3. Contact IT if Group Policy is preventing the change"
    }
    TestResultText = @{
        Passed  = 'Windows Firewall is active on at least one network profile.'
        Failed  = 'Firewall query failed. Review Windows Security for details.'
        Warning = 'Windows Firewall appears to be disabled. This is a security risk; re-enable it if possible.'
    }
}

# ── 6. Internet Connectivity ──────────────────────────────────────────────────
$Steps += @{
    Name         = 'Internet Connectivity'
    Description  = "Pings Google's public DNS (8.8.8.8) to confirm external internet access."
    Enabled      = $true
    Order        = 6
    UserFeedback = 'Testing external internet connectivity via ping...'

    DetectionScript = {
        if (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return @{ Status = 'Passed'; Message = 'Internet accessible' }
        }
        return @{ Status = 'Failed'; Message = 'No internet connectivity' }
    }

    ResolutionScript = { ipconfig /flushdns | Out-Null }

    ResolutionText = @{
        Failed = "1. Confirm the network cable is plugged in or WiFi is connected`n2. Restart your modem and router (unplug for 30 seconds, then reconnect)`n3. Run 'ipconfig /flushdns' then 'ipconfig /renew'`n4. Contact your ISP if the issue persists after the above steps"
    }
    TestResultText = @{
        Passed  = 'External internet access is confirmed. Traffic can reach the public internet.'
        Failed  = 'Cannot reach the public internet. Local network may be up but WAN connectivity is broken.'
        Warning = 'Internet access is intermittent. Packets may be dropping or routing is unstable.'
    }
}

# ── 7. WiFi Signal Strength ───────────────────────────────────────────────────
$Steps += @{
    Name         = 'WiFi Signal Strength'
    Description  = 'Reports wireless signal quality as a percentage and rates it Excellent / Good / Fair / Weak.'
    Enabled      = $true
    Order        = 7
    UserFeedback = 'Measuring wireless signal strength via netsh...'

    DetectionScript = {
        try {
            $wifiInterface = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                             Where-Object { $_.MediaType -eq 'Wireless802.11' }
            if (-not $wifiInterface) { return @{ Status = 'Warning'; Message = 'No wireless adapter found' } }
            $wifiStatus = netsh wlan show interfaces 2>$null | Select-String 'Signal' | Out-String
            if ($wifiStatus -match 'Signal\s+:\s+(\d+)%') {
                $signal  = [int]$Matches[1]
                $quality = if ($signal -ge 80) { 'Excellent' } elseif ($signal -ge 60) { 'Good' } elseif ($signal -ge 40) { 'Fair' } else { 'Weak' }
                return @{ Status = 'Passed'; Message = "WiFi signal: $signal% ($quality)" }
            }
            return @{ Status = 'Warning'; Message = 'WiFi adapter present, signal unknown' }
        } catch { return @{ Status = 'Warning'; Message = 'Unable to determine WiFi status' } }
    }

    ResolutionScript = { Start-Process 'ms-settings:network-wifi' }

    ResolutionText = @{
        Warning = "1. Move closer to the wireless access point`n2. Reduce physical obstructions (walls, furniture) between the device and AP`n3. Switch to the 5 GHz band if available`n4. Check for interference from other nearby wireless devices or appliances"
    }
    TestResultText = @{
        Passed  = 'WiFi signal strength is being measured and reported successfully.'
        Failed  = 'WiFi signal check failed. The adapter may not be responding.'
        Warning = 'WiFi signal is weak or undetermined. Consider moving closer to the access point.'
    }
}

# ── 8. VPN Status ─────────────────────────────────────────────────────────────
$Steps += @{
    Name         = 'VPN Status'
    Description  = 'Checks whether any VPN connections are configured and if any are currently active.'
    Enabled      = $true
    Order        = 8
    UserFeedback = 'Checking VPN connection state...'

    DetectionScript = {
        try {
            $vpnConnections = Get-VpnS2SInterface -ErrorAction SilentlyContinue | Where-Object { $_.ConnectionState -eq 'Connected' }
            $rasConnections = Get-VpnS2SInterface -ErrorAction SilentlyContinue
            if ($vpnConnections) {
                $vpnNames = ($vpnConnections | Select-Object -ExpandProperty Name) -join ', '
                return @{ Status = 'Passed'; Message = "VPN connected: $vpnNames" }
            } elseif ($rasConnections) {
                return @{ Status = 'Warning'; Message = 'VPN configured but not connected' }
            }
            return @{ Status = 'Warning'; Message = 'No VPN configured' }
        } catch { return @{ Status = 'Warning'; Message = 'Unable to determine VPN status' } }
    }

    ResolutionScript = { Start-Process 'ms-settings:network-vpn' }

    ResolutionText = @{
        Warning = "1. Open your VPN client and connect to the appropriate server`n2. Verify your VPN credentials have not expired`n3. Contact IT support for VPN server details or a credential reset"
    }
    TestResultText = @{
        Passed  = 'A VPN connection is active.'
        Failed  = 'VPN status query encountered an unexpected error.'
        Warning = 'No active VPN connection detected. If VPN access is required for your work, connect before continuing.'
    }
}

# ── 9. Internet Speed Test ────────────────────────────────────────────────────
$Steps += @{
    Name         = 'Internet Speed Test'
    Description  = 'Downloads a small reference image and measures response time as a proxy for connection speed.'
    Enabled      = $true
    Order        = 9
    UserFeedback = 'Running a lightweight speed/latency test...'

    DetectionScript = {
        try {
            $testUrl   = 'https://www.google.com/images/branding/googlelogo/1x/googlelogo_color_272x92dp.png'
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $null      = (New-Object System.Net.WebClient).DownloadData($testUrl)
            $stopwatch.Stop()
            $timeMs = $stopwatch.ElapsedMilliseconds
            if ($timeMs -lt 500)      { return @{ Status = 'Passed';  Message = "Fast connection (~$timeMs ms response)" } }
            elseif ($timeMs -lt 2000) { return @{ Status = 'Passed';  Message = "Normal connection (~$timeMs ms response)" } }
            else                      { return @{ Status = 'Warning'; Message = "Slow connection (~$timeMs ms response)" } }
        } catch { return @{ Status = 'Failed'; Message = 'Speed test failed or no internet' } }
    }

    ResolutionScript = { Start-Process 'ms-settings:network' }

    ResolutionText = @{
        Failed  = "1. Confirm internet connectivity first (ping 8.8.8.8)`n2. Restart your modem and router`n3. Check for bandwidth-heavy background applications or downloads`n4. Contact your ISP if speeds remain consistently low"
        Warning = "1. Restart your modem and router to clear congestion`n2. Close background applications that consume bandwidth (streaming, cloud sync)`n3. Try connecting via Ethernet cable instead of WiFi for a more stable connection"
    }
    TestResultText = @{
        Passed  = 'Internet response time is within normal range.'
        Failed  = 'Speed test could not complete. No internet access or the test endpoint is unreachable.'
        Warning = 'Connection is slow. Consider restarting networking equipment or switching to a wired connection.'
    }
}

# ── 10. VPN Speed ─────────────────────────────────────────────────────────────
$Steps += @{
    Name         = 'VPN Speed (if connected)'
    Description  = 'If a VPN is active, measures download latency through the VPN tunnel.'
    Enabled      = $true
    Order        = 10
    UserFeedback = 'Testing download latency through the VPN tunnel (if active)...'

    DetectionScript = {
        try {
            $vpnConnections = Get-VpnS2SInterface -ErrorAction SilentlyContinue | Where-Object { $_.ConnectionState -eq 'Connected' }
            if (-not $vpnConnections) { return @{ Status = 'Warning'; Message = 'VPN speed test unable to run' } }
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $null      = (New-Object System.Net.WebClient).DownloadData('https://www.google.com/images/branding/googlelogo/1x/googlelogo_color_272x92dp.png')
            $stopwatch.Stop()
            $timeMs = $stopwatch.ElapsedMilliseconds
            return @{ Status = 'Passed'; Message = "VPN latency: ~$timeMs ms" }
        } catch { return @{ Status = 'Warning'; Message = 'VPN speed test unable to run' } }
    }

    ResolutionScript = { Start-Process 'ms-settings:network-vpn' }

    ResolutionText = @{
        Warning = "1. Disconnect and reconnect VPN to obtain a fresher server connection`n2. Switch to a VPN server geographically closer to your location`n3. Contact IT support if high latency persists across multiple servers"
    }
    TestResultText = @{
        Passed  = 'VPN tunnel latency is within acceptable range.'
        Failed  = 'VPN speed test failed unexpectedly.'
        Warning = 'VPN is either not connected (step skipped) or latency is high. Reconnect or switch servers.'
    }
}

#endregion

#region ── JSON generator ──────────────────────────────────────────────────────

$outputPath = Join-Path $PSScriptRoot 'DiagSteps\NetworkDiagSteps.json'

$jsonSteps = foreach ($step in $Steps) {
    $detection  = if ($step.DetectionScript  -is [scriptblock]) { $step.DetectionScript.ToString().Trim()  } else { [string]$step.DetectionScript }
    $resolution = if ($step.ResolutionScript -is [scriptblock]) { $step.ResolutionScript.ToString().Trim() } else { [string]$step.ResolutionScript }

    [ordered]@{
        Name             = $step.Name
        Description      = $step.Description
        Enabled          = $step.Enabled
        Order            = $step.Order
        UserFeedback     = $step.UserFeedback
        DetectionScript  = $detection
        ResolutionScript = $resolution
        ResolutionText   = $step.ResolutionText
        TestResultText   = $step.TestResultText
    }
}

$output = [ordered]@{
    '$schema'     = 'NetworkDiagSteps.schema.json'
    SchemaVersion = '1.0'
    Steps         = @($jsonSteps)
}

$output | ConvertTo-Json -Depth 6 | Set-Content -Path $outputPath -Encoding UTF8
Write-Host "Generated: $outputPath" -ForegroundColor Green

#endregion
