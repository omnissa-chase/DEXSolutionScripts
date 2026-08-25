#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_agent_health_score_standalone
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 4 seconds
    Requires     : nothing -- measures the device directly, no cache, no sweep script

    Composite agent health, 0-100, computed live. Standalone counterpart to
    scom_agent_health_score. Deploy one or the other, not both.

    THE TWO SCORES ARE NOT THE SAME NUMBER AND MUST NOT BE POOLED.

    The sweep's score can deduct 235 points across fourteen checks. This one can
    deduct at most 130, because a recurring sensor may not make network calls and may
    not spend the seconds an event log query costs. Same point values, same reason
    names, same thresholds -- a strictly smaller set of rules:

      40  HealthServiceStopped          service not Running, or start type Manual/Disabled
      20  NoManagementGroup             no management group assigned
      15  ConfigurationCacheStale       connector config older than 24h
      15  AgentRuntimeFootprintHigh     >400MB working set or >15% average CPU
      15  ChannelCertificateProblem     missing, expired, or expiring within 30 days
      15  TimeSyncStale                 no successful time sync in 48h
      10  HealthServiceStateOversized   Health Service State above 1536MB
       5  MultiHomedAgent               assigned to more than one management group

    NOT COVERED HERE, and each of them is a genuine outage the sweep would catch:
    ManagementServerUnreachable (25, needs a socket probe), AgentNotRegistered (25),
    ConnectorAuthenticationFailure (20), HealthServiceStoreCorruption (20),
    WorkflowsUnloaded (10), and IntermittentConnectivity (5) -- all six need the
    Operations Manager and ESENT event logs, which cost seconds a recurring sensor
    does not have.

    So 100 here means "no locally visible fault", not "healthy". A device that cannot
    reach its management server at all still scores 100. That is the price of dropping
    the sweep, and it is the reason to run OneTimeSensor/scom_agent_health.ps1 once
    against the same fleet: it does the full fourteen-step assessment in a single
    run-once collection and will tell you how much this sensor is missing.

    -1 means no agent installed or the measurement failed -- it is NOT a bad score.
    Filter it out before averaging or the fleet number is fiction.

    Banding, unchanged from the sweep: 100 clean, 85-99 minor, 60-84 degraded,
    below 60 the agent is not doing its job. Read the band, not the digit -- the gap
    between 85 and 90 is one threshold crossing, not a trend.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # -- Tunables: MUST match Invoke-AutoRemediateSCOMAgentPart1/2/3.ps1 --
    $ConfigStaleHours    = 24
    $StateFolderWarnMB   = 1536
    $RuntimeMemoryWarnMB = 400
    $RuntimeCpuWarnPct   = 15
    $CertExpiryWarnDays  = 30
    $SyncStaleHours      = 48
    $StateFolderBudgetMs = 2500   # skip the subtree walk if the sensor is already slow

    $agentRoot = $null
    foreach ($candidate in @('HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0',
                             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft Operations Manager\3.0')) {
        if (Test-Path $candidate -ErrorAction SilentlyContinue) { $agentRoot = $candidate; break }
    }
    $svc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue

    if (-not $agentRoot -and -not $svc) { Write-Output -1; return }

    $deductions = @()

    # -- 40: HealthService not monitoring --
    # Running AND not Manual/Disabled, matching the sweep's ServiceRunning exactly.
    $serviceHealthy = $false
    if ($svc -and $svc.Status -eq 'Running') {
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='HealthService'" -ErrorAction SilentlyContinue
        if (-not $cim -or ($cim.StartMode -ne 'Disabled' -and $cim.StartMode -ne 'Manual')) { $serviceHealthy = $true }
    }
    if (-not $serviceHealthy) { $deductions += @{ P = 40; R = 'HealthServiceStopped' } }

    # -- 20 / 5: management group assignment --
    $mgCount = 0
    if ($agentRoot) {
        $mgRoot = Join-Path $agentRoot 'Agent Management Groups'
        if (Test-Path $mgRoot -ErrorAction SilentlyContinue) {
            $mgCount = @(Get-ChildItem -Path $mgRoot -ErrorAction SilentlyContinue).Count
        }
    }
    if     ($mgCount -eq 0) { $deductions += @{ P = 20; R = 'NoManagementGroup' } }
    elseif ($mgCount -gt 1) { $deductions += @{ P =  5; R = 'MultiHomedAgent' } }

    $installDir = ''
    if ($agentRoot) {
        $setup = Get-ItemProperty -Path (Join-Path $agentRoot 'Setup') -ErrorAction SilentlyContinue
        if ($setup -and $setup.InstallDirectory) { $installDir = [string]$setup.InstallDirectory }
    }

    # -- 15: configuration cache stale --
    if ($installDir) {
        $configDir = Join-Path $installDir 'Health Service State\Connector Configuration Cache'
        if (Test-Path -LiteralPath $configDir -ErrorAction SilentlyContinue) {
            $config = Get-ChildItem -Path $configDir -Filter 'OpsMgrConnector.Config.xml' -Recurse -File -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($config -and ((Get-Date) - $config.LastWriteTime).TotalHours -gt $ConfigStaleHours) {
                $deductions += @{ P = 15; R = 'ConfigurationCacheStale' }
            }
        }
    }

    # -- 15: runtime footprint --
    # @() matters: HealthService with no MonitoringHost child is a single object, and
    # (pipeline).Count on one object is empty in PowerShell 5.1.
    $procs = @(Get-Process -Name 'HealthService', 'MonitoringHost' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $memMB = [int][math]::Round((($procs | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB)

        # NUMBER_OF_PROCESSORS rather than a Win32_ComputerSystem query: same number,
        # no CIM round trip. A recurring sensor pays that cost on every sample.
        $cores = 0
        if (-not [int]::TryParse([string]$env:NUMBER_OF_PROCESSORS, [ref]$cores) -or $cores -lt 1) { $cores = 1 }

        $cpuSeconds = 0.0
        $lifetime   = 0.0
        foreach ($p in $procs) {
            try {
                $cpuSeconds += $p.TotalProcessorTime.TotalSeconds
                $span = ((Get-Date) - $p.StartTime).TotalSeconds
                if ($span -gt $lifetime) { $lifetime = $span }
            }
            catch { }
        }

        $cpuPct = -1.0
        if ($lifetime -gt 0) { $cpuPct = ($cpuSeconds / $lifetime / $cores) * 100 }

        if ($memMB -gt $RuntimeMemoryWarnMB -or ($cpuPct -ge 0 -and $cpuPct -gt $RuntimeCpuWarnPct)) {
            $deductions += @{ P = 15; R = 'AgentRuntimeFootprintHigh' }
        }
    }

    # -- 15: channel certificate --
    if ($agentRoot) {
        $machineSettings = Get-ItemProperty -Path (Join-Path $agentRoot 'Machine Settings') -ErrorAction SilentlyContinue
        $serial = if ($machineSettings) { $machineSettings.ChannelCertificateSerialNumber } else { $null }

        # Absence is not a fault: domain-joined agents authenticate with Kerberos.
        if ($serial) {
            $serialHex = ''
            if ($serial -is [byte[]]) {
                $bytes = [byte[]]::new($serial.Length)
                [array]::Copy($serial, $bytes, $serial.Length)
                [array]::Reverse($bytes)
                $serialHex = (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join '')
            }
            else {
                $serialHex = ([string]$serial).Replace(' ', '').ToUpperInvariant()
            }

            if ($serialHex) {
                $cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
                        Where-Object { $_.SerialNumber -eq $serialHex } | Select-Object -First 1

                if (-not $cert -or ($cert.NotAfter - (Get-Date)).TotalDays -lt $CertExpiryWarnDays) {
                    $deductions += @{ P = 15; R = 'ChannelCertificateProblem' }
                }
            }
        }
    }

    # -- 15: time synchronisation --
    # Sync AGE, not measured skew: skew needs w32tm.exe and a sensor may not launch a
    # process. Reported under its own reason name so it is never mistaken for the
    # sweep's measured TimeSkew.
    $w32Key = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
    $w32 = Get-ItemProperty -Path $w32Key -Name 'LastKnownGoodTime' -ErrorAction SilentlyContinue
    if ($w32 -and $w32.LastKnownGoodTime) {
        $lastSync = [DateTime]::FromFileTime([int64]$w32.LastKnownGoodTime)
        if (((Get-Date) - $lastSync).TotalHours -gt $SyncStaleHours) {
            $deductions += @{ P = 15; R = 'TimeSyncStale' }
        }
    }

    # -- 10: state folder oversized --
    # Last on purpose. It is the only unbounded read here, so it is also the only one
    # cheap to abandon: a sensor that is already slow skips it rather than blocking
    # the fleet-wide sensor queue for a 10-point deduction.
    if ($installDir -and $sw.ElapsedMilliseconds -lt $StateFolderBudgetMs) {
        $stateDir = Join-Path $installDir 'Health Service State'
        if (Test-Path -LiteralPath $stateDir -ErrorAction SilentlyContinue) {
            $fso = $null
            try {
                $fso = New-Object -ComObject Scripting.FileSystemObject
                if (($fso.GetFolder($stateDir).Size / 1MB) -gt $StateFolderWarnMB) {
                    $deductions += @{ P = 10; R = 'HealthServiceStateOversized' }
                }
            }
            catch { }
            finally { if ($fso) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso) } }
        }
    }

    # -- Result --
    # First-wins on a tie, and rules are appended in descending point order, so this
    # resolves identically to the sweep's Sort-Object without relying on a sort
    # stability guarantee PowerShell does not make.
    $top = $null
    foreach ($d in $deductions) { if ($null -eq $top -or $d.P -gt $top.P) { $top = $d } }

    $score = 100
    foreach ($d in $deductions) { $score -= $d.P }
    if ($score -lt 0) { $score = 0 }

    Write-Output $score
    return
}
catch {
    Write-Output -1
    return
}
