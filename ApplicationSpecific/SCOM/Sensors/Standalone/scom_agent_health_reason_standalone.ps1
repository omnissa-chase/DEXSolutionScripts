#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_agent_health_reason_standalone
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 4 seconds
    Requires     : nothing -- measures the device directly, no cache, no sweep script

    The single largest deduction behind scom_agent_health_score_standalone, as a
    stable token. Standalone counterpart to scom_agent_health_reason. Deploy one or
    the other, not both, and always deploy this WITH its score sensor -- a reason
    without a score tells you what is worst, not whether it matters.

    Values, in descending point order:

      HealthServiceStopped          40  Service not Running, or start type Manual/Disabled.
                                        The device is grey in the Operations console.
                                        Invoke-AutoRemediateSCOMAgentPart1.ps1 fixes this.
      NoManagementGroup             20  Agent installed but unassigned. On an endpoint
                                        fleet this is usually a Log Analytics install of
                                        the same binary, not a broken SCOM agent.
      ConfigurationCacheStale       15  Connector config untouched for over 24h.
      AgentRuntimeFootprintHigh     15  >400MB working set or >15% average CPU. Deploy
                                        Invoke-AutoRemediateSCOMMonitoringHost.ps1 to
                                        confirm over two samples and recycle.
      ChannelCertificateProblem     15  Missing, expired, or expiring within 30 days.
                                        PKI action -- nothing on the endpoint fixes it.
      TimeSyncStale                 15  No successful time sync in 48h. See
                                        GenericTroubleshooting/TimeSyncHealth.
      HealthServiceStateOversized   10  State folder above 1536MB. Deploy
                                        Invoke-AutoRemediateSCOMHealthServiceCache.ps1
                                        to a targeted ring.
      MultiHomedAgent                5  More than one management group. Legitimate, but
                                        every workflow set runs once per group.

      HealthyLocal                      No locally visible fault. Deliberately NOT the
                                        sweep's "Healthy": this sensor cannot see the
                                        management server or the event logs, so a device
                                        that cannot report at all still lands here.
      NoAgentInstalled                  No agent on the device. Not a fault -- exclude
                                        this population before computing any rate.
      ""                                Measurement failed.

    TimeSyncStale is named differently from the sweep's TimeSkew on purpose. The sweep
    measures real clock offset with w32tm.exe; a sensor may not launch a process, so
    this reads the age of the last successful sync instead. Related signal, different
    measurement, different name -- do not merge the two in a report.

    Only the largest deduction is reported. A device with four findings shows one. Use
    the individual standalone sensors alongside this to see the rest.

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

    if (-not $agentRoot -and -not $svc) { Write-Output 'NoAgentInstalled'; return }

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

    if ($null -eq $top) { Write-Output 'HealthyLocal'; return }

    Write-Output $top.R
    return
}
catch {
    Write-Output ""
    return
}
