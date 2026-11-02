<#
.SYNOPSIS
    Invoke-AutoRemediateProfileBloat_BreakTest -- deliberately bloats a throw-away
    local user profile with aged cache data, then verifies
    Invoke-AutoRemediateProfileBloat.ps1 trims what it promises to and reports
    what it promises to leave alone.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateProfileBloat\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It creates a disabled local account
    (DEXTestBloat) with a real on-disk profile, fills that profile's cache folders
    with hundreds of megabytes of aged fixture files, pads its registry hive, and
    deletes the whole profile and account when the run ends. The remediation it
    invokes processes EVERY non-special profile on the host, so aged cache files in
    the real signed-in user's Temp, browser, Teams, WER and Recent folders are also
    deleted by a -RemediationTest run; the script under test has no profile-scope
    parameter the harness could use to confine it. Run it only on a disposable VM
    or a marked test host. See Assert-DexTestHost in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Steps 8 and 9 of Invoke-AutoRemediateProfileBloat.ps1 have
    ResolutionScript = $null by design, so breaking them must NOT expect a repair.
    Each break declares which it is:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    Every ExpectFixed break also plants a fresh (un-aged) control file beside the
    aged bloat. The script promises to delete aged cache files only, so Validate
    requires the aged files gone AND the control file still present.

    REPORTED-ONLY VALIDATION
    The script under test records run summaries (LastRun, Warnings, ...) under
    HKLM:\Software\AirWatch\Extensions\ProfileBloat\Remediation rather than
    per-step DEXRecords values. A report-only break is therefore validated by the
    Warnings counter of a run that started after this test did, plus the step's own
    "[Warning] <step name>:" line in the captured remediation output.

    REBOOTS
    None of the breaks in this catalog needs a reboot; the fixture profile is never
    loaded, so its files and hive are free to mutate. The reboot plumbing is kept so
    the harness stays uniform with its siblings, and -IncludeRebootBreaks has no
    effect here.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateProfileBloat.ps1 and validate the
    outcome. Without this the script breaks and reports only.

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
    Script Name  : Invoke-AutoRemediateProfileBloat_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateProfileBloat\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateProfileBloat'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateProfileBloat.ps1'
# The script under test writes run summaries here (LastRun, Passed, Warnings, Failed,
# CleanupsRun, CleanupErrors, ReclaimedMB, ProfilesProcessed), not per-step DEXRecords.
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extensions\ProfileBloat\Remediation'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# The script scans every non-special Win32_UserProfile, so the bloat has to live in
# a real profile. A dedicated, disabled local account gets one via the userenv
# CreateProfile API (no logon, no password ever used) and is deleted afterwards.
# Nothing is planted in, or read from, any other user's profile.
$FixtureUserName   = 'DEXTestBloat'
$ControlFileName   = 'DEXTest-control-fresh.bin'
$RequiredFreeBytes = 2GB

# Defaults of the script under test. The harness invokes it with no parameters and
# no environment overrides, so these are the thresholds it will apply.
$ScriptMinFileAgeDays     = 7
$ScriptMinSizeThresholdMB = 50
$ScriptRoamingWarnMB      = 500
$ScriptHiveWarnMB         = 100
$ScriptRecentWarnCount    = 500

# Fixture sizes sit comfortably past each threshold so rounding cannot save the host.
$BloatAgeDays      = 30
$BloatBytes        = 64MB
$RoamingBloatBytes = 520MB
$HiveBloatBytes    = 110MB

# Relative (to the profile root) locations the script's cache rules target.
$RelTemp            = 'AppData\Local\Temp\DEXTest'
$RelChromeCache     = 'AppData\Local\Google\Chrome\User Data\Default\Cache\DEXTest'
$RelEdgeCodeCache   = 'AppData\Local\Microsoft\Edge\User Data\Default\Code Cache\DEXTest'
$RelTeamsClassic    = 'AppData\Roaming\Microsoft\Teams\Cache\DEXTest'
$RelTeamsNew        = 'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache\DEXTest'
$RelExplorerDir     = 'AppData\Local\Microsoft\Windows\Explorer'
$RelCrashDumps      = 'AppData\Local\CrashDumps\DEXTest'
$RelWerQueue        = 'AppData\Local\Microsoft\Windows\WER\ReportQueue\DEXTest'
$RelD3DCache        = 'AppData\Local\D3DSCache\DEXTest'
$RelRdpCache        = 'AppData\Local\Microsoft\Terminal Server Client\Cache\DEXTest'
$RelRecentDir       = 'AppData\Roaming\Microsoft\Windows\Recent'
$RelJumpLists       = 'AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations\DEXTest'
$RelRoamingRoot     = 'AppData\Roaming'
$RelRoamingBloat    = 'AppData\Roaming\DEXTest'
$RelNtUser          = 'NTUSER.DAT'
$RelUsrClass        = 'AppData\Local\Microsoft\Windows\UsrClass.dat'

function Add-DexUserEnvType {
    if ('DexUserEnv' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DexUserEnv
{
    [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int CreateProfile(
        [MarshalAs(UnmanagedType.LPWStr)] string pszUserSid,
        [MarshalAs(UnmanagedType.LPWStr)] string pszUserName,
        [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszProfilePath,
        uint cchProfilePath);
}
'@ -ErrorAction Stop
}

function Get-FixtureProfilePath {
    # Resolved from the account SID every time rather than assumed, because Windows
    # appends a suffix (DEXTestBloat.HOSTNAME) when a stale folder is in the way.
    $user = Get-LocalUser -Name $FixtureUserName -ErrorAction SilentlyContinue
    if (-not $user) { return $null }
    $prof = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($user.SID.Value)'" -ErrorAction SilentlyContinue
    if ($prof -and $prof.LocalPath -and (Test-Path -LiteralPath $prof.LocalPath)) { return $prof.LocalPath }
    return $null
}

function Initialize-Fixture {
    $drive = New-Object System.IO.DriveInfo($env:SystemDrive)
    if ($drive.AvailableFreeSpace -lt $RequiredFreeBytes) {
        throw "Only $([math]::Round($drive.AvailableFreeSpace / 1GB, 1)) GB free on $env:SystemDrive; the fixture needs $($RequiredFreeBytes / 1GB) GB."
    }
    if (-not (Get-Command -Name New-LocalUser -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.PowerShell.LocalAccounts is not available; cannot build the test fixture.'
    }

    $user = Get-LocalUser -Name $FixtureUserName -ErrorAction SilentlyContinue
    if (-not $user) {
        # The password is random, never persisted and never used; the account is
        # disabled as soon as its profile exists.
        $chars    = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
        $plain    = (-join ($chars | Get-Random -Count 20)) + 'Aa1!'
        $password = ConvertTo-SecureString -String $plain -AsPlainText -Force
        $user = New-LocalUser -Name $FixtureUserName -Password $password -AccountNeverExpires `
                    -UserMayNotChangePassword -Description 'DEX break-test fixture account; safe to delete' -ErrorAction Stop
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Created local account '$FixtureUserName'"
    }

    if (-not (Get-FixtureProfilePath)) {
        # First choice: userenv!CreateProfile (no logon). On the lab VM it returned
        # 0x800706F7 (RPC_X_BAD_STUB_DATA, run a70511beb91d, 2026-11-02), so a real
        # profile load through a hidden process started as the user is the fallback.
        $created = $false
        try {
            Add-DexUserEnvType
            $buffer = New-Object System.Text.StringBuilder 1024
            $hr = [DexUserEnv]::CreateProfile($user.SID.Value, $FixtureUserName, $buffer, 1024)
            if ($hr -eq 0 -and (Get-FixtureProfilePath)) { $created = $true }
            else { Write-DexStep -Status 'Info' -Name 'Fixture' -Message ('CreateProfile returned 0x{0:X8}; loading the profile through a logon instead' -f $hr) }
        } catch {
            Write-DexStep -Status 'Info' -Name 'Fixture' -Message "CreateProfile unavailable ($($_.Exception.Message)); loading the profile through a logon instead"
        }
        if (-not $created) {
            if (-not $password) {
                # Account left over from an earlier run: give it a fresh random password.
                $chars    = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
                $plain    = (-join ($chars | Get-Random -Count 20)) + 'Aa1!'
                $password = ConvertTo-SecureString -String $plain -AsPlainText -Force
                Set-LocalUser -Name $FixtureUserName -Password $password -ErrorAction Stop
            }
            Enable-LocalUser -Name $FixtureUserName -ErrorAction Stop
            $cred = New-Object System.Management.Automation.PSCredential (".\$FixtureUserName", $password)
            Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c exit 0' -Credential $cred `
                -LoadUserProfile -WorkingDirectory $env:SystemRoot -WindowStyle Hidden -Wait -ErrorAction Stop
            Start-Sleep -Seconds 2
        }
        $path = Get-FixtureProfilePath
        if (-not $path) { throw 'The profile was not created (Win32_UserProfile does not list it).' }
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Created profile at '$path'"
    }

    Disable-LocalUser -Name $FixtureUserName -ErrorAction SilentlyContinue
}

function Remove-Fixture {
    $user = Get-LocalUser -Name $FixtureUserName -ErrorAction SilentlyContinue
    if (-not $user) { return }
    $prof = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($user.SID.Value)'" -ErrorAction SilentlyContinue
    if ($prof) {
        $localPath = $prof.LocalPath
        # Deletes the folder and the ProfileList entry together, the same way the
        # Advanced System Properties dialog does.
        $prof | Remove-CimInstance -ErrorAction Stop
        if ($localPath -and (Test-Path -LiteralPath $localPath)) {
            Remove-Item -LiteralPath $localPath -Recurse -Force -ErrorAction Stop
        }
    }
    Remove-LocalUser -Name $FixtureUserName -ErrorAction Stop
}

# -- Helpers ------------------------------------------------------------------

function Resolve-DexFixturePaths {
    param([string[]]$RelativePaths)
    $root = Get-FixtureProfilePath
    if (-not $root) { return @() }
    return @($RelativePaths | ForEach-Object { Join-Path $root $_ })
}

function New-DexBloatFile {
    <#
        Creates a file of exactly the requested size and back-dates it. SetLength
        allocates the clusters without writing them, so a 500 MB fixture lands in
        milliseconds; Length -- which is all the script measures -- reads back in full.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$SizeBytes,
        [int]$AgeDays = 0
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { $fs.SetLength($SizeBytes) } finally { $fs.Dispose() }
    if ($AgeDays -gt 0) {
        [System.IO.File]::SetLastWriteTime($Path, (Get-Date).AddDays(-$AgeDays))
    }
}

function Set-DexFileLength {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][long]$Length)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { $fs.SetLength($Length) } finally { $fs.Dispose() }
}

function Measure-DexAgedFiles {
    <#
        Mirrors Measure-CacheTarget in the script under test: bytes and count of files
        under each path whose LastWriteTime is older than the cut-off. A path may be a
        folder (recursed) or a single file.
    #>
    param(
        [string[]]$Path,
        [string[]]$Include = @('*'),
        [int]$AgeDays = $ScriptMinFileAgeDays
    )
    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $bytes  = [long]0
    $count  = 0
    foreach ($p in $Path) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $item  = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        $files = if ($item -is [System.IO.DirectoryInfo]) {
            Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue
        } else {
            $item
        }
        foreach ($f in $files) {
            $nameOk = $false
            foreach ($pattern in $Include) { if ($f.Name -like $pattern) { $nameOk = $true; break } }
            if ($nameOk -and $f.LastWriteTime -lt $cutoff) { $bytes += $f.Length; $count++ }
        }
    }
    return [PSCustomObject]@{ Bytes = $bytes; Count = $count }
}

function Add-DexCacheBloat {
    <#
        Plants aged bloat past MinSizeThresholdMB in a fixture cache folder, either as
        one large file or many half-megabyte ones, plus a fresh control file.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RelativeDir,
        [ValidateSet('Single', 'Many')][string]$Layout = 'Single'
    )
    $root = Get-FixtureProfilePath
    if (-not $root) { throw 'Fixture profile is missing; cannot plant cache bloat.' }
    $dir = Join-Path $root $RelativeDir
    if ($Layout -eq 'Single') {
        New-DexBloatFile -Path (Join-Path $dir 'DEXTest-aged-bloat.bin') -SizeBytes $BloatBytes -AgeDays $BloatAgeDays
    } else {
        $each = 512KB
        $n    = [int][math]::Ceiling($BloatBytes / $each)
        for ($i = 1; $i -le $n; $i++) {
            New-DexBloatFile -Path (Join-Path $dir ('DEXTest-aged-{0:D4}.bin' -f $i)) -SizeBytes $each -AgeDays $BloatAgeDays
        }
    }
    New-DexBloatFile -Path (Join-Path $dir $ControlFileName) -SizeBytes 1MB -AgeDays 0
}

function Test-DexCacheBloatPresent {
    param([Parameter(Mandatory = $true)][string[]]$RelativeDirs)
    $paths = Resolve-DexFixturePaths -RelativePaths $RelativeDirs
    if ($paths.Count -eq 0) { return $false }
    return ((Measure-DexAgedFiles -Path $paths).Bytes -ge ($ScriptMinSizeThresholdMB * 1MB))
}

function Test-DexCacheBloatCleared {
    # Aged fixture files gone, fresh control file kept: the exact contract of the step.
    param([Parameter(Mandatory = $true)][string[]]$RelativeDirs)
    $paths = Resolve-DexFixturePaths -RelativePaths $RelativeDirs
    if ($paths.Count -eq 0) { return $false }
    $agedGone    = (Measure-DexAgedFiles -Path $paths).Count -eq 0
    $controlKept = @($paths | ForEach-Object { Join-Path $_ $ControlFileName } | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
    return ($agedGone -and $controlKept)
}

function Remove-DexCacheBloat {
    param([Parameter(Mandatory = $true)][string[]]$RelativeDirs)
    foreach ($p in (Resolve-DexFixturePaths -RelativePaths $RelativeDirs)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-DexStepReported {
    <#
        Confirms the remediation script reported a finding for a given report-only
        step. The script under test has no per-step registry record, so two
        independent signals are required: the summary key's Warnings counter from a
        run that started after this test did, and the step's own [Warning] line in
        the captured console output.
    #>
    param([Parameter(Mandatory = $true)][string]$StepName)

    $outputOk = $false
    if ($state -and $state.Remediation -and $state.Remediation.Output) {
        $pattern  = '\[Warning\]\s+' + [regex]::Escape($StepName) + ':'
        $outputOk = ([string]$state.Remediation.Output) -match $pattern
    }

    $regOk = $false
    if (Test-Path -LiteralPath $DexRecordsPath) {
        $key = Get-ItemProperty -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
        $lastRun = $null
        if ($key -and $key.LastRun) {
            try { $lastRun = [datetime]::ParseExact([string]$key.LastRun, 'yyyy-MM-dd HH:mm:ss', $null) } catch { $lastRun = $null }
        }
        $started = [datetime]::Parse([string]$state.StartedAt)
        $regOk = $key -and ([int]$key.Warnings -ge 1) -and $lastRun -and ($lastRun -ge $started.AddMinutes(-1))
    }

    return ($outputOk -and $regOk)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        # Step 1: User Temp Files (AppData\Local\Temp).
        Name            = 'UserTempFiles'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{ Name = 'SingleLargeAgedFile'; Apply = { Add-DexCacheBloat -RelativeDir $RelTemp -Layout Single } },
            @{ Name = 'ManySmallAgedFiles';  Apply = { Add-DexCacheBloat -RelativeDir $RelTemp -Layout Many   } }
        )
        Capture  = { @{ Existed = [bool](Test-DexCacheBloatPresent -RelativeDirs @($RelTemp)) } }
        Verify   = { Test-DexCacheBloatPresent -RelativeDirs @($RelTemp) }
        Validate = { Test-DexCacheBloatCleared -RelativeDirs @($RelTemp) }
        Restore  = { param($Original); Remove-DexCacheBloat -RelativeDirs @($RelTemp) }
    },

    @{
        # Step 2: Browser Caches. The script's targets carry a mid-path wildcard for the
        # browser profile name; 'Default' is what Resolve-Path expands it to here.
        Name            = 'BrowserCaches'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{ Name = 'ChromeDefaultCache'; Apply = { Add-DexCacheBloat -RelativeDir $RelChromeCache   -Layout Single } },
            @{ Name = 'EdgeCodeCache';      Apply = { Add-DexCacheBloat -RelativeDir $RelEdgeCodeCache -Layout Many   } }
        )
        Capture  = { @{ Existed = [bool](Test-DexCacheBloatPresent -RelativeDirs @($RelChromeCache, $RelEdgeCodeCache)) } }
        Verify   = { Test-DexCacheBloatPresent -RelativeDirs @($RelChromeCache, $RelEdgeCodeCache) }
        Validate = { Test-DexCacheBloatCleared -RelativeDirs @($RelChromeCache, $RelEdgeCodeCache) }
        Restore  = { param($Original); Remove-DexCacheBloat -RelativeDirs @($RelChromeCache, $RelEdgeCodeCache) }
    },

    @{
        # Step 3: Teams Cache, classic (Roaming) and new (Packages\...\EBWebView) layouts.
        Name            = 'TeamsCache'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{ Name = 'ClassicTeamsCache';   Apply = { Add-DexCacheBloat -RelativeDir $RelTeamsClassic -Layout Single } },
            @{ Name = 'NewTeamsWebViewCache'; Apply = { Add-DexCacheBloat -RelativeDir $RelTeamsNew     -Layout Many   } }
        )
        Capture  = { @{ Existed = [bool](Test-DexCacheBloatPresent -RelativeDirs @($RelTeamsClassic, $RelTeamsNew)) } }
        Verify   = { Test-DexCacheBloatPresent -RelativeDirs @($RelTeamsClassic, $RelTeamsNew) }
        Validate = { Test-DexCacheBloatCleared -RelativeDirs @($RelTeamsClassic, $RelTeamsNew) }
        Restore  = { param($Original); Remove-DexCacheBloat -RelativeDirs @($RelTeamsClassic, $RelTeamsNew) }
    },

    @{
        # Step 4: Explorer Thumbnail and Icon Cache. The script targets file globs
        # (thumbcache_*.db, iconcache_*.db), so the fixture is a file, not a folder.
        Name            = 'ExplorerIconCache'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'AgedThumbcacheDb'
                Apply = {
                    $dir = (Resolve-DexFixturePaths -RelativePaths @($RelExplorerDir))[0]
                    New-DexBloatFile -Path (Join-Path $dir 'thumbcache_DEXTest.db')      -SizeBytes $BloatBytes -AgeDays $BloatAgeDays
                    New-DexBloatFile -Path (Join-Path $dir 'thumbcache_DEXTestFresh.db') -SizeBytes 1MB -AgeDays 0
                }
            },
            @{
                Name  = 'AgedIconcacheDb'
                Apply = {
                    $dir = (Resolve-DexFixturePaths -RelativePaths @($RelExplorerDir))[0]
                    New-DexBloatFile -Path (Join-Path $dir 'iconcache_DEXTest.db')      -SizeBytes $BloatBytes -AgeDays $BloatAgeDays
                    New-DexBloatFile -Path (Join-Path $dir 'iconcache_DEXTestFresh.db') -SizeBytes 1MB -AgeDays 0
                }
            }
        )
        Capture  = {
            $paths = Resolve-DexFixturePaths -RelativePaths @($RelExplorerDir)
            @{ AgedBytes = (Measure-DexAgedFiles -Path $paths -Include @('thumbcache_DEXTest*.db', 'iconcache_DEXTest*.db')).Bytes }
        }
        Verify   = {
            $paths = Resolve-DexFixturePaths -RelativePaths @($RelExplorerDir)
            if ($paths.Count -eq 0) { return $false }
            (Measure-DexAgedFiles -Path $paths -Include @('thumbcache_DEXTest*.db', 'iconcache_DEXTest*.db')).Bytes -ge ($ScriptMinSizeThresholdMB * 1MB)
        }
        Validate = {
            $paths = Resolve-DexFixturePaths -RelativePaths @($RelExplorerDir)
            if ($paths.Count -eq 0) { return $false }
            $agedGone    = (Measure-DexAgedFiles -Path $paths -Include @('thumbcache_DEXTest*.db', 'iconcache_DEXTest*.db')).Count -eq 0
            $controlKept = @(Get-ChildItem -LiteralPath $paths[0] -Filter '*cache_DEXTestFresh.db' -Force -ErrorAction SilentlyContinue).Count -gt 0
            $agedGone -and $controlKept
        }
        Restore  = {
            param($Original)
            foreach ($dir in (Resolve-DexFixturePaths -RelativePaths @($RelExplorerDir))) {
                if (Test-Path -LiteralPath $dir) {
                    Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like '*cache_DEXTest*.db' } |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
            }
        }
    },

    @{
        # Step 5: Crash Dumps and Error Reports.
        Name            = 'CrashDumps'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{ Name = 'LocalCrashDumps'; Apply = { Add-DexCacheBloat -RelativeDir $RelCrashDumps -Layout Single } },
            @{ Name = 'WerReportQueue';  Apply = { Add-DexCacheBloat -RelativeDir $RelWerQueue   -Layout Many   } }
        )
        Capture  = { @{ Existed = [bool](Test-DexCacheBloatPresent -RelativeDirs @($RelCrashDumps, $RelWerQueue)) } }
        Verify   = { Test-DexCacheBloatPresent -RelativeDirs @($RelCrashDumps, $RelWerQueue) }
        Validate = { Test-DexCacheBloatCleared -RelativeDirs @($RelCrashDumps, $RelWerQueue) }
        Restore  = { param($Original); Remove-DexCacheBloat -RelativeDirs @($RelCrashDumps, $RelWerQueue) }
    },

    @{
        # Step 6: RDP and Shader Caches.
        Name            = 'ShaderCaches'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{ Name = 'D3DShaderCache';  Apply = { Add-DexCacheBloat -RelativeDir $RelD3DCache -Layout Single } },
            @{ Name = 'RdpBitmapCache';  Apply = { Add-DexCacheBloat -RelativeDir $RelRdpCache -Layout Many   } }
        )
        Capture  = { @{ Existed = [bool](Test-DexCacheBloatPresent -RelativeDirs @($RelD3DCache, $RelRdpCache)) } }
        Verify   = { Test-DexCacheBloatPresent -RelativeDirs @($RelD3DCache, $RelRdpCache) }
        Validate = { Test-DexCacheBloatCleared -RelativeDirs @($RelD3DCache, $RelRdpCache) }
        Restore  = { param($Original); Remove-DexCacheBloat -RelativeDirs @($RelD3DCache, $RelRdpCache) }
    },

    @{
        # Step 7: Recent Items and Jump Lists. The step fails on file COUNT (>= 500 aged
        # Recent\*.lnk) as well as size, so one method exercises each trigger.
        Name            = 'RecentItems'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'ManyAgedShortcuts'
                Apply = {
                    $dir = (Resolve-DexFixturePaths -RelativePaths @($RelRecentDir))[0]
                    for ($i = 1; $i -le ($ScriptRecentWarnCount + 100); $i++) {
                        New-DexBloatFile -Path (Join-Path $dir ('DEXTest_{0:D4}.lnk' -f $i)) -SizeBytes 1KB -AgeDays $BloatAgeDays
                    }
                    New-DexBloatFile -Path (Join-Path $dir 'DEXTest_control-fresh.lnk') -SizeBytes 1KB -AgeDays 0
                }
            },
            @{
                Name  = 'LargeAgedJumpLists'
                Apply = { Add-DexCacheBloat -RelativeDir $RelJumpLists -Layout Single }
            }
        )
        Capture  = {
            $recent = Resolve-DexFixturePaths -RelativePaths @($RelRecentDir)
            @{ AgedShortcuts = (Measure-DexAgedFiles -Path $recent -Include @('DEXTest_*.lnk')).Count }
        }
        Verify   = {
            $recent = Resolve-DexFixturePaths -RelativePaths @($RelRecentDir)
            if ($recent.Count -eq 0) { return $false }
            $lnk = Measure-DexAgedFiles -Path $recent -Include @('DEXTest_*.lnk')
            ($lnk.Count -ge $ScriptRecentWarnCount) -or (Test-DexCacheBloatPresent -RelativeDirs @($RelJumpLists))
        }
        Validate = {
            $recent = Resolve-DexFixturePaths -RelativePaths @($RelRecentDir)
            if ($recent.Count -eq 0) { return $false }
            $lnkGone      = (Measure-DexAgedFiles -Path $recent -Include @('DEXTest_*.lnk')).Count -eq 0
            $jumpGone     = (Measure-DexAgedFiles -Path (Resolve-DexFixturePaths -RelativePaths @($RelJumpLists))).Count -eq 0
            $controlKept  = (Test-Path -LiteralPath (Join-Path $recent[0] 'DEXTest_control-fresh.lnk')) -or
                            (Test-Path -LiteralPath (Join-Path (Resolve-DexFixturePaths -RelativePaths @($RelJumpLists))[0] $ControlFileName))
            $lnkGone -and $jumpGone -and $controlKept
        }
        Restore  = {
            param($Original)
            foreach ($dir in (Resolve-DexFixturePaths -RelativePaths @($RelRecentDir))) {
                if (Test-Path -LiteralPath $dir) {
                    Get-ChildItem -LiteralPath $dir -Filter 'DEXTest_*.lnk' -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
            }
            Remove-DexCacheBloat -RelativeDirs @($RelJumpLists)
        }
    },

    @{
        # Step 8: Oversized Roaming AppData. Report only -- the script must flag the
        # profile and leave the data exactly where it found it.
        Name            = 'OversizedRoamingAppData'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'SingleLargeRoamingFile'
                Apply = {
                    $dir = (Resolve-DexFixturePaths -RelativePaths @($RelRoamingBloat))[0]
                    New-DexBloatFile -Path (Join-Path $dir 'DEXTest-roaming-bloat.bin') -SizeBytes $RoamingBloatBytes -AgeDays 1
                }
            },
            @{
                Name  = 'ManyRoamingFiles'
                Apply = {
                    $dir  = (Resolve-DexFixturePaths -RelativePaths @($RelRoamingBloat))[0]
                    $each = 8MB
                    $n    = [int][math]::Ceiling($RoamingBloatBytes / $each)
                    for ($i = 1; $i -le $n; $i++) {
                        New-DexBloatFile -Path (Join-Path $dir ('DEXTest-roaming-{0:D4}.bin' -f $i)) -SizeBytes $each -AgeDays 1
                    }
                }
            }
        )
        Capture  = {
            $roaming = Resolve-DexFixturePaths -RelativePaths @($RelRoamingRoot)
            @{ RoamingBytes = (Measure-DexAgedFiles -Path $roaming -AgeDays 0).Bytes }
        }
        Verify   = {
            # Same measurement the script makes: everything under AppData\Roaming, no age cut.
            $roaming = Resolve-DexFixturePaths -RelativePaths @($RelRoamingRoot)
            if ($roaming.Count -eq 0) { return $false }
            (Measure-DexAgedFiles -Path $roaming -AgeDays 0).Bytes -ge ($ScriptRoamingWarnMB * 1MB)
        }
        # Correct behaviour is to report and leave alone: the planted bytes must all
        # still be there, the profile must still be over the threshold, and the finding
        # must have been recorded.
        Validate = {
            $bloat   = Resolve-DexFixturePaths -RelativePaths @($RelRoamingBloat)
            $roaming = Resolve-DexFixturePaths -RelativePaths @($RelRoamingRoot)
            if ($bloat.Count -eq 0) { return $false }
            $intact    = (Measure-DexAgedFiles -Path $bloat -AgeDays 0).Bytes -ge $RoamingBloatBytes
            $stillOver = (Measure-DexAgedFiles -Path $roaming -AgeDays 0).Bytes -ge ($ScriptRoamingWarnMB * 1MB)
            $reported  = Test-DexStepReported -StepName 'Oversized Roaming AppData'
            $intact -and $stillOver -and $reported
        }
        Restore  = { param($Original); Remove-DexCacheBloat -RelativeDirs @($RelRoamingBloat) }
    },

    @{
        # Step 9: Oversized User Registry Hive. Report only. The fixture profile is
        # never loaded, so its NTUSER.DAT can be padded and truncated back freely.
        Name            = 'OversizedRegistryHive'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'PadNtUserDat'
                Apply = {
                    $hive = (Resolve-DexFixturePaths -RelativePaths @($RelNtUser))[0]
                    if (-not (Test-Path -LiteralPath $hive)) { throw "Fixture hive not found at $hive" }
                    Set-DexFileLength -Path $hive -Length $HiveBloatBytes
                }
            },
            @{
                Name  = 'PlantUsrClassDat'
                Apply = {
                    $hive = (Resolve-DexFixturePaths -RelativePaths @($RelUsrClass))[0]
                    if (Test-Path -LiteralPath $hive) {
                        Set-DexFileLength -Path $hive -Length $HiveBloatBytes
                    } else {
                        New-DexBloatFile -Path $hive -SizeBytes $HiveBloatBytes -AgeDays 0
                    }
                }
            }
        )
        Capture  = {
            $paths = Resolve-DexFixturePaths -RelativePaths @($RelNtUser, $RelUsrClass)
            $nt = if ($paths.Count -gt 0) { Get-Item -LiteralPath $paths[0] -Force -ErrorAction SilentlyContinue } else { $null }
            $uc = if ($paths.Count -gt 1) { Get-Item -LiteralPath $paths[1] -Force -ErrorAction SilentlyContinue } else { $null }
            @{
                NtUserLength    = if ($nt) { [long]$nt.Length } else { 0 }
                UsrClassExisted = [bool]$uc
                UsrClassLength  = if ($uc) { [long]$uc.Length } else { 0 }
            }
        }
        Verify   = {
            $paths = Resolve-DexFixturePaths -RelativePaths @($RelNtUser, $RelUsrClass)
            if ($paths.Count -eq 0) { return $false }
            $over = $false
            foreach ($p in $paths) {
                $f = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                if ($f -and ($f.Length / 1MB) -ge $ScriptHiveWarnMB) { $over = $true }
            }
            $over
        }
        Validate = {
            $paths = Resolve-DexFixturePaths -RelativePaths @($RelNtUser, $RelUsrClass)
            if ($paths.Count -eq 0) { return $false }
            $stillOver = $false
            foreach ($p in $paths) {
                $f = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                if ($f -and ($f.Length / 1MB) -ge $ScriptHiveWarnMB) { $stillOver = $true }
            }
            $stillOver -and (Test-DexStepReported -StepName 'Oversized User Registry Hive')
        }
        Restore  = {
            param($Original)
            $paths = Resolve-DexFixturePaths -RelativePaths @($RelNtUser, $RelUsrClass)
            if ($paths.Count -eq 0) { return }
            $nt = Get-Item -LiteralPath $paths[0] -Force -ErrorAction SilentlyContinue
            if ($nt -and [long]$Original.NtUserLength -gt 0 -and $nt.Length -gt [long]$Original.NtUserLength) {
                Set-DexFileLength -Path $paths[0] -Length ([long]$Original.NtUserLength)
            }
            if (Test-Path -LiteralPath $paths[1]) {
                if ([bool]$Original.UsrClassExisted) {
                    if ((Get-Item -LiteralPath $paths[1] -Force).Length -gt [long]$Original.UsrClassLength) {
                        Set-DexFileLength -Path $paths[1] -Length ([long]$Original.UsrClassLength)
                    }
                } else {
                    Remove-Item -LiteralPath $paths[1] -Force -ErrorAction SilentlyContinue
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

Write-DexBanner -Title "Invoke-AutoRemediateProfileBloat_BreakTest" -Detail "Environment: $Environment"

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

        # Every break plants into its own DEXTest folder (or its own hive file) inside the
        # fixture profile, and no cleanup target overlaps another break's threshold, so any
        # combination can share a run; no selection guard is needed.

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
            # On 2026-10-28 a disabled Spooler was left behind because the next break's Capture
            # threw and the applied list had not been committed yet.
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
