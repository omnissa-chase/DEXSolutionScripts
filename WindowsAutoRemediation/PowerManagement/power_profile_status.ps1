<#
.NOTES
    Script Name  : power_profile_status.ps1
    Data Type    : String (JSON)
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07
    Timeout      : < 5 seconds

    Read-only reporting sensor. Reuses the detection sweep designed for the
    (not-yet-built) Invoke-AutoRemediatePowerPlan.ps1 -- mechanism detection,
    active scheme/overlay, policy-lock check, battery wear, and PROCTHROTTLEMAX
    AC/DC -- but makes NO changes. Remediation logic stays in that separate
    script; this sensor exists purely to surface findings to UEM.

    PROCTHROTTLEMAX is the single highest-yield finding: OEM tools and stale
    GPOs commonly cap AC max processor state below 100%, and the machine
    crawls permanently as a result -- this alone drives OverallStatus Critical.

    Modern Standby (S0ix) hardware hides the classic Balanced/High Performance
    schemes behind an "overlay" slider instead; `powercfg /a` is used to detect
    which mechanism is active so overlay vs. scheme is read correctly.
    `/energy` and `/batteryreport` are intentionally not used -- both are
    60-second traces that would blow this sensor's runtime budget.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $BatteryWearWarnPercent = 30

    $KnownOverlayNames = @{
        '00000000-0000-0000-0000-000000000000' = 'Balanced (Recommended)'
        '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Better Battery'
        'ded574b5-45a0-4f42-8737-46345c09c238' = 'Better Performance'
        '3af9b8d9-7c97-431d-ad78-34a8bfea439f' = 'Best Performance'
    }

    function Get-PowercfgValue {
        param([string[]]$Lines, [string]$LabelRegex)
        $line = $Lines | Where-Object { $_ -match $LabelRegex } | Select-Object -First 1
        if ($line -and $line -match "$LabelRegex\s*:\s*(.+)$") { return $Matches[1].Trim() }
        return $null
    }

    function ConvertFrom-PowercfgHex {
        param([string]$Value)
        if ($Value -and $Value -match '0x([0-9A-Fa-f]+)') {
            return [Convert]::ToInt32($Matches[1], 16)
        }
        return -1
    }

    # -- Mechanism (Modern Standby vs legacy S3 vs unsupported) --
    # `powercfg /a` prints two sections -- "available" and "not available" --
    # so membership must be checked against the AVAILABLE section only, not
    # just whether the state name appears anywhere in the output.
    $mechanism = 'Unsupported'
    try {
        $availability = (& powercfg /a 2>&1) -join "`n"
        $availableSection = ''
        if ($availability -match '(?s)available on this system:(.*?)(?:not available on this system:|$)') {
            $availableSection = $Matches[1]
        }
        if ($availableSection -match 'Standby \(S0 Low Power Idle\)') {
            $mechanism = 'ModernStandby'
        }
        elseif ($availableSection -match 'Standby \(S3\)') {
            $mechanism = 'S3'
        }
    } catch {}

    # -- Active scheme + overlay --
    $activeSchemeName = 'Unknown'
    try {
        $schemeRaw = & powercfg /getactivescheme 2>&1
        if ($schemeRaw -match '\(([^)]+)\)\s*$') { $activeSchemeName = $Matches[1] }
    } catch {}

    $activeOverlayName = 'N/A'
    try {
        $overlayGuid = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActiveOverlayAcPowerScheme' -ErrorAction SilentlyContinue).ActiveOverlayAcPowerScheme
        if ($overlayGuid) {
            $overlayGuid = $overlayGuid.ToString().Trim().ToLowerInvariant()
            $activeOverlayName = if ($KnownOverlayNames.ContainsKey($overlayGuid)) { $KnownOverlayNames[$overlayGuid] } else { "Custom ($overlayGuid)" }
        }
    } catch {}

    # -- Policy lock --
    $policyManaged = $false
    try {
        $policyKey = Get-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings' -ErrorAction SilentlyContinue
        if ($policyKey -and $policyKey.ValueCount -gt 0) { $policyManaged = $true }
    } catch {}

    # -- Battery presence, wear, power source --
    $hasBattery = $false
    $batteryWearPercent = -1
    $powerSource = 'AC'
    $estimatedChargeRemaining = -1
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($battery) {
            $hasBattery = $true
            $estimatedChargeRemaining = [int]$battery.EstimatedChargeRemaining

            try {
                $wmiBattery = Get-CimInstance -Namespace 'root\WMI' -ClassName 'BatteryStatus' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($wmiBattery) { $powerSource = if ($wmiBattery.PowerOnline) { 'AC' } else { 'DC' } }
            } catch {}

            try {
                $full   = (Get-CimInstance -Namespace 'root\WMI' -ClassName 'BatteryFullChargedCapacity' -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
                $design = (Get-CimInstance -Namespace 'root\WMI' -ClassName 'BatteryStaticData' -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
                if ($full -and $design -and $design -gt 0) {
                    $batteryWearPercent = [int][math]::Round((1 - ($full / $design)) * 100)
                }
            } catch {}
        }
    } catch {}

    # -- PROCTHROTTLEMAX AC/DC (highest-yield finding) --
    $procThrottleMaxAC = -1
    $procThrottleMaxDC = -1
    try {
        $procRaw = & powercfg /q SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 2>&1
        $procThrottleMaxAC = ConvertFrom-PowercfgHex (Get-PowercfgValue -Lines $procRaw -LabelRegex 'Current AC Power Setting Index')
        $procThrottleMaxDC = ConvertFrom-PowercfgHex (Get-PowercfgValue -Lines $procRaw -LabelRegex 'Current DC Power Setting Index')
    } catch {}

    # -- Battery Saver threshold --
    $batterySaverThresholdPercent = -1
    try {
        $saverRaw = & powercfg /q SCHEME_CURRENT SUB_ENERGYSAVER ESBATTTHRESHOLD 2>&1
        $batterySaverThresholdPercent = ConvertFrom-PowercfgHex (Get-PowercfgValue -Lines $saverRaw -LabelRegex 'Current AC Power Setting Index')
    } catch {}

    $overallStatus = 'Healthy'
    if ($procThrottleMaxAC -ge 0 -and $procThrottleMaxAC -lt 100) {
        $overallStatus = 'Critical'
    }
    elseif ($batteryWearPercent -ge $BatteryWearWarnPercent) {
        $overallStatus = 'Warning'
    }

    $result = [PSCustomObject]@{
        GeneratedAt                  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        OverallStatus                = $overallStatus
        StandbyMechanism             = $mechanism
        ActiveSchemeName             = $activeSchemeName
        ActiveOverlayName            = $activeOverlayName
        PolicyManaged                = $policyManaged
        HasBattery                   = $hasBattery
        PowerSource                  = $powerSource
        EstimatedChargeRemainingPct  = $estimatedChargeRemaining
        BatteryWearPercent           = $batteryWearPercent
        ProcThrottleMaxAC            = $procThrottleMaxAC
        ProcThrottleMaxDC            = $procThrottleMaxDC
        BatterySaverThresholdPercent = $batterySaverThresholdPercent
    }

    Write-Output ($result | ConvertTo-Json -Compress)
}
catch {
    Write-Output ([PSCustomObject]@{ OverallStatus = 'Unknown'; Error = $_.Exception.Message } | ConvertTo-Json -Compress)
}
