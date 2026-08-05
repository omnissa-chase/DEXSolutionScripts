#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_duration_summary
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)

    Returns every logon phase timing as a single compressed JSON object.

    Use this instead of the 17 individual sensors when you want one sensor slot and
    intend to parse downstream (Workspace ONE Intelligence, a report, or an agent).
    Use the individual sensors when you want to chart, threshold, or alert on a value
    directly -- UEM cannot threshold inside a JSON string.

    All duration keys ending in "Ms" are integer milliseconds. Timestamps are ISO 8601
    local time, or null when unavailable.

    Sentinel values for the *Ms and *Count keys:
      -1  Unknown -- phase could not be measured
      -2  Not applicable -- feature not present on this device
      -3  Log disabled -- required event log is off; run DeployMode ConfigureLogging

    Returns {"CollectorPresent":false} when Measure-LogonDuration.ps1 has never run.
#>

try {
    $regPath = "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration"

    $data = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    if ($null -eq $data) {
        Write-Output '{"CollectorPresent":false}'
        return
    }

    # Defined before use: PowerShell 5.1 resolves functions at call time, but keeping
    # them above the payload keeps the read order obvious.
    function ConvertTo-Ms {
        param([object]$Raw)

        $s = [string]$Raw
        if ([string]::IsNullOrWhiteSpace($s)) { return -1 }
        if ($s -eq 'LogDisabled')             { return -3 }
        if ($s -eq 'N/A')                     { return -2 }
        if ($s -eq 'Unknown')                 { return -1 }

        $value = 0.0
        $ok = [double]::TryParse(($s -replace ',', '.'),
                  [Globalization.NumberStyles]::Float,
                  [Globalization.CultureInfo]::InvariantCulture, [ref]$value)
        if (-not $ok) { return -1 }

        return [int][math]::Round($value * 1000)
    }

    function ConvertTo-Count {
        param([object]$Raw)

        $s = [string]$Raw
        if ([string]::IsNullOrWhiteSpace($s)) { return -1 }
        if ($s -eq 'LogDisabled')             { return -3 }
        if ($s -eq 'N/A')                     { return -2 }
        if ($s -eq 'Unknown')                 { return -1 }

        $value = 0
        if (-not [int]::TryParse($s, [ref]$value)) { return -1 }
        return $value
    }

    function ConvertTo-Iso {
        param([object]$Raw)

        $s = [string]$Raw
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        if ($s -eq 'Unknown' -or $s -eq 'N/A' -or $s -eq 'LogDisabled') { return $null }

        $parsed = [datetime]::MinValue
        $ok = [datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm:ss',
                  [Globalization.CultureInfo]::InvariantCulture,
                  [Globalization.DateTimeStyles]::None, [ref]$parsed)
        if (-not $ok) {
            $ok = [datetime]::TryParse($s, [ref]$parsed)
        }
        if (-not $ok) { return $null }

        return $parsed.ToString('s')
    }

    $username = [string]$data.Username
    if ([string]::IsNullOrWhiteSpace($username) -or $username -eq 'Unknown') {
        $username = ""
    }

    $payload = [ordered]@{
        CollectorPresent    = $true
        CollectorVersion    = [string]$data.CollectorVersion
        Username            = $username
        LogonTime           = ConvertTo-Iso   $data.LogonTime
        ShellReadyTime      = ConvertTo-Iso   $data.ShellReadyTime
        DataCollectedAt     = ConvertTo-Iso   $data.DataCollectedAt
        TotalMs             = ConvertTo-Ms    $data.TotalLogonDurationSec
        GpStartTime         = ConvertTo-Iso   $data.GPStartTime
        GpMs                = ConvertTo-Ms    $data.GPDurationSec
        GpScriptsMs         = ConvertTo-Ms    $data.GPScriptsDurationSec
        FolderRedirectMs    = ConvertTo-Ms    $data.FolderRedirDurationSec
        ProfileLoadMs       = ConvertTo-Ms    $data.ProfileLoadDurationSec
        FslogixAttachMs     = ConvertTo-Ms    $data.FSLogixAttachDurationSec
        ActiveSetupMs       = ConvertTo-Ms    $data.ActiveSetupDurationSec
        AppxLoadMs          = ConvertTo-Ms    $data.AppXLoadDurationSec
        PrintersMappedCount = ConvertTo-Count $data.PrintersMappedCount
        PrinterMappingMs    = ConvertTo-Ms    $data.PrinterMappingDurationSec
        LogonTaskCount      = ConvertTo-Count $data.LogonTaskCount
        LogonTaskTotalMs    = ConvertTo-Ms    $data.LogonTaskTotalDurationSec
    }

    Write-Output (ConvertTo-Json -InputObject $payload -Compress)
    return
}
catch {
    Write-Output '{"CollectorPresent":false}'
    return
}
