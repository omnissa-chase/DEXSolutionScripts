<#
.SYNOPSIS
    Start-UserProfileCleanup_BreakTest -- plants stale, oversized local user profiles,
    then verifies Start-UserProfileCleanup.ps1 deletes the right one and only that one.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Start-UserProfileCleanup\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It creates local user accounts, loads
    their profiles, and runs a profile-deleting script against them. Run it only on
    a disposable VM or a marked test host. See Assert-DexTestHost in
    DEXTestFramework.psm1.

    THE SCRATCH COPY -- READ THIS BEFORE RUNNING
    Start-UserProfileCleanup.ps1 has hard-coded constants: it deletes a local
    profile only when it is idle for more than $DAYS_INACTIVE (30) days AND larger
    than $SIZE_THRESHOLD_MB (500), and it skips $ENROLLMENTUSER ("Administrator").
    A fixture cannot be 30 days old, so this harness never runs the script in place.
    Initialize-Fixture copies it to
        C:\Temp\FixReport\Start-UserProfileCleanup\scratch.ps1
    and applies four exact text replacements, aborting if any anchor is missing:
      $DAYS_INACTIVE = 30               -> $DAYS_INACTIVE = 0
      $SIZE_THRESHOLD_MB = 500          -> $SIZE_THRESHOLD_MB = 32
      $ENROLLMENTUSER="Administrator"   -> $ENROLLMENTUSER="DEXTestEnroll"
      $_.SID -ne $EnrollmentSID         -> $_.SID -ne $EnrollmentSID -and ($_.SID -in @('<fixture SIDs>'))   (1.1.0 filter)
    The fourth is the safety net: with the thresholds at 0 and 32 the unmodified
    filter would make every idle local profile on the host a deletion candidate.
    The scratch copy is regenerated after each fixture user is created so the SID
    list always names exactly the DEXTest* accounts and nothing else. Every other
    line of the script -- domain filter, enrollment-user exclusion, size walk,
    age test, Remove-WmiObject -- runs unchanged. $RemediationScript points at the
    scratch copy; the file under DiskCleanup\ is never executed by this harness.

    FIXTURES
    Three local accounts, all prefixed DEXTest, created with a random password that
    lives only in this process's memory and is never written anywhere:
      DEXTestProfile  oversized (96MB payload) and idle      -> must be deleted
      DEXTestKeep     under the 32MB threshold and idle      -> must survive
      DEXTestEnroll   oversized and idle, but named as the enrollment user in the
                      scratch copy                           -> must survive
    Each profile is materialised either through the Win32 CreateProfile API or by a
    throwaway interactive logon (Start-Process -Credential -LoadUserProfile), then
    its ProfileList load/unload stamps and NTUSER.DAT are backdated 60 days so the
    "inactive for N days" line in the script's output is meaningful even though
    $DAYS_INACTIVE is 0. Restore deletes the profile (Win32_UserProfile), the
    account, the folder and the ProfileList key. No other profile is ever touched.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
      ExpectFixed        -- the profile must be gone from disk, Win32_UserProfile
                            and ProfileList
      ExpectReportedOnly -- the profile must still exist, and the script's own
                            output is checked for whether it examined it
    The script writes no DEXRecords registry key; it reports through stdout, which
    the harness captures as Remediation.Output.

    REBOOTS
    No break in this catalog requires a reboot. The reboot plumbing is kept so the
    harness stays uniform with the rest of the family.

.PARAMETER RemediationTest
    After breaking, run the scratch copy of Start-UserProfileCleanup.ps1 and
    validate the outcome. Without this the script breaks and reports only.

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
    Script Name  : Start-UserProfileCleanup_BreakTest.ps1
    Version      : 1.1.0 (2026-11-05: scratch anchor follows the script's 1.1.0 candidate filter,
                   which considers every non-special, unloaded profile except the enrollment user's)
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated); local DEXTest accounts are candidates on any host
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Start-UserProfileCleanup\

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

$ScriptUnderTest   = 'Start-UserProfileCleanup'
$SourceScript      = Join-Path $PSScriptRoot '..\Start-UserProfileCleanup.ps1'
# The remediation that actually runs is the scratch copy described in the header, never $SourceScript.
$RemediationScript = 'C:\Temp\FixReport\Start-UserProfileCleanup\scratch.ps1'
$DexRecordsPath    = $null   # Start-UserProfileCleanup.ps1 writes no DEXRecords key; it reports via stdout
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
$FixturePrefix          = 'DEXTest'
$FixtureStaleUser       = 'DEXTestProfile'   # oversized + idle: must be deleted
$FixtureSmallUser       = 'DEXTestKeep'      # idle but under the size threshold: must survive
$FixtureEnrollUser      = 'DEXTestEnroll'    # oversized + idle but named $ENROLLMENTUSER in the scratch copy: must survive
$ScratchDaysInactive    = 0
$ScratchSizeThresholdMB = 32
$FixturePayloadMB       = 96
$FixtureBackdateDays    = 60
$FixturePayloadName     = 'DEXTest_Payload.bin'
$ProfileListPath        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

# Passwords for the fixture accounts, generated per run and kept only here.
$script:FixtureCredentials = @{}

function Initialize-Fixture {
    if (-not (Test-Path -LiteralPath $SourceScript)) { throw "Script under test not found at $SourceScript" }

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs -and $cs.PartOfDomain) {
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Host is joined to '$($cs.Domain)'. Since script 1.1.0 local accounts are candidates too, so the local DEXTest fixtures are selected here as on a workgroup host."
    }

    # A fresh profile is a copy of C:\Users\Default; the under-threshold fixture relies on that
    # copy staying well below the scratch threshold.
    $defaultMB = Get-ProfileSizeMB -Path 'C:\Users\Default'
    if ($defaultMB -gt ($ScratchSizeThresholdMB / 2)) {
        throw "C:\Users\Default is ${defaultMB}MB; the under-threshold fixture needs it below $($ScratchSizeThresholdMB / 2)MB. Raise `$ScratchSizeThresholdMB and `$FixturePayloadMB."
    }

    # Leftovers from an interrupted run would make Windows create DEXTestProfile.<HOST> folders
    # and confuse every probe; clear them before anything is captured.
    $leftovers = @(Get-FixtureLeftoverNames)
    if ($leftovers.Count -gt 0) {
        Write-DexStep -Status 'Warning' -Name 'Fixture' -Message "Removing leftovers from an earlier run: $($leftovers -join ', ')"
        foreach ($n in $leftovers) { Remove-FixtureUserCompletely -Name $n }
    }

    Add-FixtureUserEnvType
    # Build the scratch copy now so a missing anchor aborts before any account is created.
    Update-ScratchScript
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Scratch copy at $RemediationScript (days=$ScratchDaysInactive, sizeMB=$ScratchSizeThresholdMB, enrollment=$FixtureEnrollUser); Default profile ${defaultMB}MB"
}

function Remove-Fixture {
    # Sweep every DEXTest* account/profile/folder/ProfileList entry, then the scratch copy, so a
    # SID-specific script is never left around to be run by hand.
    $failed = @()
    foreach ($n in @(Get-FixtureLeftoverNames)) {
        try { Remove-FixtureUserCompletely -Name $n } catch { $failed += "$n ($($_.Exception.Message))" }
    }
    $script:FixtureCredentials = @{}
    if (Test-Path -LiteralPath $RemediationScript) {
        Remove-Item -LiteralPath $RemediationScript -Force -ErrorAction SilentlyContinue
    }
    if ($failed.Count -gt 0) { throw "Fixture remnants could not be removed: $($failed -join '; ')" }
}

# -- Helpers ------------------------------------------------------------------

function Add-FixtureUserEnvType {
    # userenv!CreateProfile builds C:\Users\<name> and the ProfileList entry without a logon.
    if ('DexTest.UserEnv' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace DexTest {
    public static class UserEnv {
        [DllImport("userenv.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        public static extern int CreateProfile(string pszUserSid, string pszUserName, StringBuilder pszProfilePath, uint cchProfilePath);
    }
}
'@ -ErrorAction Stop
}

function New-FixturePassword {
    # 28 chars from a CSPRNG plus a fixed complexity tail; returned as SecureString only.
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 24
    $rng.GetBytes($bytes)
    $rng.Dispose()
    $chars = foreach ($b in $bytes) { $alphabet[$b % $alphabet.Length] }
    $plain = (-join $chars) + 'Aa1!'
    $secure = New-Object System.Security.SecureString
    foreach ($c in $plain.ToCharArray()) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    return $secure
}

function Get-FixtureLeftoverNames {
    # Every DEXTest* name that still has an account, a profile object, a folder or a ProfileList entry.
    $names = @()
    $names += @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$FixturePrefix*" } | Select-Object -ExpandProperty Name)
    $names += @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$FixturePrefix*" } | ForEach-Object { ($_.Name -split '\.')[0] })
    $names += @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
                Where-Object { $_.LocalPath -like "C:\Users\$FixturePrefix*" } |
                ForEach-Object { ((Split-Path -Leaf $_.LocalPath) -split '\.')[0] })
    $names += @(Get-ChildItem -LiteralPath $ProfileListPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $img = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
                    if ($img -and $img -like "*\$FixturePrefix*") { ((Split-Path -Leaf $img) -split '\.')[0] }
                })
    return @($names | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-FixtureUserSid {
    param([Parameter(Mandatory = $true)][string]$Name)
    $u = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if ($u) { return $u.SID.Value }
    return $null
}

function Get-FixtureProfile {
    # Win32_UserProfile row for the account, matched by SID when the account exists, else by path.
    param([Parameter(Mandatory = $true)][string]$Name)
    $sid = Get-FixtureUserSid -Name $Name
    if ($sid) {
        $p = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
        if ($p) { return $p }
    }
    return (Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPath -eq "C:\Users\$Name" -or $_.LocalPath -like "C:\Users\$Name.*" } |
            Select-Object -First 1)
}

function Get-FixtureProfileListKeys {
    param([Parameter(Mandatory = $true)][string]$Name)
    return @(Get-ChildItem -LiteralPath $ProfileListPath -ErrorAction SilentlyContinue | Where-Object {
        $img = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        $img -and (($img -like "*\$Name") -or ($img -like "*\$Name.*"))
    })
}

function Get-FixtureProfileFolders {
    param([Parameter(Mandatory = $true)][string]$Name)
    return @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -eq $Name -or $_.Name -like "$Name.*" })
}

function Get-ProfileSizeMB {
    # Same walk as the script's Get-FolderSizeMB: .NET enumeration, reparse points skipped.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    [int64]$bytes = 0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            $dir = New-Object System.IO.DirectoryInfo($current)
            foreach ($f in $dir.EnumerateFiles()) { try { $bytes += $f.Length } catch { } }
            foreach ($d in $dir.EnumerateDirectories()) {
                if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($d.FullName) }
            }
        } catch { continue }
    }
    return [math]::Round($bytes / 1MB, 2)
}

function New-FixtureLocalUser {
    param([Parameter(Mandatory = $true)][string]$Name)
    $secure = New-FixturePassword
    $script:FixtureCredentials[$Name] = New-Object System.Management.Automation.PSCredential ("$env:COMPUTERNAME\$Name", $secure)
    New-LocalUser -Name $Name -Password $secure -Description 'DEX break-test fixture; safe to delete' `
        -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop | Out-Null
    # S-1-5-32-545 is BUILTIN\Users regardless of UI language; membership grants the interactive logon right.
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $Name -ErrorAction Stop
    return (Get-FixtureUserSid -Name $Name)
}

function New-FixtureProfileViaApi {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Sid)
    Add-FixtureUserEnvType
    $sb = New-Object System.Text.StringBuilder 260
    $hr = [DexTest.UserEnv]::CreateProfile($Sid, $Name, $sb, 260)
    # 0 = S_OK; 0x800700B7 = HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)
    if ($hr -ne 0 -and $hr -ne -2147024713) {
        throw ('CreateProfile failed for {0}: HRESULT 0x{1:X8}' -f $Name, $hr)
    }
    return $sb.ToString()
}

function New-FixtureProfileViaLogon {
    <#
        CreateProcessWithLogonW with LOGON_WITH_PROFILE loads (and creates, if needed) the
        profile exactly like an interactive logon would, then unloads it when cmd.exe exits.
        Needs the Secondary Logon service, which is Manual and starts on demand.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $cred = $script:FixtureCredentials[$Name]
    if (-not $cred) { throw "No credential held for fixture user $Name" }
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', 'exit' `
        -Credential $cred -LoadUserProfile -WorkingDirectory "$env:SystemRoot\System32" `
        -WindowStyle Hidden -Wait -ErrorAction Stop
}

function Set-FixtureProfileBackdate {
    <#
        Win32_UserProfile.LastUseTime is derived from the ProfileList load/unload stamps (and,
        on recent builds, NTUSER.DAT's timestamps). Both are pushed back so the fixture reads
        as idle. Best effort: $DAYS_INACTIVE is 0 in the scratch copy, so a profile unloaded a
        second ago already qualifies.
    #>
    param([Parameter(Mandatory = $true)][string]$Sid, [Parameter(Mandatory = $true)][string]$Path)
    $then = (Get-Date).AddDays(-$FixtureBackdateDays)
    $ft   = $then.ToFileTime()
    # 0xFFFFFFFF is an [int32] -1 in Windows PowerShell 5.1, so "-band 0xFFFFFFFF" kept all 64 bits and
    # the [uint32] cast of the low word threw (run 0c7bf67c2b55, 2026-11-02). Mask with an explicit int64.
    $mask = [int64]4294967295
    $high = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32](($ft -shr 32) -band $mask)), 0)
    $low  = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]($ft -band $mask)), 0)
    $key  = Join-Path $ProfileListPath $Sid
    if (Test-Path -LiteralPath $key) {
        foreach ($n in 'LocalProfileLoadTimeHigh', 'LocalProfileUnloadTimeHigh') {
            Set-ItemProperty -LiteralPath $key -Name $n -Value $high -Type DWord -ErrorAction SilentlyContinue
        }
        foreach ($n in 'LocalProfileLoadTimeLow', 'LocalProfileUnloadTimeLow') {
            Set-ItemProperty -LiteralPath $key -Name $n -Value $low -Type DWord -ErrorAction SilentlyContinue
        }
    }
    foreach ($f in 'NTUSER.DAT', 'ntuser.dat.LOG1', 'ntuser.dat.LOG2') {
        $p = Join-Path $Path $f
        if (Test-Path -LiteralPath $p) {
            try {
                [System.IO.File]::SetLastWriteTime($p, $then)
                [System.IO.File]::SetLastAccessTime($p, $then)
            } catch { }
        }
    }
}

function New-FixtureProfile {
    <#
        Creates the account, materialises the profile by the chosen method, plants the payload,
        backdates the stamps and regenerates the scratch copy so its SID allow-list includes
        the new account. Returns the profile folder path.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Api', 'Logon')][string]$Method,
        [int]$PayloadMB = 0
    )
    $sid = New-FixtureLocalUser -Name $Name

    if ($Method -eq 'Logon') {
        try {
            New-FixtureProfileViaLogon -Name $Name
        } catch {
            Write-DexStep -Status 'Warning' -Name "Fixture $Name" -Message "interactive logon load failed ($($_.Exception.Message)); falling back to CreateProfile"
            New-FixtureProfileViaApi -Name $Name -Sid $sid | Out-Null
        }
    } else {
        New-FixtureProfileViaApi -Name $Name -Sid $sid | Out-Null
    }

    $prof = Get-FixtureProfile -Name $Name
    if (-not $prof) { throw "Profile for $Name was not created (no Win32_UserProfile row)." }
    if ($prof.Loaded) { throw "Profile for $Name is still loaded; the script cannot delete a loaded profile." }
    $path = $prof.LocalPath

    if ($PayloadMB -gt 0) {
        $fs = [System.IO.File]::Create((Join-Path $path $FixturePayloadName))
        try { $fs.SetLength([int64]$PayloadMB * 1MB) } finally { $fs.Dispose() }
    }

    Set-FixtureProfileBackdate -Sid $sid -Path $path
    Update-ScratchScript
    return $path
}

function Remove-FixtureUserCompletely {
    # Profile object first (removes folder + ProfileList key), then the account, then any remnant.
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name -notlike "$FixturePrefix*") { throw "Refusing to remove '$Name': not a $FixturePrefix fixture." }

    $prof = Get-FixtureProfile -Name $Name
    if ($prof) {
        if ($prof.Loaded) { throw "Profile for $Name is loaded and cannot be removed." }
        Remove-CimInstance -InputObject $prof -ErrorAction SilentlyContinue
    }
    if (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) {
        Remove-LocalUser -Name $Name -ErrorAction SilentlyContinue
    }
    $script:FixtureCredentials.Remove($Name)

    foreach ($folder in @(Get-FixtureProfileFolders -Name $Name)) {
        Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $folder.FullName) {
            & takeown.exe /F $folder.FullName /R /D Y 2>&1 | Out-Null
            & icacls.exe $folder.FullName /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($key in @(Get-FixtureProfileListKeys -Name $Name)) {
        Remove-Item -LiteralPath $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    $remnants = @()
    if (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) { $remnants += 'account' }
    if (Get-FixtureProfile -Name $Name)                          { $remnants += 'Win32_UserProfile' }
    if (@(Get-FixtureProfileFolders -Name $Name).Count -gt 0)     { $remnants += 'folder' }
    if (@(Get-FixtureProfileListKeys -Name $Name).Count -gt 0)    { $remnants += 'ProfileList key' }
    if ($remnants.Count -gt 0) { throw "$Name not fully removed: $($remnants -join ', ') remain." }
}

function Update-ScratchScript {
    <#
        Copies Start-UserProfileCleanup.ps1 to $RemediationScript with the four replacements
        from the header. Throws if any anchor is missing, because a scratch copy without the
        SID allow-list would be a sledgehammer. With no DEXTest account present the allow-list
        is a SID that matches nobody.
    #>
    $text = [System.IO.File]::ReadAllText($SourceScript)

    $sids = @(Get-LocalUser -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like "$FixturePrefix*" } |
              ForEach-Object { $_.SID.Value })
    if ($sids.Count -eq 0) { $sids = @('S-1-0-0') }
    $sidList = ($sids | ForEach-Object { "'$_'" }) -join ','

    $edits = @(
        @{ Old = '$DAYS_INACTIVE = 30';             New = "`$DAYS_INACTIVE = $ScratchDaysInactive" },
        @{ Old = '$SIZE_THRESHOLD_MB = 500';        New = "`$SIZE_THRESHOLD_MB = $ScratchSizeThresholdMB" },
        @{ Old = '$ENROLLMENTUSER="Administrator"'; New = "`$ENROLLMENTUSER=`"$FixtureEnrollUser`"" },
        # 1.1.0 (2026-11-05) replaced the Win32_UserAccount domain filter with a SID exclusion of the enrollment user.
        @{ Old = '$_.SID -ne $EnrollmentSID';       New = "`$_.SID -ne `$EnrollmentSID -and (`$_.SID -in @($sidList))" }
    )
    foreach ($e in $edits) {
        if (-not $text.Contains($e.Old)) {
            throw "Scratch anchor not found in $SourceScript -- the script has changed; refusing to build the scratch copy: $($e.Old)"
        }
        $text = $text.Replace($e.Old, $e.New)
    }

    $dir = Split-Path -Path $RemediationScript -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $header = "# SCRATCH COPY generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by Start-UserProfileCleanup_BreakTest.ps1 -- confined to SIDs @($sidList). Do not run by hand.`r`n"
    [System.IO.File]::WriteAllText($RemediationScript, $header + $text, (New-Object System.Text.UTF8Encoding $false))
}

function Test-ScratchAllowsSid {
    param([Parameter(Mandatory = $true)][string]$Sid)
    if (-not (Test-Path -LiteralPath $RemediationScript)) { return $false }
    return ([System.IO.File]::ReadAllText($RemediationScript)).Contains("'$Sid'")
}

function Test-FixtureProfileGone {
    param([Parameter(Mandatory = $true)][string]$Name)
    (-not (Get-FixtureProfile -Name $Name)) -and
    (@(Get-FixtureProfileFolders -Name $Name).Count -eq 0) -and
    (@(Get-FixtureProfileListKeys -Name $Name).Count -eq 0)
}

function Test-FixtureProfilePresent {
    param([Parameter(Mandatory = $true)][string]$Name)
    $p = Get-FixtureProfile -Name $Name
    [bool]$p -and (Test-Path -LiteralPath $p.LocalPath) -and (@(Get-FixtureProfileListKeys -Name $Name).Count -gt 0)
}

function Test-RemediationOutputMatches {
    # The script reports via stdout only; the harness keeps that in $state.Remediation.Output.
    param([Parameter(Mandatory = $true)][string]$Pattern)
    if (-not $state -or -not $state.Remediation) { return $false }
    return ("$($state.Remediation.Output)" -match $Pattern)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
# Each break owns one account, so all three can share a run.
$BreakCatalog = @(

    @{
        Name            = 'StaleOversizedProfile'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'CreateProfileApi'
                Apply = { New-FixtureProfile -Name $FixtureStaleUser -Method Api -PayloadMB $FixturePayloadMB | Out-Null }
            },
            @{
                Name  = 'InteractiveLogonLoad'
                Apply = { New-FixtureProfile -Name $FixtureStaleUser -Method Logon -PayloadMB $FixturePayloadMB | Out-Null }
            }
        )
        Capture  = {
            @{
                AccountExisted = [bool](Get-LocalUser -Name $FixtureStaleUser -ErrorAction SilentlyContinue)
                FolderExisted  = (@(Get-FixtureProfileFolders -Name $FixtureStaleUser).Count -gt 0)
            }
        }
        # Broken means the script's own selection would pick it: a Win32_UserProfile row with a
        # usable LastUseTime, a folder over the scratch threshold, and its SID on the allow-list.
        Verify   = {
            $p = Get-FixtureProfile -Name $FixtureStaleUser
            if (-not $p -or $p.Loaded -or $null -eq $p.LastUseTime) { return $false }
            $sid = Get-FixtureUserSid -Name $FixtureStaleUser
            (Test-Path -LiteralPath $p.LocalPath) -and
            ((Get-ProfileSizeMB -Path $p.LocalPath) -gt $ScratchSizeThresholdMB) -and
            (Test-ScratchAllowsSid -Sid $sid)
        }
        Validate = { Test-FixtureProfileGone -Name $FixtureStaleUser }
        Restore  = {
            param($Original)
            Remove-FixtureUserCompletely -Name $FixtureStaleUser
        }
    },

    @{
        Name            = 'UnderThresholdProfileKept'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        # Negative control for the size test: idle, on the allow-list, but small. The script must
        # examine it (it prints the size and idle days) and leave it alone.
        Methods         = @(
            @{
                Name  = 'CreateProfileApi'
                Apply = { New-FixtureProfile -Name $FixtureSmallUser -Method Api | Out-Null }
            },
            @{
                Name  = 'InteractiveLogonLoad'
                Apply = { New-FixtureProfile -Name $FixtureSmallUser -Method Logon | Out-Null }
            }
        )
        Capture  = {
            @{
                AccountExisted = [bool](Get-LocalUser -Name $FixtureSmallUser -ErrorAction SilentlyContinue)
                FolderExisted  = (@(Get-FixtureProfileFolders -Name $FixtureSmallUser).Count -gt 0)
            }
        }
        Verify   = {
            $p = Get-FixtureProfile -Name $FixtureSmallUser
            if (-not $p -or $p.Loaded -or $null -eq $p.LastUseTime) { return $false }
            $sid = Get-FixtureUserSid -Name $FixtureSmallUser
            (Test-Path -LiteralPath $p.LocalPath) -and
            ((Get-ProfileSizeMB -Path $p.LocalPath) -le $ScratchSizeThresholdMB) -and
            (Test-ScratchAllowsSid -Sid $sid)
        }
        Validate = {
            (Test-FixtureProfilePresent -Name $FixtureSmallUser) -and
            (Test-RemediationOutputMatches -Pattern "Examining profile: $FixtureSmallUser") -and
            -not (Test-RemediationOutputMatches -Pattern "Deleted profile: [^\r\n]*\\$FixtureSmallUser")
        }
        Restore  = {
            param($Original)
            Remove-FixtureUserCompletely -Name $FixtureSmallUser
        }
    },

    @{
        Name            = 'EnrollmentUserProfileKept'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        # Negative control for the $ENROLLMENTUSER exclusion: oversized and idle, so only the name
        # match protects it. The script drops it before the examine loop, so it must appear
        # nowhere in the output and still exist afterwards.
        Methods         = @(
            @{
                Name  = 'CreateProfileApi'
                Apply = { New-FixtureProfile -Name $FixtureEnrollUser -Method Api -PayloadMB $FixturePayloadMB | Out-Null }
            },
            @{
                Name  = 'InteractiveLogonLoad'
                Apply = { New-FixtureProfile -Name $FixtureEnrollUser -Method Logon -PayloadMB $FixturePayloadMB | Out-Null }
            }
        )
        Capture  = {
            @{
                AccountExisted = [bool](Get-LocalUser -Name $FixtureEnrollUser -ErrorAction SilentlyContinue)
                FolderExisted  = (@(Get-FixtureProfileFolders -Name $FixtureEnrollUser).Count -gt 0)
            }
        }
        Verify   = {
            $p = Get-FixtureProfile -Name $FixtureEnrollUser
            if (-not $p -or $p.Loaded -or $null -eq $p.LastUseTime) { return $false }
            $sid = Get-FixtureUserSid -Name $FixtureEnrollUser
            (Test-Path -LiteralPath $p.LocalPath) -and
            ((Get-ProfileSizeMB -Path $p.LocalPath) -gt $ScratchSizeThresholdMB) -and
            (Test-ScratchAllowsSid -Sid $sid) -and
            (([System.IO.File]::ReadAllText($RemediationScript)).Contains("`$ENROLLMENTUSER=`"$FixtureEnrollUser`""))
        }
        Validate = {
            (Test-FixtureProfilePresent -Name $FixtureEnrollUser) -and
            -not (Test-RemediationOutputMatches -Pattern "Examining profile: $FixtureEnrollUser") -and
            -not (Test-RemediationOutputMatches -Pattern "Deleted profile: [^\r\n]*\\$FixtureEnrollUser")
        }
        Restore  = {
            param($Original)
            Remove-FixtureUserCompletely -Name $FixtureEnrollUser
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

Write-DexBanner -Title "Start-UserProfileCleanup_BreakTest" -Detail "Environment: $Environment"

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
