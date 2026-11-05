<#
.SYNOPSIS
    Invoke-AutoRemediateZoom_BreakTest -- deliberately plants Zoom faults, then
    verifies Invoke-AutoRemediateZoom.ps1 reports or repairs them as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateZoom\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It plants files inside the logged-on
    user's %APPDATA%\Zoom\data\cache and %APPDATA%\Zoom\logs folders, writes an Outlook
    add-in key and a webcam consent entry into the user's hive, and writes
    EnableAutoUpdate under the machine-wide HKLM:\SOFTWARE\Zoom\ZoomUpdate key. Run it
    only on a disposable VM or a marked test host. See Assert-DexTestHost in
    DEXTestFramework.psm1.

    WHAT IS BROKEN AND HOW IT COMES BACK
    Invoke-AutoRemediateZoom.ps1 resolves the logged-on user from
    Win32_ComputerSystem.UserName, reads that user's hive through HKEY_USERS\<SID> and
    that user's C:\Users\<name>\AppData\Roaming\Zoom, so this harness does the same;
    run elevated as the interactive user the hive is the harness user's own. Every
    planted file and key carries the DEXTest prefix (the webcam entry is the one
    exception, see below), every break Captures what it is about to change (which
    folders and keys existed, the previous EnableAutoUpdate value and kind, every
    *Zoom* webcam consent entry and its Value, the names of the user's real Zoom data
    files) and Restore writes that back. The user's real Zoom settings, SQLite
    databases and sign-in tokens are never the target of a break.

    Two things are not confined to the prefix. Step 1's resolution deletes EVERY
    top-level file in %APPDATA%\Zoom\logs and every file under data\cache -- that is
    the remediation under test; Zoom recreates both (on the lab host neither folder
    exists until the harness creates it, and Restore removes what it created). And the
    webcam fixture has to be the key Windows itself would create for the detected
    binary, NonPackaged\C:#Program Files#Zoom#bin#Zoom.exe, because step 5 matches
    '*Zoom*' and writes Allow into whatever matches; Capture records that key's prior
    state and every other *Zoom* entry's Value, and Restore puts each back.

    EXCLUSIVITY
    $env:AllowDestructiveActions is one value for the whole child, so gated (flag unset)
    and ungated (flag 'true') breaks cannot share a run; nor can two breaks that need
    different CacheSizeWarningMB values or the same fixture (the webcam entry; the logs
    folder, which step 1 wipes before step 4 reads it). The first drawn decides, the
    rest are dropped and named in the output. Variables are set immediately before the
    child powershell.exe starts and put back afterwards.

    EXPECTED OUTCOMES (derived from the script's own messages, 1.0.2)
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    CacheBloat                 ExpectFixed. 5 x 16MB DEXTest_bloat_* files under data\cache
                               and/or logs (log fixtures are .txt aged 30 days, so step 4
                               never reads one), CacheSizeWarningMB=64. Apply aborts if
                               Zoom.exe runs (step 1 refuses; the harness never kills Zoom).
                               Validate: fixtures gone; Step01_ZoomCacheLogBloat reads
                               "[Remediated] Zoom data/logs total <n>MB (threshold: 64MB).
                               Will clear log files and cache subdirectory if Zoom is not
                               running."
    UpdaterAutoUpdateDisabled  ExpectReportedOnly. EnableAutoUpdate=0 (DWORD) under
                               HKLM:\SOFTWARE\Zoom\ZoomUpdate -- machine-wide and
                               prefix-less by necessity, the only registry input step 2
                               reads; Capture keeps the old value and kind or the key's
                               absence. Validate: still 0; Step02_ZoomUpdaterVersionHealth
                               reads "[Warning] Installed version: <v>. Updater issue(s):
                               ZoomUpdate\EnableAutoUpdate=0 (auto-update disabled via
                               registry policy). Review via MDM deployment policy." (the
                               pattern tolerates the doubled backslash 1.0.2 prints).
    OutlookAddinCrashDisabled  ExpectReportedOnly. DEXTest.ZoomLabAddin, LoadBehavior 2,
                               under HKU\<SID>\Software\Microsoft\Office\Outlook\Addins.
                               Validate: still 2; Step03_OutlookAddinConflict reads
                               "[Warning] Zoom Outlook add-in was auto-disabled by Office
                               crash protection: ... DEXTest.ZoomLabAddin (User): Disabled
                               by crash protection ...".
    SsoTokenCacheGated         ExpectReportedOnly, flag unset. logs\DEXTest_signin.log with
                               exactly 3 lines matching the step 4 regex, stamped one hour
                               in the future so it is the newest *.log;
                               CacheSizeWarningMB=1048576 so step 1 cannot wipe it first.
                               Validate: fixture and every real data file still present;
                               Step04_SigninSSOTokenCache reads "[Warning] 3 sign-in/auth
                               failure pattern(s) found in Zoom log (last 500 lines of
                               DEXTest_signin.log). Set $AllowDestructiveActions=$true to
                               clear auth cache."
    WebcamDeniedGated          ExpectReportedOnly, flag unset. Value=Deny on the Zoom
                               NonPackaged entry. Validate: still Deny;
                               Step05_CameraWebcamPermission reads "[Warning] Webcam access
                               is denied for Zoom: <key>. Set $AllowDestructiveActions=$true
                               to grant access."
    WebcamDenied               ExpectFixed, flag 'true'. Same plant; Apply aborts when the
                               user's newest real Zoom log matches the step 4 regex (with
                               the flag set, step 4 would delete real auth/token files).
                               Validate: Value is Allow; record reads "[Remediated] Webcam
                               access is denied for Zoom: <key>."

    NOT COVERED
      Step 1 'Zoom is running' refusal -- needs the user's Zoom open.
      Step 2 'Zoom Automatic Updater task is Disabled' -- the lab host has no such task.
      Step 4 ungated -- the resolution deletes every data file matching
             auth|token|login|sso|credential, the user's real sign-in state. By design.
      Step 5 'globally denied' -- the user's global camera consent is not a Zoom fixture.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the fault is genuinely in place. The
    probes read the registry and file system directly, independent of the script's
    install detection, so a script that exits "not installed" shows up as a Validate
    failure (no fresh DEXRecords), never as a false green. A break that cannot be
    verified aborts the run as BreakFailed. No break requires a reboot; the reboot
    plumbing is kept so the harness stays uniform with the rest of the family.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateZoom.ps1 and validate the outcome.
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
    Script Name  : Invoke-AutoRemediateZoom_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateZoom\

    1.0.0  Initial: CacheBloat, UpdaterAutoUpdateDisabled, OutlookAddinCrashDisabled,
           SsoTokenCacheGated, WebcamDeniedGated, WebcamDenied. Written against script
           1.0.2 (install detection fixed for a Program Files install without App Paths).

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

$ScriptUnderTest   = 'Invoke-AutoRemediateZoom'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateZoom.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ZoomErrors'
$ZoomUpdatePath    = 'HKLM:\SOFTWARE\Zoom\ZoomUpdate'
$ZoomRootPath      = 'HKLM:\SOFTWARE\Zoom'
$SelfPath          = $MyInvocation.MyCommand.Path

# _AutomatedTesting -> Zoom -> ApplicationSpecific -> repo root.
$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

if (-not (Test-Path -LiteralPath $RemediationScript)) {
    throw "Script under test not found at $RemediationScript"
}

# -- Fixture ------------------------------------------------------------------
# Everything planted on disk or in the registry is named with this prefix (webcam
# entry excepted, see header) and is the only thing the sweep in Remove-Fixture touches.
$FixturePrefix             = 'DEXTest'
$FixtureBloatStem          = 'DEXTest_bloat'      # CacheBloat files: <stem>_NN.bin / .txt
$FixtureCacheThresholdMB   = 64                   # CacheSizeWarningMB handed to CacheBloat runs (default 500)
$FixtureCacheFileCount     = 5
$FixtureCacheFileMB        = 16                   # 5 x 16MB = 80MB per folder, above the threshold on its own
$FixtureBloatAgeDays       = 30                   # planted log files are aged so they never become step 4's "latest log"
$FixtureSsoLogName         = 'DEXTest_signin.log' # step 4 reads the newest *.log; this one is stamped in the future
$FixtureSsoMatchCount      = 3                    # lines in the fixture log that match the step 4 regex
$FixtureSsoThresholdMB     = 1048576              # CacheSizeWarningMB for SSO runs: step 1 must never clear the logs first
$FixtureAddinName          = 'DEXTest.ZoomLabAddin'   # must match the script's '*Zoom*' filter
$FixtureAddinLoadBehavior  = 2                    # the one LoadBehavior step 3 warns on ("Disabled by crash protection")
$WebcamKeyRelative         = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'

# Same regex as step 4's DetectionScript, verbatim, so "auth failure" means the same thing here.
$SsoFailurePattern = 'sign.?in.fail|SSO.error|token.expir|auth.fail|login.fail|401|SAML.error|sso_token'

function Initialize-Fixture {
    $exe = Get-ZoomExecutable
    if (-not $exe) { throw 'Zoom.exe was not found in App Paths (HKLM or the user hive), Program Files or the per-user bin folder; Invoke-AutoRemediateZoom.ps1 would exit 0 as Skipped.' }

    # Both throw when nobody is logged on -- the script would then skip every per-user step.
    $user = Get-LoggedOnUser
    $sid  = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
        throw "Hive for $user ($sid) is not loaded under HKEY_USERS; the script's add-in and webcam checks would not see it."
    }

    $realLog = Get-NewestZoomLog -RealOnly
    $realLogNote = if ($realLog) { "$($realLog.Name) ($($realLog.LastWriteTime.ToString('s')))" } else { 'none' }
    $webcam = @(Get-ZoomWebcamEntries)
    $webcamNote = if ($webcam.Count -gt 0) { ($webcam | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ' } else { 'none' }
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Zoom $((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion) at $exe; user $user; data+logs $(Get-ZoomCacheSizeMB)MB; real data files: $(@(Get-RealZoomDataFiles).Count); newest real log: $realLogNote; EnableAutoUpdate '$((Get-ZoomUpdateBaseline).Value)'; global webcam '$(Get-WebcamGlobalValue)'; Zoom webcam entries: $webcamNote; Zoom running: $(Test-ZoomRunning)"
}

function Remove-Fixture {
    # Sweep by prefix. The per-break Restore blocks have normally done all of this already;
    # this catches anything a half-finished run left behind.
    try { foreach ($f in @(Get-FixtureFiles)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } } catch { }
    try {
        $key = Get-FixtureAddinKeyPath
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
}

# -- Helpers: user, paths, process ------------------------------------------------

function Get-LoggedOnUser {
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $u) { throw 'No interactive user is logged on; Invoke-AutoRemediateZoom.ps1 resolves its user from Win32_ComputerSystem.UserName.' }
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

function Get-ZoomExecutable {
    # Same resolution order as the script (1.0.2): HKLM App Paths, the user's App Paths,
    # Program Files, Program Files (x86), the per-user bin folder.
    $appPath = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe' -ErrorAction SilentlyContinue
    if ($appPath -and $appPath.'(default)' -and (Test-Path -LiteralPath $appPath.'(default)')) { return $appPath.'(default)' }
    $userAppPath = Get-ItemProperty "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)\Software\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe" -ErrorAction SilentlyContinue
    if ($userAppPath -and $userAppPath.'(default)' -and (Test-Path -LiteralPath $userAppPath.'(default)')) { return $userAppPath.'(default)' }
    foreach ($candidate in @(
        "$env:ProgramFiles\Zoom\bin\Zoom.exe",
        "${env:ProgramFiles(x86)}\Zoom\bin\Zoom.exe",
        (Join-Path (Get-UserProfilePath) 'AppData\Roaming\Zoom\bin\Zoom.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-ZoomRoamingPath { Join-Path (Get-UserProfilePath) 'AppData\Roaming\Zoom' }
function Get-ZoomDataPath    { Join-Path (Get-ZoomRoamingPath) 'data' }
function Get-ZoomCachePath   { Join-Path (Get-ZoomDataPath) 'cache' }
function Get-ZoomLogsPath    { Join-Path (Get-ZoomRoamingPath) 'logs' }

function Test-ZoomRunning {
    [bool](Get-Process -Name 'Zoom' -ErrorAction SilentlyContinue)
}

function Get-MissingDirectories {
    # Parent-first list of the directories that do not exist yet, so Restore removes exactly
    # what the break had to create and nothing Zoom itself made. Plain array; callers wrap in @().
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    $missing = @()
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { $missing += $p }
    }
    return @($missing)
}

function Remove-MissingDirectories {
    # Deepest first; a directory is removed only if it is now empty, so a folder Zoom
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

# -- Helpers: step 1 cache / log bloat ---------------------------------------------

function New-FixtureFile {
    # SetLength allocates without writing, so an 80MB fixture costs milliseconds while
    # FileInfo.Length (what the script measures) reports the full size.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$SizeMB,
        [int]$AgeDays = 0
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $fs = [System.IO.File]::Create($Path)
    try { $fs.SetLength([int64]$SizeMB * 1MB) } finally { $fs.Dispose() }
    if ($AgeDays -gt 0) {
        $stamp = (Get-Date).AddDays(-$AgeDays)
        $item  = Get-Item -LiteralPath $Path
        $item.CreationTime = $stamp; $item.LastWriteTime = $stamp; $item.LastAccessTime = $stamp
    }
}

function Get-ZoomCacheSizeMB {
    # Same arithmetic as step 1's DetectionScript: data and logs, recursive, rounded per folder.
    $totalMB = 0
    foreach ($dir in @((Get-ZoomDataPath), (Get-ZoomLogsPath))) {
        if (Test-Path -LiteralPath $dir) {
            $sum = (Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            $totalMB += [math]::Round($sum / 1MB, 0)
        }
    }
    return $totalMB
}

function Add-FixtureBloatFiles {
    # 'cache' plants .bin files under data\cache; 'logs' plants aged .txt files at the top of logs.
    # Neither ends in .log, so step 4 never picks one as the newest log.
    param([Parameter(Mandatory = $true)][string[]]$Targets)
    foreach ($t in $Targets) {
        for ($i = 1; $i -le $FixtureCacheFileCount; $i++) {
            if ($t -eq 'cache') {
                New-FixtureFile -Path (Join-Path (Get-ZoomCachePath) ('{0}_{1:D2}.bin' -f $FixtureBloatStem, $i)) -SizeMB $FixtureCacheFileMB
            } else {
                New-FixtureFile -Path (Join-Path (Get-ZoomLogsPath) ('{0}_{1:D2}.txt' -f $FixtureBloatStem, $i)) -SizeMB $FixtureCacheFileMB -AgeDays $FixtureBloatAgeDays
            }
        }
    }
}

function Get-FixtureFiles {
    # Every DEXTest* file under data\cache (recursive) and logs (top level). Plain array.
    $files = @()
    $cache = Get-ZoomCachePath
    if (Test-Path -LiteralPath $cache) { $files += @(Get-ChildItem -LiteralPath $cache -Recurse -File -Filter "$FixturePrefix*" -ErrorAction SilentlyContinue) }
    $logs  = Get-ZoomLogsPath
    if (Test-Path -LiteralPath $logs)  { $files += @(Get-ChildItem -LiteralPath $logs -File -Filter "$FixturePrefix*" -ErrorAction SilentlyContinue) }
    return @($files)
}

function Get-FixtureBloatFiles {
    return @(Get-FixtureFiles | Where-Object { $_.Name -like "${FixtureBloatStem}_*" })
}

# -- Helpers: step 4 sign-in log and real data ----------------------------------------

function Get-FixtureSsoLogPath { Join-Path (Get-ZoomLogsPath) $FixtureSsoLogName }

function Get-RealZoomDataFiles {
    # The user's own files at the top of data (what step 4's resolution would filter). Plain array.
    $dir = Get-ZoomDataPath
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "$FixturePrefix*" })
}

function Get-NewestZoomLog {
    # Step 4's selection (newest *.log), or with -RealOnly the one it would pick had the
    # harness planted nothing. $null when there is none.
    param([switch]$RealOnly)
    $dir = Get-ZoomLogsPath
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    return Get-ChildItem -LiteralPath $dir -Filter '*.log' -File -ErrorAction SilentlyContinue |
           Where-Object { -not $RealOnly -or $_.Name -notlike "$FixturePrefix*" } |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-LogAuthMatchCount {
    # Step 4's count for one log file: matching lines among the last 500.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $lines = Get-Content -LiteralPath $Path -Tail 500 -ErrorAction SilentlyContinue
    return @($lines | Where-Object { $_ -match $SsoFailurePattern }).Count
}

function Add-FixtureSsoLog {
    $path = Get-FixtureSsoLogPath
    $dir  = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    # Exactly three lines match the step 4 regex: sso_token, sign-in fail, SSO error.
    # Nothing else in the file may contain 401, auth/login fail, token expir or SAML error.
    $lines = @(
        "$stamp [INFO]  DEXTest fixture log planted by Invoke-AutoRemediateZoom_BreakTest.ps1; safe to delete."
        "$stamp [INFO]  DEXTest heartbeat ok"
        "$stamp [ERROR] DEXTest sso_token refresh rejected by identity provider"
        "$stamp [ERROR] DEXTest sign-in failed: assertion rejected"
        "$stamp [WARN]  DEXTest SSO error while redirecting to the identity provider"
        "$stamp [INFO]  DEXTest end of fixture"
    )
    Set-Content -LiteralPath $path -Value $lines -Encoding ASCII -ErrorAction Stop
    # Newest *.log by a margin Zoom cannot beat while the run lasts.
    $future = (Get-Date).AddHours(1)
    $item   = Get-Item -LiteralPath $path
    $item.LastWriteTime = $future; $item.CreationTime = $future
}

function Test-RealLogHasAuthPattern {
    # True when the user's newest real log would make step 4 Warning on its own.
    $log = Get-NewestZoomLog -RealOnly
    if (-not $log) { return $false }
    return ((Get-LogAuthMatchCount -Path $log.FullName) -gt 0)
}

# -- Helpers: step 2 updater policy -------------------------------------------------

function Get-ZoomUpdateBaseline {
    # @{ RootExisted; KeyExisted; HadValue; Value; Kind } for EnableAutoUpdate.
    $r = @{ RootExisted = (Test-Path -LiteralPath $ZoomRootPath); KeyExisted = (Test-Path -LiteralPath $ZoomUpdatePath); HadValue = $false; Value = $null; Kind = $null }
    if ($r.KeyExisted) {
        $key = Get-Item -LiteralPath $ZoomUpdatePath -ErrorAction SilentlyContinue
        if ($key -and (@($key.GetValueNames()) -contains 'EnableAutoUpdate')) {
            $r.HadValue = $true
            $r.Value    = $key.GetValue('EnableAutoUpdate')
            $r.Kind     = "$($key.GetValueKind('EnableAutoUpdate'))"
        }
    }
    return $r
}

function Get-EnableAutoUpdate {
    if (-not (Test-Path -LiteralPath $ZoomUpdatePath)) { return $null }
    $v = Get-ItemProperty -LiteralPath $ZoomUpdatePath -ErrorAction SilentlyContinue
    if ($v -and $v.PSObject.Properties['EnableAutoUpdate']) { return $v.EnableAutoUpdate }
    return $null
}

function Restore-ZoomUpdateBaseline {
    param($Original)
    if (Test-Path -LiteralPath $ZoomUpdatePath) {
        if ([bool]$Original.HadValue) {
            $kind = if ($Original.Kind) { "$($Original.Kind)" } else { 'DWord' }
            Set-ItemProperty -LiteralPath $ZoomUpdatePath -Name 'EnableAutoUpdate' -Value $Original.Value -Type $kind -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -LiteralPath $ZoomUpdatePath -Name 'EnableAutoUpdate' -ErrorAction SilentlyContinue
        }
    }
    # Keys the break created are removed only if nothing else has moved in.
    foreach ($pair in @(@{ Path = $ZoomUpdatePath; Existed = [bool]$Original.KeyExisted }, @{ Path = $ZoomRootPath; Existed = [bool]$Original.RootExisted })) {
        if ($pair.Existed -or -not (Test-Path -LiteralPath $pair.Path)) { continue }
        $item = Get-Item -LiteralPath $pair.Path -ErrorAction SilentlyContinue
        if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) {
            Remove-Item -LiteralPath $pair.Path -Force -ErrorAction SilentlyContinue
        }
    }
}

# -- Helpers: step 3 Outlook add-in ---------------------------------------------------

function Get-UserAddinsKeyPath {
    "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)\Software\Microsoft\Office\Outlook\Addins"
}

function Get-FixtureAddinKeyPath { Join-Path (Get-UserAddinsKeyPath) $FixtureAddinName }

function Get-FixtureAddinLoadBehavior {
    $key = Get-FixtureAddinKeyPath
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    $v = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if ($v -and $v.PSObject.Properties['LoadBehavior']) { return [int]$v.LoadBehavior }
    return $null
}

function Add-FixtureAddin {
    $addins = Get-UserAddinsKeyPath
    if (-not (Test-Path -LiteralPath $addins)) { New-Item -Path $addins -Force -ErrorAction Stop | Out-Null }
    $key = Join-Path $addins $FixtureAddinName
    New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    # LoadBehavior is the only value the script reads; FriendlyName and Description are
    # what every real COM add-in registers, so the key looks like one to Outlook's UI.
    Set-ItemProperty -LiteralPath $key -Name 'LoadBehavior' -Value $FixtureAddinLoadBehavior -Type DWord -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'FriendlyName' -Value 'DEX Test Zoom Lab Add-in' -Type String -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'Description'  -Value 'Planted by Invoke-AutoRemediateZoom_BreakTest.ps1; safe to delete.' -Type String -ErrorAction Stop
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

# -- Helpers: step 5 webcam consent (.NET registry API: the key name holds ':' and '#') ----

function Get-WebcamKeyRelative { "$(Get-LoggedOnUserSid)\$WebcamKeyRelative" }

function Get-WebcamGlobalValue {
    $k = [Microsoft.Win32.Registry]::Users.OpenSubKey((Get-WebcamKeyRelative), $false)
    if (-not $k) { return $null }
    try { return $k.GetValue('Value') } finally { $k.Close() }
}

function Get-FixtureWebcamKeyName {
    # The key Windows (and the script's resolution) would use for the detected binary.
    $exe = Get-ZoomExecutable
    if (-not $exe) { throw 'Zoom.exe could not be resolved; no webcam consent key name to plant.' }
    return ($exe -replace '\\', '#')
}

function Get-ZoomWebcamEntries {
    # @{ Name; Value } for every *Zoom* key under NonPackaged -- the set step 5 acts on. Plain array.
    $np = [Microsoft.Win32.Registry]::Users.OpenSubKey("$(Get-WebcamKeyRelative)\NonPackaged", $false)
    if (-not $np) { return @() }
    try {
        $list = @()
        foreach ($n in @($np.GetSubKeyNames() | Where-Object { $_ -like '*Zoom*' })) {
            $sub = $np.OpenSubKey($n, $false)
            if (-not $sub) { continue }
            try { $list += @{ Name = $n; Value = $sub.GetValue('Value') } } finally { $sub.Close() }
        }
        return @($list)
    } finally { $np.Close() }
}

function Get-ZoomWebcamValue {
    param([Parameter(Mandatory = $true)][string]$KeyName)
    $entry = @(Get-ZoomWebcamEntries | Where-Object { $_.Name -eq $KeyName })
    if ($entry.Count -eq 0) { return $null }
    return $entry[0].Value
}

function Set-ZoomWebcamValue {
    # $null removes the key; otherwise writes Value as a string (what Windows writes).
    param([Parameter(Mandatory = $true)][string]$KeyName, $Value)
    $np = [Microsoft.Win32.Registry]::Users.CreateSubKey("$(Get-WebcamKeyRelative)\NonPackaged")
    try {
        if ($null -eq $Value) { $np.DeleteSubKeyTree($KeyName, $false); return }
        $sub = $np.CreateSubKey($KeyName)
        try { $sub.SetValue('Value', "$Value", [Microsoft.Win32.RegistryValueKind]::String) } finally { $sub.Close() }
    } finally { $np.Close() }
}

function Test-HkuKeyExists {
    param([Parameter(Mandatory = $true)][string]$Relative)
    $k = [Microsoft.Win32.Registry]::Users.OpenSubKey($Relative, $false)
    if (-not $k) { return $false }
    $k.Close(); return $true
}

function Get-WebcamBaseline {
    $name = Get-FixtureWebcamKeyName
    @{
        WebcamKeyExisted   = Test-HkuKeyExists -Relative (Get-WebcamKeyRelative)
        NonPackagedExisted = Test-HkuKeyExists -Relative "$(Get-WebcamKeyRelative)\NonPackaged"
        GlobalValue        = Get-WebcamGlobalValue
        FixtureKeyName     = $name
        FixtureKeyExisted  = ($null -ne (Get-ZoomWebcamValue -KeyName $name))
        ZoomEntries        = @(Get-ZoomWebcamEntries)
        RealDataFileNames  = @(Get-RealZoomDataFiles | ForEach-Object { $_.Name })
    }
}

function Set-FixtureWebcamDeny {
    $global = Get-WebcamGlobalValue
    if ("$global" -eq 'Deny') {
        throw 'Webcam access is globally denied for this user; step 5 reports that first and never reads the per-app entry. Allow camera access in Settings > Privacy > Camera and re-run.'
    }
    Set-ZoomWebcamValue -KeyName (Get-FixtureWebcamKeyName) -Value 'Deny'
}

function Test-FixtureWebcamDenied {
    # The script's own test: a *Zoom* NonPackaged entry with Value Deny, global not Deny.
    $global = Get-WebcamGlobalValue
    if ("$global" -eq 'Deny') { Write-Host '           global webcam consent is Deny; step 5 would report that instead'; return $false }
    $name = Get-FixtureWebcamKeyName
    $v    = Get-ZoomWebcamValue -KeyName $name
    if ("$v" -ne 'Deny') { Write-Host "           $name Value is '$v', expected 'Deny'"; return $false }
    if (-not ($name -like '*Zoom*')) { Write-Host '           fixture key name does not match the script filter'; return $false }
    return $true
}

function Restore-WebcamBaseline {
    param($Original)
    $before = @{}
    foreach ($e in @($Original.ZoomEntries | Where-Object { $_ })) { $before["$($e.Name)"] = $e.Value }
    # Every *Zoom* entry now present: back to its captured Value, or removed if the run created it.
    foreach ($e in @(Get-ZoomWebcamEntries)) {
        if ($before.ContainsKey("$($e.Name)")) { Set-ZoomWebcamValue -KeyName $e.Name -Value $before["$($e.Name)"] }
        else { Set-ZoomWebcamValue -KeyName $e.Name -Value $null }
    }
    # Captured entries the run removed (it should not) come back.
    foreach ($n in @($before.Keys)) {
        if ($null -eq (Get-ZoomWebcamValue -KeyName $n) -and $null -ne $before[$n]) { Set-ZoomWebcamValue -KeyName $n -Value $before[$n] }
    }
    # Parent keys the harness created are removed only if empty.
    $rel = Get-WebcamKeyRelative
    foreach ($pair in @(@{ Path = "$rel\NonPackaged"; Existed = [bool]$Original.NonPackagedExisted }, @{ Path = $rel; Existed = [bool]$Original.WebcamKeyExisted })) {
        if ($pair.Existed) { continue }
        $k = [Microsoft.Win32.Registry]::Users.OpenSubKey($pair.Path, $false)
        if (-not $k) { continue }
        $empty = ($k.SubKeyCount -eq 0 -and $k.ValueCount -eq 0)
        $k.Close()
        if ($empty) { [Microsoft.Win32.Registry]::Users.DeleteSubKey($pair.Path, $false) }
    }
}

function Test-RealDataFilesIntact {
    param($Original)
    $now = @(Get-RealZoomDataFiles | ForEach-Object { $_.Name })
    foreach ($n in @($Original.RealDataFileNames | Where-Object { $_ })) {
        if ($now -notcontains "$n") { Write-Host "           real Zoom data file '$n' is no longer present"; return $false }
    }
    return $true
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
    # The text the script wrote for one step (Step<nn>_<name without punctuation>), or $null.
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix)
    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $null }
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    $name = @($key.GetValueNames() | Where-Object { $_ -like "$ValueNamePrefix*" } | Select-Object -First 1)
    if ($name.Count -eq 0) { return $null }
    return "$($key.GetValue($name[0]))"
}

function Test-DexRecordFresh {
    # True when LastScanTime was written by this run. A script that exits early ("not
    # installed", parse error) leaves the previous run's values, and a stale Step record
    # would otherwise read as a pass. Host-stream diagnostics only.
    if (-not $state.Remediation -or -not $state.Remediation.StartedAt) { Write-Host '           no remediation record'; return $false }
    $raw = Get-DexRecordRaw -Name 'LastScanTime'
    if (-not $raw) { Write-Host "           no LastScanTime under $DexRecordsPath (did the script exit before its steps ran?)"; return $false }
    try {
        $scan  = [datetime]::ParseExact($raw, 'yyyy-MM-dd HH:mm:ss', $null)
        $start = ([datetime]$state.Remediation.StartedAt).AddMinutes(-1)
        if ($scan -lt $start) { Write-Host "           LastScanTime '$raw' predates this run ($($state.Remediation.StartedAt)); stale records"; return $false }
    } catch { Write-Host "           LastScanTime '$raw' is unreadable: $($_.Exception.Message)"; return $false }
    return $true
}

function Test-DexRecordMatches {
    # Host-stream diagnostics only; callers are [bool]-cast. Also requires the record to be fresh.
    param(
        [Parameter(Mandatory = $true)][string]$ValueNamePrefix,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    if (-not (Test-DexRecordFresh)) { return $false }
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
    # Every variable the child must see; $null removes one. ExtraEnv is a hashtable
    # in-process and a PSCustomObject after a JSON round-trip (Resume), hence the normalisation.
    $vars = @{
        AllowDestructiveActions = if ([bool]$state.DestructiveFlag) { 'true' } else { $null }
        CacheSizeWarningMB      = $null
    }
    $extra = ConvertTo-DexHashtable -InputObject $state.ExtraEnv
    if ($extra) { foreach ($k in @($extra.Keys)) { $vars[$k] = "$($extra[$k])" } }
    return $vars
}

function Invoke-RemediationScript {
    # Runs the script under test once and returns @{ ExitCode; DurationSec; StartedAt; Variables;
    # Output }, writing nothing to the output stream. The child inherits this process's
    # environment, so the variables are set here and put back afterwards (null removes one).
    # Stderr is captured as text under a temporary 'Continue': under 'Stop' the child's first
    # stderr line redirected with 2>&1 would become a terminating NativeCommandError.
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
# DestructiveFlag: $true  -- the run must set $env:AllowDestructiveActions = 'true'
#                  $false -- the run must leave it unset
#                  $null  -- either
# Env: variables the child powershell.exe must see for this break; two breaks that
#      need different values for the same variable cannot share a run.
# Fixture: breaks sharing a fixture cannot share a run.
$BreakCatalog = @(

    @{
        Name            = 'CacheBloat'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $null
        Env             = @{ CacheSizeWarningMB = "$FixtureCacheThresholdMB" }
        Fixture         = 'ZoomLogs'
        Methods         = @(
            @{ Name = 'PlantDataCacheFiles'; Apply = { Assert-ZoomClosed; Add-FixtureBloatFiles -Targets @('cache') } },
            @{ Name = 'PlantLogFiles';       Apply = { Assert-ZoomClosed; Add-FixtureBloatFiles -Targets @('logs') } },
            @{ Name = 'PlantBothFolders';    Apply = { Assert-ZoomClosed; Add-FixtureBloatFiles -Targets @('cache', 'logs') } }
        )
        Capture  = {
            @{
                MissingDirs = @(Get-MissingDirectories -Paths @((Get-ZoomRoamingPath), (Get-ZoomDataPath), (Get-ZoomCachePath), (Get-ZoomLogsPath)))
                CacheSizeMB = Get-ZoomCacheSizeMB
            }
        }
        # Broken means the script's own measurement is at or over the threshold it will be given.
        Verify   = {
            $count = @(Get-FixtureBloatFiles).Count
            $sizeMB = Get-ZoomCacheSizeMB
            if ($count -eq 0) { Write-Host '           no bloat fixture files found'; return $false }
            if ($sizeMB -lt $FixtureCacheThresholdMB) { Write-Host "           data+logs measure ${sizeMB}MB, below the ${FixtureCacheThresholdMB}MB threshold"; return $false }
            if (Test-ZoomRunning) { Write-Host '           Zoom.exe is running; the resolution would refuse'; return $false }
            $true
        }
        # Step 1 clears every top-level file in logs and every file under data\cache; ours must be gone.
        Validate = {
            $left = @(Get-FixtureBloatFiles)
            if ($left.Count -gt 0) { Write-Host "           $($left.Count) bloat fixture file(s) still present: $(($left | Select-Object -First 3).Name -join ', ')" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step01_' -Pattern "^\[Remediated\] Zoom data/logs total \d+MB \(threshold: ${FixtureCacheThresholdMB}MB\)\. Will clear log files and cache subdirectory if Zoom is not running\.$"
            $exitOk = (Test-RemediationExitCode -Expected 0) -or (Test-OtherStepFailed -ExceptPrefix 'Step01_')
            ($left.Count -eq 0) -and $reported -and $exitOk
        }
        Restore  = {
            param($Original)
            foreach ($f in @(Get-FixtureBloatFiles)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
            Remove-MissingDirectories -Paths @($Original.MissingDirs)
        }
    },

    @{
        Name            = 'UpdaterAutoUpdateDisabled'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $null
        Env             = @{}
        Fixture         = 'ZoomUpdate'
        Methods         = @(
            @{
                Name  = 'SetEnableAutoUpdateZero'
                Apply = {
                    if (-not (Test-Path -LiteralPath $ZoomUpdatePath)) { New-Item -Path $ZoomUpdatePath -Force -ErrorAction Stop | Out-Null }
                    Set-ItemProperty -LiteralPath $ZoomUpdatePath -Name 'EnableAutoUpdate' -Value 0 -Type DWord -ErrorAction Stop
                }
            }
        )
        Capture  = { Get-ZoomUpdateBaseline }
        Verify   = {
            $v = Get-EnableAutoUpdate
            if ($v -ne 0) { Write-Host "           EnableAutoUpdate is '$v', expected 0"; return $false }
            $true
        }
        # Step 2: "Installed version: <v>. Updater issue(s): ZoomUpdate\EnableAutoUpdate=0 (auto-update
        # disabled via registry policy). Review via MDM deployment policy." 1.0.2 prints the backslash
        # doubled (a literal '\\' inside a double-quoted string); the pattern accepts one or two.
        Validate = {
            $still = ((Get-EnableAutoUpdate) -eq 0)
            if (-not $still) { Write-Host '           EnableAutoUpdate changed during the run (step 2 has no resolution)' }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step02_' -Pattern '^\[Warning\] Installed version: .+\. Updater issue\(s\): .*ZoomUpdate\\{1,2}EnableAutoUpdate=0 \(auto-update disabled via registry policy\).*\. Review via MDM deployment policy\.$'
            $exitOk = (Test-RemediationExitCode -Expected 0) -or (Test-OtherStepFailed -ExceptPrefix 'Step02_')
            $still -and $reported -and $exitOk
        }
        Restore  = {
            param($Original)
            Restore-ZoomUpdateBaseline -Original $Original
        }
    },

    @{
        Name            = 'OutlookAddinCrashDisabled'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $null
        Env             = @{}
        Fixture         = 'OutlookAddin'
        Methods         = @(
            @{ Name = 'PlantUserAddinLoadBehavior2'; Apply = { Add-FixtureAddin } }
        )
        Capture  = { @{ AddinsKeyExisted = (Test-Path -LiteralPath (Get-UserAddinsKeyPath)) } }
        # The script's own test: a '*Zoom*' key under the user's Outlook\Addins with LoadBehavior 2.
        Verify   = {
            $lb = Get-FixtureAddinLoadBehavior
            if ($lb -ne $FixtureAddinLoadBehavior) { Write-Host "           $FixtureAddinName LoadBehavior is '$lb', expected $FixtureAddinLoadBehavior"; return $false }
            if (-not ($FixtureAddinName -like '*Zoom*')) { Write-Host '           fixture name does not match the script filter'; return $false }
            $true
        }
        # Step 3: "Zoom Outlook add-in was auto-disabled by Office crash protection: <name> (User): Disabled
        # by crash protection[; ...]. If Outlook stability issues recur, consider disabling the add-in via MDM policy."
        Validate = {
            $lb    = Get-FixtureAddinLoadBehavior
            $still = ($lb -eq $FixtureAddinLoadBehavior)
            if (-not $still) { Write-Host "           $FixtureAddinName LoadBehavior is '$lb' after the run; expected $FixtureAddinLoadBehavior (step 3 has no resolution)" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step03_' -Pattern "^\[Warning\] Zoom Outlook add-in was auto-disabled by Office crash protection: .*$([regex]::Escape($FixtureAddinName)) \(User\): Disabled by crash protection.*\. If Outlook stability issues recur, consider disabling the add-in via MDM policy\.$"
            $exitOk = (Test-RemediationExitCode -Expected 0) -or (Test-OtherStepFailed -ExceptPrefix 'Step03_')
            $still -and $reported -and $exitOk
        }
        Restore  = {
            param($Original)
            Restore-FixtureAddin -Original $Original
        }
    },

    @{
        Name            = 'SsoTokenCacheGated'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $false
        Env             = @{ CacheSizeWarningMB = "$FixtureSsoThresholdMB" }
        Fixture         = 'ZoomLogs'
        Methods         = @(
            @{ Name = 'PlantNewestLogWithAuthFailures'; Apply = { Add-FixtureSsoLog } }
        )
        Capture  = {
            @{
                MissingDirs       = @(Get-MissingDirectories -Paths @((Get-ZoomRoamingPath), (Get-ZoomLogsPath)))
                RealDataFileNames = @(Get-RealZoomDataFiles | ForEach-Object { $_.Name })
            }
        }
        # Broken means step 4's own selection lands on the fixture and its own count is 3.
        Verify   = {
            $newest = Get-NewestZoomLog
            if (-not $newest -or $newest.Name -ne $FixtureSsoLogName) { Write-Host "           newest *.log is '$(if ($newest) { $newest.Name } else { 'none' })', expected $FixtureSsoLogName"; return $false }
            $n = Get-LogAuthMatchCount -Path $newest.FullName
            if ($n -ne $FixtureSsoMatchCount) { Write-Host "           fixture log matches $n line(s), expected $FixtureSsoMatchCount"; return $false }
            $true
        }
        # Step 4 gated: "<n> sign-in/auth failure pattern(s) found in Zoom log (last 500 lines of <name>).
        # Set $AllowDestructiveActions=$true to clear auth cache." Nothing in data may be touched.
        Validate = {
            param($Original)
            $still = Test-Path -LiteralPath (Get-FixtureSsoLogPath)
            if (-not $still) { Write-Host '           fixture log is gone after a gated run' }
            $dataOk   = Test-RealDataFilesIntact -Original $Original
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step04_' -Pattern "^\[Warning\] $FixtureSsoMatchCount sign-in/auth failure pattern\(s\) found in Zoom log \(last 500 lines of $([regex]::Escape($FixtureSsoLogName))\)\. Set \`$AllowDestructiveActions=\`$true to clear auth cache\.$"
            $exitOk = (Test-RemediationExitCode -Expected 0) -or (Test-OtherStepFailed -ExceptPrefix 'Step04_')
            $still -and $dataOk -and $reported -and $exitOk
        }
        Restore  = {
            param($Original)
            $p = Get-FixtureSsoLogPath
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
            Remove-MissingDirectories -Paths @($Original.MissingDirs)
        }
    },

    @{
        Name            = 'WebcamDeniedGated'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $false
        Env             = @{}
        Fixture         = 'Webcam'
        Methods         = @(
            @{ Name = 'SetZoomConsentDeny'; Apply = { Set-FixtureWebcamDeny } }
        )
        Capture  = { Get-WebcamBaseline }
        Verify   = { Test-FixtureWebcamDenied }
        # Step 5 gated: "Webcam access is denied for Zoom: <key>. Set $AllowDestructiveActions=$true to grant access."
        Validate = {
            param($Original)
            $name  = "$($Original.FixtureKeyName)"
            $v     = Get-ZoomWebcamValue -KeyName $name
            $still = ("$v" -eq 'Deny')
            if (-not $still) { Write-Host "           $name Value is '$v' after a gated run; expected 'Deny'" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step05_' -Pattern "^\[Warning\] Webcam access is denied for Zoom: .*$([regex]::Escape($name)).*\. Set \`$AllowDestructiveActions=\`$true to grant access\.$"
            $exitOk = (Test-RemediationExitCode -Expected 0) -or (Test-OtherStepFailed -ExceptPrefix 'Step05_')
            $still -and $reported -and $exitOk
        }
        Restore  = {
            param($Original)
            Restore-WebcamBaseline -Original $Original
        }
    },

    @{
        Name            = 'WebcamDenied'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $true
        Env             = @{}
        Fixture         = 'Webcam'
        Methods         = @(
            @{
                Name  = 'SetZoomConsentDeny'
                Apply = {
                    # With the flag set, step 4 deletes the user's real auth/token files whenever the
                    # newest real log matches its regex. This harness will not let that happen.
                    if (Test-RealLogHasAuthPattern) {
                        throw "The user's newest real Zoom log ($((Get-NewestZoomLog -RealOnly).Name)) matches the step 4 auth-failure regex; an ungated run would delete real sign-in files from $(Get-ZoomDataPath). Run WebcamDeniedGated instead."
                    }
                    Set-FixtureWebcamDeny
                }
            }
        )
        Capture  = { Get-WebcamBaseline }
        Verify   = { Test-FixtureWebcamDenied }
        # Step 5 ungated: the record is tagged [Remediated] (no "Set $AllowDestructiveActions" suffix),
        # the entry reads Allow, and nothing in data was touched.
        Validate = {
            param($Original)
            $name    = "$($Original.FixtureKeyName)"
            $v       = Get-ZoomWebcamValue -KeyName $name
            $allowed = ("$v" -eq 'Allow')
            if (-not $allowed) { Write-Host "           $name Value is '$v' after the run; expected 'Allow'" }
            $dataOk   = Test-RealDataFilesIntact -Original $Original
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step05_' -Pattern "^\[Remediated\] Webcam access is denied for Zoom: .*$([regex]::Escape($name)).*\.$"
            $exitOk = (Test-RemediationExitCode -Expected 0) -or (Test-OtherStepFailed -ExceptPrefix 'Step05_')
            $allowed -and $dataOk -and $reported -and $exitOk
        }
        Restore  = {
            param($Original)
            Restore-WebcamBaseline -Original $Original
        }
    }
)

function Assert-ZoomClosed {
    if (Test-ZoomRunning) {
        throw 'Zoom.exe is running. Step 1 refuses to clear logs and cache while Zoom runs and this harness does not kill a user''s Zoom: close Zoom and re-run.'
    }
}

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

Write-DexBanner -Title "Invoke-AutoRemediateZoom_BreakTest" -Detail "Environment: $Environment"

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
            @($BreakCatalog | Where-Object { $BreakName -contains $_.Name })
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

        # Breaks that share a fixture (the webcam entry; the logs folder, which step 1 wipes
        # before step 4 reads it) or need different values of the same variable: first drawn wins.
        $kept  = @()
        $extra = @{}
        $seenFixtures = @{}
        foreach ($def in $selected) {
            $reason = $null
            if ($def.Fixture -and $seenFixtures.ContainsKey($def.Fixture)) { $reason = "shares fixture '$($def.Fixture)' with $($seenFixtures[$def.Fixture])" }
            if (-not $reason -and $def.Env) {
                foreach ($k in @($def.Env.Keys)) {
                    if ($extra.ContainsKey($k) -and ("$($extra[$k])" -ne "$($def.Env[$k])")) { $reason = "needs $k='$($def.Env[$k])' but the run already has '$($extra[$k])'"; break }
                }
            }
            if ($reason) {
                Write-DexStep -Status 'Info' -Name 'Selection' -Message "dropped $($def.Name): $reason"
                continue
            }
            if ($def.Fixture) { $seenFixtures[$def.Fixture] = $def.Name }
            if ($def.Env) { foreach ($k in @($def.Env.Keys)) { $extra[$k] = "$($def.Env[$k])" } }
            $kept += $def
        }
        $selected = @($kept)
        $state.ExtraEnv = $extra
        if ($selected.Count -eq 0) { throw 'Every selected break was dropped by the exclusivity rules.' }

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
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message ("invoking $([System.IO.Path]::GetFileName($RemediationScript)) with " + (($vars.Keys | Sort-Object | ForEach-Object { "$_=$(if ($null -eq $vars[$_]) { '<unset>' } else { "'$($vars[$_])'" })" }) -join ' '))

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
