<#
.SYNOPSIS
    DriverTestKit -- non-destructive unit-test plumbing for the driver remediation scripts.

.DESCRIPTION
    Dot-source this file from a *.Tests.ps1. It provides Invoke-DriverScriptUnderStubs,
    which runs a driver remediation script in a child Windows PowerShell 5.1 process
    exactly the way the Workspace ONE script engine does (as a file, functions in
    script scope, nothing dot-sourced into the console), but with the three things
    that touch hardware replaced by stubs:

        Get-WmiObject   returns a fake Win32_PnPEntity fleet from a JSON state file
        pnputil         logs every call and, when its verb matches -FixOn, heals the
                        targeted device(s) by writing ErrorCode 0 back to the state file
        Start-Sleep     no-op, so a full escalation chain completes in well under a second

    Nothing here needs elevation, a snapshot, or real PnP hardware. It exercises the
    detection / classification / escalation / exit-code logic only. Real device
    behaviour is covered by the *_BreakTest.ps1 harnesses, which ARE destructive.

.NOTES
    Script Name  : DriverTestKit.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Any (no elevation required)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-28

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

Set-StrictMode -Off

function New-FakeDevice {
    <#
    .SYNOPSIS
        Builds one fake Win32_PnPEntity record for the stub fleet.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DeviceID = ('FAKE\' + ($Name -replace '[^A-Za-z0-9]', '_') + '\1'),
        [int]$ErrorCode = 0
    )
    @{ Name = $Name; DeviceID = $DeviceID; ConfigManagerErrorCode = $ErrorCode }
}

function Invoke-DriverScriptUnderStubs {
    <#
    .SYNOPSIS
        Runs a driver remediation script in a stubbed child process and returns what happened.

    .PARAMETER ScriptPath
        Full path of the script under test.

    .PARAMETER Devices
        Fake PnP fleet. Use New-FakeDevice. Each entry needs Name, DeviceID, ConfigManagerErrorCode.

    .PARAMETER FixOn
        pnputil verb that heals devices: 'scan-devices', 'restart-device', 'rollback-driver',
        'remove-device', or '' (default) for a device that never recovers. scan-devices heals
        every errored device; the others heal only the instance id passed on the command line.

    .PARAMETER DriverFilter
        Value for the DriverFilter environment variable, the way UEM would deliver it.
        Leave unset to clear the variable for the child process.

    .PARAMETER ScriptParams
        Named parameters forwarded to the script on its command line, e.g.
        @{ AllowedActions = @('Scan','Reinstall'); DriverFilter = 'Realtek' }. This is how
        the *_BreakTest.ps1 harnesses invoke the scripts, so it must keep working.

    .PARAMETER OemDriverCount
        Number of 'Published Name' lines the pnputil /enum-drivers stub emits.

    .OUTPUTS
        Hashtable: ExitCode, Output (string), Lines (string[]), PnpCalls (string[]),
        FinalDevices (the fleet after the run).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][object[]]$Devices,
        [ValidateSet('', 'scan-devices', 'restart-device', 'rollback-driver', 'remove-device')]
        [string]$FixOn = '',
        [string]$DriverFilter,
        [hashtable]$ScriptParams = @{},
        [int]$OemDriverCount = 3,
        [int]$TimeoutSec = 120
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Script under test not found: $ScriptPath" }

    $runId     = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $workDir   = Join-Path $env:TEMP "DEXDriverUnit_$runId"
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $stateFile = Join-Path $workDir 'devices.json'
    $callsFile = Join-Path $workDir 'pnputil.calls'
    $bootFile  = Join-Path $workDir 'bootstrap.ps1'

    # Normalise the fleet to plain objects so ConvertTo-Json round-trips cleanly.
    $fleet = foreach ($d in $Devices) {
        [pscustomobject]@{
            Name                   = [string]$d.Name
            DeviceID               = [string]$d.DeviceID
            ConfigManagerErrorCode = [int]$d.ConfigManagerErrorCode
        }
    }
    # The fleet is wrapped in an outer object on purpose: in PowerShell 5.1 ConvertFrom-Json
    # returns a top-level JSON array as ONE object (the array itself), so @() around it does
    # not enumerate the devices. A property holding the array round-trips cleanly.
    ConvertTo-Json -InputObject @{ Devices = @($fleet) } -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding UTF8
    Set-Content -LiteralPath $callsFile -Value '' -Encoding UTF8

    # Build the forwarded-argument text as PowerShell source so arrays survive intact.
    $argText = ''
    foreach ($k in $ScriptParams.Keys) {
        $v = $ScriptParams[$k]
        $vals = @($v) | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }
        $argText += " -$k " + ($vals -join ',')
    }

    $escapedScript = $ScriptPath.Replace("'", "''")
    $escapedState  = $stateFile.Replace("'", "''")
    $escapedCalls  = $callsFile.Replace("'", "''")

    $bootstrap = @"
`$ErrorActionPreference = 'Continue'
`$global:DexStubState = '$escapedState'
`$global:DexStubCalls = '$escapedCalls'
`$global:DexStubFixOn = '$FixOn'
`$global:DexStubOemCount = $OemDriverCount

function global:Get-WmiObject {
    param([string]`$Class, `$ErrorAction, `$Filter, `$Namespace, `$ComputerName)
    `$raw = Get-Content -LiteralPath `$global:DexStubState -Raw
    if ([string]::IsNullOrWhiteSpace(`$raw)) { return }
    foreach (`$d in @((ConvertFrom-Json -InputObject `$raw).Devices)) {
        [pscustomobject]@{
            Name                   = `$d.Name
            DeviceID               = `$d.DeviceID
            ConfigManagerErrorCode = [int]`$d.ConfigManagerErrorCode
        }
    }
}

function global:pnputil {
    `$line = (`$args | ForEach-Object { [string]`$_ }) -join ' '
    Add-Content -LiteralPath `$global:DexStubCalls -Value `$line -Encoding UTF8
    `$verb = ([string]`$args[0]).TrimStart('/')
    if (`$verb -eq 'enum-drivers') {
        for (`$i = 0; `$i -lt `$global:DexStubOemCount; `$i++) { "Published Name:     oem`$i.inf" }
        `$global:LASTEXITCODE = 0
        return
    }
    if (`$global:DexStubFixOn -and `$verb -eq `$global:DexStubFixOn) {
        `$fleet = @((ConvertFrom-Json -InputObject (Get-Content -LiteralPath `$global:DexStubState -Raw)).Devices)
        `$target = if (`$args.Count -gt 1) { [string]`$args[1] } else { `$null }
        foreach (`$d in `$fleet) {
            if (`$verb -eq 'scan-devices' -or `$d.DeviceID -eq `$target) { `$d.ConfigManagerErrorCode = 0 }
        }
        ConvertTo-Json -InputObject @{ Devices = `$fleet } -Depth 4 | Set-Content -LiteralPath `$global:DexStubState -Encoding UTF8
    }
    `$global:LASTEXITCODE = 0
}

function global:Start-Sleep { param(`$Seconds, `$Milliseconds) }

& '$escapedScript'$argText
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $bootFile -Value $bootstrap -Encoding UTF8

    # Environment for the child: DriverFilter exactly as UEM would (or would not) set it.
    $savedFilter = $env:DriverFilter
    if ($PSBoundParameters.ContainsKey('DriverFilter')) { $env:DriverFilter = $DriverFilter } else { $env:DriverFilter = $null }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = 'powershell.exe'
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bootFile`""
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            throw "Script under test did not exit within $TimeoutSec s: $ScriptPath"
        }
        $proc.WaitForExit()
        $out = ($stdout.Result + $stderr.Result)
    } finally {
        $env:DriverFilter = $savedFilter
    }

    $calls = @(Get-Content -LiteralPath $callsFile -ErrorAction SilentlyContinue | Where-Object { $_ })
    $final = @((ConvertFrom-Json -InputObject (Get-Content -LiteralPath $stateFile -Raw)).Devices)
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue

    return @{
        ExitCode     = $proc.ExitCode
        Output       = $out
        Lines        = @($out -split "`r?`n")
        PnpCalls     = $calls
        FinalDevices = $final
    }
}

# -- Assertion helpers (Pester 3.4 and 5.x compatible: a throw inside It fails the test) --

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [string]$Because = 'condition was false')
    if (-not $Condition) { throw "ASSERT: $Because" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What = 'value')
    if ("$Expected" -ne "$Actual") { throw "ASSERT: $What expected [$Expected] but was [$Actual]" }
}

function Assert-OutputContains {
    param([Parameter(Mandatory = $true)][hashtable]$Run, [Parameter(Mandatory = $true)][string]$Pattern)
    if ($Run.Output -notmatch $Pattern) {
        throw "ASSERT: output did not match /$Pattern/`n--- output ---`n$($Run.Output)"
    }
}

function Assert-OutputLacks {
    param([Parameter(Mandatory = $true)][hashtable]$Run, [Parameter(Mandatory = $true)][string]$Pattern)
    if ($Run.Output -match $Pattern) {
        throw "ASSERT: output unexpectedly matched /$Pattern/`n--- output ---`n$($Run.Output)"
    }
}

function Assert-PnpCalled {
    param([Parameter(Mandatory = $true)][hashtable]$Run, [Parameter(Mandatory = $true)][string]$Pattern)
    if (-not ($Run.PnpCalls | Where-Object { $_ -match $Pattern })) {
        throw "ASSERT: expected a pnputil call matching /$Pattern/; calls were: $($Run.PnpCalls -join ' ; ')"
    }
}

function Assert-PnpNotCalled {
    param([Parameter(Mandatory = $true)][hashtable]$Run, [Parameter(Mandatory = $true)][string]$Pattern)
    if ($Run.PnpCalls | Where-Object { $_ -match $Pattern }) {
        throw "ASSERT: did not expect a pnputil call matching /$Pattern/; calls were: $($Run.PnpCalls -join ' ; ')"
    }
}

function Assert-PnpOrder {
    <#
    .SYNOPSIS
        Asserts the given verbs appear in the pnputil call log in this relative order.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Run, [Parameter(Mandatory = $true)][string[]]$Verbs)
    $idx = -1
    foreach ($v in $Verbs) {
        $found = $false
        for ($i = $idx + 1; $i -lt $Run.PnpCalls.Count; $i++) {
            if ($Run.PnpCalls[$i] -match ('^/' + [regex]::Escape($v))) { $idx = $i; $found = $true; break }
        }
        if (-not $found) { throw "ASSERT: pnputil verb '$v' not found after position $idx; calls were: $($Run.PnpCalls -join ' ; ')" }
    }
}
