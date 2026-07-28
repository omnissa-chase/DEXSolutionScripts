<#
.SYNOPSIS
    Inspect and remediate Wi-Fi adapter, driver, and power settings that
    commonly cause low or unstable Wi-Fi signal.

.DESCRIPTION
    Runs an ordered sequence of Wi-Fi health checks and automatically executes
    the corresponding remediation for any step that fails (or warns, when
    ResolveOnWarning is set). Fully self-contained -- no JSON, no UI, no
    external dependencies.

    +------+------------------------------+----------------------------------+
    | Step | Name                         | Remediates On                    |
    +------+------------------------------+----------------------------------+
    |  1   | Wireless Adapter Detection   | --                               |
    |  2   | Wi-Fi Signal Strength        | Warning, Failed (adapter bounce) |
    |  3   | Driver Age                   | --                               |
    |  4   | NIC Power Management         | Failed                           |
    |  5   | Adapter Power Saving Mode    | Failed                           |
    |  6   | Power Plan Wireless Settings | Failed                           |
    |  7   | USB Selective Suspend        | Warning                          |
    +------+------------------------------+----------------------------------+

    Each step returns @{ Status = 'Passed'|'Warning'|'Failed'; Message = '...' }
    Resolution scripts run silently; errors are captured and reported at the end.

.PARAMETER AdapterName
    Optional: target a specific wireless adapter by Name (as shown in
    Get-NetAdapter). If omitted, all physical wireless adapters are used.
    Accepts env var: $env:AdapterName.  Default: '' (auto-detect).

.NOTES
    Script Name  : Invoke-AutoRemediateWiFiSignalIssues.ps1
    Version      : 2.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-28
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

param(
    [string]$AdapterName = $(if ($env:AdapterName) { $env:AdapterName } else { '' })
)

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Wireless Adapter Detection'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $found = if ($AdapterName) {
                @(Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)
            } else {
                @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                    Where-Object { $_.MediaType -match '802.11' -or
                                   $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN' })
            }
            if (-not $found -or $found.Count -eq 0) {
                $hint = if ($AdapterName) { " matching '$AdapterName'" } else { '' }
                return @{ Status = 'Failed'; Message = "No wireless adapter found$hint." }
            }
            $info = ($found | ForEach-Object { "$($_.Name) [$($_.InterfaceDescription)] - $($_.Status)" }) -join '; '
            return @{ Status = 'Passed'; Message = "$($found.Count) adapter(s): $info" }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Wi-Fi Signal Strength'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $true
        DetectionScript  = {
            try {
                $wlanOut  = netsh wlan show interfaces 2>$null
                $sigLine  = $wlanOut | Where-Object { $_ -match '^\s+Signal\s*:' } | Select-Object -First 1
                if (-not $sigLine) {
                    return @{ Status = 'Warning'; Message = 'Wi-Fi not connected or no signal data (netsh). Will bounce adapter.' }
                }
                $pct      = if ($sigLine -match '(\d+)%') { [int]$Matches[1] } else { 0 }
                $ssidLine = $wlanOut | Where-Object { $_ -match '^\s+SSID\s*:' } | Select-Object -First 1
                $ssid     = if ($ssidLine -match ':\s+(.+)') { $Matches[1].Trim() } else { 'Unknown' }
                if ($pct -ge 60) {
                    return @{ Status = 'Passed'; Message = "Signal $pct% on '$ssid' -- acceptable." }
                }
                if ($pct -ge 30) {
                    return @{ Status = 'Warning'; Message = "Signal $pct% on '$ssid' -- marginal (< 60%). Will bounce adapter." }
                }
                return @{ Status = 'Failed'; Message = "Signal $pct% on '$ssid' -- poor (< 30%). Physical or environment issue likely." }
            } catch {
                return @{ Status = 'Warning'; Message = "Could not read Wi-Fi signal info: $($_.Exception.Message)" }
            }
        }
        ResolutionScript = {
            $bounce = if ($AdapterName) {
                @(Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)
            } else {
                @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                    Where-Object { $_.MediaType -match '802.11' -or
                                   $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN' })
            }
            foreach ($a in $bounce) { Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 3
            foreach ($a in $bounce) { Enable-NetAdapter  -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 5
        }
    },

    @{
        Name             = 'Driver Age'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $wifiAdapters = if ($AdapterName) {
                @(Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)
            } else {
                @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                    Where-Object { $_.MediaType -match '802.11' -or
                                   $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN' })
            }
            $stale = @()
            foreach ($a in $wifiAdapters) {
                try {
                    $drvProps = Get-PnpDeviceProperty -InstanceId $a.PnPDeviceID `
                                    -KeyName 'DEVPKEY_Device_DriverDate','DEVPKEY_Device_DriverVersion' `
                                    -ErrorAction SilentlyContinue
                    $date = ($drvProps | Where-Object KeyName -eq 'DEVPKEY_Device_DriverDate').Data
                    $ver  = ($drvProps | Where-Object KeyName -eq 'DEVPKEY_Device_DriverVersion').Data
                    if ($date -and ([datetime]$date -lt (Get-Date).AddYears(-2))) {
                        $stale += "$($a.Name) (v$ver, dated $([datetime]$date | Get-Date -Format 'yyyy-MM-dd'))"
                    }
                } catch { }
            }
            if ($stale.Count -gt 0) {
                return @{ Status = 'Warning'; Message = "Driver(s) older than 2 years: $($stale -join '; '). Run Invoke-DriverUpdates.ps1 to update." }
            }
            return @{ Status = 'Passed'; Message = 'Wi-Fi driver(s) are current (less than 2 years old).' }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'NIC Power Management'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $wifiAdapters = if ($AdapterName) {
                @(Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)
            } else {
                @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                    Where-Object { $_.MediaType -match '802.11' -or
                                   $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN' })
            }
            $offenders = @()
            foreach ($a in $wifiAdapters) {
                try {
                    $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
                    if ($pm.AllowComputerToTurnOffDevice -eq 'Enabled') { $offenders += $a.Name }
                } catch { }
            }
            if ($offenders.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "'Allow computer to turn off device' is Enabled on: $($offenders -join ', ')." }
            }
            return @{ Status = 'Passed'; Message = "'Allow computer to turn off device' is Disabled on all wireless adapters." }
        }
        ResolutionScript = {
            $wifiAdapters = if ($AdapterName) {
                @(Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)
            } else {
                @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                    Where-Object { $_.MediaType -match '802.11' -or
                                   $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN' })
            }
            foreach ($a in $wifiAdapters) {
                Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Disabled `
                    -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name             = 'Adapter Power Saving Mode'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $wifiAdapters = if ($AdapterName) {
                @(Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)
            } else {
                @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                    Where-Object { $_.MediaType -match '802.11' -or
                                   $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN' })
            }
            $offenders = @()
            foreach ($a in $wifiAdapters) {
                $props = Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -match 'Power Saving Mode' -and
                                   $_.DisplayValue -notmatch 'Off|Disabled|Maximum Performance' }
                foreach ($p in $props) { $offenders += "$($a.Name): '$($p.DisplayName)' = $($p.DisplayValue)" }
            }
            if ($offenders.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "Power saving not at maximum performance: $($offenders -join '; ')." }
            }
            return @{ Status = 'Passed'; Message = 'Adapter power saving properties are at maximum performance (or not exposed by driver).' }
        }
        ResolutionScript = {
            $wifiAdapters = if ($AdapterName) {
                @(Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)
            } else {
                @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                    Where-Object { $_.MediaType -match '802.11' -or
                                   $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN' })
            }
            foreach ($a in $wifiAdapters) {
                $props = Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -match 'Power Saving Mode' -and
                                   $_.DisplayValue -notmatch 'Off|Disabled|Maximum Performance' }
                foreach ($p in $props) {
                    $target = $p.ValidDisplayValues |
                        Where-Object { $_ -match 'Off|Disabled|Maximum Performance' } |
                        Select-Object -First 1
                    if ($target) {
                        Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName $p.DisplayName `
                            -DisplayValue $target -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    },

    @{
        Name             = 'Power Plan Wireless Settings'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $wirelessGuid    = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
            $powerSavingGuid = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
            try {
                $schemeLine   = powercfg /getactivescheme | Where-Object { $_ -match 'GUID' } | Select-Object -First 1
                $activeScheme = if ($schemeLine -match 'GUID:\s*([\w-]+)') { $Matches[1] } else { $null }
                if (-not $activeScheme) {
                    return @{ Status = 'Failed'; Message = 'Could not determine active power scheme GUID.' }
                }
                $query  = powercfg /q $activeScheme $wirelessGuid $powerSavingGuid
                $acLine = $query | Where-Object { $_ -match 'Current AC Power Setting Index' }
                $dcLine = $query | Where-Object { $_ -match 'Current DC Power Setting Index' }
                $acVal  = if ($acLine -match '0x([0-9A-Fa-f]+)') { [Convert]::ToInt32($Matches[1], 16) } else { -1 }
                $dcVal  = if ($dcLine -match '0x([0-9A-Fa-f]+)') { [Convert]::ToInt32($Matches[1], 16) } else { -1 }
                if ($acVal -eq 0 -and $dcVal -eq 0) {
                    return @{ Status = 'Passed'; Message = "Wireless adapter power saving at Maximum Performance (AC=0, DC=0)." }
                }
                return @{ Status = 'Failed'; Message = "Wireless adapter power saving not at Maximum Performance (AC=$acVal, DC=$dcVal; 0=MaxPerf, 3=MaxSave)." }
            } catch {
                return @{ Status = 'Failed'; Message = "Could not query power plan settings: $($_.Exception.Message)" }
            }
        }
        ResolutionScript = {
            $wirelessGuid    = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
            $powerSavingGuid = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
            $schemeLine   = powercfg /getactivescheme | Where-Object { $_ -match 'GUID' } | Select-Object -First 1
            $activeScheme = if ($schemeLine -match 'GUID:\s*([\w-]+)') { $Matches[1] } else { return }
            powercfg /setacvalueindex $activeScheme $wirelessGuid $powerSavingGuid 0
            powercfg /setdcvalueindex $activeScheme $wirelessGuid $powerSavingGuid 0
            powercfg /setactive $activeScheme
        }
    },

    @{
        Name             = 'USB Selective Suspend'
        Order            = 7
        Enabled          = $true
        ResolveOnWarning = $true
        DetectionScript  = {
            $usbGuid     = '2a737441-1930-4402-8d77-b2bebba308a3'
            $suspendGuid = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
            try {
                $schemeLine   = powercfg /getactivescheme | Where-Object { $_ -match 'GUID' } | Select-Object -First 1
                $activeScheme = if ($schemeLine -match 'GUID:\s*([\w-]+)') { $Matches[1] } else { $null }
                if (-not $activeScheme) {
                    return @{ Status = 'Passed'; Message = 'Could not read power scheme; USB check skipped.' }
                }
                $query  = powercfg /q $activeScheme $usbGuid $suspendGuid 2>$null
                $acLine = $query | Where-Object { $_ -match 'Current AC Power Setting Index' }
                $acVal  = if ($acLine -match '0x([0-9A-Fa-f]+)') { [Convert]::ToInt32($Matches[1], 16) } else { $null }
                if ($null -eq $acVal) {
                    return @{ Status = 'Passed'; Message = 'USB Selective Suspend setting not found (non-USB adapter or not applicable).' }
                }
                # 0 = suspend enabled (can power off adapter); 1 = disabled (no suspend)
                if ($acVal -eq 0) {
                    return @{ Status = 'Warning'; Message = 'USB Selective Suspend is Enabled -- can drop USB Wi-Fi adapters. Will disable.' }
                }
                return @{ Status = 'Passed'; Message = 'USB Selective Suspend is Disabled -- USB adapters will not be suspended.' }
            } catch {
                return @{ Status = 'Passed'; Message = "USB Selective Suspend check skipped: $($_.Exception.Message)" }
            }
        }
        ResolutionScript = {
            $usbGuid     = '2a737441-1930-4402-8d77-b2bebba308a3'
            $suspendGuid = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
            $schemeLine   = powercfg /getactivescheme | Where-Object { $_ -match 'GUID' } | Select-Object -First 1
            $activeScheme = if ($schemeLine -match 'GUID:\s*([\w-]+)') { $Matches[1] } else { return }
            powercfg /setacvalueindex $activeScheme $usbGuid $suspendGuid 1
            powercfg /setdcvalueindex $activeScheme $usbGuid $suspendGuid 1
            powercfg /setactive $activeScheme
        }
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ''
Write-Host "`n-- Invoke-AutoRemediateWiFiSignalIssues ---------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '-------------------------------------------------------------------' -ForegroundColor Cyan

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
    $remNote = if ($remediated)    { '  -> Remediation ran' }
               elseif ($remError)  { "  -> Remediation ERROR: $remError" }
               else                { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n-------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "`n-------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0