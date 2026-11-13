<#
.SYNOPSIS
    office_cache_mb -- size in MB of the Microsoft Office cache folders that Clear-OfficeCache.ps1
    would clear for the signed-in user (the non-optional catalogue entries).

.DESCRIPTION
    Integer sensor. Measures the same folders as the clear script, for the console user only
    (per-user data; Hub runs the sensor as SYSTEM, so the profile path comes from ProfileList).
    -1 when Microsoft Office is not installed or no user is signed in. 0 when installed and empty.
    A value at or above 1000 MB is where the clear script earns its keep.

.NOTES
    Sensor Name  : office_cache_mb
    Data Type    : Integer
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Timeout      : 30 seconds
    Companion    : Clear-OfficeCache.ps1 (same catalogue), app_cache_health.ps1 (all products)

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1
$InstallMarkers = @('{PF}\Microsoft Office\root\Office16\WINWORD.EXE', '{PF86}\Microsoft Office\root\Office16\WINWORD.EXE', '{Local}\Microsoft\Office\16.0')
$Catalogue = @(
    @{ Name = 'Office Document Cache (Upload Center)'; Paths = @('{Local}\Microsoft\Office\16.0\OfficeFileCache'); Optional = $false },
    @{ Name = 'Web service and Backstage caches'; Paths = @('{Local}\Microsoft\Office\16.0\WebServiceCache', '{Local}\Microsoft\Office\16.0\BackstageInAppNavCache'); Optional = $false },
    @{ Name = 'Office temporary internet files'; Paths = @('{Local}\Microsoft\Windows\INetCache\Content.MSO', '{Local}\Microsoft\Windows\INetCache\Content.Word'); Optional = $false },
    @{ Name = 'Web add-in cache (add-ins re-download, may ask to sign in again)'; Paths = @('{Local}\Microsoft\Office\16.0\Wef'); Optional = $true }
)
function Expand-Token { param([string]$Path, $User)
    $p = $Path.Replace('{PF}', [string]$env:ProgramFiles).Replace('{PF86}', [string]${env:ProgramFiles(x86)})
    if ($User) { $p = $p.Replace('{Profile}', $User.Profile).Replace('{Local}', $User.Local).Replace('{Roaming}', $User.Roaming).Replace('{Packages}', $User.Packages) }
    return $p
}
function Resolve-Folders { param([string]$Pattern, $User, [string]$Exclude)
    $p = Expand-Token $Pattern $User
    if ($p -match '\{(Profile|Local|Roaming|Packages)\}') { return ,@() }
    $hits = @()
    if ($p -match '[\*\?]') { $hits = @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object { $_.FullName }) }
    elseif (Test-Path -LiteralPath $p -PathType Container) { $hits = @($p) }
    if ($Exclude) { $hits = @($hits | Where-Object { $_ -notmatch $Exclude }) }
    return ,@($hits)
}
function Test-Marker { param([string]$Pattern, $User)
    $p = Expand-Token $Pattern $User
    if ($p -match '\{(Profile|Local|Roaming|Packages)\}') { return $false }
    if ($p -match '[\*\?]') { return (@(Get-Item -Path $p -Force -ErrorAction SilentlyContinue).Count -gt 0) }
    return (Test-Path -LiteralPath $p)
}
function Get-ConsoleUser {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if (-not $cs -or -not $cs.UserName) { return $null }
    try {
        $sid = ([Security.Principal.NTAccount]([string]$cs.UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
        $p = [string](Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $null }
        return @{ Name = [string]$cs.UserName; Sid = $sid; Profile = $p; Local = "$p\AppData\Local"; Roaming = "$p\AppData\Roaming"; Packages = "$p\AppData\Local\Packages" }
    } catch { return $null }
}
function Measure-Folder { param([string]$Path)
    # .NET walk with a try/catch per directory: an order of magnitude faster than Get-ChildItem -Recurse on cache folders with thousands of small files.
    $s = [long]0; $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $di = New-Object System.IO.DirectoryInfo $d; foreach ($f in $di.GetFiles()) { $s += $f.Length }; foreach ($sub in $di.GetDirectories()) { if (($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($sub.FullName) } } } catch { }
    }
    return $s
}
function Measure-Catalogue { param($Catalogue, $User, [switch]$IncludeOptional)
    $bytes = [long]0; $folders = 0
    foreach ($e in @($Catalogue | Where-Object { -not $_.Optional -or $IncludeOptional })) {
        foreach ($pat in @($e.Paths)) { foreach ($f in (Resolve-Folders $pat $User $e.Exclude)) { $bytes += Measure-Folder $f; $folders++ } }
    }
    return @{ Bytes = $bytes; Folders = $folders }
}
function Test-Installed { param($Markers, $User)
    foreach ($m in $Markers) { if (Test-Marker $m $null) { return $true } }
    if ($User) { foreach ($m in $Markers) { if (Test-Marker $m $User) { return $true } } }
    return $false
}
$u = Get-ConsoleUser
if (-not $u -or -not (Test-Installed $InstallMarkers $u)) { Write-Output -1; exit 0 }
$m = Measure-Catalogue $Catalogue $u
Write-Output ([int][math]::Round($m.Bytes / 1MB))
exit 0