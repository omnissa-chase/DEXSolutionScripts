#Requires -Version 5.1
<#
.SYNOPSIS
    Test-VpnSensorGate -- lab check of the self-refreshing cache gate that every vpn_*
    sensor 1.1.0 carries, against Invoke-VpnStateCollection.ps1 1.1.0.

.DESCRIPTION
    Runs the collector once normally (which persists its own copy, hash and state
    fingerprint), then drives vpn_health_score.ps1 and vpn_health_reason.ps1 through
    four scenarios, each sensor run in a fresh powershell.exe process the way Hub
    launches it (-NoProfile -ExecutionPolicy Bypass -File), and asserts the cache
    moves exactly as the gate design says. Cache values the test changes are restored.

      A. Fresh cache (LastChecked = now)
         -> sensor emits the cached score; LastRun unchanged.
      B. LastChecked 20 min back, fingerprint unchanged
         -> sensor emits the score; LastChecked refreshed to within the last minute;
            LastRun unchanged.
      C. LastChecked 20 min back, StateFingerprint = 'tampered'
         -> sensor emits the score; LastRun refreshed to within the last minute;
            StateFingerprint recomputed to the live value; sensor run took < 45 s.
      D. LastChecked 20 min back, StateFingerprint = 'tampered', CollectorHash = '0000'
         -> sensor emits the cached score; LastRun NOT refreshed;
            vpn_health_reason emits a value ending in 'Stale'.
         Then the collector is re-run to restore CollectorHash.

    Every sensor invocation must produce exactly one line of output.

    Not a break test of a remediation, so it does not use the DEXTestFramework
    pattern or write a FixReport. It prints [Passed ]/[Failed ] lines in the same
    visual style and exits 1 on any failure.

    RUN ELEVATED. The collector writes HKLM and C:\ProgramData with a locked ACL, and
    the test rewrites cache values under HKLM. From an elevated prompt:

      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\chase\repos\DEXSolutionScripts\VPN\_AutomatedTesting\Test-VpnSensorGate.ps1"

    The lab tunnel (WireGuard, adapter CBRADLEYSWIN11, InterfaceDescription 'WireGuard
    Tunnel', 10.99.0.1/24, DNS 10.99.0.2, NlMtu 1420) is not required; the scenarios
    hold on a no-client host too, where the fingerprint is the empty string.

.NOTES
    Script Name  : Test-VpnSensorGate.ps1
    Version      : 1.0.0
    Context      : Elevated administrator, lab host only
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Collector  = Join-Path $RepoRoot 'VPN\Invoke-VpnStateCollection.ps1'
$SensorDir  = Join-Path $RepoRoot 'VPN\Sensors'
$ScoreSensor  = Join-Path $SensorDir 'vpn_health_score.ps1'
$ReasonSensor = Join-Path $SensorDir 'vpn_health_reason.ps1'
$RegPath    = 'HKLM:\Software\AirWatch\Extensions\VPN'
$PsExe      = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$script:Failures = 0

function Write-Step {
    param([string]$Status, [string]$Name, [string]$Message = '')
    if ($Status -eq 'Failed') { $script:Failures++ }
    Write-Output "  [$($Status.PadRight(7))] $Name$(if ($Message) { ": $Message" })"
}

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Step -Status 'Passed' -Name $Name -Message $Detail }
    else            { Write-Step -Status 'Failed' -Name $Name -Message $Detail }
}

# Verbatim copy of the collector's / sensors' function, so scenario C can compare
# the recomputed StateFingerprint with the live value.
function Get-VpnStateFingerprint {
    $x = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'
    $e = foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $hw = $true
        if ($a.PSObject.Properties['HardwareInterface']) { $hw = [bool]$a.HardwareInterface }
        elseif ($a.PSObject.Properties['ConnectorPresent']) { $hw = [bool]$a.ConnectorPresent }
        if ($hw -or $a.Name -match $x -or $a.InterfaceDescription -match $x) { continue }
        $m = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).NlMtu
        $d = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) -join ','
        "$($a.ifIndex)|$($a.Status)|$m|$d"
    }
    return ((@($e) | Sort-Object) -join ';')
}

function Get-Cache {
    Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
}

function Set-CacheValue {
    param([string]$Name, [string]$Value)
    Set-ItemProperty -Path $RegPath -Name $Name -Value $Value -Type String
}

function Invoke-Collector {
    # Normal (non-quiet) run, as Hub or a console would launch it.
    $prev = $env:VPN_COLLECTOR_QUIET
    Remove-Item Env:\VPN_COLLECTOR_QUIET -ErrorAction SilentlyContinue
    # Local Continue: under Stop, PS 5.1 turns a native command's stderr into a terminating
    # error when redirected with 2>&1, which would abort the harness instead of failing a step.
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $PsExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Collector 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
    }
    finally {
        if ($null -ne $prev) { $env:VPN_COLLECTOR_QUIET = $prev }
    }
}

function Invoke-Sensor {
    # Fresh process per call, as Hub does. Returns the raw output lines and the wall time.
    param([string]$Path)
    Remove-Item Env:\VPN_COLLECTOR_QUIET -ErrorAction SilentlyContinue
    $ErrorActionPreference = 'Continue'   # see Invoke-Collector; stderr lines become output lines and fail the one-line check
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    $out = @(& $PsExe -NoProfile -ExecutionPolicy Bypass -File $Path 2>&1 | ForEach-Object { [string]$_ })
    $sw.Stop()
    return [pscustomobject]@{
        Lines    = $out
        Value    = $(if ($out.Count -ge 1) { $out[0] } else { $null })
        Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        ExitCode = $LASTEXITCODE
    }
}

function Assert-OneLine {
    param($Result, [string]$Name)
    $detail = "$($Result.Lines.Count) line(s) in $($Result.Seconds) s: '$($Result.Lines -join ' | ')'"
    Assert-True ($Result.Lines.Count -eq 1 -and -not [string]::IsNullOrEmpty($Result.Lines[0])) "$Name emits exactly one line" $detail
}

function Test-WithinLastMinute {
    param([string]$Stamp)
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse($Stamp, [ref]$t)) { return $false }
    return ($t -gt (Get-Date).AddMinutes(-1) -and $t -le (Get-Date).AddSeconds(5))
}

# -- Preconditions -------------------------------------------------------------
Write-Output ''
Write-Output "Test-VpnSensorGate  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "  Collector : $Collector"
Write-Output "  Sensors   : $ScoreSensor"
Write-Output "              $ReasonSensor"
Write-Output ''

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Step -Status 'Failed' -Name 'Precondition' -Message 'run this from an elevated (Administrator) PowerShell; the collector and the test write HKLM'
    exit 1
}
foreach ($f in $Collector, $ScoreSensor, $ReasonSensor) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Step -Status 'Failed' -Name 'Precondition' -Message "missing $f"; exit 1 }
}

$saved = $null

try {
    # -- Step 0: one normal collector run ----------------------------------------
    Write-Output 'Step 0  Normal collector run (persists copy, hash, fingerprint)'
    $r0 = Invoke-Collector
    Assert-True ($r0.ExitCode -eq 0) 'Collector exits 0' "exit $($r0.ExitCode)"
    $c0 = Get-Cache
    Assert-True ($null -ne $c0 -and -not [string]::IsNullOrEmpty($c0.LastRun))          'Cache has LastRun'           "$($c0.LastRun)"
    Assert-True (-not [string]::IsNullOrEmpty($c0.LastChecked) -and $c0.LastChecked -eq $c0.LastRun) 'LastChecked equals LastRun' "$($c0.LastChecked)"
    Assert-True ($null -ne $c0.StateFingerprint)                                          'Cache has StateFingerprint'  "'$($c0.StateFingerprint)'"
    Assert-True (-not [string]::IsNullOrEmpty($c0.CollectorPath) -and (Test-Path -LiteralPath $c0.CollectorPath)) 'Persisted collector copy exists' "$($c0.CollectorPath)"
    $liveHash = if ($c0.CollectorPath -and (Test-Path -LiteralPath $c0.CollectorPath)) { (Get-FileHash -LiteralPath $c0.CollectorPath -Algorithm SHA256).Hash } else { '' }
    Assert-True (-not [string]::IsNullOrEmpty($c0.CollectorHash) -and $c0.CollectorHash -eq $liveHash) 'CollectorHash matches the file' "$($c0.CollectorHash)"
    $liveFp = Get-VpnStateFingerprint
    Assert-True ($c0.StateFingerprint -eq $liveFp) 'StateFingerprint matches live fingerprint' "'$liveFp'"

    if ($c0.CollectorPath -and (Test-Path -LiteralPath $c0.CollectorPath)) {
        $acl = Get-Acl -LiteralPath (Split-Path -Parent $c0.CollectorPath)
        $usersWrite = @($acl.Access | Where-Object { $_.IdentityReference -like '*\Users' -and $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write) })
        Assert-True ($acl.AreAccessRulesProtected -and $usersWrite.Count -eq 0) 'Persist folder ACL: inheritance off, Users cannot write' "owner $($acl.Owner); $(@($acl.Access).Count) rule(s)"
    }

    $expectedScore = [string]$c0.HealthScore
    $saved = [ordered]@{
        LastRun          = $c0.LastRun
        LastChecked      = $c0.LastChecked
        StateFingerprint = $c0.StateFingerprint
        CollectorHash    = $c0.CollectorHash
    }
    Write-Output "  Baseline: HealthScore=$expectedScore HealthReason=$($c0.HealthReason) LastRun=$($c0.LastRun)"
    Write-Output ''

    # -- A. Fresh cache -----------------------------------------------------------
    Write-Output 'Scenario A  Fresh cache (LastChecked = now)'
    Set-CacheValue 'LastChecked' (Get-Date -Format 'o')
    $lastRunBefore = (Get-Cache).LastRun
    $rA = Invoke-Sensor -Path $ScoreSensor
    Assert-OneLine $rA 'A: vpn_health_score'
    Assert-True ($rA.Value -eq $expectedScore) 'A: emits the cached score' "'$($rA.Value)' expected '$expectedScore'"
    $cA = Get-Cache
    Assert-True ($cA.LastRun -eq $lastRunBefore) 'A: LastRun unchanged' "$($cA.LastRun)"
    Write-Output ''

    # -- B. Stale stamp, fingerprint unchanged ------------------------------------
    Write-Output 'Scenario B  LastChecked 20 min back, fingerprint unchanged'
    Set-CacheValue 'LastChecked' ((Get-Date).AddMinutes(-20).ToString('o'))
    $lastRunBefore = (Get-Cache).LastRun
    $rB = Invoke-Sensor -Path $ScoreSensor
    Assert-OneLine $rB 'B: vpn_health_score'
    Assert-True ($rB.Value -eq $expectedScore) 'B: emits the cached score' "'$($rB.Value)'"
    $cB = Get-Cache
    Assert-True (Test-WithinLastMinute $cB.LastChecked) 'B: LastChecked refreshed to within the last minute' "$($cB.LastChecked)"
    Assert-True ($cB.LastRun -eq $lastRunBefore) 'B: LastRun unchanged' "$($cB.LastRun)"
    Write-Output ''

    # -- C. Stale stamp, fingerprint tampered -> collector rerun ------------------
    Write-Output 'Scenario C  LastChecked 20 min back, StateFingerprint tampered'
    Set-CacheValue 'LastChecked' ((Get-Date).AddMinutes(-20).ToString('o'))
    Set-CacheValue 'StateFingerprint' 'tampered'
    $lastRunBefore = (Get-Cache).LastRun
    Start-Sleep -Seconds 1   # so a refreshed LastRun cannot equal the baseline stamp by coincidence
    $rC = Invoke-Sensor -Path $ScoreSensor
    Assert-OneLine $rC 'C: vpn_health_score'
    Assert-True ($rC.Value -eq $expectedScore) 'C: emits the score' "'$($rC.Value)'"
    Assert-True ($rC.Seconds -lt 45) 'C: sensor run took under 45 s' "$($rC.Seconds) s"
    $cC = Get-Cache
    Assert-True ($cC.LastRun -ne $lastRunBefore -and (Test-WithinLastMinute $cC.LastRun)) 'C: LastRun refreshed to within the last minute' "$($cC.LastRun)"
    $liveFp = Get-VpnStateFingerprint
    Assert-True ($cC.StateFingerprint -eq $liveFp) 'C: StateFingerprint recomputed to the live value' "'$($cC.StateFingerprint)'"
    Assert-True ($cC.CollectorHash -eq $liveHash) 'C: CollectorHash intact after the quiet rerun' "$($cC.CollectorHash)"
    Write-Output ''

    # -- D. Stale stamp, fingerprint tampered, hash broken -> fallback + Stale ----
    Write-Output 'Scenario D  LastChecked 20 min back, StateFingerprint tampered, CollectorHash 0000'
    Set-CacheValue 'LastChecked' ((Get-Date).AddMinutes(-20).ToString('o'))
    Set-CacheValue 'StateFingerprint' 'tampered'
    Set-CacheValue 'CollectorHash' '0000'
    $lastRunBefore = (Get-Cache).LastRun
    $rD = Invoke-Sensor -Path $ScoreSensor
    Assert-OneLine $rD 'D: vpn_health_score'
    Assert-True ($rD.Value -eq $expectedScore) 'D: emits the cached score' "'$($rD.Value)'"
    $cD = Get-Cache
    Assert-True ($cD.LastRun -eq $lastRunBefore) 'D: LastRun NOT refreshed' "$($cD.LastRun)"

    Set-CacheValue 'LastChecked' ((Get-Date).AddMinutes(-20).ToString('o'))   # the score sensor does not stamp on this path, but be explicit
    $rD2 = Invoke-Sensor -Path $ReasonSensor
    Assert-OneLine $rD2 'D: vpn_health_reason'
    Assert-True ([string]$rD2.Value -match 'Stale$') 'D: vpn_health_reason ends in Stale' "'$($rD2.Value)'"
    Assert-True ((Get-Cache).LastRun -eq $lastRunBefore) 'D: LastRun still not refreshed after the reason sensor' "$((Get-Cache).LastRun)"
    Write-Output ''

    # -- Restore: re-run the collector so hash, fingerprint and stamps are live ---
    Write-Output 'Restore  Re-run the collector'
    $rR = Invoke-Collector
    Assert-True ($rR.ExitCode -eq 0) 'Restore: collector exits 0' "exit $($rR.ExitCode)"
    $cR = Get-Cache
    $liveHash = if ($cR.CollectorPath -and (Test-Path -LiteralPath $cR.CollectorPath)) { (Get-FileHash -LiteralPath $cR.CollectorPath -Algorithm SHA256).Hash } else { '' }
    Assert-True (-not [string]::IsNullOrEmpty($cR.CollectorHash) -and $cR.CollectorHash -eq $liveHash) 'Restore: CollectorHash matches the file again' "$($cR.CollectorHash)"
    Assert-True ($cR.StateFingerprint -eq (Get-VpnStateFingerprint)) 'Restore: StateFingerprint is live' "'$($cR.StateFingerprint)'"
    Assert-True ($cR.LastChecked -eq $cR.LastRun -and (Test-WithinLastMinute $cR.LastRun)) 'Restore: LastRun and LastChecked fresh and equal' "$($cR.LastRun)"
    $rF = Invoke-Sensor -Path $ReasonSensor
    Assert-OneLine $rF 'Restore: vpn_health_reason'
    Assert-True ([string]$rF.Value -notmatch 'Stale$') 'Restore: vpn_health_reason no longer Stale' "'$($rF.Value)'"
    $saved = $null   # the collector rewrote every value we touched; nothing left to put back
}
catch {
    Write-Step -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
}
finally {
    if ($saved) {
        # Only reached when the restore run did not happen; put the baseline stamps back
        # so the cache is not left with 'tampered' or '0000' in it.
        try {
            foreach ($k in $saved.Keys) { Set-CacheValue $k ([string]$saved[$k]) }
            Write-Step -Status 'Warning' -Name 'Restore' -Message 'collector re-run did not complete; baseline LastRun/LastChecked/StateFingerprint/CollectorHash written back'
        }
        catch {
            Write-Step -Status 'Failed' -Name 'Restore' -Message "could not write the baseline back: $($_.Exception.Message)"
        }
    }
}

Write-Output ''
if ($script:Failures -gt 0) {
    Write-Output "RESULT: FAILED ($script:Failures failed assertion(s))"
    exit 1
}
Write-Output 'RESULT: PASSED'
exit 0
