<#
.NOTES
    Script Name  : time_sync_health.ps1
    Data Type    : String (JSON)
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07
    Timeout      : < 5 seconds

    Reports W32Time service and clock-sync health. Uses "Time since Last Good
    Sync Time" from `w32tm /query /status /verbose` (a seconds-elapsed counter)
    rather than parsing "Last Successful Sync Time" as a date -- that field is
    locale-formatted text and unreliable to parse consistently across machines.

    The single highest-value check here is clock offset vs. the Kerberos max
    clock skew (5 minutes / 300s) on domain-joined machines: past that threshold
    authentication starts failing outright, independent of anything else being
    wrong. Workgroup machines are graded on a much looser bar since Windows
    intentionally does not keep them tightly synced.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $KerberosMaxSkewSeconds = 300
    $StaleSyncWarnSeconds   = 86400   # 24h
    $StaleSyncCritSeconds   = 259200  # 72h

    $svc = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
    $serviceStatus    = if ($svc) { $svc.Status.ToString() } else { 'NotFound' }
    $serviceStartType = if ($svc) { $svc.StartType.ToString() } else { 'Unknown' }

    $isDomainJoined = $false
    try {
        $isDomainJoined = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
    } catch {}

    $statusText = @()
    try { $statusText = & w32tm /query /status /verbose 2>&1 } catch {}

    function Get-W32tmValue {
        param([string[]]$Lines, [string]$LabelRegex)
        $line = $Lines | Where-Object { $_ -match $LabelRegex } | Select-Object -First 1
        if ($line -and $line -match "$LabelRegex\s*:\s*(.+)$") { return $Matches[1].Trim() }
        return $null
    }

    $isSynchronized = $true
    $leapLine = Get-W32tmValue -Lines $statusText -LabelRegex 'Leap Indicator'
    if ($leapLine -and $leapLine -match '^\s*3\b') { $isSynchronized = $false }

    $source = Get-W32tmValue -Lines $statusText -LabelRegex 'Source'
    if (-not $source) { $source = 'Unknown' }

    $stratum = -1
    $stratumRaw = Get-W32tmValue -Lines $statusText -LabelRegex 'Stratum'
    if ($stratumRaw -and $stratumRaw -match '^(\d+)') { $stratum = [int]$Matches[1] }

    $phaseOffsetSeconds = -1
    $offsetRaw = Get-W32tmValue -Lines $statusText -LabelRegex 'Phase Offset'
    if ($offsetRaw -and $offsetRaw -match '(-?[\d\.]+)s') {
        $phaseOffsetSeconds = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
    }

    $secondsSinceLastGoodSync = -1
    $sinceRaw = Get-W32tmValue -Lines $statusText -LabelRegex 'Time since Last Good Sync Time'
    if ($sinceRaw -and $sinceRaw -match '([\d\.]+)s') {
        $secondsSinceLastGoodSync = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
    }

    $exceedsKerberosSkew = ($phaseOffsetSeconds -ge 0) -and ([math]::Abs($phaseOffsetSeconds) -gt $KerberosMaxSkewSeconds)

    $overallStatus = 'Healthy'
    if ($serviceStatus -eq 'NotFound') {
        $overallStatus = 'Unknown'
    }
    elseif ($isDomainJoined) {
        if ($serviceStatus -ne 'Running' -or $exceedsKerberosSkew -or -not $isSynchronized) {
            $overallStatus = 'Critical'
        }
        elseif ($secondsSinceLastGoodSync -ge $StaleSyncCritSeconds) {
            $overallStatus = 'Critical'
        }
        elseif ($secondsSinceLastGoodSync -ge $StaleSyncWarnSeconds -or $secondsSinceLastGoodSync -lt 0) {
            $overallStatus = 'Warning'
        }
    }
    else {
        # Workgroup machines are not required to stay tightly synced; only flag
        # the service being fully disabled or a very large drift.
        if ($serviceStartType -eq 'Disabled' -or $exceedsKerberosSkew) {
            $overallStatus = 'Warning'
        }
    }

    $result = [PSCustomObject]@{
        GeneratedAt               = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        OverallStatus             = $overallStatus
        ServiceStatus             = $serviceStatus
        ServiceStartType          = $serviceStartType
        IsDomainJoined            = $isDomainJoined
        IsSynchronized            = $isSynchronized
        Source                    = $source
        Stratum                   = $stratum
        PhaseOffsetSeconds        = $phaseOffsetSeconds
        SecondsSinceLastGoodSync  = $secondsSinceLastGoodSync
        ExceedsKerberosSkew       = $exceedsKerberosSkew
    }

    Write-Output ($result | ConvertTo-Json -Compress)
}
catch {
    Write-Output ([PSCustomObject]@{ OverallStatus = 'Unknown'; Error = $_.Exception.Message } | ConvertTo-Json -Compress)
}
