#Requires -Version 5.1
<#
.SYNOPSIS
    Repairs Windows Time (W32Time) so the clock stays inside the Kerberos skew
    window: service state, time source configuration, a fresh sync, and the clock
    offset itself.

.DESCRIPTION
    Pairs with GenericTroubleshooting\TimeSyncHealth\time_sync_health.ps1, which grades
    the same four things. Past 5 minutes of skew, Kerberos authentication fails
    outright on a domain-joined device, so this is one of the few logon-breaking
    faults that is both common and fully repairable from the endpoint.

    +------+----------------------------------+------------------------------------------+
    | Step | Name                             | Action                                   |
    +------+----------------------------------+------------------------------------------+
    |  1   | W32Time Service                  | Set start type, start the service        |
    |  2   | Time Source Configuration        | Domain: point at the domain hierarchy    |
    |      |                                  | Workgroup: report, or set NTP on request |
    |  3   | Clock Synchronization            | Force a resync when stale or unsynced    |
    |  4   | Clock Offset                     | Resync; lift the phase-correction limit  |
    |      |                                  | when the clock is too far out to correct |
    |  5   | Hypervisor Time Sync Conflict    | Report only                              |
    +------+----------------------------------+------------------------------------------+

    Step 2 on a workgroup device is report-only by default. A workgroup machine with
    NoSync is often a VM that is deliberately taking time from its hypervisor; set
    ConfigureWorkgroupNtp=true to have the script configure an NTP peer instead.

    Step 4: W32Time refuses to correct an offset larger than MaxPos/NegPhaseCorrection
    (15 or 48 hours depending on build). When the clock is that far out the script
    temporarily lifts the limit, resyncs, and puts the original limits back. That is
    a large clock jump on a device whose clock is already unusable; disable it with
    AllowLargeCorrection=false if you would rather have it reported.

    Step 5 has no remediation. A VM that takes time from both the hypervisor and the
    domain fights itself; which source to turn off is a platform decision.

    Domain controllers are skipped entirely: a DC's time configuration is deliberate.

    Results are written to HKLM:\Software\AirWatch\Extensions\TimeSync\Remediation.

.PARAMETER KerberosMaxSkewSeconds
    Offset beyond which step 4 acts. Defaults to $env:KerberosMaxSkewSeconds, then 300.

.PARAMETER StaleSyncWarnSeconds
    Seconds since the last good sync beyond which step 3 acts. Defaults to
    $env:StaleSyncWarnSeconds, then 86400 (24 h).

.PARAMETER ConfigureWorkgroupNtp
    On a workgroup device with no usable time source, configure WorkgroupNtpServer
    instead of only reporting. Defaults to $env:ConfigureWorkgroupNtp, then false.

.PARAMETER WorkgroupNtpServer
    Peer list used when ConfigureWorkgroupNtp is set. Defaults to
    $env:WorkgroupNtpServer, then 'time.windows.com,0x9'.

.PARAMETER AllowLargeCorrection
    Let step 4 lift the phase-correction limit for a clock that is too far out for
    W32Time to correct on its own. Defaults to $env:AllowLargeCorrection, then true.

.PARAMETER ResyncWaitSeconds
    How long to wait for a resync to complete before calling it failed. A service
    that was just (re)started needs several seconds before its first poll lands.
    Defaults to $env:ResyncWaitSeconds, then 20.

.EXAMPLE
    $env:WhatIf = 'true'; .\Invoke-AutoRemediateTimeSync.ps1

    Reports what would change without touching the device. The intended first run.

.EXAMPLE
    .\Invoke-AutoRemediateTimeSync.ps1 -ConfigureWorkgroupNtp $true

    Also configures an NTP peer on workgroup devices that have none.

.NOTES
    Script Name  : Invoke-AutoRemediateTimeSync.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03 (1.0.1: two-stage resync with a 20 s default wait after
                   a freshly restarted service reported 'Local CMOS Clock' for longer
                   than the 10 s budget; the offset step no longer reports a 0 s
                   offset against the local clock as Passed)
    Timeout      : 60 seconds (worst case: two bounded resync waits of ResyncWaitSeconds)

    Environment variables: WhatIf=true (dry run; absent or unparseable means live) and
    one per parameter above, same names. Explicit parameters win over the environment.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateTimeSync {
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(30, 3600)]
    [int]$KerberosMaxSkewSeconds = $(
        $v = 0
        if ([int]::TryParse("$env:KerberosMaxSkewSeconds".Trim(), [ref]$v) -and $v -ge 30) { $v } else { 300 }
    ),

    [ValidateRange(600, 2592000)]
    [int]$StaleSyncWarnSeconds = $(
        $v = 0
        if ([int]::TryParse("$env:StaleSyncWarnSeconds".Trim(), [ref]$v) -and $v -ge 600) { $v } else { 86400 }
    ),

    [bool]$ConfigureWorkgroupNtp = $(
        $env:ConfigureWorkgroupNtp -and $env:ConfigureWorkgroupNtp.Trim() -in @('true', '1', 'yes', 'y')
    ),

    [string]$WorkgroupNtpServer = $(
        if ([string]::IsNullOrWhiteSpace($env:WorkgroupNtpServer)) { 'time.windows.com,0x9' } else { $env:WorkgroupNtpServer.Trim() }
    ),

    [bool]$AllowLargeCorrection = $(
        -not ($env:AllowLargeCorrection -and $env:AllowLargeCorrection.Trim() -in @('false', '0', 'no', 'n'))
    ),

    [ValidateRange(6, 45)]
    [int]$ResyncWaitSeconds = $(
        $v = 0
        if ([int]::TryParse("$env:ResyncWaitSeconds".Trim(), [ref]$v) -and $v -ge 6 -and $v -le 45) { $v } else { 20 }
    )
)

$SCRIPT_VERSION = "1.0.1"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\TimeSync\Remediation"
$DexRecordsPath = "HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\TimeSync"
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateTimeSync.log"
$W32Params      = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
$W32Config      = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'

# Modules are loaded before the WhatIf bridge: auto-loading them afterwards makes
# PowerShell print a "What if: Set Alias" line for every alias they define.
Import-Module CimCmdlets -ErrorAction SilentlyContinue

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot set $WhatIfPreference directly. Bridge it from an environment
# variable. Absent, empty, or unparseable => $false (live run).
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing Invoke-AutoRemediateTimeSync, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # -WhatIf:$false so a dry run is still recorded; the log is evidence, not state.
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

Write-Log "Settings: KerberosMaxSkewSeconds=$KerberosMaxSkewSeconds StaleSyncWarnSeconds=$StaleSyncWarnSeconds ConfigureWorkgroupNtp=$ConfigureWorkgroupNtp WorkgroupNtpServer='$WorkgroupNtpServer' AllowLargeCorrection=$AllowLargeCorrection ResyncWaitSeconds=$ResyncWaitSeconds"

# -- Pre-flight ------------------------------------------------------------------
$svc = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Output "$HEAD The Windows Time service is not present on this device. Nothing to do."
    Write-Log 'W32Time service not found. Exiting without changes.'
    exit 0
}

$cs             = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$IsDomainJoined = [bool]($cs -and $cs.PartOfDomain)
$IsDomainController = [bool]($cs -and $cs.DomainRole -ge 4)
$IsVirtual      = [bool]($cs -and ("$($cs.Manufacturer) $($cs.Model)" -match 'VMware|Virtual|Hyper-V|QEMU|KVM|Xen|Nutanix|Parallels'))

if ($IsDomainController) {
    Write-Output "$HEAD This device is a domain controller; its time configuration is deliberate. Nothing to do."
    Write-Log 'Domain controller detected. Exiting without changes.'
    exit 0
}

Write-Log "Device: DomainJoined=$IsDomainJoined Virtual=$IsVirtual Manufacturer='$($cs.Manufacturer)' Model='$($cs.Model)'"

# -- Helpers -----------------------------------------------------------------------
# w32tm's status output is locale-formatted text. Only counters that are printed as
# numbers with a unit are parsed; the human-readable dates are never touched.
function Get-W32tmStatus {
    $lines = @()
    try { $lines = @(& w32tm.exe /query /status /verbose 2>&1 | ForEach-Object { [string]$_ }) } catch { $lines = @() }

    $get = {
        param([string]$Label)
        $line = $lines | Where-Object { $_ -match "^\s*$Label\s*:" } | Select-Object -First 1
        if ($line -and $line -match "^\s*$Label\s*:\s*(.+)$") { return $Matches[1].Trim() }
        return $null
    }

    $leap = & $get 'Leap Indicator'
    $isSynchronized = -not ($leap -and $leap -match '^\s*3\b')

    $offset = $null
    $raw = & $get 'Phase Offset'
    if ($raw -and $raw -match '(-?[\d\.]+)s') {
        $offset = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
    }

    $since = $null
    $raw = & $get 'Time since Last Good Sync Time'
    if ($raw -and $raw -match '([\d\.]+)s') {
        $since = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
    }

    $stratum = $null
    $raw = & $get 'Stratum'
    if ($raw -and $raw -match '^(\d+)') { $stratum = [int]$Matches[1] }

    return [PSCustomObject]@{
        Available        = ($lines.Count -gt 0 -and $null -ne $leap)
        IsSynchronized   = $isSynchronized
        PhaseOffsetSec   = $offset
        SecondsSinceSync = $since
        Stratum          = $stratum
        Source           = (& $get 'Source')
    }
}

function Get-W32Configuration {
    $p = Get-ItemProperty -Path $W32Params -ErrorAction SilentlyContinue
    $c = Get-ItemProperty -Path $W32Config -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        Type      = [string]$p.Type
        NtpServer = [string]$p.NtpServer
        MaxPos    = if ($null -ne $c.MaxPosPhaseCorrection) { [uint32]$c.MaxPosPhaseCorrection } else { 54000 }
        MaxNeg    = if ($null -ne $c.MaxNegPhaseCorrection) { [uint32]$c.MaxNegPhaseCorrection } else { 54000 }
    }
}

function Invoke-W32tm {
    # Returns the combined output; throws when w32tm reports a non-zero exit code.
    param([string[]]$Arguments)
    $out = & w32tm.exe @Arguments 2>&1 | ForEach-Object { [string]$_ }
    if ($LASTEXITCODE -ne 0) { throw "w32tm $($Arguments -join ' ') failed ($LASTEXITCODE): $(($out -join ' ').Trim())" }
    return $out
}

function Test-W32Fresh {
    param($S)
    return ($S.Available -and $S.IsSynchronized -and $null -ne $S.SecondsSinceSync -and $S.SecondsSinceSync -lt 120 -and $S.Source -notmatch 'Local CMOS Clock|Free-running')
}

function Wait-W32Sync {
    # Two stages inside one budget. First a queued resync with source rediscovery,
    # polled for half the budget. A service that was just restarted can still be
    # settling then (it reports 'Local CMOS Clock' until its first poll completes),
    # so the second half issues a blocking resync, which also returns w32tm's own
    # reason when no time data is available, and polls until the deadline.
    param([int]$WaitSeconds)
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $midpoint = (Get-Date).AddSeconds([math]::Max(3, [int]($WaitSeconds / 2)))

    $null = Invoke-W32tm -Arguments @('/resync', '/rediscover', '/nowait')
    do {
        Start-Sleep -Milliseconds 1000
        $s = Get-W32tmStatus
        if (Test-W32Fresh $s) { return $s }
    } while ((Get-Date) -lt $midpoint)

    $script:LastResyncMessage = ''
    try { $null = Invoke-W32tm -Arguments @('/resync') }
    catch { $script:LastResyncMessage = $_.Exception.Message }
    do {
        $s = Get-W32tmStatus
        if (Test-W32Fresh $s) { return $s }
        Start-Sleep -Milliseconds 1000
    } while ((Get-Date) -lt $deadline)
    return $s
}

function Get-HypervisorTimeSync {
    # Which hypervisor integration is pushing time into this guest, if any.
    $sources = @()
    $hv = Get-Service -Name 'vmictimesync' -ErrorAction SilentlyContinue
    if ($hv -and $hv.Status -eq 'Running') { $sources += 'Hyper-V Time Synchronization service' }

    $toolbox = Join-Path $env:ProgramFiles 'VMware\VMware Tools\VMwareToolboxCmd.exe'
    if (Test-Path -LiteralPath $toolbox) {
        try {
            $state = (& $toolbox timesync status 2>&1 | Out-String).Trim()
            if ($state -match '^Enabled') { $sources += 'VMware Tools periodic time sync' }
        } catch { }
    }
    return $sources
}

$Config = Get-W32Configuration
$Status = Get-W32tmStatus
Write-Log "Service: Status=$($svc.Status) StartType=$($svc.StartType)  Config: Type=$($Config.Type) NtpServer='$($Config.NtpServer)' MaxPos=$($Config.MaxPos) MaxNeg=$($Config.MaxNeg)  Status: Sync=$($Status.IsSynchronized) Offset=$($Status.PhaseOffsetSec) Since=$($Status.SecondsSinceSync) Source='$($Status.Source)'"

$script:ResyncedThisRun = $false

# -- Step Definitions -----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        # Domain members need the service running and Automatic. Workgroup devices
        # start it on a trigger, so Manual is normal there; Disabled never is, and a
        # workgroup device with an NTP peer configured should still be running it.
        Name             = 'W32Time Service'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $svc = Get-Service -Name 'W32Time'
            $wantRunning = $IsDomainJoined -or ($Config.Type -ne 'NoSync' -and -not [string]::IsNullOrWhiteSpace($Config.NtpServer))
            if ($svc.StartType -eq 'Disabled') {
                return @{ Status = 'Failed'; Message = "W32Time is Disabled (status $($svc.Status))" }
            }
            if ($IsDomainJoined -and $svc.StartType -ne 'Automatic') {
                return @{ Status = 'Failed'; Message = "W32Time start type is $($svc.StartType); a domain member needs Automatic" }
            }
            if ($wantRunning -and $svc.Status -ne 'Running') {
                return @{ Status = 'Failed'; Message = "W32Time is $($svc.Status) with a time source configured" }
            }
            return @{ Status = 'Passed'; Message = "W32Time is $($svc.Status), start type $($svc.StartType)" }
        }
        ResolutionScript = {
            $target = if ($IsDomainJoined) { 'Automatic' } else { 'Manual' }
            $svc = Get-Service -Name 'W32Time'
            if ($svc.StartType -eq 'Disabled' -or ($IsDomainJoined -and $svc.StartType -ne 'Automatic')) {
                Set-Service -Name 'W32Time' -StartupType $target -ErrorAction Stop
            }
            if ((Get-Service -Name 'W32Time').Status -ne 'Running') {
                Start-Service -Name 'W32Time' -ErrorAction Stop
            }
            $after = Get-Service -Name 'W32Time'
            if ($after.Status -ne 'Running') { throw "W32Time is still $($after.Status) after Start-Service" }
            # Later steps read status from a running service.
            $script:Status = Get-W32tmStatus
        }
    },

    @{
        Name             = 'Time Source Configuration'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $cfg = Get-W32Configuration
            if ($IsDomainJoined) {
                if ($cfg.Type -eq 'NT5DS' -or $cfg.Type -eq 'AllSync') {
                    return @{ Status = 'Passed'; Message = "Type $($cfg.Type): taking time from the domain hierarchy" }
                }
                return @{ Status = 'Failed'; Message = "Type is '$($cfg.Type)' (peer '$($cfg.NtpServer)') on a domain member; expected NT5DS" }
            }
            $hasPeer = ($cfg.Type -eq 'NTP' -or $cfg.Type -eq 'AllSync') -and -not [string]::IsNullOrWhiteSpace($cfg.NtpServer)
            if ($hasPeer) {
                return @{ Status = 'Passed'; Message = "Type $($cfg.Type), peer '$($cfg.NtpServer)'" }
            }
            $hv = Get-HypervisorTimeSync
            $note = if ($hv.Count -gt 0) { " Time is coming from: $($hv -join ', ')." } else { '' }
            if ($ConfigureWorkgroupNtp) {
                return @{ Status = 'Failed'; Message = "Workgroup device has no NTP peer (Type '$($cfg.Type)').$note Configuring '$WorkgroupNtpServer'" }
            }
            return @{ Status = 'Warning'; Message = "Workgroup device has no NTP peer (Type '$($cfg.Type)').$note Set ConfigureWorkgroupNtp=true to configure '$WorkgroupNtpServer'; not auto-remediated" }
        }
        ResolutionScript = {
            if ($IsDomainJoined) {
                $null = Invoke-W32tm -Arguments @('/config', '/syncfromflags:domhier', '/update')
            } else {
                $null = Invoke-W32tm -Arguments @('/config', "/manualpeerlist:$WorkgroupNtpServer", '/syncfromflags:manual', '/update')
            }
            Restart-Service -Name 'W32Time' -ErrorAction Stop
            $script:Config = Get-W32Configuration
            $script:Status = Wait-W32Sync -WaitSeconds $ResyncWaitSeconds
            $script:ResyncedThisRun = $true
            if (-not $script:Status.IsSynchronized) {
                throw "Source reconfigured but the clock did not synchronise within $ResyncWaitSeconds s; the time source may be unreachable"
            }
        }
    },

    @{
        Name             = 'Clock Synchronization'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $s = Get-W32tmStatus
            if (-not $s.Available) {
                return @{ Status = 'Failed'; Message = 'w32tm reported no status (service not running or not responding)' }
            }
            if ($Config.Type -eq 'NoSync' -and -not $IsDomainJoined) {
                return @{ Status = 'Passed'; Message = 'Workgroup device with Type NoSync; synchronisation not expected from W32Time' }
            }
            if (-not $s.IsSynchronized) {
                return @{ Status = 'Failed'; Message = "Clock is not synchronised (leap indicator 3); source '$($s.Source)'" }
            }
            if ($null -eq $s.SecondsSinceSync -or $s.SecondsSinceSync -ge $StaleSyncWarnSeconds) {
                $age = if ($null -eq $s.SecondsSinceSync) { 'unknown' } else { "$([math]::Round($s.SecondsSinceSync / 3600, 1)) h" }
                return @{ Status = 'Failed'; Message = "Last good sync was $age ago (threshold $([math]::Round($StaleSyncWarnSeconds / 3600, 1)) h); source '$($s.Source)'" }
            }
            return @{ Status = 'Passed'; Message = "Synchronised $([math]::Round($s.SecondsSinceSync / 60, 1)) min ago from '$($s.Source)', stratum $($s.Stratum)" }
        }
        ResolutionScript = {
            $script:Status = Wait-W32Sync -WaitSeconds $ResyncWaitSeconds
            $script:ResyncedThisRun = $true
            if (-not (Test-W32Fresh $script:Status)) {
                $why = if ($script:LastResyncMessage) { " w32tm: $($script:LastResyncMessage)" } else { '' }
                throw "Resync did not complete within $ResyncWaitSeconds s (source '$($script:Status.Source)', peer '$($Config.NtpServer)'); the time source may be unreachable (network, VPN, DNS, or DC).$why"
            }
        }
    },

    @{
        Name             = 'Clock Offset'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $s = Get-W32tmStatus
            if ($null -eq $s.PhaseOffsetSec) {
                return @{ Status = 'Warning'; Message = 'Phase offset not reported; see Clock Synchronization' }
            }
            if (-not $s.IsSynchronized -or $s.Source -match 'Local CMOS Clock|Free-running') {
                # An offset against the local clock is always zero and means nothing.
                return @{ Status = 'Warning'; Message = "Not synchronised to any source (reporting '$($s.Source)'); offset cannot be measured. See Clock Synchronization" }
            }
            $abs = [math]::Abs($s.PhaseOffsetSec)
            if ($abs -gt $KerberosMaxSkewSeconds) {
                return @{ Status = 'Failed'; Message = "Clock is $([math]::Round($abs, 1)) s from its source (Kerberos limit $KerberosMaxSkewSeconds s)" }
            }
            return @{ Status = 'Passed'; Message = "Offset $([math]::Round($s.PhaseOffsetSec, 3)) s from '$($s.Source)'" }
        }
        ResolutionScript = {
            $before = Get-W32tmStatus
            $abs    = [math]::Abs($before.PhaseOffsetSec)
            $limit  = [math]::Min($Config.MaxPos, $Config.MaxNeg)
            $lifted = $false

            if ($abs -gt $limit) {
                if (-not $AllowLargeCorrection) {
                    throw "Offset $([math]::Round($abs)) s exceeds the W32Time correction limit ($limit s) and AllowLargeCorrection is false; correct the clock manually"
                }
                # Lift the limit for one resync, then restore it so the service does not
                # keep accepting huge jumps from a bad source afterwards.
                Set-ItemProperty -Path $W32Config -Name 'MaxPosPhaseCorrection' -Value ([uint32]::MaxValue) -Type DWord -ErrorAction Stop
                Set-ItemProperty -Path $W32Config -Name 'MaxNegPhaseCorrection' -Value ([uint32]::MaxValue) -Type DWord -ErrorAction Stop
                $null   = Invoke-W32tm -Arguments @('/config', '/update')
                $lifted = $true
            }

            try {
                $script:Status = Wait-W32Sync -WaitSeconds $ResyncWaitSeconds
                $script:ResyncedThisRun = $true
            } finally {
                if ($lifted) {
                    Set-ItemProperty -Path $W32Config -Name 'MaxPosPhaseCorrection' -Value $Config.MaxPos -Type DWord -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $W32Config -Name 'MaxNegPhaseCorrection' -Value $Config.MaxNeg -Type DWord -ErrorAction SilentlyContinue
                    try { $null = Invoke-W32tm -Arguments @('/config', '/update') } catch { }
                }
            }

            $after = $script:Status
            if ($null -eq $after.PhaseOffsetSec -or [math]::Abs($after.PhaseOffsetSec) -gt $KerberosMaxSkewSeconds) {
                $now = if ($null -eq $after.PhaseOffsetSec) { 'unknown' } else { "$([math]::Round([math]::Abs($after.PhaseOffsetSec), 1)) s" }
                throw "Offset is still $now after resync (was $([math]::Round($abs, 1)) s); the source may be unreachable or itself wrong"
            }
        }
    },

    @{
        # Report only. A guest that takes time from the hypervisor and from the domain
        # has two masters. Turning one off is a platform decision, not an endpoint fix.
        Name             = 'Hypervisor Time Sync Conflict'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $IsVirtual) { return @{ Status = 'Passed'; Message = 'Physical device' } }
            $hv = Get-HypervisorTimeSync
            if ($hv.Count -eq 0) { return @{ Status = 'Passed'; Message = 'Virtual machine; no hypervisor time sync active' } }
            $cfg = Get-W32Configuration
            if ($cfg.Type -eq 'NoSync') {
                return @{ Status = 'Passed'; Message = "Virtual machine taking time from: $($hv -join ', ') (W32Time NoSync, no conflict)" }
            }
            return @{ Status = 'Warning'; Message = "Two time sources: $($hv -join ', ') and W32Time ($($cfg.Type)). Disable one at the platform level; not auto-remediated" }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine ------------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Output "`r`n-- Invoke-AutoRemediateTimeSync -------------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   Domain joined: $IsDomainJoined"
Write-Output '--------------------------------------------------------------------'

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

    # -- Remediation ------------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        if ($PSCmdlet.ShouldProcess($step.Name, 'Repair Windows Time')) {
            try {
                & $step.ResolutionScript | Out-Null
                $remediated = $true
            } catch {
                $remError = $_.Exception.Message
            }
        }
    }

    # -- Output -------------------------------------------------------------------
    $remNote = if ($remediated)   { '  -> Remediated' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$remNote"
    Write-Log "$($step.Name): $status - $message$remNote"

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -----------------------------------------------------------------
$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count
$remErrs  = @($results | Where-Object { $_.RemError }).Count

$final = Get-W32tmStatus
Write-Output "`r`n--------------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations applied: $remCount"
Write-Output "  Clock: synchronised=$($final.IsSynchronized)  offset=$($final.PhaseOffsetSec)s  source='$($final.Source)'"
Write-Output "--------------------------------------------------------------------`r`n"
Write-Log "Summary: Passed=$passed Warnings=$warnings Failed=$failed RemediationsApplied=$remCount RemediationErrors=$remErrs Resynced=$($script:ResyncedThisRun) FinalOffset=$($final.PhaseOffsetSec)"

# -- Registry Reporting --------------------------------------------------------
# Skipped entirely on a WhatIf run -- a dry run must not claim a remediation state
# that was never actually applied.
if (-not $WhatIfPreference) {
    try {
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $RegPath -Name 'LastRun'           -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion'     -Value $SCRIPT_VERSION -Type String
        Set-ItemProperty -Path $RegPath -Name 'Passed'            -Value $passed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Warnings'          -Value $warnings -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Failed'            -Value $failed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationsRun'   -Value $remCount -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationErrors' -Value $remErrs  -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Resynced'          -Value $(if ($script:ResyncedThisRun) { 1 } else { 0 }) -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'FinalOffsetSec'    -Value $(if ($null -ne $final.PhaseOffsetSec) { [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $final.PhaseOffsetSec) } else { 'Unknown' }) -Type String
        Write-Log "Results cached to $RegPath"
    } catch {
        Write-Log "Registry cache write failed: $($_.Exception.Message)" 'WARN'
    }

    # Per-step DEXRecords values (family convention), so a runbook can tell which
    # step warned or failed. Fully wrapped: a registry failure here must never
    # change the exit code.
    try {
        if (-not (Test-Path $DexRecordsPath)) {
            New-Item -Path $DexRecordsPath -Force -ErrorAction Stop | Out-Null
        }
        $existing = Get-Item -Path $DexRecordsPath -ErrorAction SilentlyContinue
        if ($existing) {
            $existing.GetValueNames() | ForEach-Object {
                Remove-ItemProperty -Path $DexRecordsPath -Name $_ -ErrorAction SilentlyContinue
            }
        }
        Set-ItemProperty -Path $DexRecordsPath -Name 'LastScanTime'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ItemProperty -Path $DexRecordsPath -Name 'ScriptVersion'   -Value $SCRIPT_VERSION -Type String
        Set-ItemProperty -Path $DexRecordsPath -Name 'TotalSteps'      -Value $results.Count -Type DWord
        Set-ItemProperty -Path $DexRecordsPath -Name 'PassedCount'     -Value $passed        -Type DWord
        Set-ItemProperty -Path $DexRecordsPath -Name 'WarningCount'    -Value $warnings      -Type DWord
        Set-ItemProperty -Path $DexRecordsPath -Name 'FailedCount'     -Value $failed        -Type DWord
        Set-ItemProperty -Path $DexRecordsPath -Name 'RemediatedCount' -Value $remCount      -Type DWord
        foreach ($r in $results) {
            $valueName = 'Step{0:D2}_{1}' -f $r.Order, ($r.Name -replace '[^A-Za-z0-9]', '')
            $tag       = if ($r.Remediated) { '[Remediated]' } else { "[$($r.Status)]" }
            $text      = "$tag $($r.Name): $($r.Message)"
            if ($r.RemError) { $text += "  -> Remediation ERROR: $($r.RemError)" }
            if ($text.Length -gt 500) { $text = $text.Substring(0, 497) + '...' }
            Set-ItemProperty -Path $DexRecordsPath -Name $valueName -Value $text -Type String
        }
        Write-Log "Per-step results written to $DexRecordsPath"
    } catch {
        Write-Log "DEXRecords write failed: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-Log 'WhatIf run -- registry cache left untouched.'
}

exit $(if ($remErrs -gt 0) { 1 } else { 0 })
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

Invoke-AutoRemediateTimeSync
Exit 0
