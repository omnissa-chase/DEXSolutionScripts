<#
.SYNOPSIS
    Invoke-AutoRemediateTeams_BreakTest -- deliberately plants a Teams fault, then
    verifies Invoke-AutoRemediateTeams.ps1 reports it as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateTeams\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes notification override keys
    into the logged-on user's hive. Run it only on a disposable VM or a marked test
    host. See Assert-DexTestHost in DEXTestFramework.psm1.

    WHAT IS BROKEN AND HOW IT COMES BACK
    Invoke-AutoRemediateTeams.ps1 resolves the logged-on user from
    Win32_ComputerSystem.UserName and reads that user's hive through HKEY_USERS\<SID>,
    so this harness does the same; run elevated as the interactive user the hive is
    the harness user's own. Every planted key carries the DEXTest prefix, Capture
    records whether the parent Notifications\Settings key existed, and Restore removes
    only the DEXTest keys (and the parent only if the harness created it and it is
    still empty). The user's real Teams data, sign-in tokens, settings and the MSTeams
    package are never touched. Teams may stay running: the only break here is a
    registry read.

    WHAT THIS HOST CAN EXERCISE (CBRADLEYSWIN11, 2026-11-05)
    New Teams is installed as the MSTeams AppX package (26276.513.5241.9675). There is
    no Classic Teams (no %LOCALAPPDATA%\Microsoft\Teams\Update.exe), so the script
    runs its "Variant: New (AppX)" path and only 2 of its 6 steps are enabled:
      Step 5 Teams Notification Settings     -- covered (NotificationOverrideDisabled)
      Step 6 New Teams Package Registration  -- NOT covered: the only non-Passed branch
             needs Get-AppxPackage to report a Status other than Ok, which means a
             genuinely broken or staged package. Injecting that would mean removing or
             corrupting the user's New Teams install, which this harness will not do.
    Steps 1-4 (Teams Cache Bloat, Sign-in / Auth Token Cache, Teams Updater Stuck,
    Classic Teams Update Health) are Enabled = $_teamsIsClassic and are skipped on this
    host; they cannot be exercised here without a Classic Teams install. A fake
    %LOCALAPPDATA%\Microsoft\Teams\Update.exe marker would switch them on but would
    also make every inventory on the device report Classic Teams as installed, so it
    is deliberately not planted.

    EXPECTED OUTCOMES (derived from the script's own messages, 1.0.2)
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    NotificationOverrideDisabled  ExpectReportedOnly. Plants a notification override
                                  key whose name matches the script's '*Teams*' filter
                                  (DEXTest.MSTeams.Lab) with Enabled = 0 under
                                  HKU\<SID>\SOFTWARE\Microsoft\Windows\CurrentVersion\
                                  Notifications\Settings. Method PlantMixedOverrides
                                  also plants DEXTest.Teams.Enabled with Enabled = 1 to
                                  prove the script lists only the disabled key.
                                  Validate: the key still has Enabled 0, DEXRecords
                                  Step05_TeamsNotificationSettings reads
                                  "[Warning] Teams notifications are explicitly disabled
                                  for: <names>. This is often intentional (Focus Assist /
                                  user preference). Review before changing.", <names>
                                  contains the disabled fixture and not the enabled one,
                                  LastScanTime is from this run, and the script exited 0
                                  unless some other step genuinely reported Failed.

    THE SCRIPT IS NEVER GIVEN $AllowDestructiveActions
    No break in this catalog needs the flag (step 5 has no resolution). The harness
    removes AllowDestructiveActions and CacheSizeWarningMB from the child's environment
    so a stale value in the operator's shell can never make step 6 re-register the
    package.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the fault is genuinely in place.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    REBOOTS
    No break in this catalog requires a reboot. The reboot plumbing is kept so the
    harness stays uniform with the rest of the family.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateTeams.ps1 and validate the outcome.
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
    How many components to break when selecting randomly. Default 2 (the catalog
    currently holds one break, so the draw selects it and its method).

.PARAMETER IncludeRebootBreaks
    Allow breaks that require a reboot to take effect. Default off.

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateTeams_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateTeams\

    1.0.0  Initial: NotificationOverrideDisabled (two methods). Classic-only steps and
           step 6 documented as not coverable on a New-Teams-only host.

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

$ScriptUnderTest   = 'Invoke-AutoRemediateTeams'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateTeams.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\TeamsErrors'
$SelfPath          = $MyInvocation.MyCommand.Path

# _AutomatedTesting -> Teams -> Microsoft -> ApplicationSpecific -> repo root.
$modulePath = Join-Path $PSScriptRoot '..\..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

if (-not (Test-Path -LiteralPath $RemediationScript)) {
    throw "Script under test not found at $RemediationScript"
}

# -- Fixture ------------------------------------------------------------------
# Everything planted in the registry is named with this prefix and is the only
# thing the sweep in Remove-Fixture will touch.
$FixturePrefix           = 'DEXTest'
$FixtureDisabledKeyName  = 'DEXTest.MSTeams.Lab'    # matches the script's '*Teams*' / '*MSTeams*' filter; Enabled = 0
$FixtureEnabledKeyName   = 'DEXTest.Teams.Enabled'  # matches the filter too; Enabled = 1, must NOT be listed
$FixtureKeyNames         = @($FixtureDisabledKeyName, $FixtureEnabledKeyName)
# Variables the script reads from the environment. Both are removed from the child
# for every run: no break here needs them and a stale AllowDestructiveActions would
# arm step 6.
$RemediationVariableNames = @('AllowDestructiveActions', 'CacheSizeWarningMB')

function Initialize-Fixture {
    # Both throw when nobody is logged on -- the script would then Warning step 5 and skip the rest.
    $user = Get-LoggedOnUser
    $sid  = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
        throw "Hive for $user ($sid) is not loaded under HKEY_USERS; the script's notification check would not see it."
    }

    $pkg     = Get-NewTeamsPackage
    $classic = Test-ClassicTeamsInstalled
    if (-not $pkg -and -not $classic) {
        throw 'Neither New Teams (MSTeams AppX) nor Classic Teams (Update.exe) is installed; Invoke-AutoRemediateTeams.ps1 would exit 0 as Skipped.'
    }

    $existing = @(Get-TeamsNotificationKeys | Where-Object { $_.PSChildName -notlike "$FixturePrefix*" })
    $existingNote = if ($existing.Count -gt 0) {
        ($existing | ForEach-Object { "$($_.PSChildName)=$((Get-ItemProperty -LiteralPath $_.PSPath -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled)" }) -join ', '
    } else { 'none' }
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "New Teams $(if ($pkg) { "$($pkg.Version) status '$($pkg.Status)'" } else { 'absent' }); Classic Teams $(if ($classic) { 'present' } else { 'absent' }); user $user; real *Teams* notification keys: $existingNote; Teams running: $(Test-TeamsRunning)"
}

function Remove-Fixture {
    # Sweep by prefix. The per-break Restore blocks have normally done all of this already;
    # this catches anything a half-finished run left behind.
    try {
        foreach ($k in @(Get-FixtureNotificationKeys)) {
            Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

# -- Helpers ------------------------------------------------------------------

function Get-LoggedOnUser {
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $u) { throw 'No interactive user is logged on; Invoke-AutoRemediateTeams.ps1 resolves its user from Win32_ComputerSystem.UserName.' }
    return $u
}

function Get-LoggedOnUserSid {
    $u = Get-LoggedOnUser
    return ([Security.Principal.NTAccount]$u).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Get-UserProfilePath {
    # Mirrors the script: C:\Users\<short name>, never $env:USERPROFILE.
    $shortName = (Get-LoggedOnUser).Split('\')[-1]
    $p = "C:\Users\$shortName"
    if (-not (Test-Path -LiteralPath $p)) { throw "Profile folder '$p' for the logged-on user not found." }
    return $p
}

function Get-NewTeamsPackage {
    # Same order as the script: every user's packages first (needs elevation), then the caller's.
    $pkg = $null
    try   { $pkg = Get-AppxPackage -Name 'MSTeams' -AllUsers -ErrorAction Stop | Select-Object -First 1 }
    catch { $pkg = Get-AppxPackage -Name 'MSTeams' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    return $pkg
}

function Test-ClassicTeamsInstalled {
    # The script's Classic marker: Update.exe in the user's %LOCALAPPDATA%\Microsoft\Teams.
    [bool](Test-Path -LiteralPath (Join-Path (Get-UserProfilePath) 'AppData\Local\Microsoft\Teams\Update.exe'))
}

function Test-TeamsRunning {
    [bool](Get-Process -Name 'ms-teams', 'Teams' -ErrorAction SilentlyContinue)
}

function Get-NotificationSettingsPath {
    "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings"
}

function Get-TeamsNotificationKeys {
    # The same filter as step 5's DetectionScript. Plain array; callers wrap in @().
    $base = Get-NotificationSettingsPath
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    return @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue |
             Where-Object { $_.PSChildName -like '*Teams*' -or $_.PSChildName -like '*MSTeams*' })
}

function Get-FixtureNotificationKeys {
    # Only our own keys. Plain array; callers wrap in @().
    return @(Get-TeamsNotificationKeys | Where-Object { $FixtureKeyNames -contains $_.PSChildName })
}

function Get-FixtureKeyEnabled {
    # The Enabled value of one fixture key, or $null when the key or value is absent.
    param([Parameter(Mandatory = $true)][string]$KeyName)
    $key = Join-Path (Get-NotificationSettingsPath) $KeyName
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    $v = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if ($v -and $v.PSObject.Properties['Enabled']) { return [int]$v.Enabled }
    return $null
}

function Add-FixtureNotificationKey {
    param(
        [Parameter(Mandatory = $true)][string]$KeyName,
        [Parameter(Mandatory = $true)][int]$Enabled
    )
    $base = Get-NotificationSettingsPath
    if (-not (Test-Path -LiteralPath $base)) {
        New-Item -Path $base -Force -ErrorAction Stop | Out-Null
    }
    $key = Join-Path $base $KeyName
    New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    # Enabled is the only value the script reads; the rest is what real app keys carry so
    # the key reads as a notification override in regedit, plus a note on where it came from.
    Set-ItemProperty -LiteralPath $key -Name 'Enabled'     -Value $Enabled -Type DWord  -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'DEXTestNote' -Value 'Planted by Invoke-AutoRemediateTeams_BreakTest.ps1; safe to delete.' -Type String -ErrorAction Stop
}

function Get-NotificationBaseline {
    @{
        SettingsKeyExisted = (Test-Path -LiteralPath (Get-NotificationSettingsPath))
        RealDisabledKeys   = @(Get-TeamsNotificationKeys |
                               Where-Object { ($FixtureKeyNames -notcontains $_.PSChildName) -and
                                              ((Get-ItemProperty -LiteralPath $_.PSPath -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled -eq 0) } |
                               ForEach-Object { $_.PSChildName })
    }
}

function Restore-NotificationBaseline {
    param($Original)
    $base = Get-NotificationSettingsPath
    foreach ($k in @(Get-FixtureNotificationKeys)) {
        Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    # The parent is removed only if the harness created it and nothing else has moved in.
    if (-not [bool]$Original.SettingsKeyExisted -and (Test-Path -LiteralPath $base)) {
        $item = Get-Item -LiteralPath $base -ErrorAction SilentlyContinue
        if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) {
            Remove-Item -LiteralPath $base -Force -ErrorAction SilentlyContinue
        }
    }
}

# -- Helpers: DEXRecords -----------------------------------------------------------

function Get-DexRecordRaw {
    # One DEXRecords value by exact name, as a string, or $null.
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $null }
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    if (@($key.GetValueNames()) -notcontains $Name) { return $null }
    return "$($key.GetValue($Name))"
}

function Get-DexRecordValue {
    <#
        The text the remediation script wrote to DEXRecords for one step, or $null.
        Value names are Step<nn>_<name without punctuation>; the text starts with
        [Warning], [Failed] or [Remediated].
    #>
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix)
    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $null }
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    $name = @($key.GetValueNames() | Where-Object { $_ -like "$ValueNamePrefix*" } | Select-Object -First 1)
    if ($name.Count -eq 0) { return $null }
    return "$($key.GetValue($name[0]))"
}

function Test-DexRecordFresh {
    <#
        True when LastScanTime under DEXRecords was written by this run's remediation.
        The script wipes and rewrites the key on every run, but a run that exits early
        (not installed, parse error) leaves the previous run's values in place, and a
        stale Step record would otherwise read as a pass. Host-stream diagnostics only.
    #>
    if (-not $state.Remediation -or -not $state.Remediation.StartedAt) { Write-Host '           no remediation record'; return $false }
    $raw = Get-DexRecordRaw -Name 'LastScanTime'
    if (-not $raw) { Write-Host "           no LastScanTime under $DexRecordsPath"; return $false }
    try {
        $scan  = [datetime]::ParseExact($raw, 'yyyy-MM-dd HH:mm:ss', $null)
        $start = ([datetime]$state.Remediation.StartedAt).AddMinutes(-1)
        if ($scan -lt $start) { Write-Host "           LastScanTime '$raw' predates this run ($($state.Remediation.StartedAt)); stale records"; return $false }
    } catch { Write-Host "           LastScanTime '$raw' is unreadable: $($_.Exception.Message)"; return $false }
    return $true
}

function Test-DexRecordMatches {
    # Host-stream diagnostics only; callers are [bool]-cast.
    param(
        [Parameter(Mandatory = $true)][string]$ValueNamePrefix,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    $text = Get-DexRecordValue -ValueNamePrefix $ValueNamePrefix
    if ($null -eq $text) {
        Write-Host "           no $ValueNamePrefix value under $DexRecordsPath"
        return $false
    }
    if ($text -notmatch $Pattern) {
        Write-Host "           $ValueNamePrefix = '$text' did not match '$Pattern'"
        return $false
    }
    return $true
}

function Test-OtherStepFailed {
    # True when any DEXRecords step other than the one named reported [Failed].
    param([Parameter(Mandatory = $true)][string]$ExceptPrefix)
    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $false }
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $false }
    foreach ($name in @($key.GetValueNames() | Where-Object { $_ -like 'Step*' -and $_ -notlike "$ExceptPrefix*" })) {
        if ("$($key.GetValue($name))" -like '[[]Failed]*') {
            Write-Host "           another step reported Failed: $name = '$($key.GetValue($name))'"
            return $true
        }
    }
    return $false
}

function Test-RemediationExitCode {
    param([Parameter(Mandatory = $true)][int]$Expected)
    if (-not $state.Remediation) { Write-Host '           no remediation record'; return $false }
    $rc = [int]$state.Remediation.ExitCode
    if ($rc -ne $Expected) { Write-Host "           remediation exit code $rc, expected $Expected" }
    return ($rc -eq $Expected)
}

function Add-HarnessError {
    # Every catch funnels here so the result's HarnessError field carries message and line.
    param([Parameter(Mandatory = $true)]$ErrorRecord, [string]$Context = 'Harness')
    $entry = "$Context`: $($ErrorRecord.Exception.Message) (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))"
    if ($state) {
        $state.HarnessError = if ($state.HarnessError) { "$($state.HarnessError); $entry" } else { $entry }
    }
}

# -- Helpers: running the script under test --------------------------------------

function Get-RemediationVariables {
    # Every variable the child must see for this run. $null removes it from the child's block.
    $vars = @{}
    foreach ($n in $RemediationVariableNames) { $vars[$n] = $null }
    return $vars
}

function Invoke-RemediationScript {
    <#
        Runs the script under test once with the given variables and returns
        @{ ExitCode; DurationSec; StartedAt; Variables; Output }. Writes nothing to the
        output stream: Validate blocks are [bool]-cast, where any stray string would read
        as a pass.

        The script reads its UEM variables from the environment. The child powershell.exe
        inherits this process's block, so the values are set here and put back afterwards
        (a null value removes the variable). Stderr from the child is captured as text:
        under the harness's $ErrorActionPreference = 'Stop' the first stderr line of a
        native command redirected with 2>&1 would otherwise become a terminating
        NativeCommandError.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Variables)

    $savedEnv = @{}
    foreach ($k in @($Variables.Keys)) { $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
    $startedAt = (Get-Date).ToString('o')
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($k in @($Variables.Keys)) { [Environment]::SetEnvironmentVariable($k, $Variables[$k], 'Process') }

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1 |
                  ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        foreach ($k in @($savedEnv.Keys)) {
            [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process')
        }
    }
    $sw.Stop()

    $shown = @{}
    foreach ($k in @($Variables.Keys)) { $shown[$k] = if ($null -eq $Variables[$k]) { '<unset>' } else { "$($Variables[$k])" } }

    return @{
        ExitCode    = $rc
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        StartedAt   = $startedAt
        Variables   = $shown
        Output      = ($output | Out-String).Trim()
    }
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
# Verify and Validate emit nothing on the output stream but their single verdict;
# diagnostics go to the host stream.
$BreakCatalog = @(

    @{
        Name            = 'NotificationOverrideDisabled'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'PlantDisabledOverride'
                Apply = { Add-FixtureNotificationKey -KeyName $FixtureDisabledKeyName -Enabled 0 }
            },
            @{
                Name  = 'PlantMixedOverrides'
                Apply = {
                    Add-FixtureNotificationKey -KeyName $FixtureDisabledKeyName -Enabled 0
                    Add-FixtureNotificationKey -KeyName $FixtureEnabledKeyName  -Enabled 1
                }
            }
        )
        Capture  = { Get-NotificationBaseline }
        # The script's own test: a '*Teams*' key under Notifications\Settings with Enabled -eq 0.
        Verify   = {
            $enabled = Get-FixtureKeyEnabled -KeyName $FixtureDisabledKeyName
            if ($enabled -ne 0) { Write-Host "           $FixtureDisabledKeyName Enabled is '$enabled', expected 0"; return $false }
            if (-not ($FixtureDisabledKeyName -like '*Teams*')) { Write-Host '           fixture name does not match the script filter'; return $false }
            $seen = @(Get-TeamsNotificationKeys | Where-Object { $_.PSChildName -eq $FixtureDisabledKeyName })
            if ($seen.Count -ne 1) { Write-Host '           the script filter does not pick up the fixture key'; return $false }
            $true
        }
        # Step 5 message: "Teams notifications are explicitly disabled for: <names>. This is often
        # intentional (Focus Assist / user preference). Review before changing." No resolution exists,
        # so the key must be untouched and the run must exit 0 unless another step really Failed.
        Validate = {
            param($Original)
            $enabled = Get-FixtureKeyEnabled -KeyName $FixtureDisabledKeyName
            $intact  = ($enabled -eq 0)
            if (-not $intact) { Write-Host "           $FixtureDisabledKeyName Enabled is '$enabled' after the run; expected 0 (step 5 has no resolution)" }
            $plantedEnabled = Get-FixtureKeyEnabled -KeyName $FixtureEnabledKeyName
            $mixedIntact = ($null -eq $plantedEnabled) -or ($plantedEnabled -eq 1)
            if (-not $mixedIntact) { Write-Host "           $FixtureEnabledKeyName Enabled is '$plantedEnabled' after the run; expected 1" }

            $fresh    = Test-DexRecordFresh
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step05_' -Pattern '^\[Warning\] Teams notifications are explicitly disabled for: .+\. This is often intentional \(Focus Assist / user preference\)\. Review before changing\.$'
            $namesOk  = $false
            if ($reported) {
                $text  = Get-DexRecordValue -ValueNamePrefix 'Step05_'
                $names = @(([regex]::Match($text, 'disabled for: (.+?)\. This is often')).Groups[1].Value -split ',\s*')
                $hasDisabled = ($names -contains $FixtureDisabledKeyName)
                $hasEnabled  = ($names -contains $FixtureEnabledKeyName)
                if (-not $hasDisabled) { Write-Host "           '$FixtureDisabledKeyName' missing from the reported list: $($names -join ', ')" }
                if ($hasEnabled)       { Write-Host "           '$FixtureEnabledKeyName' (Enabled=1) was listed as disabled: $($names -join ', ')" }
                # Real disabled keys captured before the break must still be listed too.
                $realMissing = @($Original.RealDisabledKeys | Where-Object { $_ -and ($names -notcontains "$_") })
                if ($realMissing.Count -gt 0) { Write-Host "           real disabled key(s) not listed: $($realMissing -join ', ')" }
                $namesOk = $hasDisabled -and (-not $hasEnabled) -and ($realMissing.Count -eq 0)
            }
            $exitOk = (Test-RemediationExitCode -Expected 0) -or (Test-OtherStepFailed -ExceptPrefix 'Step05_')
            $intact -and $mixedIntact -and $fresh -and $reported -and $namesOk -and $exitOk
        }
        Restore  = {
            param($Original)
            Restore-NotificationBaseline -Original $Original
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

Write-DexBanner -Title "Invoke-AutoRemediateTeams_BreakTest" -Detail "Environment: $Environment"

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
            Add-HarnessError -ErrorRecord $_ -Context "Restore $($b.Name)"
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    try { Remove-Fixture } catch { Add-HarnessError -ErrorRecord $_ -Context 'Remove-Fixture' }
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
            @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { $IncludeRebootBreaks -or -not $_.RequiresReboot })
        }
        # An if-expression unrolls a one-element array to the bare hashtable; re-wrap.
        $candidates = @($candidates)

        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) {
            $candidates
        } else {
            Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount
        }
        $selected = @($selected)

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
            $vars = Get-RemediationVariables
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message ("invoking $([System.IO.Path]::GetFileName($RemediationScript)) with " + (($vars.Keys | Sort-Object | ForEach-Object { "$_=<unset>" }) -join ' '))

            $state.Remediation = Invoke-RemediationScript -Variables $vars
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "exit $($state.Remediation.ExitCode) in $($state.Remediation.DurationSec) s"
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
            $passed = [bool](& $def.Validate ([PSCustomObject]$b.OriginalState))

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
    Add-HarnessError -ErrorRecord $_ -Context 'Harness'
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
            Add-HarnessError -ErrorRecord $_ -Context "Restore $($b.Name)"
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    try { Remove-Fixture } catch { $restoreFailed = $true; Add-HarnessError -ErrorRecord $_ -Context 'Remove-Fixture' }

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
