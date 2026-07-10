<#
.SYNOPSIS
    NetworkResolutionWizard -- Automated network diagnostic and remediation.

.NOTES
    Script Name  : Invoke-AutoRemediateNetworkStack.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-09
    Timeout      : 15 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'DNS Resolution'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $dns = (
                Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = 1' `
                    -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty DNSServerSearchOrder |
                Select-Object -Unique
            ) -join ', '

            if (-not $dns) {
                return @{ Status = 'Failed'; Message = 'No DNS servers configured' }
            }
            try {
                $null = Resolve-DnsName -Name 'google.com' -ErrorAction Stop
                return @{ Status = 'Passed'; Message = "DNS resolving correctly ($dns)" }
            } catch {
                return @{ Status = 'Failed'; Message = "DNS configured ($dns) but resolution failed" }
            }
        }
        ResolutionScript = {
            ipconfig /flushdns | Out-Null
            ipconfig /renew    | Out-Null
        }
    },

    @{
        Name             = 'Default Gateway'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $gw = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = 1' `
                      -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty DefaultIPGateway |
                  Select-Object -First 1

            if (-not $gw) {
                return @{ Status = 'Failed'; Message = 'No default gateway configured' }
            }
            if (Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue) {
                return @{ Status = 'Passed'; Message = "Gateway reachable ($gw)" }
            }
            return @{ Status = 'Failed'; Message = "Gateway unreachable ($gw)" }
        }
        ResolutionScript = {
            ipconfig /release | Out-Null
            Start-Sleep -Seconds 2
            ipconfig /renew   | Out-Null
        }
    },

    @{
        Name             = 'Network Adapters'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                        Where-Object { $_.Status -eq 'Up' }

            if (-not $adapters -or $adapters.Count -eq 0) {
                return @{ Status = 'Failed'; Message = 'No active physical network adapters found' }
            }
            return @{ Status = 'Passed'; Message = "$($adapters.Count) active adapter(s): $(($adapters.Name) -join ', ')" }
        }
        ResolutionScript = {
            # Attempt to re-enable any disabled physical adapters
            Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Disabled' } |
                ForEach-Object { Enable-NetAdapter -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 3
        }
    },

    @{
        Name             = 'Winsock / IP Stack'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Validate the TCP/IP stack by opening a socket to a known reliable endpoint
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $ar  = $tcp.BeginConnect('8.8.8.8', 53, $null, $null)
                $ok  = $ar.AsyncWaitHandle.WaitOne(3000, $false)
                $tcp.Close()

                if ($ok) {
                    return @{ Status = 'Passed'; Message = 'TCP/IP stack is functional' }
                }
                return @{ Status = 'Failed'; Message = 'TCP/IP stack unresponsive -- socket timed out' }
            } catch {
                return @{ Status = 'Failed'; Message = "TCP/IP stack error: $($_.Exception.Message)" }
            }
        }
        ResolutionScript = {
            netsh winsock reset | Out-Null
            netsh int ip reset  | Out-Null
            # Note: a reboot is required to fully apply winsock/IP stack reset;
            # subsequent steps may still fail until the device is rebooted.
        }
    },

    @{
        Name             = 'Adapter Bounce'
        Order            = 5
        Enabled          = $true
        # Detection always returns Warning so ResolveOnWarning triggers the bounce
        # unconditionally as a layer-2 failsafe after Winsock/IP stack remediation.
        ResolveOnWarning = $true
        DetectionScript  = {
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                        Where-Object { $_.Status -eq 'Up' }

            if (-not $adapters -or $adapters.Count -eq 0) {
                return @{ Status = 'Failed'; Message = 'No active adapters found to bounce' }
            }
            return @{ Status = 'Warning'; Message = "Adapter bounce queued for: $(($adapters.Name) -join ', ')" }
        }
        ResolutionScript = {
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                        Where-Object { $_.Status -eq 'Up' }
            foreach ($adapter in $adapters) {
                Disable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 3
            foreach ($adapter in $adapters) {
                Enable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 5   # Allow DHCP and link negotiation to settle
        }
    },

    @{
        Name             = 'Firewall Status'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $true   # Firewall disabled returns 'Warning' -- still remediate
        DetectionScript  = {
            $profiles = Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                        Where-Object { $_.Enabled }

            if (-not $profiles -or $profiles.Count -eq 0) {
                return @{ Status = 'Warning'; Message = 'Windows Firewall is disabled on all profiles' }
            }
            $names = ($profiles.Name) -join ', '
            return @{ Status = 'Passed'; Message = "Firewall active on: $names" }
        }
        ResolutionScript = {
            Set-NetFirewallProfile -All -Enabled True -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Internet Connectivity'
        Order            = 7
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue) {
                return @{ Status = 'Passed'; Message = 'Internet accessible (8.8.8.8 reachable)' }
            }
            # Secondary check via HTTP in case ICMP is blocked
            try {
                $null = Invoke-WebRequest -Uri 'https://www.msftconnecttest.com/connecttest.txt' `
                            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                return @{ Status = 'Passed'; Message = 'Internet accessible (HTTP connectivity confirmed)' }
            } catch {}
            return @{ Status = 'Failed'; Message = 'No internet connectivity detected' }
        }
        ResolutionScript = {
            ipconfig /flushdns | Out-Null
            ipconfig /renew    | Out-Null
        }
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ''
Write-Host "`n-- NetworkResolutionWizard --------------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation ----------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # -- Output ---------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)          { '  -> Remediation ran' }
               elseif ($remError)        { "  -> Remediation ERROR: $remError" }
               else                      { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color

    $results.Add([PSCustomObject]@{
        Order       = $step.Order
        Name        = $step.Name
        Status      = $status
        Message     = $message
        Remediated  = $remediated
        RemError    = $remError
    })
}

# -- Summary -------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
