<#
.SYNOPSIS
    Invoke-AutoRemediateOneDrive_BreakTest -- deliberately breaks OneDrive components,
    then verifies Invoke-AutoRemediateOneDrive.ps1 actually fixes them.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateOneDrive\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It kills OneDrive.exe, deletes the
    logged-on user's OneDrive Run key, stops or disables the FileSyncHelper service
    and writes HKLM OneDrive policy. Run it only on a disposable VM or a marked test
    host. See Assert-DexTestHost in DEXTestFramework.psm1.

    WHAT IS BROKEN AND HOW IT COMES BACK
    Invoke-AutoRemediateOneDrive.ps1 resolves the logged-on user from
    Win32_ComputerSystem.UserName and reads that user's hive through
    HKEY_USERS\<SID>, so this harness does the same. Every break Captures the exact
    value it is about to change (Run key string, service StartMode/State, policy
    value, whether a key existed) and Restore writes that back. Nothing under the
    user's OneDrive sync folders is touched and no account is signed in or out.
    A OneDrive that is not signed in (the lab default) is fine: starting
    OneDrive.exe, the Run key, the service and the policy value all exist and
    behave without an account.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Three of the five steps in Invoke-AutoRemediateOneDrive.ps1 have
    ResolutionScript = $null by design, so breaking them must NOT expect a repair.
    Each break declares which it is:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    NOT COVERED
      Step 3 Sync Error Detection -- the only trigger is an Error record in the
             Application event log, and a log record cannot be removed without
             clearing the whole log, so Restore could not put the machine back.
      Step 2 (Accounts key absent / empty) and Step 5 (KFM bitmask on a real
             Business account) in forms that would need the user's real account
             keys to be deleted or edited.

    REBOOTS
    No break in this catalog requires a reboot. The reboot plumbing is kept so the
    harness stays uniform with the rest of the family.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateOneDrive.ps1 and validate the outcome.
    Without this the script breaks and reports only.

.PARAMETER Environment
    Physical (default) restores the machine when the run ends.
    Snapshot skips restore on the assumption the host reverts a checkpoint.

.PARAMETER Seed
    Replays an earlier run's random break selection exactly. Omit for a new random
    seed, which is always recorded in the result.

.PARAMETER BreakName
    Force specific breaks instead of a random selection.

.PARAMETER BreakCount
    How many components to break when selecting randomly. Default 2.

.PARAMETER IncludeRebootBreaks
    Allow breaks that require a reboot to take effect. Default off.

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateOneDrive_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), with an interactive user logged on
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateOneDrive\

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [switch]$RemediationTest,
    [ValidateSet('Snapshot', 'Physical')][string]$Environment = 'Physical',
    [int]$Seed = 0,
    [string[]]$BreakName,
    [int]$BreakCount = 2,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Invoke-AutoRemediateOneDrive'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateOneDrive.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\OneDriveErrors'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
$FixturePrefix          = 'DEXTest'
$FixtureServiceName     = 'FileSyncHelper'
$FixtureAccountKeyName  = 'BusinessDEXTest'           # inert subkey under the user's OneDrive\Accounts; must match the script's Business* filter (1.0.2) and is not a name OneDrive itself reads
$FixtureKfmPolicyPath   = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
$FixtureKfmPolicyName   = 'KFMSilentOptIn'
# Not a GUID on purpose: OneDrive ignores a tenant id it cannot parse, the script only tests
# the value for presence, and the prefix makes the value recognisable as ours.
$FixtureKfmPolicyValue  = 'DEXTest-00000000-0000-0000-0000-000000000000'
$FixtureStartTaskName   = 'DEXTest-StartOneDrive'

function Initialize-Fixture {
    $exe = Get-OneDriveExecutable
    if (-not $exe) { throw 'OneDrive is not installed on this host; Invoke-AutoRemediateOneDrive.ps1 would exit 0 as Skipped.' }

    # Both throw when nobody is logged on -- the script would then skip or Warning every per-user step.
    $user = Get-LoggedOnUser
    $sid  = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
        throw "Hive for $user ($sid) is not loaded under HKEY_USERS; the script's Run-key and Accounts checks would not see it."
    }

    $signedIn = @(Get-OneDriveAccountKeys | Where-Object {
        (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).UserEmail
    }).Count
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "OneDrive $((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion); user $user; signed-in account keys: $signedIn; OneDrive.exe running: $([bool](Get-Process -Name OneDrive -ErrorAction SilentlyContinue))"
}

function Remove-Fixture {
    # Sweep by prefix. The per-break Restore blocks have normally done all of this already;
    # this catches anything a half-finished run left behind.
    try {
        $acct = Join-Path (Get-OneDriveAccountsPath) $FixtureAccountKeyName
        if (Test-Path -LiteralPath $acct) { Remove-Item -LiteralPath $acct -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    try {
        $v = (Get-ItemProperty -LiteralPath $FixtureKfmPolicyPath -Name $FixtureKfmPolicyName -ErrorAction SilentlyContinue).$FixtureKfmPolicyName
        if ($v -and "$v" -like "$FixturePrefix*") {
            Remove-ItemProperty -LiteralPath $FixtureKfmPolicyPath -Name $FixtureKfmPolicyName -ErrorAction SilentlyContinue
        }
    } catch { }
    if (Get-ScheduledTask -TaskName $FixtureStartTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $FixtureStartTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# -- Helpers ------------------------------------------------------------------

function Get-LoggedOnUser {
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $u) { throw 'No interactive user is logged on; Invoke-AutoRemediateOneDrive.ps1 resolves its user from Win32_ComputerSystem.UserName.' }
    return $u
}

function Get-LoggedOnUserSid {
    $u = Get-LoggedOnUser
    return ([Security.Principal.NTAccount]$u).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Get-UserRunKeyPath {
    "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)\Software\Microsoft\Windows\CurrentVersion\Run"
}

function Get-OneDriveAccountsPath {
    "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)\Software\Microsoft\OneDrive\Accounts"
}

function Get-OneDriveAccountKeys {
    $p = Get-OneDriveAccountsPath
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-ChildItem -LiteralPath $p -ErrorAction SilentlyContinue)
}

function Get-OneDriveRunValue {
    (Get-ItemProperty -LiteralPath (Get-UserRunKeyPath) -Name 'OneDrive' -ErrorAction SilentlyContinue).OneDrive
}

function Get-OneDriveExecutable {
    # Same resolution order as the script: per-user install first, then the machine-wide one.
    $shortName = (Get-LoggedOnUser).Split('\')[-1]
    $perUser   = "C:\Users\$shortName\AppData\Local\Microsoft\OneDrive\OneDrive.exe"
    if (Test-Path -LiteralPath $perUser) { return $perUser }
    foreach ($candidate in @(
        "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe",
        "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Test-OneDriveRunning {
    [bool](Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
}

function Wait-OneDriveProcess {
    # Polls until OneDrive.exe is present (or absent with -Gone). Returns the final state.
    param([int]$Seconds = 20, [switch]$Gone)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $running = Test-OneDriveRunning
        if ($Gone -and -not $running) { return $true }
        if (-not $Gone -and $running) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Stop-OneDriveProcess {
    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if (-not (Wait-OneDriveProcess -Seconds 10 -Gone)) { throw 'OneDrive.exe is still running after Stop-Process.' }
}

function Start-OneDriveInUserSession {
    <#
        Starts OneDrive.exe on the logged-on user's desktop the same way the script does:
        a throwaway Interactive scheduled task. Works whether this harness runs as that
        user or as SYSTEM from a task, where Start-Process would launch as SYSTEM.
    #>
    $exe  = Get-OneDriveExecutable
    $user = Get-LoggedOnUser
    try {
        $action    = New-ScheduledTaskAction -Execute $exe -Argument '/background'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit '00:01:00'
        Register-ScheduledTask -TaskName $FixtureStartTaskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $FixtureStartTaskName -ErrorAction Stop
        Wait-OneDriveProcess -Seconds 20 | Out-Null
    } finally {
        Unregister-ScheduledTask -TaskName $FixtureStartTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Get-FixtureServiceCim {
    Get-CimInstance -ClassName Win32_Service -Filter "Name='$FixtureServiceName'" -ErrorAction SilentlyContinue
}

function ConvertTo-StartupType {
    param([string]$StartMode)
    switch ($StartMode) {
        'Auto'     { 'Automatic' }
        'Manual'   { 'Manual'    }
        'Disabled' { 'Disabled'  }
        default    { 'Manual'    }
    }
}

function Restore-FixtureService {
    # Shared by both service breaks: StartMode back first, then the State the service was in.
    param($Original)
    Set-Service -Name $FixtureServiceName -StartupType (ConvertTo-StartupType $Original.StartMode) -ErrorAction SilentlyContinue
    $now = Get-Service -Name $FixtureServiceName -ErrorAction SilentlyContinue
    if (-not $now) { return }
    if ($Original.State -eq 'Running' -and $now.Status -ne 'Running') {
        Start-Service -Name $FixtureServiceName -ErrorAction SilentlyContinue
    } elseif ($Original.State -ne 'Running' -and $now.Status -eq 'Running') {
        Stop-Service -Name $FixtureServiceName -Force -ErrorAction SilentlyContinue
    }
}

function Test-DexRecordContains {
    <#
        Confirms the remediation script reported a finding for a given step. Used
        by ExpectReportedOnly breaks, where the correct behaviour is to surface the
        problem rather than fix it.
    #>
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix)

    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $false }
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $false }
    return @($key.GetValueNames() | Where-Object { $_ -like "$ValueNamePrefix*" }).Count -gt 0
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name            = 'AutoStartAndProcess'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'RemoveRunKey'
                Apply = {
                    Remove-ItemProperty -LiteralPath (Get-UserRunKeyPath) -Name 'OneDrive' -ErrorAction SilentlyContinue
                }
            },
            @{
                Name  = 'StopProcess'
                Apply = { Stop-OneDriveProcess }
            },
            @{
                Name  = 'RemoveRunKeyAndStopProcess'
                Apply = {
                    Remove-ItemProperty -LiteralPath (Get-UserRunKeyPath) -Name 'OneDrive' -ErrorAction SilentlyContinue
                    Stop-OneDriveProcess
                }
            }
        )
        Capture  = {
            @{ RunValue = Get-OneDriveRunValue; WasRunning = Test-OneDriveRunning }
        }
        # Step 1 fails on either half missing, which is the condition the break must produce.
        Verify   = { (-not (Get-OneDriveRunValue)) -or (-not (Test-OneDriveRunning)) }
        # The script promises both: Run key restored and OneDrive.exe started in the user session.
        Validate = {
            $runValue = Get-OneDriveRunValue
            [bool]$runValue -and ($runValue -like '*OneDrive.exe*') -and (Wait-OneDriveProcess -Seconds 20)
        }
        Restore  = {
            param($Original)
            $runKey = Get-UserRunKeyPath
            if ($Original.RunValue) {
                Set-ItemProperty -LiteralPath $runKey -Name 'OneDrive' -Value $Original.RunValue -Type String -ErrorAction SilentlyContinue
            } else {
                Remove-ItemProperty -LiteralPath $runKey -Name 'OneDrive' -ErrorAction SilentlyContinue
            }
            if ($Original.WasRunning -and -not (Test-OneDriveRunning)) {
                Start-OneDriveInUserSession
            } elseif (-not $Original.WasRunning -and (Test-OneDriveRunning)) {
                Stop-OneDriveProcess
            }
        }
    },

    @{
        Name            = 'AccountNotSignedIn'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        # OneDrive reads only Personal and Business<n> under Accounts; an extra BusinessDEXTest
        # subkey is invisible to it but matches the script's Business* account filter (1.0.2)
        # and counts as "not signed in" to Step 2. Step 5 also sees it as a business account
        # without KfmFoldersProtectedNow, which only warns when a KFM policy is set.
        Methods         = @(
            @{
                Name  = 'AddUnsignedAccountKey'
                Apply = {
                    $accounts = Get-OneDriveAccountsPath
                    if (-not (Test-Path -LiteralPath $accounts)) {
                        New-Item -Path $accounts -Force -ErrorAction Stop | Out-Null
                    }
                    New-Item -Path (Join-Path $accounts $FixtureAccountKeyName) -Force -ErrorAction Stop | Out-Null
                }
            }
        )
        Capture  = { @{ AccountsExisted = (Test-Path -LiteralPath (Get-OneDriveAccountsPath)) } }
        Verify   = {
            $key = Join-Path (Get-OneDriveAccountsPath) $FixtureAccountKeyName
            (Test-Path -LiteralPath $key) -and
            -not (Get-ItemProperty -LiteralPath $key -Name 'UserEmail' -ErrorAction SilentlyContinue).UserEmail
        }
        Validate = {
            $stillThere = Test-Path -LiteralPath (Join-Path (Get-OneDriveAccountsPath) $FixtureAccountKeyName)
            $reported   = Test-DexRecordContains -ValueNamePrefix 'Step02_'
            $stillThere -and $reported
        }
        Restore  = {
            param($Original)
            $accounts = Get-OneDriveAccountsPath
            $key      = Join-Path $accounts $FixtureAccountKeyName
            if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
            if (-not $Original.AccountsExisted -and (Test-Path -LiteralPath $accounts)) {
                $item = Get-Item -LiteralPath $accounts -ErrorAction SilentlyContinue
                if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) {
                    Remove-Item -LiteralPath $accounts -Force -ErrorAction SilentlyContinue
                }
            }
        }
    },

    @{
        Name            = 'FilesOnDemandServiceStopped'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        # FileSyncHelper is Manual/Stopped on an idle Windows 11 host, so the break often finds
        # it already down; the remediation still has to genuinely start it for Validate to pass.
        Methods         = @(
            @{
                Name  = 'StopService'
                Apply = {
                    if (-not (Get-Service -Name $FixtureServiceName -ErrorAction SilentlyContinue)) {
                        throw "Service '$FixtureServiceName' is not present on this host; Step 4 would report Passed."
                    }
                    Stop-Service -Name $FixtureServiceName -Force -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $svc = Get-FixtureServiceCim
            @{ StartMode = "$($svc.StartMode)"; State = "$($svc.State)" }
        }
        Verify   = {
            $svc = Get-Service -Name $FixtureServiceName -ErrorAction SilentlyContinue
            $svc -and $svc.Status -ne 'Running' -and $svc.StartType -ne 'Disabled'
        }
        Validate = {
            (Get-Service -Name $FixtureServiceName -ErrorAction SilentlyContinue).Status -eq 'Running'
        }
        Restore  = {
            param($Original)
            Restore-FixtureService -Original $Original
        }
    },

    @{
        Name            = 'FilesOnDemandServiceDisabled'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'DisableAndStop'
                Apply = {
                    if (-not (Get-Service -Name $FixtureServiceName -ErrorAction SilentlyContinue)) {
                        throw "Service '$FixtureServiceName' is not present on this host; Step 4 would report Passed."
                    }
                    Set-Service -Name $FixtureServiceName -StartupType Disabled -ErrorAction Stop
                    Stop-Service -Name $FixtureServiceName -Force -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $svc = Get-FixtureServiceCim
            @{ StartMode = "$($svc.StartMode)"; State = "$($svc.State)" }
        }
        Verify   = {
            (Get-Service -Name $FixtureServiceName -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
        }
        # The script must flag it and explicitly refuse to re-enable it.
        Validate = {
            $svc = Get-Service -Name $FixtureServiceName -ErrorAction SilentlyContinue
            $svc -and $svc.StartType -eq 'Disabled' -and $svc.Status -ne 'Running' -and
            (Test-DexRecordContains -ValueNamePrefix 'Step04_')
        }
        Restore  = {
            param($Original)
            Restore-FixtureService -Original $Original
        }
    },

    @{
        Name            = 'KfmPolicyDrift'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        # Step 5 warns when a KFM policy is set but a Business account has not protected all
        # three folders. The policy value is the only thing written; the user's account keys
        # are read, never changed.
        Methods         = @(
            @{
                Name  = 'SetKfmSilentOptInPolicy'
                Apply = {
                    $biz = @(Get-OneDriveAccountKeys | Where-Object { $_.PSChildName -like 'Business*' })
                    if ($biz.Count -eq 0) {
                        throw 'No Business* key under the user''s OneDrive\Accounts; Step 5 reports Passed without one and this harness will not fabricate an account key.'
                    }
                    $signedIn = @($biz | Where-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).UserEmail })
                    if ($signedIn.Count -gt 0) {
                        throw 'A Business account is signed in; refusing to set a KFM policy that live OneDrive would act on.'
                    }
                    if (-not (Test-Path -LiteralPath $FixtureKfmPolicyPath)) {
                        New-Item -Path $FixtureKfmPolicyPath -Force -ErrorAction Stop | Out-Null
                    }
                    Set-ItemProperty -LiteralPath $FixtureKfmPolicyPath -Name $FixtureKfmPolicyName -Value $FixtureKfmPolicyValue -Type String -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $exists = Test-Path -LiteralPath $FixtureKfmPolicyPath
            $value  = if ($exists) { (Get-ItemProperty -LiteralPath $FixtureKfmPolicyPath -Name $FixtureKfmPolicyName -ErrorAction SilentlyContinue).$FixtureKfmPolicyName } else { $null }
            @{ KeyExisted = $exists; HadValue = ($null -ne $value); Value = $value }
        }
        Verify   = {
            $value = (Get-ItemProperty -LiteralPath $FixtureKfmPolicyPath -Name $FixtureKfmPolicyName -ErrorAction SilentlyContinue).$FixtureKfmPolicyName
            if ($value -ne $FixtureKfmPolicyValue) { return $false }
            # At least one Business account must not be fully protected, or Step 5 stays green.
            $unprotected = @(Get-OneDriveAccountKeys | Where-Object { $_.PSChildName -like 'Business*' } | Where-Object {
                $mask = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'KfmFoldersProtectedNow' -ErrorAction SilentlyContinue).KfmFoldersProtectedNow
                ($null -eq $mask) -or (($mask -band 7) -ne 7)
            })
            $unprotected.Count -gt 0
        }
        Validate = {
            $value      = (Get-ItemProperty -LiteralPath $FixtureKfmPolicyPath -Name $FixtureKfmPolicyName -ErrorAction SilentlyContinue).$FixtureKfmPolicyName
            $stillThere = ($value -eq $FixtureKfmPolicyValue)
            $reported   = Test-DexRecordContains -ValueNamePrefix 'Step05_'
            $stillThere -and $reported
        }
        Restore  = {
            param($Original)
            if ($Original.HadValue) {
                Set-ItemProperty -LiteralPath $FixtureKfmPolicyPath -Name $FixtureKfmPolicyName -Value "$($Original.Value)" -Type String -ErrorAction SilentlyContinue
            } else {
                Remove-ItemProperty -LiteralPath $FixtureKfmPolicyPath -Name $FixtureKfmPolicyName -ErrorAction SilentlyContinue
            }
            if (-not $Original.KeyExisted -and (Test-Path -LiteralPath $FixtureKfmPolicyPath)) {
                $item = Get-Item -LiteralPath $FixtureKfmPolicyPath -ErrorAction SilentlyContinue
                if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) {
                    Remove-Item -LiteralPath $FixtureKfmPolicyPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
)

function Get-BreakDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)
    $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Request-TestReboot {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    Save-DexTestState -State $State
    Register-DexTestResume -State $State -BreakTestPath $SelfPath
    Write-DexStep -Status 'Info' -Name 'Reboot' -Message 'Rebooting to apply pending state; run resumes automatically.'
    & shutdown.exe /r /t 15 /f | Out-Null
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title "Invoke-AutoRemediateOneDrive_BreakTest" -Detail "Environment: $Environment"

# -- Restore-only mode ---------------------------------------------------------
if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    foreach ($b in $state.Breaks) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
            Write-DexStep -Status 'Passed' -Name "Restore $($b.Name)"
        } catch {
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    Remove-Fixture
    Unregister-DexTestResume -State $state
    $state.Phase   = 'Restored'
    $state.Overall = 'Restored'
    Write-DexTestResult -State $state | Out-Null
    Clear-DexTestState -State $state
    exit 0
}

# -- Acquire context -----------------------------------------------------------
if ($Resume) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    if (Test-DexRebootOccurred -State $state) {
        $state.RebootCount = [int]$state.RebootCount + 1
        Write-DexStep -Status 'Info' -Name 'Resume' -Message "Reboot #$($state.RebootCount) confirmed; resuming at phase '$($state.Phase)'."
    } else {
        Write-DexStep -Status 'Warning' -Name 'Resume' -Message 'No reboot detected since the run started.'
    }
    # RemediationTest cannot survive as a switch across the reboot, so it is
    # recovered from the state that was persisted before the machine went down.
    $RemediationTest = [bool]$state.RemediationTest
} else {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
    $state.RemediationTest = [bool]$RemediationTest
    Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"
}

$exitCode = 0

try {
    # -- Phase: apply breaks ---------------------------------------------------
    if ($state.Phase -eq 'Init') {

        Initialize-Fixture

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { $BreakName -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { $IncludeRebootBreaks -or -not $_.RequiresReboot })
        }

        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) {
            $candidates
        } else {
            Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount
        }

        # The two FileSyncHelper breaks act on the same service: Disabled would make the Stopped
        # break's Validate (expects Running) impossible, and the Stopped break's Restore would
        # undo the Disabled break's fault before the script saw it. Keep Stopped, drop Disabled.
        $serviceBreaks = @($selected | Where-Object { $_.Name -like 'FilesOnDemandService*' })
        if ($serviceBreaks.Count -gt 1) {
            $selected = @($selected | Where-Object { $_.Name -ne 'FilesOnDemandServiceDisabled' })
            Write-DexStep -Status 'Info' -Name 'Selection' -Message 'FilesOnDemandServiceDisabled dropped: it shares the service with FilesOnDemandServiceStopped; test it alone with -BreakName FilesOnDemandServiceDisabled'
        }

        $applied = @()
        foreach ($def in $selected) {
            $method = (Get-DexRandomSubset -InputObject $def.Methods -Random $state.Random -Count 1)[0]

            $original = & $def.Capture
            & $method.Apply

            if ($def.RequiresReboot) { $state.RequiresReboot = $true }

            $applied += @{
                Name            = $def.Name
                Method          = $method.Name
                ExpectedOutcome = $def.ExpectedOutcome
                RequiresReboot  = [bool]$def.RequiresReboot
                Applied         = $true
                BreakVerified   = $false
                OriginalState   = $original
            }
            Write-DexStep -Status 'Info' -Name "Break $($def.Name)" -Message "method '$($method.Name)' applied"
            # Commit at once so Restore can undo this break even if a later Capture/Apply throws.
            $state.Breaks = $applied
            Save-DexTestState -State $state
        }

        $state.Breaks = $applied
        $state.Phase  = 'Broken'
        Save-DexTestState -State $state

        if ($state.RequiresReboot) {
            Request-TestReboot -State $state
            exit 0
        }
    }

    # -- Phase: verify the break -----------------------------------------------
    if ($state.Phase -eq 'Broken') {

        $allVerified = $true
        foreach ($b in $state.Breaks) {
            $def = Get-BreakDefinition -Name $b.Name
            $ok  = [bool](& $def.Verify)
            $b.BreakVerified = $ok
            if ($ok) {
                Write-DexStep -Status 'Passed' -Name "Verify $($b.Name)" -Message 'component is genuinely broken'
            } else {
                $allVerified = $false
                Write-DexStep -Status 'Failed' -Name "Verify $($b.Name)" -Message 'break did not land; remediation would be a false green'
            }
        }

        if (-not $allVerified) {
            $state.Phase   = 'BreakFailed'
            $state.Overall = 'BreakFailed'
            Save-DexTestState -State $state
            throw 'One or more breaks could not be verified; refusing to run remediation.'
        }

        $state.Phase = 'BreakVerified'
        Save-DexTestState -State $state
    }

    # -- Phase: remediate ------------------------------------------------------
    if ($state.Phase -eq 'BreakVerified') {

        if (-not $RemediationTest) {
            $state.Overall = 'BreakOnly'
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message 'skipped (-RemediationTest not supplied)'
        } else {
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript))"

            $sw     = [System.Diagnostics.Stopwatch]::StartNew()
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1
            $rc     = $LASTEXITCODE
            $sw.Stop()

            $state.Remediation = @{
                ExitCode    = $rc
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Output      = ($output | Out-String).Trim()
            }
            $state.Phase = 'Remediated'
            Save-DexTestState -State $state

            if ($state.RequiresReboot) {
                Request-TestReboot -State $state
                exit 0
            }
        }
    }

    # -- Phase: validate -------------------------------------------------------
    if ($state.Phase -eq 'Remediated') {

        $validation = @()
        foreach ($b in $state.Breaks) {
            $def    = Get-BreakDefinition -Name $b.Name
            $passed = [bool](& $def.Validate)

            $expected = if ($b.ExpectedOutcome -eq 'ExpectFixed') {
                'component repaired by remediation'
            } else {
                'component detected and reported, left unmodified'
            }

            $validation += @{
                Name     = $b.Name
                Expected = $expected
                Actual   = if ($passed) { 'as expected' } else { 'NOT as expected' }
                Result   = if ($passed) { 'Pass' } else { 'Fail' }
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) `
                          -Name "Validate $($b.Name)" -Message $expected
        }

        $state.Validation = $validation
        $state.Phase      = 'Validated'

        $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        $state.Overall = if ($failedCount -eq 0) {
            'Passed'
        } elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) {
            # Remediation claimed success while the component is still broken.
            'FalsePass'
        } else {
            'Failed'
        }

        Save-DexTestState -State $state
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

# -- Restore -------------------------------------------------------------------
# Snapshot environments revert on the host, so restoring here would only add risk.
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    # Restore newest-first. A later break's Capture can record state an earlier break had
    # already changed; undoing in reverse order lets the oldest capture, the true baseline, win.
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
        } catch {
            $restoreFailed = $true
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    try { Remove-Fixture } catch { $restoreFailed = $true }

    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'machine returned to baseline'
    }
}

Unregister-DexTestResume -State $state

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
