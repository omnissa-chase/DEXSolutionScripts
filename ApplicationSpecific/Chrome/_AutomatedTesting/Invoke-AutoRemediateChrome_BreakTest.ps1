<#
.SYNOPSIS
    Invoke-AutoRemediateChrome_BreakTest -- deliberately breaks Chrome components,
    then verifies Invoke-AutoRemediateChrome.ps1 actually fixes them.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateChrome\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It plants files inside the logged-on
    user's Chrome profile tree and registers orphaned NativeMessaging host keys. Run
    it only on a disposable VM or a marked test host. See Assert-DexTestHost in
    DEXTestFramework.psm1.

    WHERE THE FIXTURES LIVE
    Invoke-AutoRemediateChrome.ps1 reads only the logged-on user's Default profile
    (Win32_ComputerSystem.UserName -> C:\Users\<name>\AppData\Local\Google\Chrome\
    User Data\Default). A separate DEXTest Chrome profile directory would never be
    looked at, so the cache, extension and crash fixtures are planted inside that
    real tree. Every planted file carries the DEXTest prefix and Restore removes
    only those, plus any directory the break itself had to create. The one side
    effect that is not confined: the script's own cache clear deletes EVERY file in
    Default\Cache and Default\Code Cache, which is the remediation under test.

    CHROME MUST BE CLOSED
    The script refuses to clear the cache while chrome.exe is running and this
    harness will not kill a user's browser. Initialize-Fixture aborts the run if
    Chrome is running. Keep Chrome closed until the run has finished.

    THRESHOLDS
    The script's cache (500MB) and extension (20) thresholds are overridable through
    $env:CacheSizeWarningMB and $env:ExtensionCountWarning. Initialize-Fixture sets
    both to small values in this process so the remediation child inherits them,
    and Remove-Fixture clears them again. Planting 500MB of cache is pointless when
    the knob exists.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Four of the six steps in Invoke-AutoRemediateChrome.ps1 have
    ResolutionScript = $null by design, so breaking them must NOT expect a repair.
    Each break declares which it is:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    NOT COVERED
      Step 3 Google Update Service Health -- the lab host has no gupdate/gupdatem
             services (current Chrome ships GoogleUpdater* instead), so there is
             nothing to stop or disable; the step reports "not found" on every run.
      Step 4 Enterprise Policy Check -- the only Warning path needs UpdateDefault=2
             under HKLM:\SOFTWARE\Policies\Google\Chrome, a machine-wide policy
             value that cannot carry a DEXTest prefix.

    REBOOTS
    No break in this catalog requires a reboot. The reboot plumbing is kept so the
    harness stays uniform with the rest of the family.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateChrome.ps1 and validate the outcome.
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
    Script Name  : Invoke-AutoRemediateChrome_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the logged-on user with Chrome closed
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateChrome\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateChrome'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateChrome.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ChromeErrors'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# Everything planted on disk or in the registry is named with this prefix and is
# the only thing the sweep in Remove-Fixture will touch.
$FixturePrefix             = 'DEXTest'
$FixtureCacheThresholdMB   = 64      # handed to the script as $env:CacheSizeWarningMB (default 500)
$FixtureCacheFileCount     = 5
$FixtureCacheFileMB        = 16      # 5 x 16MB = 80MB per folder, above the threshold on its own
$FixtureExtensionThreshold = 8       # handed to the script as $env:ExtensionCountWarning (default 20)
$FixtureCrashFileCount     = 6       # detection warns at 5 or more files under 24h old
# Chrome extension IDs are 32 chars of a-p; the regex in the script allows nothing else, so
# the DEXTest prefix cannot go in the name. The stem is distinctive and every planted
# directory holds a DEXTest.marker file; Restore removes only directories with both.
$FixtureExtensionStem      = 'deadbeefdeadbeefdeadbeefdeadbe'
$FixtureNmhHostName        = 'DEXTest.orphaned.host'
$FixtureNmhManifestPath    = 'C:\Temp\FixReport\Invoke-AutoRemediateChrome\DEXTest_missing_manifest.json'
$FixtureNmhRoots           = @(
    'HKCU:\Software\Google\Chrome\NativeMessagingHosts',
    'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts',
    'HKLM:\SOFTWARE\WOW6432Node\Google\Chrome\NativeMessagingHosts'
)

function Initialize-Fixture {
    if (Get-Process -Name chrome -ErrorAction SilentlyContinue) {
        throw 'Chrome is running. Close it and re-run: the script refuses to clear the cache while chrome.exe is running, and this harness does not kill a user''s browser.'
    }
    $exe = Get-ChromeExecutable
    if (-not $exe) { throw 'Google Chrome is not installed on this host; Invoke-AutoRemediateChrome.ps1 would exit 0 as Skipped.' }

    # Throws when no interactive user is logged on -- the script would then skip every per-user step.
    $userData = Get-ChromeUserDataPath

    # The remediation runs as a child powershell.exe and inherits this process's environment.
    $env:CacheSizeWarningMB    = "$FixtureCacheThresholdMB"
    $env:ExtensionCountWarning = "$FixtureExtensionThreshold"

    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Chrome $((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion); User Data '$userData'; thresholds cache=${FixtureCacheThresholdMB}MB extensions=$FixtureExtensionThreshold"
}

function Remove-Fixture {
    Remove-Item -Path 'Env:\CacheSizeWarningMB', 'Env:\ExtensionCountWarning' -ErrorAction SilentlyContinue

    # Sweep by prefix. The per-break Restore blocks have normally done all of this already;
    # this catches anything a half-finished run left behind.
    try { Get-FixtureCacheFiles    | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
    try { Get-FixtureCrashFiles    | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
    try { Get-FixtureExtensionDirs | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    try { Get-FixtureNmhKeys       | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    if (Test-Path -LiteralPath $FixtureNmhManifestPath) {
        Remove-Item -LiteralPath $FixtureNmhManifestPath -Force -ErrorAction SilentlyContinue
    }
}

# -- Helpers ------------------------------------------------------------------

function Get-ChromeExecutable {
    # Same resolution order as the script: App Paths first, then the install folders.
    $appPath = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue
    if ($appPath -and $appPath.'(default)' -and (Test-Path -LiteralPath $appPath.'(default)')) {
        return $appPath.'(default)'
    }
    foreach ($candidate in @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-ChromeUserDataPath {
    # Mirrors the script exactly: the per-user tree belongs to Win32_ComputerSystem.UserName,
    # never to $env:LOCALAPPDATA (which is SYSTEM's when run from a SYSTEM task).
    $loggedOn = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $loggedOn) {
        throw 'No interactive user is logged on; Invoke-AutoRemediateChrome.ps1 resolves its profile paths from Win32_ComputerSystem.UserName.'
    }
    $shortName   = $loggedOn.Split('\')[-1]
    $userProfile = "C:\Users\$shortName"
    if (-not (Test-Path -LiteralPath $userProfile)) {
        throw "Profile folder '$userProfile' for logged-on user '$loggedOn' not found."
    }
    return (Join-Path $userProfile 'AppData\Local\Google\Chrome\User Data')
}

function Get-ChromeDefaultPath {
    Join-Path (Get-ChromeUserDataPath) 'Default'
}

function Get-MissingDirectories {
    <#
        Returns, parent-first, the directories in the list that do not exist yet. Capture
        records this so Restore removes exactly the directories the break had to create
        and nothing Chrome itself had already made.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    $missing = @()
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { $missing += $p }
    }
    return @($missing)
}

function Remove-MissingDirectories {
    # Deepest first; a directory is removed only if it is now empty, so a folder Chrome
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

function New-FixtureFile {
    <#
        SetLength allocates the bytes without writing them, so an 80MB fixture costs
        milliseconds; FileInfo.Length (what the script measures) reports the full size.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$SizeMB
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $fs = [System.IO.File]::Create($Path)
    try { $fs.SetLength([int64]$SizeMB * 1MB) } finally { $fs.Dispose() }
}

function Get-ChromeCacheSizeMB {
    # Same arithmetic as Step 1's DetectionScript.
    $default = Get-ChromeDefaultPath
    $totalMB = 0
    foreach ($folder in @('Cache', 'Code Cache')) {
        $fullPath = Join-Path $default $folder
        if (Test-Path -LiteralPath $fullPath) {
            $sum = (Get-ChildItem -LiteralPath $fullPath -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            $totalMB += [math]::Round($sum / 1MB, 0)
        }
    }
    return $totalMB
}

function Add-FixtureCacheFiles {
    param([Parameter(Mandatory = $true)][string[]]$Folders)
    $default = Get-ChromeDefaultPath
    foreach ($folder in $Folders) {
        for ($i = 1; $i -le $FixtureCacheFileCount; $i++) {
            $name = '{0}_cache_{1:D2}.bin' -f $FixturePrefix, $i
            New-FixtureFile -Path (Join-Path (Join-Path $default $folder) $name) -SizeMB $FixtureCacheFileMB
        }
    }
}

function Get-FixtureCacheFiles {
    $default = Get-ChromeDefaultPath
    $files = @()
    foreach ($folder in @('Cache', 'Code Cache')) {
        $fullPath = Join-Path $default $folder
        if (Test-Path -LiteralPath $fullPath) {
            $files += @(Get-ChildItem -LiteralPath $fullPath -File -Filter "$FixturePrefix*" -ErrorAction SilentlyContinue)
        }
    }
    return @($files)
}

function Get-FixtureExtensionId {
    # 30-char stem + two a-p letters from the index: always matches ^[a-p]{32}$.
    param([Parameter(Mandatory = $true)][int]$Index)
    $hi = [char](97 + [math]::Floor($Index / 16))
    $lo = [char](97 + ($Index % 16))
    return "$FixtureExtensionStem$hi$lo"
}

function Get-ChromeExtensionDirCount {
    # Same filter as Step 2's DetectionScript.
    $extRoot = Join-Path (Get-ChromeDefaultPath) 'Extensions'
    if (-not (Test-Path -LiteralPath $extRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '^[a-p]{32}$' }).Count
}

function Get-FixtureExtensionDirs {
    $extRoot = Join-Path (Get-ChromeDefaultPath) 'Extensions'
    if (-not (Test-Path -LiteralPath $extRoot)) { return @() }
    $dirs = @(Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue |
              Where-Object {
                  $_.Name -like "$FixtureExtensionStem*" -and
                  (Test-Path -LiteralPath (Join-Path $_.FullName "$FixturePrefix.marker"))
              })
    return @($dirs)
}

function Get-ChromeCrashReportPath {
    Join-Path (Get-ChromeUserDataPath) 'Crashpad\reports'
}

function Get-FixtureCrashFiles {
    $reports = Get-ChromeCrashReportPath
    if (-not (Test-Path -LiteralPath $reports)) { return @() }
    return @(Get-ChildItem -LiteralPath $reports -File -Filter "$FixturePrefix*" -ErrorAction SilentlyContinue)
}

function Add-FixtureNmhKeys {
    param([Parameter(Mandatory = $true)][string[]]$Roots)
    # The manifest must be absent for the key to count as orphaned.
    if (Test-Path -LiteralPath $FixtureNmhManifestPath) {
        Remove-Item -LiteralPath $FixtureNmhManifestPath -Force -ErrorAction Stop
    }
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            New-Item -Path $root -Force -ErrorAction Stop | Out-Null
        }
        $key = Join-Path $root $FixtureNmhHostName
        New-Item -Path $key -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $key -Name '(default)' -Value $FixtureNmhManifestPath -ErrorAction Stop
    }
}

function Get-FixtureNmhKeys {
    $keys = @()
    foreach ($root in $FixtureNmhRoots) {
        $key = Join-Path $root $FixtureNmhHostName
        if (Test-Path -LiteralPath $key) { $keys += Get-Item -LiteralPath $key -ErrorAction SilentlyContinue }
    }
    return @($keys)
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
# All four breaks touch different components and can share a run.
$BreakCatalog = @(

    @{
        Name            = 'CacheBloat'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'PlantCacheFiles'
                Apply = { Add-FixtureCacheFiles -Folders @('Cache') }
            },
            @{
                Name  = 'PlantCodeCacheFiles'
                Apply = { Add-FixtureCacheFiles -Folders @('Code Cache') }
            },
            @{
                Name  = 'PlantBothFolders'
                Apply = { Add-FixtureCacheFiles -Folders @('Cache', 'Code Cache') }
            }
        )
        Capture  = {
            $userData = Get-ChromeUserDataPath
            $default  = Join-Path $userData 'Default'
            @{
                MissingDirs = @(Get-MissingDirectories -Paths @(
                    $userData, $default, (Join-Path $default 'Cache'), (Join-Path $default 'Code Cache')))
                CacheSizeMB = Get-ChromeCacheSizeMB
            }
        }
        # Broken means the script's own measurement is at or over the threshold it will be given.
        Verify   = {
            @(Get-FixtureCacheFiles).Count -gt 0 -and (Get-ChromeCacheSizeMB) -ge $FixtureCacheThresholdMB
        }
        # The script promises to delete every file under Cache and Code Cache; ours must be gone.
        Validate = { @(Get-FixtureCacheFiles).Count -eq 0 }
        Restore  = {
            param($Original)
            Get-FixtureCacheFiles | Remove-Item -Force -ErrorAction SilentlyContinue
            Remove-MissingDirectories -Paths @($Original.MissingDirs)
        }
    },

    @{
        Name            = 'ExtensionCount'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'PlantFakeExtensionDirs'
                Apply = {
                    $extRoot = Join-Path (Get-ChromeDefaultPath) 'Extensions'
                    for ($i = 0; $i -lt $FixtureExtensionThreshold; $i++) {
                        $dir = Join-Path $extRoot (Get-FixtureExtensionId -Index $i)
                        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
                        Set-Content -LiteralPath (Join-Path $dir "$FixturePrefix.marker") `
                            -Value 'Planted by Invoke-AutoRemediateChrome_BreakTest.ps1; safe to delete.' -ErrorAction Stop
                    }
                }
            }
        )
        Capture  = {
            $userData = Get-ChromeUserDataPath
            $default  = Join-Path $userData 'Default'
            @{
                MissingDirs    = @(Get-MissingDirectories -Paths @($userData, $default, (Join-Path $default 'Extensions')))
                ExtensionCount = Get-ChromeExtensionDirCount
            }
        }
        Verify   = {
            @(Get-FixtureExtensionDirs).Count -eq $FixtureExtensionThreshold -and
            (Get-ChromeExtensionDirCount) -ge $FixtureExtensionThreshold
        }
        # Correct behaviour is to report and leave alone: the directories must still be
        # here afterwards, and the finding must have reached the registry.
        Validate = {
            $stillThere = @(Get-FixtureExtensionDirs).Count -eq $FixtureExtensionThreshold
            $reported   = Test-DexRecordContains -ValueNamePrefix 'Step02_'
            $stillThere -and $reported
        }
        Restore  = {
            param($Original)
            Get-FixtureExtensionDirs | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Remove-MissingDirectories -Paths @($Original.MissingDirs)
        }
    },

    @{
        Name            = 'CrashLoop'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'PlantRecentCrashReports'
                Apply = {
                    $reports = Get-ChromeCrashReportPath
                    for ($i = 1; $i -le $FixtureCrashFileCount; $i++) {
                        $name = '{0}_crash_{1:D2}.dmp' -f $FixturePrefix, $i
                        New-FixtureFile -Path (Join-Path $reports $name) -SizeMB 1
                    }
                }
            }
        )
        Capture  = {
            $userData = Get-ChromeUserDataPath
            @{
                MissingDirs = @(Get-MissingDirectories -Paths @(
                    $userData, (Join-Path $userData 'Crashpad'), (Join-Path $userData 'Crashpad\reports')))
            }
        }
        Verify   = {
            $reports = Get-ChromeCrashReportPath
            $recent  = @(Get-ChildItem -LiteralPath $reports -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) }).Count
            @(Get-FixtureCrashFiles).Count -eq $FixtureCrashFileCount -and $recent -ge 5
        }
        Validate = {
            $stillThere = @(Get-FixtureCrashFiles).Count -eq $FixtureCrashFileCount
            $reported   = Test-DexRecordContains -ValueNamePrefix 'Step05_'
            $stillThere -and $reported
        }
        Restore  = {
            param($Original)
            Get-FixtureCrashFiles | Remove-Item -Force -ErrorAction SilentlyContinue
            Remove-MissingDirectories -Paths @($Original.MissingDirs)
        }
    },

    @{
        Name            = 'OrphanedNativeMessagingHost'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        # HKCU here is the hive of whoever runs this harness; the remediation child runs in the
        # same context, so the two always agree (both the user, or both SYSTEM from a task).
        Methods         = @(
            @{
                Name  = 'RegisterInHkcu'
                Apply = { Add-FixtureNmhKeys -Roots @($FixtureNmhRoots[0]) }
            },
            @{
                Name  = 'RegisterInHklm'
                Apply = { Add-FixtureNmhKeys -Roots @($FixtureNmhRoots[1]) }
            },
            @{
                Name  = 'RegisterInWow6432Node'
                Apply = { Add-FixtureNmhKeys -Roots @($FixtureNmhRoots[2]) }
            },
            @{
                Name  = 'RegisterInAllHives'
                Apply = { Add-FixtureNmhKeys -Roots $FixtureNmhRoots }
            }
        )
        Capture  = {
            @{ MissingRoots = @($FixtureNmhRoots | Where-Object { -not (Test-Path -LiteralPath $_) }) }
        }
        Verify   = {
            $keys = @(Get-FixtureNmhKeys)
            if ($keys.Count -eq 0) { return $false }
            $orphaned = $true
            foreach ($k in $keys) {
                $manifest = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).'(default)'
                if (-not $manifest -or (Test-Path -LiteralPath $manifest)) { $orphaned = $false }
            }
            $orphaned
        }
        Validate = { @(Get-FixtureNmhKeys).Count -eq 0 }
        Restore  = {
            param($Original)
            Get-FixtureNmhKeys | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            # Parent keys the break created are removed only if nothing else has moved in.
            foreach ($root in @($Original.MissingRoots)) {
                if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
                $item = Get-Item -LiteralPath $root -ErrorAction SilentlyContinue
                if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) {
                    Remove-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
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

Write-DexBanner -Title "Invoke-AutoRemediateChrome_BreakTest" -Detail "Environment: $Environment"

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
