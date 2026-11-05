<#
.SYNOPSIS
    Invoke-AutoRemediateOutlook_BreakTest -- deliberately plants Outlook faults, then
    verifies Invoke-AutoRemediateOutlook.ps1 reports or repairs them as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateOutlook\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes an add-in key and Cached Mode
    values into the logged-on user's Outlook hive, drops a fixture .ost into the user's
    Outlook data folder, lowers the script's OST threshold, writes tier state under the
    script's DEXRecords key, writes UpdatesEnabled under the machine's Click-to-Run
    configuration, and -- for OstRenameDeferredClose only -- lets the script close and
    relaunch the user's running Outlook once. Run it only on a disposable VM or a marked
    test host. See Assert-DexTestHost in DEXTestFramework.psm1.

    WHAT IS BROKEN AND HOW IT COMES BACK
    Invoke-AutoRemediateOutlook.ps1 resolves the logged-on user from
    Win32_ComputerSystem.UserName and reads that user's hive through HKEY_USERS\<SID>,
    so this harness does the same; run elevated as the interactive user the hive is
    the harness user's own. Every planted artefact carries the DEXTest prefix, every
    break Captures what it is about to change (whether the Addins or Cached Mode key or
    the Outlook folder existed, SyncWindowSetting / SyncWindowSettingDays, the
    DEXRecords Ost* values, the UpdatesEnabled value, the names of the user's real OSTs,
    the PIDs of a running Outlook) and Restore writes that back. No real add-in, OST or
    profile is modified.

    THE USER'S REAL OST IS NEVER THE TARGET
    Step 2 acts on the LARGEST .ost in the user's Outlook folder. Initialize-Fixture
    measures every real .ost there and sizes the fixture at the largest real OST plus
    a margin (minimum $FixtureOstBaseMB), then hands the script a threshold equal to the
    fixture size through $env:CacheSizeWarningMB. The fixture is therefore always the
    largest file and the only one at or over the threshold. The run aborts with a
    HarnessError rather than proceed when a real OST is already at or above the
    threshold the script will be given, when the fixture would exceed
    $FixtureOstMaxMB or the free space on the drive, or when OUTLOOK.EXE is running
    during a break that renames (the script refuses to rename a locked OST; this
    harness does not kill a user's Outlook -- close it and re-run).

    THE SCRIPT IS GATED BY $AllowDestructiveActions (AND MORE FOR TIER 2)
    Steps 1 and 2 only remediate when $env:AllowDestructiveActions is true, so each of
    those faults has a gated break (flag unset, ExpectReportedOnly) and ungated breaks
    (flag 'true', ExpectFixed). The flag is one environment variable for the whole
    child process, so gated and ungated breaks cannot share a run: when the seeded draw
    mixes them the first drawn decides and the others are dropped. The OST breaks share
    one fixture file and are mutually exclusive in the same way. Each break may declare
    extra variables (AllowOstRename, CloseOutlookForRepair, OutlookCloseGraceSeconds);
    every variable is set immediately before the child powershell.exe is launched and
    put back afterwards. C2RUpdatesDisabled runs with any flag.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the fault is genuinely in place.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES (derived from the script's own messages, 1.1.0)
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    ThirdPartyAddinConflictGated  ExpectReportedOnly. Plants DEXTest.LabAddin with
                                  LoadBehavior 3 in the user hive. Validate: the key
                                  still has LoadBehavior 3 and DEXRecords
                                  Step01_OfficeAddinConflict reads
                                  "[Warning] 1 active third-party add-in(s) detected:
                                  DEXTest.LabAddin. ..." (a digit, not the blank that
                                  1.0.1 printed for a single add-in).
    ThirdPartyAddinConflict       ExpectFixed. Same plant, flag 'true'. Validate:
                                  LoadBehavior is 0 and the record starts
                                  "[Remediated] 1 active third-party add-in(s)".
                                  Apply aborts if a real active third-party add-in is
                                  registered: the script disables the FIRST one it
                                  finds, which could be the real one.
    OstOverThresholdGated         ExpectReportedOnly. Fixture DEXTest_lab.ost sized as
                                  above, threshold handed to the script, no tier 1
                                  timestamp. Validate: the fixture is still there, no
                                  .bak, no SyncWindowSetting change, and
                                  Step02_OSTCacheSize reads "[Warning] DEXTest_lab.ost is
                                  <n>MB (threshold: <n>MB). Tier 1: set Cached Mode
                                  SyncWindowSetting=12 month(s) ... -- set
                                  $AllowDestructiveActions=$true to apply."
    OstOverThreshold              ExpectFixed (tier 1). Same fixture, flag 'true', no
                                  tier 1 timestamp. Validate: Cached Mode
                                  SyncWindowSetting is 12 and SyncWindowSettingDays
                                  absent in the user hive, DEXRecords OstTier1AppliedAt
                                  is a fresh ISO timestamp, the fixture is untouched (no
                                  .bak), and the record starts "[Remediated] ... Tier 1:
                                  set Cached Mode SyncWindowSetting=12 month(s)".
    OstRenameTier2                ExpectFixed (tier 2, Outlook closed). Fixture plus
                                  OstTier1AppliedAt planted 10 days back and
                                  SyncWindowSetting 12; AllowOstRename=true. Validate:
                                  the fixture .ost is gone, exactly one
                                  DEXTest_lab_<yyyyMMdd-HHmmss>.bak exists, every real
                                  OST captured beforehand is still present, and the
                                  record reads "[Remediated] DEXTest_lab.ost (<n>MB)
                                  renamed to DEXTest_lab_<stamp>.bak; ...".
    OstRenameDeferredClose        ExpectFixed (tier 2, Outlook OPEN). Capture aborts with
                                  a HarnessError when OUTLOOK.EXE is not running: start
                                  classic Outlook first. The harness never launches or
                                  kills Outlook itself; the script's helper closes it
                                  (toast, 15 s grace, CloseMainWindow every 10 s for up
                                  to 60 s) and relaunches it once. Same planting plus
                                  CloseOutlookForRepair=true and OutlookCloseGraceSeconds=15.
                                  Validate: record reads "[Warning] Dispatched: Outlook
                                  closes in 15 s for OST repair (DEXTest_lab.ost, <n>MB)
                                  ...", then within 120 s
                                  C:\ProgramData\AirWatch\Extensions\Outlook\state\result.json
                                  appears with Outcome Renamed (CloseAttempts is logged),
                                  the fixture is gone and a .bak present, real OSTs intact,
                                  OUTLOOK.EXE is running again under a new PID. Then the
                                  PRODUCTION CLEANUP is exercised: a Limited user cannot
                                  delete a task an administrator registered (run
                                  ff8b6dd9627d), so Validate waits up to 90 s for the task
                                  to leave Running and the helper powershell.exe to exit
                                  (run 0cb9cfebabdf: a second run 5 s after result.json
                                  met a Running task, which the script skips by design),
                                  then runs the script a second time with the same
                                  variables and asserts that task
                                  DEX-OutlookOstRepair is gone and DEXRecords
                                  OstRepairLastOutcome = Renamed with OstRepairLastFinished
                                  equal to the result file's Finished (the ingestion path).
                                  Restore runs after that: it deletes fixture, .bak, any
                                  result.json the second run left, the empty state folder
                                  if this run created it, and any leftover task.
    C2RUpdatesDisabled            ExpectReportedOnly. Sets UpdatesEnabled = 'False' under
                                  HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration
                                  (Capture keeps the old value or its absence). Validate:
                                  value still 'False', Step04_OfficeC2RUpdateHealth reads
                                  "[Warning] C2R updates are disabled (UpdatesEnabled=False)
                                  ..." (1.0.1 said Failed and promised an update attempt
                                  the script never makes), and the script exited 0 unless
                                  some other step genuinely reported Failed.

    NOT COVERED
      Step 2 'Wait' branch (tier 1 applied, tier 2 not yet due) and the two refusal
             branches (AllowOstRename unset; Outlook open without CloseOutlookForRepair):
             reported-only paths, derivable from the breaks above by changing Env.
      Step 2 helper outcome UserActionRequired (Outlook ignores every CloseMainWindow
             for 60 s, as in run a0a4367071fd) -- needs a human or a modal dialog to
             hold Outlook open; the harness reports CloseAttempts when it happens.
      Step 3 Exchange Sync Backlog -- the only trigger is an Outlook error event in the
             Application log, which cannot be removed without clearing the log.
      Step 4 ErrorCode branch -- a planted non-zero ErrorCode under ClickToRun\Updates
             would still produce Failed with "Will trigger a retry".
      Step 5 Outlook Profile Health -- every warning branch needs the user's real
             DefaultProfile or Profiles keys to be removed or edited.

    REBOOTS
    No break in this catalog requires a reboot. The reboot plumbing is kept so the
    harness stays uniform with the rest of the family.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateOutlook.ps1 and validate the outcome.
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
    Script Name  : Invoke-AutoRemediateOutlook_BreakTest.ps1
    Version      : 1.1.2
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateOutlook\

    1.1.2  OstRenameDeferredClose waits (<= 90 s) for the helper task to leave Running and
           the helper process to exit before the second run; the script skips a Running
           task by design and run 0cb9cfebabdf hit that window. Task state is printed
           before and immediately after the second run.
    1.1.1  OstRenameDeferredClose runs the script a second time after result.json and
           asserts the production cleanup (task removed, outcome ingested into DEXRecords)
           instead of expecting the Limited-user helper to delete an admin task; Restore
           cleans the helper's state leftovers after that run.
    1.1.0  Tracks script 1.1.0: OstOverThreshold expects tier 1 (sync window), new
           OstRenameTier2 and OstRenameDeferredClose, per-break Env, OST breaks exclusive.
    1.0.0  Initial: add-in gated/ungated, OST gated/ungated, C2RUpdatesDisabled.

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

$ScriptUnderTest   = 'Invoke-AutoRemediateOutlook'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateOutlook.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\OutlookErrors'
$C2RConfigPath     = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$SelfPath          = $MyInvocation.MyCommand.Path

# Four levels up since the Microsoft products moved under ApplicationSpecific\Microsoft (commit e87eaea).
$modulePath = Join-Path $PSScriptRoot '..\..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

if (-not (Test-Path -LiteralPath $RemediationScript)) {
    throw "Script under test not found at $RemediationScript"
}

# -- Fixture ------------------------------------------------------------------
# Everything planted on disk or in the registry is named with this prefix and is
# the only thing the sweep in Remove-Fixture will touch.
$FixturePrefix        = 'DEXTest'
$FixtureAddinName     = 'DEXTest.LabAddin'   # must NOT match the script's Microsoft matcher: '^Microsoft\.|UCAddin|UmOutlookAddin|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync'
$FixtureOstBaseName   = 'DEXTest_lab'        # the script renames it to DEXTest_lab_<yyyyMMdd-HHmmss>.bak
$FixtureOstBaseMB     = 128                  # fixture size when no real OST exists
$FixtureOstMarginMB   = 256                  # fixture = largest real OST + this margin, never smaller than the base
$FixtureOstMaxMB      = 8192                 # refuse to create a fixture larger than this
$FixtureFreeSpaceMB   = 1024                 # keep at least this much free after the fixture
$FixtureSyncWindow    = 12                   # the script's default OstSyncWindowMonths
$FixtureTier1AgeDays  = 10                   # planted OstTier1AppliedAt age; script default OstTier2AfterDays is 7
$FixtureGraceSeconds  = 15                   # OutlookCloseGraceSeconds handed to the deferred-close break
$FixtureHelperDir     = 'C:\ProgramData\AirWatch\Extensions\Outlook'      # the script's helper folder
$FixtureResultPath    = "$FixtureHelperDir\state\result.json"            # the helper's outcome file
$FixtureHelperPath    = "$FixtureHelperDir\OstRepairHelper.ps1"          # the helper the script persists and the task runs
$FixtureTaskName      = 'DEX-OutlookOstRepair'                            # the script's one-shot task

# Same matcher as the script, verbatim, so "third-party" means the same thing here.
$MicrosoftAddinMatcher = '^Microsoft\.|UCAddin|UmOutlookAddin|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync'

# Set by Initialize-Fixture from the real OSTs on this host; persisted in state as
# OstFixtureMB so a -Resume or -Restore run uses the same number.
$script:OstFixtureMB = 0

function Initialize-Fixture {
    if (-not (Test-OutlookInstalled)) {
        throw 'Classic Outlook (Office16 OUTLOOK.EXE) and the Click-to-Run configuration key are both absent; Invoke-AutoRemediateOutlook.ps1 would exit 0 as Skipped.'
    }

    # Both throw when nobody is logged on -- the script would then skip or Warning every per-user step.
    $user = Get-LoggedOnUser
    $sid  = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
        throw "Hive for $user ($sid) is not loaded under HKEY_USERS; the script's add-in and profile checks would not see it."
    }
    $officeVer = Get-OfficeVersion
    if (-not $officeVer) {
        throw 'Office version could not be resolved from VersionToReport or HKLM Office keys; the script would skip its add-in and OST checks.'
    }

    # OST sizing: the fixture must be the largest .ost in the folder by a clear margin.
    $realOsts  = @(Get-RealOstFiles)
    $largestMB = 0
    foreach ($f in $realOsts) {
        $mb = [math]::Ceiling($f.Length / 1MB)
        if ($mb -gt $largestMB) { $largestMB = $mb }
    }
    $script:OstFixtureMB = [math]::Max($FixtureOstBaseMB, $largestMB + $FixtureOstMarginMB)

    $thirdParty = @(Get-ActiveThirdPartyAddins)
    $realList   = if ($realOsts.Count -gt 0) { ($realOsts | ForEach-Object { "$($_.Name) $([math]::Round($_.Length / 1MB, 0))MB" }) -join ', ' } else { 'none' }
    $cm         = Get-CachedModeValues
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Outlook $(Get-OutlookVersion); Office $officeVer; user $user; real OSTs: $realList; OST fixture $($script:OstFixtureMB)MB (threshold $($script:OstFixtureMB)MB); real active third-party add-ins: $($thirdParty.Count); SyncWindowSetting '$($cm.SyncWindowSetting)' Days '$($cm.SyncWindowSettingDays)'; OstTier1AppliedAt '$(Get-DexRecordRaw -Name 'OstTier1AppliedAt')'; OUTLOOK.EXE running: $(Test-OutlookRunning)"
}

function Remove-Fixture {
    # Sweep by prefix. The per-break Restore blocks have normally done all of this already;
    # this catches anything a half-finished run left behind.
    try {
        $key = Get-FixtureAddinKeyPath
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    try {
        foreach ($f in @(Get-FixtureOstArtifacts)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    try {
        $t = Get-ScheduledTask -TaskName $FixtureTaskName -ErrorAction SilentlyContinue
        if ($t -and $t.State -ne 'Running') { Unregister-ScheduledTask -TaskName $FixtureTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    } catch { }
}

# -- Helpers ------------------------------------------------------------------

function Get-LoggedOnUser {
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $u) { throw 'No interactive user is logged on; Invoke-AutoRemediateOutlook.ps1 resolves its user from Win32_ComputerSystem.UserName.' }
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

function Get-OutlookDataPath {
    Join-Path (Get-UserProfilePath) 'AppData\Local\Microsoft\Outlook'
}

function Get-C2RConfig {
    Get-ItemProperty -LiteralPath $C2RConfigPath -ErrorAction SilentlyContinue
}

function Test-OutlookInstalled {
    foreach ($p in @(
        "$env:ProgramFiles\Microsoft Office\root\Office16\OUTLOOK.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OUTLOOK.EXE",
        "$env:ProgramFiles\Microsoft Office\Office16\OUTLOOK.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\OUTLOOK.EXE"
    )) {
        if (Test-Path -LiteralPath $p) { return $true }
    }
    return [bool](Get-C2RConfig)
}

function Get-OutlookVersion {
    foreach ($p in @(
        "$env:ProgramFiles\Microsoft Office\root\Office16\OUTLOOK.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OUTLOOK.EXE"
    )) {
        if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p).VersionInfo.FileVersion }
    }
    $cfg = Get-C2RConfig
    if ($cfg -and $cfg.VersionToReport) { return "$($cfg.VersionToReport) (C2R)" }
    return 'unknown'
}

function Get-OfficeVersion {
    # Same resolution order as the script: VersionToReport major.minor, then HKLM Office keys.
    $cfg = Get-C2RConfig
    if ($cfg -and $cfg.VersionToReport) {
        $parts = "$($cfg.VersionToReport)".Split('.')
        if ($parts.Count -ge 2) { return "$($parts[0]).$($parts[1])" }
    }
    foreach ($v in @('16.0', '15.0', '14.0')) {
        if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Office\$v\Outlook") { return $v }
    }
    return $null
}

function Get-UserOutlookKeyPath {
    "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)\Software\Microsoft\Office\$(Get-OfficeVersion)\Outlook"
}

function Get-UserAddinsKeyPath {
    Join-Path (Get-UserOutlookKeyPath) 'Addins'
}

function Get-FixtureAddinKeyPath {
    Join-Path (Get-UserAddinsKeyPath) $FixtureAddinName
}

function Get-FixtureAddinLoadBehavior {
    $key = Get-FixtureAddinKeyPath
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    return (Get-ItemProperty -LiteralPath $key -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
}

function Get-ActiveThirdPartyAddins {
    <#
        Every add-in the script would count as an active third-party add-in, from both
        HKLM and the user's hive, excluding our own fixture. Plain array on purpose:
        callers wrap in @(...).
    #>
    $list = New-Object System.Collections.Generic.List[string]
    $subkey = "Software\Microsoft\Office\$(Get-OfficeVersion)\Outlook\Addins"
    foreach ($root in @("HKLM:\$subkey", (Get-UserAddinsKeyPath))) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            if ($k.PSChildName -eq $FixtureAddinName) { continue }
            if ($k.PSChildName -match $MicrosoftAddinMatcher) { continue }
            $lb = (Get-ItemProperty -LiteralPath $k.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
            if ($lb -eq 3) { $list.Add("$($k.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')") }
        }
    }
    return $list.ToArray()
}

function Test-OutlookRunning {
    [bool](Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue)
}

function Test-HelperProcessRunning {
    # True while a powershell.exe with the helper script on its command line is still alive.
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
               Where-Object { "$($_.CommandLine)" -like "*$FixtureHelperPath*" })
    return ($procs.Count -gt 0)
}

function Get-FixtureTaskState {
    # 'absent' or the task's State as text; for diagnostics.
    $t = Get-ScheduledTask -TaskName $FixtureTaskName -ErrorAction SilentlyContinue
    if ($t) { return "$($t.State)" } else { return 'absent' }
}

function Get-OutlookPids {
    # Plain int array; callers wrap in @().
    return @(Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
}

function Get-RealOstFiles {
    # The user's own .ost files: everything in the Outlook folder that is not ours. Plain array.
    $dir = Get-OutlookDataPath
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.ost' -File -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -notlike "$FixturePrefix*" })
}

function Get-FixtureOstPath {
    Join-Path (Get-OutlookDataPath) "$FixtureOstBaseName.ost"
}

function Get-FixtureOstArtifacts {
    # The fixture .ost and any .bak the script made from it. Plain array.
    $dir = Get-OutlookDataPath
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
             Where-Object { ($_.Name -eq "$FixtureOstBaseName.ost") -or ($_.Name -like "${FixtureOstBaseName}_*.bak") })
}

function Get-FixtureOstBakFiles {
    $dir = Get-OutlookDataPath
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter "${FixtureOstBaseName}_*.bak" -File -ErrorAction SilentlyContinue)
}

function Get-OstFixtureSizeMB {
    # In-process after Initialize-Fixture; from the persisted state on -Resume / -Restore.
    if ($script:OstFixtureMB -gt 0) { return [int]$script:OstFixtureMB }
    if ($state -and $state.OstFixtureMB) { return [int]$state.OstFixtureMB }
    return $FixtureOstBaseMB
}

function New-FixtureOst {
    <#
        Creates the fixture with fsutil, as the lab runbook does, after proving it is safe:
        it must be the largest .ost by the configured margin, within the size cap, and
        leave free space on the drive.
    #>
    $sizeMB = Get-OstFixtureSizeMB
    $path   = Get-FixtureOstPath
    $dir    = Split-Path -Path $path -Parent

    $largestReal = 0
    foreach ($f in @(Get-RealOstFiles)) { if ($f.Length -gt $largestReal) { $largestReal = $f.Length } }
    if ($largestReal -gt 0 -and ($sizeMB * 1MB) -le ($largestReal + ($FixtureOstMarginMB * 1MB) - 1MB)) {
        throw "Fixture of ${sizeMB}MB is not at least ${FixtureOstMarginMB}MB larger than the largest real OST ($([math]::Round($largestReal / 1MB, 0))MB); the script's rename could hit a real file. Refusing."
    }
    if ($sizeMB -gt $FixtureOstMaxMB) {
        throw "Fixture would be ${sizeMB}MB (largest real OST plus ${FixtureOstMarginMB}MB), over the ${FixtureOstMaxMB}MB cap. Refusing to create it."
    }
    $drive = (Get-Item -LiteralPath (Get-UserProfilePath)).PSDrive
    $freeMB = [math]::Floor($drive.Free / 1MB)
    if ($freeMB -lt ($sizeMB + $FixtureFreeSpaceMB)) {
        throw "Only ${freeMB}MB free on $($drive.Name):; a ${sizeMB}MB fixture would leave less than ${FixtureFreeSpaceMB}MB. Refusing."
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }

    & fsutil.exe file createnew $path ([int64]$sizeMB * 1MB) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fsutil file createnew failed with exit code $LASTEXITCODE for $path" }
    if (-not (Test-Path -LiteralPath $path)) { throw "fsutil reported success but $path does not exist" }
}

function Get-MissingDirectories {
    <#
        Returns, parent-first, the directories in the list that do not exist yet. Capture
        records this so Restore removes exactly the directories the break had to create
        and nothing Outlook itself had already made. Plain array.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    $missing = @()
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { $missing += $p }
    }
    return @($missing)
}

function Remove-MissingDirectories {
    # Deepest first; a directory is removed only if it is now empty, so a folder Outlook
    # has since started using is left alone.
    param([string[]]$Paths)
    $list = @($Paths | Where-Object { $_ })
    [array]::Reverse($list)
    foreach ($p in $list) {
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        $children = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-C2RUpdatesEnabled {
    $cfg = Get-C2RConfig
    if (-not $cfg) { return $null }
    if ($cfg.PSObject.Properties['UpdatesEnabled']) { return "$($cfg.UpdatesEnabled)" }
    return $null
}

# -- Helpers: Cached Mode and DEXRecords tier state ------------------------------

function Get-CachedModePath {
    Join-Path (Get-UserOutlookKeyPath) 'Cached Mode'
}

function Get-CachedModeValues {
    # @{ KeyExisted; SyncWindowSetting; SyncWindowSettingDays } with $null for an absent value.
    $p = Get-CachedModePath
    $r = @{ KeyExisted = (Test-Path -LiteralPath $p); SyncWindowSetting = $null; SyncWindowSettingDays = $null }
    if ($r.KeyExisted) {
        $v = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue
        if ($v -and $v.PSObject.Properties['SyncWindowSetting'])     { $r.SyncWindowSetting     = [int]$v.SyncWindowSetting }
        if ($v -and $v.PSObject.Properties['SyncWindowSettingDays']) { $r.SyncWindowSettingDays = [int]$v.SyncWindowSettingDays }
    }
    return $r
}

function Set-CachedModeValue {
    # $null removes the value; otherwise writes a DWORD.
    param([Parameter(Mandatory = $true)][string]$Name, $Value)
    $p = Get-CachedModePath
    if ($null -eq $Value) {
        if (Test-Path -LiteralPath $p) { Remove-ItemProperty -LiteralPath $p -Name $Name -ErrorAction SilentlyContinue }
        return
    }
    if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $p -Name $Name -Value ([int]$Value) -Type DWord -ErrorAction Stop
}

function Get-DexRecordRaw {
    # One DEXRecords value by exact name, as a string, or $null.
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $null }
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    if (@($key.GetValueNames()) -notcontains $Name) { return $null }
    return "$($key.GetValue($Name))"
}

function Set-DexRecordRaw {
    # $null removes the value; otherwise writes a string. Creates the key if needed.
    param([Parameter(Mandatory = $true)][string]$Name, $Value)
    if ($null -eq $Value) {
        if (Test-Path -LiteralPath $DexRecordsPath) { Remove-ItemProperty -LiteralPath $DexRecordsPath -Name $Name -ErrorAction SilentlyContinue }
        return
    }
    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { New-Item -Path $DexRecordsPath -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $DexRecordsPath -Name $Name -Value "$Value" -Type String -ErrorAction Stop
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

function Wait-ForCondition {
    # Polls a scriptblock until it returns truthy or the timeout passes. Returns the final state.
    param([Parameter(Mandatory = $true)][scriptblock]$Condition, [int]$Seconds = 30, [int]$PollMs = 1000)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if ([bool](& $Condition)) { return $true }
        Start-Sleep -Milliseconds $PollMs
    } while ((Get-Date) -lt $deadline)
    return [bool](& $Condition)
}

# -- Break-local helpers shared by the gated/ungated pairs ---------------------

function Add-FixtureAddin {
    $addins = Get-UserAddinsKeyPath
    if (-not (Test-Path -LiteralPath $addins)) {
        New-Item -Path $addins -Force -ErrorAction Stop | Out-Null
    }
    $key = Join-Path $addins $FixtureAddinName
    New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    # LoadBehavior is the only value the script reads; FriendlyName and Description are
    # what every real COM add-in registers, so the key looks like one to Outlook's UI.
    Set-ItemProperty -LiteralPath $key -Name 'LoadBehavior' -Value 3 -Type DWord -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'FriendlyName' -Value 'DEX Test Lab Add-in' -Type String -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'Description'  -Value 'Planted by Invoke-AutoRemediateOutlook_BreakTest.ps1; safe to delete.' -Type String -ErrorAction Stop
}

function Get-FixtureAddinBaseline {
    @{ AddinsKeyExisted = (Test-Path -LiteralPath (Get-UserAddinsKeyPath)) }
}

function Test-FixtureAddinPlanted {
    # The script's own test: LoadBehavior 3 and a name outside the Microsoft matcher.
    $lb = Get-FixtureAddinLoadBehavior
    if ($lb -ne 3) { Write-Host "           $FixtureAddinName LoadBehavior is '$lb', expected 3"; return $false }
    if ($FixtureAddinName -match $MicrosoftAddinMatcher) { Write-Host '           fixture name matches the Microsoft matcher'; return $false }
    return $true
}

function Restore-FixtureAddin {
    param($Original)
    $addins = Get-UserAddinsKeyPath
    $key    = Join-Path $addins $FixtureAddinName
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not [bool]$Original.AddinsKeyExisted -and (Test-Path -LiteralPath $addins)) {
        $item = Get-Item -LiteralPath $addins -ErrorAction SilentlyContinue
        if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) {
            Remove-Item -LiteralPath $addins -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-OstTierBaseline {
    <#
        Everything an OST break may change: the folders it has to create, the user's real
        OST names, the fixture size, the Cached Mode values, the DEXRecords Ost* values,
        whether a helper result file existed, and the PIDs of a running Outlook.
    #>
    $profilePath = Get-UserProfilePath
    $dir         = Get-OutlookDataPath
    $cm          = Get-CachedModeValues
    @{
        MissingDirs           = @(Get-MissingDirectories -Paths @((Join-Path $profilePath 'AppData\Local\Microsoft'), $dir))
        RealOstNames          = @(Get-RealOstFiles | ForEach-Object { $_.Name })
        FixtureMB             = Get-OstFixtureSizeMB
        CachedModeExisted     = $cm.KeyExisted
        SyncWindowSetting     = $cm.SyncWindowSetting
        SyncWindowSettingDays = $cm.SyncWindowSettingDays
        Tier1AppliedAt        = Get-DexRecordRaw -Name 'OstTier1AppliedAt'
        RepairLastOutcome     = Get-DexRecordRaw -Name 'OstRepairLastOutcome'
        RepairLastFinished    = Get-DexRecordRaw -Name 'OstRepairLastFinished'
        ResultExisted         = (Test-Path -LiteralPath $FixtureResultPath)
        StateDirExisted       = (Test-Path -LiteralPath (Split-Path -Path $FixtureResultPath -Parent))
        OutlookPids           = @(Get-OutlookPids)
    }
}

function Clear-FixtureTier1State {
    # Forces the script's tier 1 branch: no timestamp means "tier 1 not yet applied".
    Set-DexRecordRaw -Name 'OstTier1AppliedAt' -Value $null
}

function Set-FixtureTier2State {
    # Forces the script's tier 2 branch: window already at target, tier 1 older than OstTier2AfterDays.
    Set-CachedModeValue -Name 'SyncWindowSetting' -Value $FixtureSyncWindow
    Set-CachedModeValue -Name 'SyncWindowSettingDays' -Value $null
    Set-DexRecordRaw -Name 'OstTier1AppliedAt' -Value (Get-Date).AddDays(-$FixtureTier1AgeDays).ToString('o')
    if (Test-Path -LiteralPath $FixtureResultPath) { Remove-Item -LiteralPath $FixtureResultPath -Force -ErrorAction SilentlyContinue }
}

function Test-FixtureOstPlanted {
    # Broken means: the fixture exists, it is the largest .ost (the one the script will
    # pick), and the script's own rounding puts it at or over the threshold it is given.
    $path = Get-FixtureOstPath
    if (-not (Test-Path -LiteralPath $path)) { Write-Host "           $path missing"; return $false }
    $fixture   = Get-Item -LiteralPath $path
    $threshold = Get-OstFixtureSizeMB
    $sizeMB    = [math]::Round($fixture.Length / 1MB, 0)
    if ($sizeMB -lt $threshold) { Write-Host "           fixture is ${sizeMB}MB, below threshold ${threshold}MB"; return $false }
    foreach ($f in @(Get-RealOstFiles)) {
        if ($f.Length -ge $fixture.Length) { Write-Host "           real OST $($f.Name) is not smaller than the fixture"; return $false }
    }
    return $true
}

function Test-FixtureTier1Due {
    # The script picks tier 1 when OstTier1AppliedAt is absent.
    $t1 = Get-DexRecordRaw -Name 'OstTier1AppliedAt'
    if ($t1) { Write-Host "           OstTier1AppliedAt still present ('$t1'); the script would not pick tier 1"; return $false }
    return $true
}

function Test-FixtureTier2Due {
    # The script picks tier 2 when the window is 1..target and OstTier1AppliedAt is older than OstTier2AfterDays (7).
    $cm = Get-CachedModeValues
    if ($cm.SyncWindowSetting -ne $FixtureSyncWindow) { Write-Host "           SyncWindowSetting is '$($cm.SyncWindowSetting)', expected $FixtureSyncWindow"; return $false }
    $t1 = Get-DexRecordRaw -Name 'OstTier1AppliedAt'
    if (-not $t1) { Write-Host '           OstTier1AppliedAt missing'; return $false }
    $age = ((Get-Date) - [datetime]$t1).TotalDays
    if ($age -lt 7) { Write-Host "           OstTier1AppliedAt is only $([math]::Round($age, 1)) day(s) old"; return $false }
    return $true
}

function Test-RealOstsIntact {
    param($Original)
    $now = @(Get-RealOstFiles | ForEach-Object { $_.Name })
    foreach ($n in @($Original.RealOstNames | Where-Object { $_ })) {
        if ($now -notcontains "$n") { Write-Host "           real OST '$n' is no longer present"; return $false }
    }
    return $true
}

function Test-FixtureRenamed {
    # The script's rename: fixture gone, exactly one <BaseName>_<yyyyMMdd-HHmmss>.bak, real OSTs untouched.
    param($Original)
    $gone = -not (Test-Path -LiteralPath (Get-FixtureOstPath))
    if (-not $gone) { Write-Host '           fixture .ost still present; it was not renamed' }
    $baks   = @(Get-FixtureOstBakFiles)
    $oneBak = ($baks.Count -eq 1) -and ($baks[0].Name -match "^$([regex]::Escape($FixtureOstBaseName))_\d{8}-\d{6}\.bak$")
    if (-not $oneBak) { Write-Host "           expected exactly one ${FixtureOstBaseName}_<stamp>.bak, found: $(if ($baks.Count) { $baks.Name -join ', ' } else { 'none' })" }
    $realOk = Test-RealOstsIntact -Original $Original
    return ($gone -and $oneBak -and $realOk)
}

function Restore-OstTierBaseline {
    param($Original)
    foreach ($f in @(Get-FixtureOstArtifacts)) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
    # Cached Mode: values back (or away), then the key itself if the harness created it.
    Set-CachedModeValue -Name 'SyncWindowSetting'     -Value $Original.SyncWindowSetting
    Set-CachedModeValue -Name 'SyncWindowSettingDays' -Value $Original.SyncWindowSettingDays
    $cmPath = Get-CachedModePath
    if (-not [bool]$Original.CachedModeExisted -and (Test-Path -LiteralPath $cmPath)) {
        $item = Get-Item -LiteralPath $cmPath -ErrorAction SilentlyContinue
        if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) {
            Remove-Item -LiteralPath $cmPath -Force -ErrorAction SilentlyContinue
        }
    }
    # DEXRecords tier state back to what the run found.
    Set-DexRecordRaw -Name 'OstTier1AppliedAt'     -Value $Original.Tier1AppliedAt
    Set-DexRecordRaw -Name 'OstRepairLastOutcome'  -Value $Original.RepairLastOutcome
    Set-DexRecordRaw -Name 'OstRepairLastFinished' -Value $Original.RepairLastFinished
    # Helper leftovers. Validate has already given the script its second run (which ingests
    # and deletes result.json and removes the task); whatever remains is cleaned here so a
    # later production run never sees this lab outcome.
    if (Test-Path -LiteralPath $FixtureResultPath) { Remove-Item -LiteralPath $FixtureResultPath -Force -ErrorAction SilentlyContinue }
    $stateDir = Split-Path -Path $FixtureResultPath -Parent
    if (-not [bool]$Original.StateDirExisted) { Remove-MissingDirectories -Paths @($stateDir) }
    $t = Get-ScheduledTask -TaskName $FixtureTaskName -ErrorAction SilentlyContinue
    if ($t -and $t.State -ne 'Running') { Unregister-ScheduledTask -TaskName $FixtureTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-MissingDirectories -Paths @($Original.MissingDirs)
}

# -- Helpers: running the script under test --------------------------------------

function Get-RemediationVariables {
    <#
        Every variable the child must see for this run. ExtraEnv is a hashtable in-process
        and a PSCustomObject after a JSON round-trip (Resume), hence the normalisation.
    #>
    $vars = @{
        AllowDestructiveActions = if ([bool]$state.DestructiveFlag) { 'true' } else { $null }
        CacheSizeWarningMB      = if ([bool]$state.SetCacheThreshold) { "$([int]$state.OstFixtureMB)" } else { $null }
    }
    $extra = ConvertTo-DexHashtable -InputObject $state.ExtraEnv
    if ($extra) { foreach ($k in @($extra.Keys)) { $vars[$k] = "$($extra[$k])" } }
    return $vars
}

function Invoke-RemediationScript {
    <#
        Runs the script under test once with the given variables and returns
        @{ ExitCode; DurationSec; Variables; Output }. Writes nothing to the output stream:
        Validate blocks call this too and their output is [bool]-cast, where any stray
        string would read as a pass.

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

    return @{
        ExitCode    = $rc
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Variables   = $Variables
        Output      = ($output | Out-String).Trim()
    }
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
# DestructiveFlag: $true  -- the run must set $env:AllowDestructiveActions = 'true'
#                  $false -- the run must leave it unset
#                  $null  -- either
# Env: extra variables the child powershell.exe must see for this break.
$BreakCatalog = @(

    @{
        Name            = 'ThirdPartyAddinConflictGated'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $false
        Env             = @{}
        Methods         = @(
            @{
                Name  = 'PlantUserAddin'
                Apply = { Add-FixtureAddin }
            }
        )
        Capture  = { Get-FixtureAddinBaseline }
        Verify   = { Test-FixtureAddinPlanted }
        # Step 1 message: "<n> active third-party add-in(s) detected: <names>. Consider disabling
        # to rule out hang/crash contributions." The \d+ is the point: 1.0.1 printed a blank.
        Validate = {
            $lb       = Get-FixtureAddinLoadBehavior
            $intact   = ($lb -eq 3)
            if (-not $intact) { Write-Host "           $FixtureAddinName LoadBehavior is '$lb' after a gated run; expected 3" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step01_' -Pattern "^\[Warning\] \d+ active third-party add-in\(s\) detected: .*$([regex]::Escape($FixtureAddinName))"
            $intact -and $reported
        }
        Restore  = {
            param($Original)
            Restore-FixtureAddin -Original $Original
        }
    },

    @{
        Name            = 'ThirdPartyAddinConflict'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $true
        Env             = @{}
        Methods         = @(
            @{
                Name  = 'PlantUserAddin'
                Apply = {
                    # The script disables the FIRST active third-party add-in it finds (user
                    # hive first, alphabetical). If a real one is registered it might be the
                    # one disabled; this harness will not let that happen.
                    $real = @(Get-ActiveThirdPartyAddins)
                    if ($real.Count -gt 0) {
                        throw "A real active third-party add-in is registered ($($real -join '; ')); the ungated run could disable it instead of the fixture. Run ThirdPartyAddinConflictGated instead, or disable it first."
                    }
                    Add-FixtureAddin
                }
            }
        )
        Capture  = { Get-FixtureAddinBaseline }
        Verify   = { Test-FixtureAddinPlanted }
        # The script promises LoadBehavior 0 on the fixture and tags the record [Remediated].
        Validate = {
            $lb       = Get-FixtureAddinLoadBehavior
            $disabled = ($lb -eq 0)
            if (-not $disabled) { Write-Host "           $FixtureAddinName LoadBehavior is '$lb'; expected 0" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step01_' -Pattern "^\[Remediated\] \d+ active third-party add-in\(s\) detected: .*$([regex]::Escape($FixtureAddinName))"
            $disabled -and $reported
        }
        Restore  = {
            param($Original)
            Restore-FixtureAddin -Original $Original
        }
    },

    @{
        Name            = 'OstOverThresholdGated'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $false
        Env             = @{}
        Methods         = @(
            @{
                Name  = 'PlantFixtureOst'
                Apply = { New-FixtureOst; Clear-FixtureTier1State }
            }
        )
        Capture  = { Get-OstTierBaseline }
        Verify   = { (Test-FixtureOstPlanted) -and (Test-FixtureTier1Due) }
        # Step 2 gated message: "<name> is <n>MB (threshold: <n>MB). Tier 1: set Cached Mode
        # SyncWindowSetting=12 month(s) (current: ...); effective at Outlook's next start, the OST
        # shrinks after Outlook compacts it -- set $AllowDestructiveActions=$true to apply."
        Validate = {
            param($Original)
            $stillThere = Test-Path -LiteralPath (Get-FixtureOstPath)
            if (-not $stillThere) { Write-Host '           fixture .ost is gone after a gated run' }
            $baks = @(Get-FixtureOstBakFiles)
            if ($baks.Count -gt 0) { Write-Host "           a .bak was made during a gated run: $($baks.Name -join ', ')" }
            $cm = Get-CachedModeValues
            $untouched = ($cm.SyncWindowSetting -eq $Original.SyncWindowSetting) -and (-not (Get-DexRecordRaw -Name 'OstTier1AppliedAt'))
            if (-not $untouched) { Write-Host "           gated run changed tier state: SyncWindowSetting '$($cm.SyncWindowSetting)', OstTier1AppliedAt '$(Get-DexRecordRaw -Name 'OstTier1AppliedAt')'" }
            $mb = Get-OstFixtureSizeMB
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step02_' -Pattern "^\[Warning\] $([regex]::Escape("$FixtureOstBaseName.ost")) is ${mb}MB \(threshold: ${mb}MB\)\. Tier 1: set Cached Mode SyncWindowSetting=$FixtureSyncWindow month\(s\) .* -- set \`$AllowDestructiveActions=\`$true to apply\.$"
            $stillThere -and ($baks.Count -eq 0) -and $untouched -and $reported
        }
        Restore  = {
            param($Original)
            Restore-OstTierBaseline -Original $Original
        }
    },

    @{
        Name            = 'OstOverThreshold'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $true
        Env             = @{}
        Methods         = @(
            @{
                Name  = 'PlantFixtureOst'
                Apply = { New-FixtureOst; Clear-FixtureTier1State }
            }
        )
        Capture  = { Get-OstTierBaseline }
        Verify   = { (Test-FixtureOstPlanted) -and (Test-FixtureTier1Due) }
        # Tier 1: SyncWindowSetting written, SyncWindowSettingDays removed, OstTier1AppliedAt
        # stamped, the OST itself left alone. Record is tagged [Remediated].
        Validate = {
            $cm = Get-CachedModeValues
            $windowOk = ($cm.SyncWindowSetting -eq $FixtureSyncWindow) -and ($null -eq $cm.SyncWindowSettingDays)
            if (-not $windowOk) { Write-Host "           Cached Mode SyncWindowSetting '$($cm.SyncWindowSetting)' Days '$($cm.SyncWindowSettingDays)'; expected $FixtureSyncWindow and absent" }
            $t1 = Get-DexRecordRaw -Name 'OstTier1AppliedAt'
            $stampOk = $false
            if ($t1) { try { $stampOk = ([math]::Abs(((Get-Date) - [datetime]$t1).TotalMinutes) -lt 60) } catch { } }
            if (-not $stampOk) { Write-Host "           OstTier1AppliedAt '$t1' is missing or not a fresh timestamp" }
            $stillThere = Test-Path -LiteralPath (Get-FixtureOstPath)
            $baks = @(Get-FixtureOstBakFiles)
            if (-not $stillThere -or $baks.Count -gt 0) { Write-Host '           tier 1 must not rename the OST' }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step02_' -Pattern "^\[Remediated\] $([regex]::Escape("$FixtureOstBaseName.ost")) is \d+MB \(threshold: \d+MB\)\. Tier 1: set Cached Mode SyncWindowSetting=$FixtureSyncWindow month\(s\)"
            $windowOk -and $stampOk -and $stillThere -and ($baks.Count -eq 0) -and $reported
        }
        Restore  = {
            param($Original)
            Restore-OstTierBaseline -Original $Original
        }
    },

    @{
        Name            = 'OstRenameTier2'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $true
        Env             = @{ AllowOstRename = 'true' }
        Methods         = @(
            @{
                Name  = 'PlantFixtureOstWithAgedTier1'
                Apply = {
                    if (Test-OutlookRunning) {
                        throw 'OUTLOOK.EXE is running. The script refuses to rename a locked OST and this harness does not kill a user''s Outlook: close Outlook and re-run -BreakName OstRenameTier2 (or test OstRenameDeferredClose with Outlook open).'
                    }
                    New-FixtureOst
                    Set-FixtureTier2State
                }
            }
        )
        Capture  = { Get-OstTierBaseline }
        Verify   = { (Test-FixtureOstPlanted) -and (Test-FixtureTier2Due) -and (-not (Test-OutlookRunning)) }
        # Resolution message: "<name> (<n>MB) renamed to <name>_<stamp>.bak; Outlook rebuilds the OST on next launch (full resync)."
        Validate = {
            param($Original)
            $renamed  = Test-FixtureRenamed -Original $Original
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step02_' -Pattern "^\[Remediated\] $([regex]::Escape("$FixtureOstBaseName.ost")) \(\d+MB\) renamed to $([regex]::Escape($FixtureOstBaseName))_\d{8}-\d{6}\.bak; Outlook rebuilds the OST on next launch \(full resync\)\.$"
            $renamed -and $reported
        }
        Restore  = {
            param($Original)
            Restore-OstTierBaseline -Original $Original
        }
    },

    @{
        Name            = 'OstRenameDeferredClose'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $true
        Env             = @{ AllowOstRename = 'true'; CloseOutlookForRepair = 'true'; OutlookCloseGraceSeconds = "$FixtureGraceSeconds" }
        Methods         = @(
            @{
                Name  = 'PlantFixtureOstWithAgedTier1OutlookOpen'
                Apply = {
                    New-FixtureOst
                    Set-FixtureTier2State
                }
            }
        )
        # Outlook must already be open: the whole point is the script's deferred close.
        Capture  = {
            if (-not (Test-OutlookRunning)) {
                throw 'OUTLOOK.EXE is not running. OstRenameDeferredClose needs classic Outlook OPEN so the script dispatches its deferred close; start Outlook (it will be closed and relaunched once) and re-run -BreakName OstRenameDeferredClose. The harness never launches Outlook itself.'
            }
            $t = Get-ScheduledTask -TaskName $FixtureTaskName -ErrorAction SilentlyContinue
            if ($t -and $t.State -eq 'Running') {
                throw "Task $FixtureTaskName is already running (a deferred close is in progress); wait for it to finish and re-run."
            }
            Get-OstTierBaseline
        }
        Verify   = { (Test-FixtureOstPlanted) -and (Test-FixtureTier2Due) -and (Test-OutlookRunning) -and (-not (Test-Path -LiteralPath $FixtureResultPath)) }
        # Script: "[Warning] Dispatched: Outlook closes in 15 s for OST repair (<name>, <n>MB); ...".
        # Helper (as the user): toast, 15 s grace, CloseMainWindow every 10 s, rename, relaunch, result.json.
        # Then the script's NEXT run must ingest result.json into DEXRecords and remove the task.
        Validate = {
            param($Original)
            $dispatched = Test-DexRecordMatches -ValueNamePrefix 'Step02_' -Pattern "^\[Warning\] Dispatched: Outlook closes in $FixtureGraceSeconds s for OST repair \($([regex]::Escape("$FixtureOstBaseName.ost")), \d+MB\)"
            Write-Host "           waiting up to 120 s for $FixtureResultPath"
            $gotResult = Wait-ForCondition -Seconds 120 -PollMs 2000 -Condition { Test-Path -LiteralPath $FixtureResultPath }
            $outcomeOk = $false
            $finished  = ''
            if ($gotResult) {
                try {
                    $r = Get-Content -LiteralPath $FixtureResultPath -Raw | ConvertFrom-Json
                    Write-Host "           result.json: Status '$($r.Status)' Outcome '$($r.Outcome)' CloseAttempts '$($r.CloseAttempts)' RenamedTo '$($r.RenamedTo)' Finished '$($r.Finished)'"
                    $finished  = "$($r.Finished)"
                    $outcomeOk = ("$($r.Outcome)" -eq 'Renamed') -and ("$($r.Ost)" -eq (Get-FixtureOstPath))
                } catch { Write-Host "           result.json unreadable: $($_.Exception.Message)" }
            } else { Write-Host '           no result.json within 120 s (toast dismissed? Outlook refused to close? task never ran?)' }
            $renamed = Test-FixtureRenamed -Original $Original
            $oldPids = @($Original.OutlookPids | ForEach-Object { [int]$_ })
            $relaunched = Wait-ForCondition -Seconds 30 -Condition {
                $now = @(Get-OutlookPids)
                ($now.Count -gt 0) -and (@($now | Where-Object { $oldPids -notcontains $_ }).Count -gt 0)
            }
            if (-not $relaunched) { Write-Host "           OUTLOOK.EXE not running under a new PID (before: $($oldPids -join ','); now: $(@(Get-OutlookPids) -join ','))" }

            # Production cleanup. The helper tries to unregister its own task, but a Limited user
            # cannot delete a task an administrator registered (run ff8b6dd9627d left it Ready), so
            # the script's next run ingests result.json into DEXRecords and removes the finished
            # task. Give it that run now, with the same variables, and assert both.
            # The helper is still alive for a few seconds after it writes result.json (relaunching
            # Outlook, then its own finally block) and the script skips a task that is Running by
            # design. Run 0cb9cfebabdf launched the second run 5 s after the file appeared, found the
            # task Running, and it settled to Ready with nobody left to delete it. Wait for the task
            # to leave Running and for the helper process to exit before giving the script its run.
            $settleSw = [System.Diagnostics.Stopwatch]::StartNew()
            $settled  = Wait-ForCondition -Seconds 90 -PollMs 2000 -Condition {
                ((Get-FixtureTaskState) -ne 'Running') -and (-not (Test-HelperProcessRunning))
            }
            $settleSw.Stop()
            Write-Host "           helper settled: $settled after $([math]::Round($settleSw.Elapsed.TotalSeconds, 1)) s; task state '$(Get-FixtureTaskState)'; helper process running: $(Test-HelperProcessRunning)"
            Write-Host '           second script run: ingest result.json, record the outcome, remove the task'
            $second = Invoke-RemediationScript -Variables (Get-RemediationVariables)
            $state.Remediation.SecondRun = $second
            Write-Host "           second run exit $($second.ExitCode) in $($second.DurationSec) s; task state immediately after: '$(Get-FixtureTaskState)'"
            $taskGone = Wait-ForCondition -Seconds 20 -Condition { -not (Get-ScheduledTask -TaskName $FixtureTaskName -ErrorAction SilentlyContinue) }
            if (-not $taskGone) { Write-Host "           task $FixtureTaskName still registered 20 s after the second run (state: $(Get-FixtureTaskState))" }
            $lastOutcome  = Get-DexRecordRaw -Name 'OstRepairLastOutcome'
            $lastFinished = Get-DexRecordRaw -Name 'OstRepairLastFinished'
            $ingested = ($lastOutcome -eq 'Renamed') -and (-not [string]::IsNullOrEmpty($lastFinished)) -and ($lastFinished -eq $finished)
            if (-not $ingested) { Write-Host "           DEXRecords OstRepairLastOutcome '$lastOutcome' OstRepairLastFinished '$lastFinished'; expected 'Renamed' and '$finished'" }
            if (Test-Path -LiteralPath $FixtureResultPath) { Write-Host '           result.json still present after the second run (Restore will remove it)' }
            $dispatched -and $gotResult -and $outcomeOk -and $renamed -and $relaunched -and $taskGone -and $ingested
        }
        Restore  = {
            param($Original)
            Restore-OstTierBaseline -Original $Original
        }
    },

    @{
        Name            = 'C2RUpdatesDisabled'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $null
        Env             = @{}
        Methods         = @(
            @{
                Name  = 'SetUpdatesEnabledFalse'
                Apply = {
                    if (-not (Test-Path -LiteralPath $C2RConfigPath)) {
                        throw "$C2RConfigPath does not exist; step 4 would report 'configuration not found' and never read UpdatesEnabled."
                    }
                    Set-ItemProperty -LiteralPath $C2RConfigPath -Name 'UpdatesEnabled' -Value 'False' -Type String -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $v = Get-C2RUpdatesEnabled
            @{ HadValue = ($null -ne $v); Value = $v }
        }
        Verify   = {
            $v = Get-C2RUpdatesEnabled
            if ($v -ne 'False') { Write-Host "           UpdatesEnabled is '$v', expected 'False'" }
            $v -eq 'False'
        }
        # Step 4: Warning "C2R updates are disabled (UpdatesEnabled=False). Version: <v>. Updates are
        # managed by policy or MDM outside this script -- no remediation attempted." and exit 0 unless
        # some other step genuinely reported Failed. 1.0.1 said Failed and exited 1 on every such device.
        Validate = {
            $stillFalse = ((Get-C2RUpdatesEnabled) -eq 'False')
            if (-not $stillFalse) { Write-Host '           UpdatesEnabled changed during the run' }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step04_' -Pattern '^\[Warning\] C2R updates are disabled \(UpdatesEnabled=False\)\. Version: .+ Updates are managed by policy or MDM outside this script -- no remediation attempted\.$'
            $exitOk = (Test-RemediationExitCode -Expected 0) -or (Test-OtherStepFailed -ExceptPrefix 'Step04_')
            $stillFalse -and $reported -and $exitOk
        }
        Restore  = {
            param($Original)
            if (-not (Test-Path -LiteralPath $C2RConfigPath)) { return }
            if ([bool]$Original.HadValue) {
                Set-ItemProperty -LiteralPath $C2RConfigPath -Name 'UpdatesEnabled' -Value "$($Original.Value)" -Type String -ErrorAction SilentlyContinue
            } else {
                Remove-ItemProperty -LiteralPath $C2RConfigPath -Name 'UpdatesEnabled' -ErrorAction SilentlyContinue
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

Write-DexBanner -Title "Invoke-AutoRemediateOutlook_BreakTest" -Detail "Environment: $Environment"

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
        $state.OstFixtureMB = [int]$script:OstFixtureMB

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
        # Re-wrap in a second statement, not as `@(if ...)`. The if-expression unrolls a
        # one-element $candidates to the bare hashtable (so -BreakName X made .Count the
        # hashtable's key count and $selected[0] $null), while wrapping the whole if in @()
        # nests the array Get-DexRandomSubset already hands back as a single object.
        $selected = @($selected)

        # $env:AllowDestructiveActions is one value for the whole child process, so a run
        # cannot hold both a gated (flag unset) and an ungated (flag 'true') break. The first
        # drawn decides; the others are dropped. Force a pair with -BreakName to see the drop.
        $flagged = @($selected | Where-Object { $null -ne $_.DestructiveFlag })
        if ($flagged.Count -gt 0) {
            $runFlag = [bool]$flagged[0].DestructiveFlag
            $dropped = @($selected | Where-Object { ($null -ne $_.DestructiveFlag) -and ([bool]$_.DestructiveFlag -ne $runFlag) })
            if ($dropped.Count -gt 0) {
                $selected = @($selected | Where-Object { ($null -eq $_.DestructiveFlag) -or ([bool]$_.DestructiveFlag -eq $runFlag) })
                Write-DexStep -Status 'Info' -Name 'Selection' -Message "gated and ungated breaks cannot share one `$env:AllowDestructiveActions; kept flag=$runFlag, dropped $($dropped.Name -join ', ')"
            }
            $state.DestructiveFlag = $runFlag
        } else {
            $state.DestructiveFlag = $false
        }
        # The OST breaks share one fixture file and one set of tier state; keep the first drawn.
        $ostBreaks = @($selected | Where-Object { $_.Name -like 'Ost*' })
        if ($ostBreaks.Count -gt 1) {
            $keep     = $ostBreaks[0].Name
            $selected = @($selected | Where-Object { ($_.Name -notlike 'Ost*') -or ($_.Name -eq $keep) })
            Write-DexStep -Status 'Info' -Name 'Selection' -Message "OST breaks share the fixture; kept '$keep', dropped $(($ostBreaks | Select-Object -Skip 1).Name -join ', ')"
        }
        # The OST threshold is handed to the script only when an OST break is in the run.
        # With the default 30720 MB any real OST the user has stays far below it.
        $state.SetCacheThreshold = ($ostBreaks.Count -gt 0)
        # Extra variables the selected breaks need (AllowOstRename, CloseOutlookForRepair, ...).
        $extra = @{}
        foreach ($def in $selected) {
            if ($def.Env) { foreach ($k in @($def.Env.Keys)) { $extra[$k] = "$($def.Env[$k])" } }
        }
        $state.ExtraEnv = $extra

        # Never run with the flag set while a real OST would be at or over the threshold the
        # script is about to use: step 2 would act on the user's file.
        if ($state.DestructiveFlag) {
            $threshold = if ($state.SetCacheThreshold) { [int]$state.OstFixtureMB } else { 30720 }
            foreach ($f in @(Get-RealOstFiles)) {
                if ([math]::Round($f.Length / 1MB, 0) -ge $threshold) {
                    throw "Real OST $($f.Name) ($([math]::Round($f.Length / 1MB, 0))MB) is at or over the ${threshold}MB threshold the script will use; an ungated run would act on it. Refusing."
                }
            }
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
            $vars = Get-RemediationVariables
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message ("invoking $([System.IO.Path]::GetFileName($RemediationScript)) with " + (($vars.Keys | Sort-Object | ForEach-Object { "$_='$($vars[$_])'" }) -join ' '))

            $state.Remediation = Invoke-RemediationScript -Variables $vars
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
    $state.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
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
