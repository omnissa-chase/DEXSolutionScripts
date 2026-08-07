<#
.SYNOPSIS
    DEXTestFramework -- shared plumbing for the *_BreakTest.ps1 harness family.

.DESCRIPTION
    Provides the pieces every break test needs and none of them should reimplement:
    the safety interlock, seeded randomization, reboot-surviving state, and the
    uniform result schema consumed by Invoke-FixReportAnalysis.ps1.

    THIS MODULE SUPPORTS DELIBERATELY DESTRUCTIVE TESTS. Break tests stop services,
    disable adapters, and delete files. Assert-DexTestHost is the only thing standing
    between that and a production outage -- every break test MUST call it first.

    Reboot survival reuses the pattern proven in
    WindowsAutoRemediation/ProcessManagement/Restart-WinProcessGraceful.ps1: a
    Task Scheduler-owned process is genuinely detached and survives, where a
    background job (a child runspace of the caller) does not.

.NOTES
    Script Name  : DEXTestFramework.psm1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1

$script:FixReportRoot  = 'C:\Temp\FixReport'
$script:MarkerFileName = '.dex-test-machine'
$script:TaskPrefix     = 'DEX_BreakTestResume'

# ==============================================================================
# Safety interlock
# ==============================================================================

function Assert-DexTestHost {
    <#
    .SYNOPSIS
        Refuses to continue unless this machine is provably a disposable test host.
    .DESCRIPTION
        Four independent gates, ALL of which must pass. The default posture is
        refusal: a machine that has not been explicitly marked as a test host can
        never be broken by accident, and an operator who has not passed -Force
        cannot break one by reflex either.
    #>
    param(
        [switch]$Force,
        [string[]]$ProductionDomainDenyList = @()
    )

    $markerPath = Join-Path $script:FixReportRoot $script:MarkerFileName

    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'DEX break tests require an elevated session. Re-run PowerShell as Administrator.'
    }

    if (-not (Test-Path -LiteralPath $markerPath)) {
        throw @"
REFUSING TO RUN. Test-host marker not found at:
    $markerPath

This machine is not marked as a disposable test host. If it genuinely is one, create
the marker and re-run:

    New-Item -ItemType Directory -Path '$script:FixReportRoot' -Force | Out-Null
    Set-Content -Path '$markerPath' -Value `$env:COMPUTERNAME
"@
    }

    if (-not $Force) {
        throw 'REFUSING TO RUN. Break tests are destructive; pass -Force to acknowledge.'
    }

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs -and $cs.PartOfDomain -and $ProductionDomainDenyList.Count -gt 0) {
        foreach ($denied in $ProductionDomainDenyList) {
            if ($cs.Domain -like $denied) {
                throw "REFUSING TO RUN. Domain '$($cs.Domain)' matches production denylist entry '$denied'."
            }
        }
    }

    Write-Host ''
    Write-Host '  ###############################################################' -ForegroundColor Red
    Write-Host '  #  DESTRUCTIVE TEST HARNESS -- THIS MACHINE WILL BE BROKEN    #' -ForegroundColor Red
    Write-Host "  #  Host: $($env:COMPUTERNAME.PadRight(52))#" -ForegroundColor Red
    Write-Host '  ###############################################################' -ForegroundColor Red
    Write-Host ''
}

# ==============================================================================
# Test context and state
# ==============================================================================

function ConvertTo-DexHashtable {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
        if ($InputObject -is [PSCustomObject]) {
            $h = @{}
            foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = $p.Value }
            return $h
        }
        return $InputObject
    }
}

function New-DexTestContext {
    <#
    .SYNOPSIS
        Creates (or resumes) the state for one break-test run.
    .DESCRIPTION
        State lives at a fixed per-script path rather than a per-TestId path so a
        post-reboot resume can find it without being told the TestId.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptUnderTest,
        [int]$Seed = 0,
        [ValidateSet('Snapshot', 'Physical')][string]$Environment = 'Physical',
        [switch]$Resume
    )

    $scriptDir = Join-Path $script:FixReportRoot $ScriptUnderTest
    $stateFile = Join-Path $scriptDir 'state.json'

    if ($Resume) {
        if (-not (Test-Path -LiteralPath $stateFile)) {
            throw "Resume requested but no in-flight state found at $stateFile"
        }
        $state = (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json) | ConvertTo-DexHashtable
        $state['Breaks'] = @($state['Breaks'] | ConvertTo-DexHashtable)
        $state['StateFile'] = $stateFile
        $state['ScriptDir'] = $scriptDir
        $state['Random']    = [System.Random]::new([int]$state['Seed'])
        return $state
    }

    if (-not (Test-Path -LiteralPath $scriptDir)) {
        New-Item -ItemType Directory -Path $scriptDir -Force -ErrorAction Stop | Out-Null
    }

    if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum ([int]::MaxValue) }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

    $state = @{
        TestId          = [guid]::NewGuid().ToString('N').Substring(0, 12)
        ScriptUnderTest = $ScriptUnderTest
        Seed            = $Seed
        Machine         = $env:COMPUTERNAME
        OSBuild         = if ($os) { "$($os.Caption) $($os.BuildNumber)" } else { 'unknown' }
        Environment     = $Environment
        StartedAt       = (Get-Date).ToString('o')
        FirstRunAt      = (Get-Date).ToString('o')
        CompletedAt     = $null
        Phase           = 'Init'
        RequiresReboot  = $false
        RebootCount     = 0
        Breaks          = @()
        Remediation     = $null
        Validation      = @()
        Overall         = 'Incomplete'
        StateFile       = $stateFile
        ScriptDir       = $scriptDir
        Random          = [System.Random]::new($Seed)
    }

    Save-DexTestState -State $state
    return $state
}

function Save-DexTestState {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    # Random and the path helpers are runtime-only; persisting them would fail to
    # round-trip through JSON and they are rebuilt from Seed on resume.
    $persist = @{}
    foreach ($k in $State.Keys) {
        if ($k -in @('Random', 'StateFile', 'ScriptDir')) { continue }
        $persist[$k] = $State[$k]
    }

    $persist | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $State['StateFile'] -Encoding UTF8 -Force -ErrorAction Stop
}

function Clear-DexTestState {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Remove-Item -LiteralPath $State['StateFile'] -Force -ErrorAction SilentlyContinue
}

function Test-DexRebootOccurred {
    <#
    .SYNOPSIS
        True when the machine has booted since this test run started.
    .DESCRIPTION
        Same technique as Invoke_RebootWithUserDefer: compare the recorded start
        time against LastBootUpTime rather than trusting a flag we set ourselves,
        which would be wrong if the reboot never actually happened.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { return $false }

    $firstRun = [datetime]::Parse($State['FirstRunAt'])
    return ($os.LastBootUpTime -gt $firstRun)
}

# ==============================================================================
# Reboot-surviving resume
# ==============================================================================

function Register-DexTestResume {
    <#
    .SYNOPSIS
        Registers an AtStartup task that re-enters the break test after a reboot.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$BreakTestPath
    )

    $taskName = "$script:TaskPrefix`_$($State['ScriptUnderTest'])"

    $argument = '-NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden ' +
                "-File `"$BreakTestPath`" -Resume -Force"

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

    Write-Host "  [Resume] Registered '$taskName' (AtStartup)." -ForegroundColor DarkCyan
}

function Unregister-DexTestResume {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $taskName = "$script:TaskPrefix`_$($State['ScriptUnderTest'])"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  [Resume] Unregistered '$taskName'." -ForegroundColor DarkCyan
    }
}

# ==============================================================================
# Randomization
# ==============================================================================

function Get-DexRandomSubset {
    <#
    .SYNOPSIS
        Deterministic Fisher-Yates selection driven by the run's seeded RNG.
    .DESCRIPTION
        Deterministic given the same Seed, which is what makes a failed run
        reproducible. Ad-hoc Get-Random calls would not be.
    #>
    param(
        [Parameter(Mandatory = $true)][object[]]$InputObject,
        [Parameter(Mandatory = $true)][System.Random]$Random,
        [int]$Count = 1
    )

    $pool = @($InputObject)
    for ($i = $pool.Count - 1; $i -gt 0; $i--) {
        $j = $Random.Next(0, $i + 1)
        $tmp = $pool[$i]; $pool[$i] = $pool[$j]; $pool[$j] = $tmp
    }

    if ($Count -gt $pool.Count) { $Count = $pool.Count }
    return @($pool[0..($Count - 1)])
}

# ==============================================================================
# Result output
# ==============================================================================

function Write-DexTestResult {
    <#
    .SYNOPSIS
        Writes the final per-run JSON consumed by Invoke-FixReportAnalysis.ps1.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $State['CompletedAt'] = (Get-Date).ToString('o')
    $resultFile = Join-Path $State['ScriptDir'] "$($State['TestId']).json"

    $result = [ordered]@{
        TestId          = $State['TestId']
        ScriptUnderTest = $State['ScriptUnderTest']
        Seed            = $State['Seed']
        Machine         = $State['Machine']
        OSBuild         = $State['OSBuild']
        Environment     = $State['Environment']
        StartedAt       = $State['StartedAt']
        CompletedAt     = $State['CompletedAt']
        Phase           = $State['Phase']
        RequiresReboot  = $State['RequiresReboot']
        RebootCount     = $State['RebootCount']
        Breaks          = $State['Breaks']
        Remediation     = $State['Remediation']
        Validation      = $State['Validation']
        Overall         = $State['Overall']
    }

    $result | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $resultFile -Encoding UTF8 -Force -ErrorAction Stop

    Write-Host "  [Result] $resultFile" -ForegroundColor DarkCyan
    return $resultFile
}

# ==============================================================================
# Console output (matches the remediation-script house style)
# ==============================================================================

function Write-DexBanner {
    param([Parameter(Mandatory = $true)][string]$Title, [string]$Detail = '')

    Write-Host ''
    Write-Host "-- $Title ".PadRight(64, '-') -ForegroundColor Cyan
    Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   $Detail"
    Write-Host ('-' * 64) -ForegroundColor Cyan
}

function Write-DexStep {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Message = ''
    )

    $color = switch ($Status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        'Info'    { 'Gray'   }
        default   { 'White'  }
    }
    Write-Host "  [$($Status.PadRight(7))] $Name$(if ($Message) { ": $Message" })" -ForegroundColor $color
}

Export-ModuleMember -Function @(
    'Assert-DexTestHost'
    'New-DexTestContext'
    'Save-DexTestState'
    'Clear-DexTestState'
    'Test-DexRebootOccurred'
    'Register-DexTestResume'
    'Unregister-DexTestResume'
    'Get-DexRandomSubset'
    'Write-DexTestResult'
    'Write-DexBanner'
    'Write-DexStep'
    'ConvertTo-DexHashtable'
)
