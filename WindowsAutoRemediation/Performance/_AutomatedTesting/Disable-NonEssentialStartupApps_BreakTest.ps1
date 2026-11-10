<#
.SYNOPSIS
    Disable-NonEssentialStartupApps_BreakTest -- plants startup entries with known facts
    (missing target, user-disabled, Microsoft-signed, genuinely slow), then verifies
    Disable-NonEssentialStartupApps.ps1 2.0.0 disables exactly the ones its rules say and
    leaves the rest, and that startup_apps_health.ps1 predicts the same verdicts.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Disable-NonEssentialStartupApps\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes Run values and StartupApproved
    records into the logged-on user's hive and a shortcut into that user's Startup folder;
    the gated break also adds a real (sleeping) startup program and reboots twice. Run it
    only on a disposable VM or a marked test host. See Assert-DexTestHost.

    WHAT IS BROKEN AND HOW IT COMES BACK
    The script resolves the console user from Win32_ComputerSystem.UserName and reads that
    user's hive through HKEY_USERS\<SID>; run elevated as the interactive user the hive is
    the harness user's own. Every planted artefact carries the DEXTest prefix: Run values
    DEXTestDangling, DEXTestOff, DEXTestSigned, DEXTestSlow; shortcut DEXTestDangling.lnk;
    files under C:\Temp\DEXTest\StartupApps. Restore removes the values, the matching
    StartupApproved records, the shortcut and the files, and the folders only when the
    harness created them. The script itself deletes nothing: it writes StartupApproved
    records (03 + FILETIME), so Validate checks those bytes and that the Run value or
    shortcut is still there.

    PARITY
    Capture runs OneTimeSensor\startup_apps_health.ps1 for a baseline; Verify runs it
    again and checks the planted entry's verdict (disable / off / ok) or the moved counter.

    GATES
    SlowUnsignedEntry needs two real logons: the script disables a slow entry only on a
    median over at least two logons, and the only writer of Shell-Core 9707/9708 is
    Explorer at logon. The break is RequiresReboot and runs only with -IncludeRebootBreaks
    or -BreakName SlowUnsignedEntry. The harness reboots, resumes at startup as SYSTEM,
    waits for the user to log on and for Explorer to time the planted program (an unsigned
    WinForms exe compiled on the spot that sleeps 15 s before it creates its window, so the
    first idle message loop Explorer waits for comes 15 s late), reboots once more for the
    second sample, then remediates. The remediation child on that path runs as SYSTEM, so
    the run also proves the console-user resolution. Log on promptly after each reboot: the
    resume waits up to 25 minutes for the logon and 10 more for the logon's 9708.

    EXPECTED OUTCOMES (derived from the script's own messages, 2.0.0)
      ExpectFixed        -- the entry is disabled (StartupApproved byte 0 = 3), not deleted
      ExpectReportedOnly -- the entry is listed with its facts and left alone

    DanglingRunEntry        ExpectFixed. Run\DEXTestDangling -> C:\Temp\DEXTest\StartupApps\gone.exe
                            (absent, drive present). Validate: StartupApproved\Run\DEXTestDangling
                            byte 0 = 3; value still present; Step01 reads "[Remediated] target
                            missing; disabled ... DEXTestDangling"; Entry_DEXTestDangling ends
                            "disabled".
    DanglingStartupShortcut ExpectFixed. Startup\DEXTestDangling.lnk -> same missing exe.
                            Validate: StartupApproved\StartupFolder\DEXTestDangling.lnk byte 0 = 3;
                            shortcut still present; Step01 names DEXTestDangling.lnk.
    UserDisabledDanglingLeft ExpectReportedOnly. Run\DEXTestOff -> missing exe, planted already
                            disabled (03 + FILETIME). Validate: bytes unchanged (same FILETIME);
                            Entry_DEXTestOff reads "Disabled; target MISSING ... already disabled,
                            left"; Step01, if written, does not name DEXTestOff.
    MicrosoftSignedLeft     ExpectReportedOnly. Run\DEXTestSigned -> "%windir%\System32\notepad.exe"
                            /dex (present, Microsoft-signed, no timing). Validate: no Disabled
                            record; Entry_DEXTestSigned reads "present; Microsoft; no launch timing".
    SlowUnsignedEntry       ExpectFixed, RequiresReboot (two logons). Run\DEXTestSlow ->
                            C:\Temp\DEXTest\StartupApps\DEXTestSlow.exe (unsigned, sleeps 15 s).
                            Verify: two 9707/9708 samples with median >= 10000 ms. Validate:
                            StartupApproved\Run\DEXTestSlow byte 0 = 3; Step02 reads
                            "[Remediated] slow at logon; disabled ... DEXTestSlow".

    NOT COVERED
      Slow protected agent (step 3 Warning) -- would need a slow entry whose name or signer
             matches the protected list; a fake "Defender" entry proves nothing useful.
      Machine Run entries (step 4) -- HKLM Run is report-only; its message is read in the
             lab from the real SecurityHealth and VMware entries.
      WhatIf -- run the script by hand with $env:WhatIf = 'true' after any break.
      No-user branch -- needs a session with nobody logged on.

.PARAMETER RemediationTest
    After breaking, run Disable-NonEssentialStartupApps.ps1 and validate the outcome.
.PARAMETER Environment
    Physical (default) restores the machine when the run ends. Snapshot skips restore.
.PARAMETER Seed
    Replays an earlier run's random break selection exactly.
.PARAMETER BreakName
    Force specific breaks instead of a random selection.
.PARAMETER BreakCount
    How many breaks to apply when selecting randomly. Default 2.
.PARAMETER IncludeRebootBreaks
    Allow SlowUnsignedEntry (two reboots and two logons). Default off.
.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.
.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.
.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Disable-NonEssentialStartupApps_BreakTest.ps1
    Version      : 1.0.2
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-10
    Reporting    : C:\Temp\FixReport\Disable-NonEssentialStartupApps\

    1.0.2  Run acf46320121b (2026-11-10, BreakFailed, restored cleanly): sleeping before the
           window existed still read 2.2 s to Explorer while Teams read 14.6 s at the same
           logon. The fixture now creates its window first and then blocks the thread, so
           the queue exists and is not idle for 15 s. The logon wait from 1.0.1 worked.
    1.0.1  SlowUnsignedEntry after run 05839c5ccecd (2026-11-06, Dirty): the sleeping exe never
           created a window, so Explorer logged its 9708 within a second (0.4 to 0.9 s over
           three logons) and the entry was never slow; it now sleeps before creating a window.
           The resume could run Verify and Restore before the user had logged on and threw
           "No interactive user"; Get-LoggedOnUser now waits for the logon, and the evidence
           wait keys on this boot's 9708 instead of a sample count. Ungated four passed in
           3cdb7d9e9cde the same day.
    1.0.0  Initial: four ungated breaks and the two-logon SlowUnsignedEntry. Tracks script 2.0.0
           and sensor 1.0.0.

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

$ScriptUnderTest   = 'Disable-NonEssentialStartupApps'
$RemediationScript = Join-Path $PSScriptRoot '..\Disable-NonEssentialStartupApps.ps1'
$SensorScript      = Join-Path $PSScriptRoot '..\OneTimeSensor\startup_apps_health.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\StartupApps'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test not found at $RemediationScript" }
if (-not (Test-Path -LiteralPath $SensorScript))      { throw "Sensor not found at $SensorScript" }

# -- Fixture ------------------------------------------------------------------
$FixtureDir   = 'C:\Temp\DEXTest\StartupApps'
$MissingExe   = "$FixtureDir\gone.exe"
$SlowExe      = "$FixtureDir\DEXTestSlow.exe"
$SlowCommand  = 'DEXTestSlow.exe'       # what Shell-Core 9707/9708 log for an unquoted path with no arguments
$SlowThreshold = 10000

function Initialize-Fixture {
    $user = Get-LoggedOnUser
    $sid  = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { throw "Hive for $user ($sid) is not loaded under HKEY_USERS." }
    if (-not (Test-Path -LiteralPath (Get-StartupFolder))) { throw "Startup folder $(Get-StartupFolder) not found." }
    $log = $null
    try { $log = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration('Microsoft-Windows-Shell-Core/Operational') } catch { }
    if (-not $log -or -not $log.IsEnabled) { throw 'Microsoft-Windows-Shell-Core/Operational is absent or disabled; the script has no launch timings without it.' }
    $run = Get-Item -LiteralPath (Get-UserRunKey) -ErrorAction SilentlyContinue
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "user $user; Run values: $(if ($run) { @($run.GetValueNames()).Count } else { 0 }); Shell-Core enabled; slow samples for $SlowCommand so far: $((Get-SlowSamples).Count)"
}

function Remove-Fixture {
    # Sweep by prefix; the per-break Restore blocks have normally done all of this already.
    try {
        $run = Get-Item -LiteralPath (Get-UserRunKey) -ErrorAction SilentlyContinue
        if ($run) { foreach ($n in @($run.GetValueNames() | Where-Object { $_ -like 'DEXTest*' })) { Remove-ItemProperty -LiteralPath (Get-UserRunKey) -Name $n -ErrorAction SilentlyContinue } }
        foreach ($sub in 'Run', 'StartupFolder') {
            $k = Get-Item -LiteralPath (Get-ApprovedKey $sub) -ErrorAction SilentlyContinue
            if ($k) { foreach ($n in @($k.GetValueNames() | Where-Object { $_ -like 'DEXTest*' })) { Remove-ItemProperty -LiteralPath (Get-ApprovedKey $sub) -Name $n -ErrorAction SilentlyContinue } }
        }
        Get-ChildItem -LiteralPath (Get-StartupFolder) -Filter 'DEXTest*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-SlowExe
        Remove-MissingDirectories -Paths @('C:\Temp\DEXTest', $FixtureDir)
    } catch { }
}

# -- Helpers: user and registry ----------------------------------------------------

function Get-LoggedOnUser {
    # On a SYSTEM resume after a reboot nobody is logged on yet; everything per-user (verify,
    # restore, the script under test) needs the hive, so wait for the logon, up to 25 minutes.
    # Run 05839c5ccecd (2026-11-06) ended Dirty because Verify ran before the logon.
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $u -and [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        $deadline = (Get-Date).AddMinutes(25)
        while (-not $u -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        }
        if ($u) { Start-Sleep -Seconds 20 }   # let the profile and Explorer settle before touching the hive
    }
    if (-not $u) { throw "No interactive user is logged on; $ScriptUnderTest.ps1 resolves its user from Win32_ComputerSystem.UserName." }
    return $u
}
function Get-LoggedOnUserSid { ([Security.Principal.NTAccount](Get-LoggedOnUser)).Translate([Security.Principal.SecurityIdentifier]).Value }
function Get-UserProfilePath {
    $p = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$(Get-LoggedOnUserSid)" -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { throw "Profile folder for the logged-on user not found." }
    return $p
}
function Get-UserRunKey   { "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)\Software\Microsoft\Windows\CurrentVersion\Run" }
function Get-ApprovedKey  { param([string]$Sub) "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Sub" }
function Get-StartupFolder { Join-Path (Get-UserProfilePath) 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' }

function Get-RunValue { param([string]$Name) $k = Get-Item -LiteralPath (Get-UserRunKey) -ErrorAction SilentlyContinue; if (-not $k) { return $null }; $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
function Set-RunValue { param([string]$Name, [string]$Data) $k = Get-UserRunKey; if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }; Set-ItemProperty -LiteralPath $k -Name $Name -Value $Data -Type String -ErrorAction Stop }
function Remove-RunValue { param([string]$Name) if (Test-Path -LiteralPath (Get-UserRunKey)) { Remove-ItemProperty -LiteralPath (Get-UserRunKey) -Name $Name -ErrorAction SilentlyContinue } }

function Get-ApprovedBytes { param([string]$Sub, [string]$Name) $k = Get-Item -LiteralPath (Get-ApprovedKey $Sub) -ErrorAction SilentlyContinue; if (-not $k) { return $null }; $v = $k.GetValue($Name); if ($v -is [byte[]]) { return $v }; return $null }
function Format-Bytes { param([byte[]]$B) if (-not $B) { return '(none)' }; ($B | ForEach-Object { $_.ToString('X2') }) -join ' ' }
function Test-ApprovedDisabled { param([string]$Sub, [string]$Name) $b = Get-ApprovedBytes -Sub $Sub -Name $Name; return ($b -and $b.Length -ge 1 -and (($b[0] -band 0x0F) -eq 3)) }
function Set-ApprovedDisabled {
    param([string]$Sub, [string]$Name)
    $k = Get-ApprovedKey $Sub
    if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
    $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()))
    Set-ItemProperty -LiteralPath $k -Name $Name -Value $bytes -Type Binary -ErrorAction Stop
    return $bytes
}
function Remove-Approved { param([string]$Sub, [string]$Name) if (Test-Path -LiteralPath (Get-ApprovedKey $Sub)) { Remove-ItemProperty -LiteralPath (Get-ApprovedKey $Sub) -Name $Name -ErrorAction SilentlyContinue } }

function New-DanglingShortcut {
    param([string]$Name)
    $path = Join-Path (Get-StartupFolder) $Name
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($path); $sc.TargetPath = $MissingExe; $sc.Arguments = '/dex'; $sc.Save()
    return $path
}

function Get-MissingDirectories {
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    @($Paths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
}
function Remove-MissingDirectories {
    param([string[]]$Paths)
    $list = @($Paths | Where-Object { $_ }); [array]::Reverse($list)
    foreach ($p in $list) {
        if ((Test-Path -LiteralPath $p -PathType Container) -and @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
}

# -- Helpers: slow exe and Shell-Core samples ---------------------------------------

function New-SlowExe {
    if (-not (Test-Path -LiteralPath $FixtureDir)) { New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null }
    if (Test-Path -LiteralPath $SlowExe) { return }
    # Creates its (hidden) window first, so the thread owns a message queue, then blocks that
    # thread for 15 s WITHOUT pumping, then pumps for 2 s and exits. Explorer's 9708 tracks
    # WaitForInputIdle: a thread with a queue that is not sitting in GetMessage is "not idle"
    # until it is, or until the 30 s cap (the same reason real tray apps read 30 s on a busy
    # boot and 0.5 s on a quiet one). Two earlier shapes were not slow to Explorer: no window
    # at all (0.4 to 0.9 s, run 05839c5ccecd) and sleeping before the window existed (2.2 s,
    # run acf46320121b).
    $src = @'
using System; using System.Windows.Forms;
public class DexTestSlow {
    [STAThread] public static void Main() {
        var f = new Form(); f.Text = "DEXTestSlow"; f.ShowInTaskbar = false; f.Opacity = 0; f.Show();
        System.Threading.Thread.Sleep(15000);
        var t = new Timer(); t.Interval = 2000; t.Tick += (s, e) => { f.Close(); }; t.Start();
        Application.Run(f);
    }
}
'@
    Add-Type -TypeDefinition $src -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -OutputAssembly $SlowExe -OutputType WindowsApplication -ErrorAction Stop
}
function Remove-SlowExe {
    if (-not (Test-Path -LiteralPath $SlowExe)) { return }
    Get-Process -Name 'DEXTestSlow' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 10; $i++) { try { Remove-Item -LiteralPath $SlowExe -Force -ErrorAction Stop; break } catch { Start-Sleep -Seconds 1 } }
}

function Get-SlowSampleTimes {
    # TimeCreated of every 9708 for $SlowCommand in the last 14 days.
    $out = @(); $reader = $null
    try {
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Microsoft-Windows-Shell-Core/Operational', [System.Diagnostics.Eventing.Reader.PathType]::LogName, '*[System[EventID=9708 and TimeCreated[timediff(@SystemTime) <= 1209600000]]]')
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        while ($null -ne ($e = $reader.ReadEvent())) {
            $cmd = $null; foreach ($p in $e.Properties) { if ("$($p.Value)" -notmatch '^\d+$') { $cmd = "$($p.Value)".Trim() } }
            if ($cmd -eq $SlowCommand) { $out += $e.TimeCreated }
        }
    } catch { } finally { if ($reader) { $reader.Dispose() } }
    return @($out)
}

function Get-SlowSamples {
    # Milliseconds of every 9707/9708 pair for $SlowCommand in the last 14 days, oldest first.
    $out = @(); $reader = $null
    try {
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Microsoft-Windows-Shell-Core/Operational', [System.Diagnostics.Eventing.Reader.PathType]::LogName, '*[System[(EventID=9707 or EventID=9708) and TimeCreated[timediff(@SystemTime) <= 1209600000]]]')
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        $start = $null
        while ($null -ne ($e = $reader.ReadEvent())) {
            $cmd = $null; foreach ($p in $e.Properties) { if ("$($p.Value)" -notmatch '^\d+$') { $cmd = "$($p.Value)".Trim() } }
            if ($cmd -ne $SlowCommand) { continue }
            if ($e.Id -eq 9707) { $start = $e.TimeCreated } elseif ($start) { $out += [int]($e.TimeCreated - $start).TotalMilliseconds; $start = $null }
        }
    } catch { } finally { if ($reader) { $reader.Dispose() } }
    return @($out)
}
function Get-Median { param([int[]]$V) $s = @($V | Sort-Object); $n = $s.Count; if (-not $n) { return -1 }; if ($n % 2) { return $s[[int](($n - 1) / 2)] }; return [int](($s[$n / 2 - 1] + $s[$n / 2]) / 2) }

# -- Helpers: sensor and DEXRecords ---------------------------------------------------

function Get-SensorSnapshot {
    # Parsed JSON of startup_apps_health.ps1, or $null. Host-stream diagnostics only.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $raw = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SensorScript 2>&1 | ForEach-Object { "$_" }) -join '' } finally { $ErrorActionPreference = $prev }
    try { $o = $raw | ConvertFrom-Json } catch { Write-Host "           sensor output did not parse: $raw"; return $null }
    if ($raw.Length -gt 1024) { Write-Host "           sensor JSON is $($raw.Length) bytes, over Hub's 1 KB cap" }
    return $o
}
function Test-SensorVerdict {
    param($Snapshot, [string]$Name, [string]$Verdict)
    if (-not $Snapshot) { return $false }
    $row = @($Snapshot.Top | Where-Object { $_.N -eq $Name }) | Select-Object -First 1
    if (-not $row) { Write-Host "           sensor Top has no row for $Name (rows: $(($Snapshot.Top | ForEach-Object { $_.N }) -join ', '))"; return $false }
    if ($row.V -ne $Verdict) { Write-Host "           sensor verdict for $Name is '$($row.V)', expected '$Verdict'"; return $false }
    return $true
}
function Get-SensorCounts { $s = Get-SensorSnapshot; if (-not $s) { return @{ Entries = -1; Missing = -1; UserDisabled = -1 } }; @{ Entries = [int]$s.Entries; Missing = [int]$s.Missing; UserDisabled = [int]$s.UserDisabled } }

function Get-DexRecordValue {
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix)
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    $name = @($key.GetValueNames() | Where-Object { $_ -like "$ValueNamePrefix*" } | Select-Object -First 1)
    if ($name.Count -eq 0) { return $null }
    return "$($key.GetValue($name[0]))"
}
function Test-DexRecordMatches {
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix, [Parameter(Mandatory = $true)][string]$Pattern)
    $text = Get-DexRecordValue -ValueNamePrefix $ValueNamePrefix
    if ($null -eq $text) { Write-Host "           no $ValueNamePrefix value under $DexRecordsPath"; return $false }
    if ($text -notmatch $Pattern) { Write-Host "           $ValueNamePrefix = '$text' did not match '$Pattern'"; return $false }
    return $true
}

# -- Helpers: running the script under test --------------------------------------

function Get-RemediationVariables { @{ WhatIf = $null; SlowThresholdMs = $null } }

function Invoke-RemediationScript {
    param([Parameter(Mandatory = $true)][hashtable]$Variables)
    $savedEnv = @{}
    foreach ($k in @($Variables.Keys)) { $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        foreach ($k in @($Variables.Keys)) { [Environment]::SetEnvironmentVariable($k, $Variables[$k], 'Process') }
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1 | ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process') }
    }
    $sw.Stop()
    return @{ ExitCode = $rc; DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Variables = $Variables; Output = ($output | Out-String).Trim() }
}

# -- Break definitions ---------------------------------------------------------
$BreakCatalog = @(

    @{
        Name = 'DanglingRunEntry'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; DestructiveFlag = $null; Group = $null
        Methods = @(@{ Name = 'PlantRunValueWithMissingExe'; Apply = { Set-RunValue -Name 'DEXTestDangling' -Data "`"$MissingExe`" /dex" } })
        Capture = { @{ Sensor = Get-SensorCounts } }
        Verify  = {
            $ok = ("$(Get-RunValue 'DEXTestDangling')" -like "*gone.exe*") -and -not (Test-Path -LiteralPath $MissingExe)
            if (-not $ok) { Write-Host "           Run\DEXTestDangling missing or $MissingExe exists" }
            if (Test-ApprovedDisabled 'Run' 'DEXTestDangling') { Write-Host '           already disabled before the run'; $ok = $false }
            return ($ok -and (Test-SensorVerdict -Snapshot (Get-SensorSnapshot) -Name 'DEXTestDangling' -Verdict 'disable'))
        }
        Validate = {
            $dis = Test-ApprovedDisabled 'Run' 'DEXTestDangling'
            if (-not $dis) { Write-Host "           StartupApproved\Run\DEXTestDangling = $(Format-Bytes (Get-ApprovedBytes 'Run' 'DEXTestDangling')); expected 03 ..." }
            $kept = $null -ne (Get-RunValue 'DEXTestDangling')
            if (-not $kept) { Write-Host '           Run\DEXTestDangling was deleted; 2.0.0 must disable, not delete' }
            $step  = Test-DexRecordMatches -ValueNamePrefix 'Step01_' -Pattern '^\[Remediated\] target missing; disabled .*DEXTestDangling'
            $entry = Test-DexRecordMatches -ValueNamePrefix 'Entry_DEXTestDangling' -Pattern 'target MISSING.*; disabled$'
            return ($dis -and $kept -and $step -and $entry)
        }
        Restore = { param($Original) Remove-RunValue 'DEXTestDangling'; Remove-Approved 'Run' 'DEXTestDangling' }
    },

    @{
        Name = 'DanglingStartupShortcut'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; DestructiveFlag = $null; Group = $null
        Methods = @(@{ Name = 'PlantShortcutToMissingExe'; Apply = { New-DanglingShortcut -Name 'DEXTestDangling.lnk' | Out-Null } })
        Capture = { @{ Sensor = Get-SensorCounts } }
        Verify  = {
            $ok = (Test-Path -LiteralPath (Join-Path (Get-StartupFolder) 'DEXTestDangling.lnk')) -and -not (Test-Path -LiteralPath $MissingExe)
            if (-not $ok) { Write-Host '           shortcut missing or target exists' }
            if (Test-ApprovedDisabled 'StartupFolder' 'DEXTestDangling.lnk') { Write-Host '           already disabled before the run'; $ok = $false }
            return ($ok -and (Test-SensorVerdict -Snapshot (Get-SensorSnapshot) -Name 'DEXTestDangling.lnk' -Verdict 'disable'))
        }
        Validate = {
            $dis = Test-ApprovedDisabled 'StartupFolder' 'DEXTestDangling.lnk'
            if (-not $dis) { Write-Host "           StartupApproved\StartupFolder\DEXTestDangling.lnk = $(Format-Bytes (Get-ApprovedBytes 'StartupFolder' 'DEXTestDangling.lnk')); expected 03 ..." }
            $kept = Test-Path -LiteralPath (Join-Path (Get-StartupFolder) 'DEXTestDangling.lnk')
            if (-not $kept) { Write-Host '           shortcut was deleted; 2.0.0 must disable, not delete' }
            $step = Test-DexRecordMatches -ValueNamePrefix 'Step01_' -Pattern '^\[Remediated\] target missing; disabled .*DEXTestDangling\.lnk'
            return ($dis -and $kept -and $step)
        }
        Restore = { param($Original) Remove-Item -LiteralPath (Join-Path (Get-StartupFolder) 'DEXTestDangling.lnk') -Force -ErrorAction SilentlyContinue; Remove-Approved 'StartupFolder' 'DEXTestDangling.lnk' }
    },

    @{
        Name = 'UserDisabledDanglingLeft'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; DestructiveFlag = $null; Group = $null
        Methods = @(@{ Name = 'PlantDisabledRunValue'; Apply = {
            Set-RunValue -Name 'DEXTestOff' -Data "`"$MissingExe`" /off"
            $script:plantedOffBytes = Set-ApprovedDisabled 'Run' 'DEXTestOff'
        } })
        Capture = { @{ Sensor = Get-SensorCounts } }
        Verify  = {
            $ok = (Test-ApprovedDisabled 'Run' 'DEXTestOff') -and ($null -ne (Get-RunValue 'DEXTestOff'))
            if (-not $ok) { Write-Host '           DEXTestOff not planted as disabled' }
            $s = Get-SensorSnapshot
            $moved = $s -and ([int]$s.UserDisabled -ge 1)
            if (-not $moved) { Write-Host "           sensor UserDisabled = $(if ($s) { $s.UserDisabled } else { 'n/a' }); expected >= 1" }
            return ($ok -and $moved)
        }
        Validate = {
            param($Original)
            $now = Get-ApprovedBytes 'Run' 'DEXTestOff'
            $same = $now -and $script:plantedOffBytes -and ((Format-Bytes $now) -eq (Format-Bytes $script:plantedOffBytes))
            if (-not $same) {
                # After a resume the planted bytes are gone from memory; byte 0 = 3 and a non-zero FILETIME is the fallback.
                $same = $now -and (($now[0] -band 0x0F) -eq 3) -and (($now[4..11] | Measure-Object -Sum).Sum -gt 0)
                if (-not $same) { Write-Host "           StartupApproved\Run\DEXTestOff = $(Format-Bytes $now); expected the planted disabled record untouched" }
            }
            $entry = Test-DexRecordMatches -ValueNamePrefix 'Entry_DEXTestOff' -Pattern '^Run; DEXTestOff: Disabled; target MISSING.*already disabled, left$'
            $step  = Get-DexRecordValue -ValueNamePrefix 'Step01_'
            $untouched = ($null -eq $step) -or ($step -notmatch 'DEXTestOff')
            if (-not $untouched) { Write-Host "           Step01 names DEXTestOff: $step" }
            return ($same -and $entry -and $untouched)
        }
        Restore = { param($Original) Remove-RunValue 'DEXTestOff'; Remove-Approved 'Run' 'DEXTestOff' }
    },

    @{
        Name = 'MicrosoftSignedLeft'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; DestructiveFlag = $null; Group = $null
        Methods = @(@{ Name = 'PlantRunValueToNotepad'; Apply = { Set-RunValue -Name 'DEXTestSigned' -Data '"%windir%\System32\notepad.exe" /dex' } })
        Capture = { @{ Sensor = Get-SensorCounts } }
        Verify  = {
            param($Original)
            $ok = "$(Get-RunValue 'DEXTestSigned')" -like '*notepad.exe*'
            if (-not $ok) { Write-Host '           Run\DEXTestSigned not planted' }
            $s = Get-SensorSnapshot
            $counted = $s -and ([int]$s.Entries -eq ([int]$Original.Sensor.Entries + 1)) -and ([int]$s.Missing -eq [int]$Original.Sensor.Missing)
            if (-not $counted) { Write-Host "           sensor Entries/Missing = $(if ($s) { "$($s.Entries)/$($s.Missing)" } else { 'n/a' }); expected $([int]$Original.Sensor.Entries + 1)/$($Original.Sensor.Missing)" }
            return ($ok -and $counted)
        }
        Validate = {
            $left = -not (Test-ApprovedDisabled 'Run' 'DEXTestSigned')
            if (-not $left) { Write-Host "           DEXTestSigned was disabled: $(Format-Bytes (Get-ApprovedBytes 'Run' 'DEXTestSigned'))" }
            $entry = Test-DexRecordMatches -ValueNamePrefix 'Entry_DEXTestSigned' -Pattern '^Run; DEXTestSigned: (Enabled|NoRecord); target present; Microsoft; no launch timing$'
            return ($left -and $entry)
        }
        Restore = { param($Original) Remove-RunValue 'DEXTestSigned'; Remove-Approved 'Run' 'DEXTestSigned' }
    },

    @{
        Name = 'SlowUnsignedEntry'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $true; DestructiveFlag = $null; Group = $null
        Methods = @(@{ Name = 'PlantSleepingUnsignedExe'; Apply = { New-SlowExe; Set-RunValue -Name 'DEXTestSlow' -Data $SlowExe } })
        Capture = { @{ Sensor = Get-SensorCounts; MissingDirs = @(Get-MissingDirectories -Paths @('C:\Temp', 'C:\Temp\DEXTest', $FixtureDir)); SamplesBefore = (Get-SlowSamples).Count } }
        WaitForEvidence = {
            # Runs on each resume: wait for the logon (Get-LoggedOnUser blocks for it), then for the
            # 9708 of THIS boot's logon, then decide whether a second logon is still needed.
            param($Original)
            Get-LoggedOnUser | Out-Null
            $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
            $deadline = (Get-Date).AddMinutes(10)
            while ((Get-Date) -lt $deadline -and (Get-SlowSampleTimes | Where-Object { $_ -gt $boot }).Count -eq 0) { Start-Sleep -Seconds 10 }
            $s = Get-SlowSamples
            Write-DexStep -Status 'Info' -Name 'Evidence' -Message "$SlowCommand samples: $($s.Count) ($($s -join ', ') ms; before the run: $($Original.SamplesBefore)); boot $boot"
            if ($s.Count -lt 2) { return 'RebootAgain' }
            return 'Enough'
        }
        Verify  = {
            $s = Get-SlowSamples
            $med = Get-Median -V $s
            $ok = ($s.Count -ge 2) -and ($med -ge $SlowThreshold)
            if (-not $ok) { Write-Host "           $SlowCommand samples $($s -join ', ') ms; need two with median >= $SlowThreshold" }
            if (Test-ApprovedDisabled 'Run' 'DEXTestSlow') { Write-Host '           already disabled before the run'; $ok = $false }
            return ($ok -and (Test-SensorVerdict -Snapshot (Get-SensorSnapshot) -Name 'DEXTestSlow' -Verdict 'disable'))
        }
        Validate = {
            $dis = Test-ApprovedDisabled 'Run' 'DEXTestSlow'
            if (-not $dis) { Write-Host "           StartupApproved\Run\DEXTestSlow = $(Format-Bytes (Get-ApprovedBytes 'Run' 'DEXTestSlow')); expected 03 ..." }
            $kept = $null -ne (Get-RunValue 'DEXTestSlow')
            $step = Test-DexRecordMatches -ValueNamePrefix 'Step02_' -Pattern '^\[Remediated\] slow at logon; disabled .*DEXTestSlow'
            return ($dis -and $kept -and $step)
        }
        Restore = { param($Original) Remove-RunValue 'DEXTestSlow'; Remove-Approved 'Run' 'DEXTestSlow'; Remove-SlowExe; Remove-MissingDirectories -Paths @($Original.MissingDirs | Where-Object { $_ }) }
    }
)

function Get-BreakDefinition { param([Parameter(Mandatory = $true)][string]$Name) $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }

function Request-TestReboot {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Save-DexTestState -State $State
    Register-DexTestResume -State $State -BreakTestPath $SelfPath
    Write-DexStep -Status 'Info' -Name 'Reboot' -Message 'Rebooting; log on when the machine is back so Explorer times the planted entry. The run resumes automatically.'
    & shutdown.exe /r /t 15 /f | Out-Null
}

function Add-HarnessError {
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)]$ErrorRecord, [string]$Context = '')
    $text = "$(if ($Context) { "$Context`: " })$($ErrorRecord.Exception.Message) (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))"
    if ($State['HarnessError']) { $State['HarnessError'] = "$($State['HarnessError']); $text" } else { $State['HarnessError'] = $text }
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title "$ScriptUnderTest`_BreakTest" -Detail "Environment: $Environment"

if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try { & $def.Restore ([PSCustomObject]$b.OriginalState); Write-DexStep -Status 'Passed' -Name "Restore $($b.Name)" }
        catch { Add-HarnessError -State $state -ErrorRecord $_ -Context "Restore $($b.Name)"; Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message }
    }
    Remove-Fixture
    Unregister-DexTestResume -State $state
    $state.Phase = 'Restored'; $state.Overall = 'Restored'
    Write-DexTestResult -State $state | Out-Null
    Clear-DexTestState -State $state
    exit 0
}

if ($Resume) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    if (Test-DexRebootOccurred -State $state) {
        $state.RebootCount = [int]$state.RebootCount + 1
        Write-DexStep -Status 'Info' -Name 'Resume' -Message "Reboot #$($state.RebootCount) confirmed; resuming at phase '$($state.Phase)'."
    } else {
        Write-DexStep -Status 'Warning' -Name 'Resume' -Message 'No reboot detected since the run started.'
    }
    $RemediationTest = [bool]$state.RemediationTest
} else {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
    $state.RemediationTest = [bool]$RemediationTest
    Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"
}

$exitCode = 0

try {
    if ($state.Phase -eq 'Init') {
        Initialize-Fixture

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { $IncludeRebootBreaks -or -not $_.RequiresReboot })
        }
        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject ([object[]]$candidates.Clone()) -Random $state.Random -Count $BreakCount }
        $selected = @($selected)
        $state['DestructiveFlag'] = $false

        $applied = @()
        foreach ($def in $selected) {
            $method = (Get-DexRandomSubset -InputObject ([object[]]@($def.Methods).Clone()) -Random $state.Random -Count 1)[0]
            $original = & $def.Capture
            & $method.Apply
            if ($def.RequiresReboot) { $state.RequiresReboot = $true }
            $applied += @{ Name = $def.Name; Method = $method.Name; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = [bool]$def.RequiresReboot; Applied = $true; BreakVerified = $false; OriginalState = $original }
            Write-DexStep -Status 'Info' -Name "Break $($def.Name)" -Message "method '$($method.Name)' applied"
            $state.Breaks = $applied
            Save-DexTestState -State $state
        }
        $state.Breaks = $applied
        $state.Phase  = 'Broken'
        Save-DexTestState -State $state
        if ($state.RequiresReboot) { Request-TestReboot -State $state; exit 0 }
    }

    if ($state.Phase -eq 'Broken') {
        # Breaks that need logon evidence wait for it here and may ask for one more reboot (at most three in all).
        foreach ($b in $state.Breaks) {
            $def = Get-BreakDefinition -Name $b.Name
            if (-not $def.WaitForEvidence) { continue }
            $answer = & $def.WaitForEvidence ([PSCustomObject]$b.OriginalState)
            if ($answer -eq 'RebootAgain' -and [int]$state.RebootCount -lt 3) { Request-TestReboot -State $state; exit 0 }
        }
        $allVerified = $true
        foreach ($b in $state.Breaks) {
            $def = Get-BreakDefinition -Name $b.Name
            $ok  = [bool](& $def.Verify ([PSCustomObject]$b.OriginalState))
            $b.BreakVerified = $ok
            if ($ok) { Write-DexStep -Status 'Passed' -Name "Verify $($b.Name)" -Message 'component is genuinely broken' }
            else { $allVerified = $false; Write-DexStep -Status 'Failed' -Name "Verify $($b.Name)" -Message 'break did not land; remediation would be a false green' }
        }
        if (-not $allVerified) {
            $state.Phase = 'BreakFailed'; $state.Overall = 'BreakFailed'
            Save-DexTestState -State $state
            throw 'One or more breaks could not be verified; refusing to run remediation.'
        }
        $state.Phase = 'BreakVerified'
        Save-DexTestState -State $state
    }

    if ($state.Phase -eq 'BreakVerified') {
        if (-not $RemediationTest) {
            $state.Overall = 'BreakOnly'
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message 'skipped (-RemediationTest not supplied)'
        } else {
            $vars = Get-RemediationVariables
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript)) as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) with WhatIf and SlowThresholdMs unset"
            $state.Remediation = Invoke-RemediationScript -Variables $vars
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "exit $($state.Remediation.ExitCode) in $($state.Remediation.DurationSec) s"
            $state.Phase = 'Remediated'
            Save-DexTestState -State $state
        }
    }

    if ($state.Phase -eq 'Remediated') {
        $validation = @()
        foreach ($b in $state.Breaks) {
            $def    = Get-BreakDefinition -Name $b.Name
            $passed = [bool](& $def.Validate ([PSCustomObject]$b.OriginalState))
            $expected = if ($b.ExpectedOutcome -eq 'ExpectFixed') { 'entry disabled by remediation (not deleted)' } else { 'entry listed with its facts and left alone' }
            $validation += @{ Name = $b.Name; Expected = $expected; Actual = $(if ($passed) { 'as expected' } else { 'NOT as expected' }); Result = $(if ($passed) { 'Pass' } else { 'Fail' }) }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($b.Name)" -Message $expected
        }
        $state.Validation = $validation
        $state.Phase = 'Validated'
        $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        $state.Overall = if ($failedCount -eq 0) { 'Passed' } elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) { 'FalsePass' } else { 'Failed' }
        Save-DexTestState -State $state
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    Add-HarnessError -State $state -ErrorRecord $_
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try { & $def.Restore ([PSCustomObject]$b.OriginalState) }
        catch { $restoreFailed = $true; Add-HarnessError -State $state -ErrorRecord $_ -Context "Restore $($b.Name)"; Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message }
    }
    try { Remove-Fixture } catch { $restoreFailed = $true; Add-HarnessError -State $state -ErrorRecord $_ -Context 'Remove-Fixture' }
    if ($restoreFailed) { $state.Overall = 'Dirty'; Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required' }
    else { $state.Phase = 'Restored'; Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'machine returned to baseline' }
}

Unregister-DexTestResume -State $state

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
