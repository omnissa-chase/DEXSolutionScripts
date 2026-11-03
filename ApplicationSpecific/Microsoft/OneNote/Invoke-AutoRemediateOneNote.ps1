<#
.SYNOPSIS
    Invoke-AutoRemediateOneNote -- Automated Microsoft OneNote (desktop) diagnostic and remediation.

.DESCRIPTION
    Sequenced OneNote health checks with remediation where safe. Desktop ONENOTE.EXE only;
    the Store app is out of scope. Self-contained; built for Workspace ONE remediation or
    standalone use. Network, disk, memory and Windows Update belong to the generic scripts.

    | Step | Name                         | Remediates On                       |
    |  2   | Crash and Hang History       | -- (report only; feeds 3)           |
    |  3   | COM Add-in Conflict          | Warning/Failed ($AllowDestructive)  |
    |  4   | Office-Disabled Items        | Warning ($ReenableDisabledItems)    |
    |  6   | Notebook Cache               | Warning ($AllowDestructive)         |
    |  7   | Sync Error Count             | -- (report only)                    |
    |  8   | Office C2R Update Health     | DISABLED (Word owns it)             |

    Pre-flight: no ONENOTE.EXE under the Click-to-Run root = "not installed", exit 0.
    Steps 2-4 and 8 are the common Office steps (spec C2-C4, C8); same engine as the Word
    script. Step 8 is suite-wide and ships Enabled = $false here. Spec C5 (AutoRecover)
    and C7 (Office Document Cache) do not apply: OneNote saves continuously and keeps
    its own cache, which steps 6 and 7 cover. One script per product until UEM has
    dynamic variables.

    Step 6 flags the notebook cache (%localappdata%\Microsoft\OneNote\16.0\cache) over
    $CacheSizeWarningMB, or 0.onecache at zero bytes while notebooks are registered.
    The rename is gated and refused while OneNote runs: unsynced local pages live
    there, and OneNote re-syncs every open notebook from the service afterwards.
    Step 7 reads OpenNotebooks\<id>; that schema is undocumented, so it reports any
    non-zero value whose name contains Error, HResult or Result, best effort.

    SYSTEM context: profile and hive come from Win32_ComputerSystem.UserName and
    HKU\<SID>, never $env:APPDATA. No interactive user: per-user steps Warn "skipped".

.PARAMETER CacheSizeWarningMB
    Notebook cache size that turns step 6 Warning. Default 4096.
.PARAMETER AllowDestructiveActions
    Enables steps 3 and 6. Default $false.
.PARAMETER CrashWarnCount7d
    Crash plus hang count in 7 days that turns step 2 Failed. Default 3.
.PARAMETER TemplateWarnMB
    Unused here; kept for family parity. Default 8.
.PARAMETER ReenableDisabledItems
    Lets step 4 clear Office's Resiliency entries. Default $false.
    Every input also reads $env:<name>.

.NOTES
    Script Name  : Invoke-AutoRemediateOneNote.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03 (1.0.0: first build from App_Remediation_Specs.md section 11)
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateOneNote {
param(
    [int] $CacheSizeWarningMB      = $(if ($env:CacheSizeWarningMB) { [int]$env:CacheSizeWarningMB } else { 4096 }),
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions) { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false }),
    [int] $CrashWarnCount7d        = $(if ($env:CrashWarnCount7d) { [int]$env:CrashWarnCount7d } else { 3 }),
    [int] $TemplateWarnMB          = $(if ($env:TemplateWarnMB) { [int]$env:TemplateWarnMB } else { 8 }),
    [bool]$ReenableDisabledItems   = $(if ($env:ReenableDisabledItems) { [System.Convert]::ToBoolean($env:ReenableDisabledItems) } else { $false })
)

# -- Product identity (the only product-specific constants) --
$_app      = 'OneNote'
$_exe      = 'ONENOTE.EXE'
$_proc     = 'ONENOTE'
$_regApp   = 'OneNote'
# Office's own modules; a fault in one of these is not an add-in's fault.
$_msModule = '^(onenote\w*|onmain|wwlib|mso\w*|oart\w*|office|msvc\w*|vcruntime\w*|ucrtbase|ntdll|kernel\w*|user32|gdi32|combase|ole\w*|rpcrt4|clr|coreclr|riched20|msptls|gfx|d2d1|dwrite)\.(dll|exe)$'
$_msAddin  = '^Microsoft\.|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync|Grammarly\.Microsoft|CopilotAddin'

# -- Pre-flight: Click-to-Run and the exe --
$_c2rConfig = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
$_c2rRoot   = $null
foreach ($p in @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
    if (Test-Path (Join-Path $p $_exe)) { $_c2rRoot = $p; break }
}
if (-not $_c2rConfig -or -not $_c2rRoot) {
    Write-Output "`r`n-- Invoke-AutoRemediate$_app -------------------------------------"
    Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output "   [Skipped] Click-to-Run Microsoft $_app is not installed on this device."
    Write-Output "----------------------------------------------------------------`r`n"
    exit 0
}

# -- Pre-flight: logged-on user --
$_loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$_shortName    = if ($_loggedOnUser) { $_loggedOnUser.Split('\')[-1] } else { $null }
$_userProfile  = if ($_shortName -and (Test-Path "C:\Users\$_shortName")) { "C:\Users\$_shortName" } else { $null }
$_userSid      = $null
if ($_loggedOnUser) {
    try { $_userSid = ([Security.Principal.NTAccount]$_loggedOnUser).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
}
$_hku = if ($_userSid) { "Registry::HKEY_USERS\$_userSid" } else { $null }
$_officeVer = '16.0'
if ($_c2rConfig.VersionToReport) {
    $parts = $_c2rConfig.VersionToReport.Split('.')
    if ($parts.Count -ge 2) { $_officeVer = "$($parts[0]).$($parts[1])" }
}
$_noUser   = @{ Status = 'Warning'; Message = 'No interactive user resolved -- per-user check skipped.' }
$_nbKey    = if ($_hku) { "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp\OpenNotebooks" } else { $null }
$_cacheDir = if ($_userProfile) { Join-Path $_userProfile "AppData\Local\Microsoft\OneNote\$_officeVer\cache" } else { $null }

$regPath = "HKLM:\Software\AirWatch\Extension\DEXRecords\${_regApp}Errors"

# -- Cross-step state (filled by step 2, read by 3) --
$script:_crash = @{ Count = 0; Hangs = 0; Module = ''; ModulePath = ''; ThirdParty = $false }
$script:_blame = @()   # step names that found something to blame

function _DirMB([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [math]::Round(($(if ($sum) { $sum } else { 0 })) / 1MB, 1)
}
function _AppOpen { [bool](Get-Process -Name $_proc -ErrorAction SilentlyContinue) }
function _Gate { if ($AllowDestructiveActions) { '' } else { ' -- set $AllowDestructiveActions=$true to apply' } }
function _Notebooks { if ($_nbKey -and (Test-Path $_nbKey)) { @(Get-ChildItem $_nbKey -ErrorAction SilentlyContinue) } else { @() } }
function _AddinKeys {
    $out = @()
    $subs = @("Software\Microsoft\Office\$_regApp\Addins", "Software\Microsoft\Office\$_officeVer\$_regApp\Addins")
    foreach ($s in $subs) {
        if ($_hku) { $out += "$_hku\$s" }
        $out += "HKLM:\$s"
        $out += "HKLM:\SOFTWARE\WOW6432Node\$($s.Substring(9))"
    }
    return $out | Where-Object { Test-Path $_ }
}
function _ActiveThirdPartyAddins {
    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($k in @(_AddinKeys)) {
        Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
            $lb = (Get-ItemProperty $_.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
            if ($lb -eq 3 -and $_.PSChildName -notmatch $_msAddin) {
                $list.Add([PSCustomObject]@{ Name = $_.PSChildName; Path = $_.PSPath; Scope = $(if ($k -like 'Registry::*') { 'user' } else { 'machine' }) })
            }
        }
    }
    return $list
}
function _AddinNamedByCrash($addins) {
    if (-not $script:_crash.ThirdParty -or -not $script:_crash.Module) { return $null }
    $token = [IO.Path]::GetFileNameWithoutExtension($script:_crash.Module)
    foreach ($a in $addins) {
        foreach ($part in ($a.Name -split '[.\s_-]')) {
            if ($part.Length -ge 4 -and ($token -like "*$part*" -or $part -like "*$token*")) { return $a }
        }
    }
    return $null
}
function _DecodeResiliency([string]$key) {
    $names = @()
    if (-not (Test-Path $key)) { return $names }
    $item = Get-Item $key -ErrorAction SilentlyContinue
    foreach ($v in $item.GetValueNames()) {
        $bytes = $item.GetValue($v)
        if ($bytes -is [byte[]]) {
            $text = [Text.Encoding]::Unicode.GetString($bytes)
            $segs = @($text -split "`0" | Where-Object { $_ -match '[A-Za-z]{3,}' })
            $names += $(if ($segs.Count -gt 0) { $segs[0].Trim() } else { $v })
        } else { $names += $v }
    }
    return $names
}

# -- Step Definitions --
$Steps = @(

    @{
        Name             = 'Crash and Hang History'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $since = (Get-Date).AddDays(-7)
            $ev = @()
            try {
                $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; Id = 1000, 1002; StartTime = $since } -ErrorAction SilentlyContinue |
                        Where-Object { $_.Properties.Count -gt 0 -and "$($_.Properties[0].Value)" -ieq $_exe })
            } catch {
                return @{ Status = 'Warning'; Message = "Unable to query the Application log: $($_.Exception.Message)" }
            }
            if ($ev.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "No $_exe crash (1000) or hang (1002) events in the last 7 days." }
            }
            $crashes = @($ev | Where-Object { $_.Id -eq 1000 })
            $hangs   = @($ev | Where-Object { $_.Id -eq 1002 })
            $script:_crash.Count = $ev.Count
            $script:_crash.Hangs = $hangs.Count
            $last = $crashes | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $mod = ''; $modPath = ''
            if ($last) {
                if ($last.Properties.Count -gt 3)  { $mod     = "$($last.Properties[3].Value)" }
                if ($last.Properties.Count -gt 11) { $modPath = "$($last.Properties[11].Value)" }
                if (-not $mod -and $last.Message -match 'Faulting module name:\s*([^,\r\n]+)') { $mod = $Matches[1].Trim() }
                $script:_crash.Module     = $mod
                $script:_crash.ModulePath = $modPath
                $script:_crash.ThirdParty = ($mod -and $mod -notmatch $_msModule -and $modPath -notmatch '\\Microsoft Office\\root\\|\\Windows\\(System32|SysWOW64)\\')
            }
            $detail = "$($crashes.Count) crash(es), $($hangs.Count) hang(s) in 7 days"
            if ($mod) { $detail += "; last faulting module $mod$(if ($modPath) { " ($modPath)" })$(if ($script:_crash.ThirdParty) { ' -- not an Office module, likely an add-in' })" }
            if ($ev.Count -ge $CrashWarnCount7d) {
                return @{ Status = 'Failed'; Message = "$detail (threshold $CrashWarnCount7d). Step 3 uses this." }
            }
            return @{ Status = 'Warning'; Message = "$detail (threshold $CrashWarnCount7d)." }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'COM Add-in Conflict'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            $addins = @(_ActiveThirdPartyAddins)
            if ($addins.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "No active third-party $_app add-ins (user and machine hives)." }
            }
            $named = _AddinNamedByCrash $addins
            $names = ($addins | ForEach-Object { "$($_.Name) [$($_.Scope)]" }) -join ', '
            if ($named) {
                $script:_blame += 'add-in'
                return @{ Status = 'Failed'; Message = "Crash module $($script:_crash.Module) matches add-in '$($named.Name)'; $($addins.Count) active third-party add-in(s): $names. Will set LoadBehavior=0 on '$($named.Name)'$(_Gate)." }
            }
            if ($script:_crash.ThirdParty) { $script:_blame += 'add-in' }
            return @{ Status = 'Warning'; Message = "$($addins.Count) active third-party add-in(s): $names. Disabling the first one is the remediation$(_Gate)." }
        }
        ResolutionScript = {
            $addins = @(_ActiveThirdPartyAddins)
            if ($addins.Count -eq 0) { return @{ Remediated = $false } }
            $target = _AddinNamedByCrash $addins
            if (-not $target) { $target = $addins[0] }
            Set-ItemProperty -Path $target.Path -Name 'LoadBehavior' -Value 0 -ErrorAction Stop
            return @{ Remediated = $true; Message = "Add-in '$($target.Name)' [$($target.Scope)] set to LoadBehavior=0. Restart $_app to take effect." }
        }
    },

    @{
        Name             = 'Office-Disabled Items'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $ReenableDisabledItems
        DetectionScript  = {
            if (-not $_hku) { return $_noUser }
            $base = "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp\Resiliency"
            $disabled = @(_DecodeResiliency "$base\DisabledItems")
            $startup  = @(_DecodeResiliency "$base\StartupItems")
            if ($disabled.Count -eq 0 -and $startup.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "$_app has not disabled any add-ins or startup items." }
            }
            $script:_blame += 'disabled-items'
            $all = @($disabled + $startup | Select-Object -First 6) -join ', '
            $gate = if ($ReenableDisabledItems) { 'Clearing the entries so they load next launch.' } else { 'Set $ReenableDisabledItems=$true to clear them; Office disabled these after a failure, so confirm first.' }
            return @{ Status = 'Warning'; Message = "$($disabled.Count) disabled item(s), $($startup.Count) disabled startup item(s): $all. $gate" }
        }
        ResolutionScript = {
            $base = "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp\Resiliency"
            $n = 0
            foreach ($sub in 'DisabledItems', 'StartupItems') {
                $k = "$base\$sub"
                if (-not (Test-Path $k)) { continue }
                foreach ($v in (Get-Item $k).GetValueNames()) { Remove-ItemProperty -Path $k -Name $v -ErrorAction Stop; $n++ }
            }
            return @{ Remediated = ($n -gt 0); Message = "Cleared $n Resiliency entr$(if ($n -eq 1) { 'y' } else { 'ies' }); items load at $_app's next start." }
        }
    },

    @{
        Name             = 'Notebook Cache'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            if (-not $_userProfile -or -not $_hku) { return $_noUser }
            if (-not (Test-Path -LiteralPath $_cacheDir)) {
                return @{ Status = 'Passed'; Message = "No notebook cache folder yet ($_cacheDir); $_app has not opened a notebook." }
            }
            $mb   = _DirMB $_cacheDir
            $nbs  = @(_Notebooks).Count
            $one  = Get-Item -LiteralPath (Join-Path $_cacheDir '0.onecache') -ErrorAction SilentlyContinue
            $corrupt = ($nbs -gt 0 -and $one -and $one.Length -eq 0)
            if ($mb -lt $CacheSizeWarningMB -and -not $corrupt) {
                return @{ Status = 'Passed'; Message = "Notebook cache is ${mb}MB (threshold ${CacheSizeWarningMB}MB) for $nbs registered notebook(s)." }
            }
            $why  = if ($corrupt) { "0.onecache is zero bytes while $nbs notebook(s) are registered (cache is not holding content)" } else { "is ${mb}MB (threshold ${CacheSizeWarningMB}MB)" }
            $open = if (_AppOpen) { " $_app is open, so the rename waits for a run with $_app closed." } else { '' }
            return @{ Status = 'Warning'; Message = "Notebook cache $why. Rename to cache_<stamp>.bak; $_app re-syncs every open notebook from the service. Unsynced local pages stay in the backup$(_Gate).$open" }
        }
        ResolutionScript = {
            if (_AppOpen) { return @{ Remediated = $false; Status = 'Warning'; Message = "Notebook cache rename skipped: $_app is open. Re-run with $_app closed." } }
            $new = "cache_$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            Rename-Item -LiteralPath $_cacheDir -NewName $new -ErrorAction Stop
            return @{ Remediated = $true; Message = "Notebook cache renamed to $new; $_app rebuilds it and re-syncs on next launch. Delete the backup once the user confirms nothing is missing." }
        }
    },

    @{
        Name             = 'Sync Error Count'
        Order            = 7
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_hku) { return $_noUser }
            $nbs = @(_Notebooks)
            if ($nbs.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "No notebooks registered under OpenNotebooks." }
            }
            $bad = @()
            foreach ($nb in $nbs) {
                $p = Get-ItemProperty $nb.PSPath -ErrorAction SilentlyContinue
                if (-not $p) { continue }
                $name = $nb.PSChildName
                $pathVal = $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and "$($_.Value)" -match '^(https?://|\\\\|[A-Za-z]:\\)' } | Select-Object -First 1
                if ($pathVal) { $name = Split-Path "$($pathVal.Value)" -Leaf }
                $errs = @($p.PSObject.Properties | Where-Object { $_.Name -match 'Error|HResult|Result' -and ($_.Value -is [int] -or $_.Value -is [uint32] -or $_.Value -is [long]) -and [int64]$_.Value -ne 0 })
                if ($errs.Count -gt 0) { $bad += "$name ($($errs[0].Name)=0x$('{0:X8}' -f (([int64]$errs[0].Value) -band 0xFFFFFFFF)))" }
            }
            if ($bad.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "$($nbs.Count) notebook(s) registered; none carries a sync error code." }
            }
            return @{ Status = 'Warning'; Message = "$($bad.Count) of $($nbs.Count) notebook(s) report a sync error: $(($bad | Select-Object -First 4) -join ', '). Report only: sync errors are permission or service problems, not local state." }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Office C2R Update Health'
        Order            = 8
        Enabled          = $false   # suite-wide: enabled only in the Word script
        ResolveOnWarning = $false
        DetectionScript  = {
            $version = $_c2rConfig.VersionToReport
            if ($_c2rConfig.UpdatesEnabled -eq 'False') {
                return @{ Status = 'Warning'; Message = "C2R updates are disabled (UpdatesEnabled=False). Version: $version. Updates are managed by policy or MDM -- no remediation attempted." }
            }
            $u = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Updates' -ErrorAction SilentlyContinue
            if ($u -and $u.ErrorCode -and $u.ErrorCode -ne 0) {
                return @{ Status = 'Warning'; Message = "C2R update last failed with error $('0x{0:X8}' -f $u.ErrorCode). Version: $version. Updates are MDM-managed; reported only." }
            }
            if (-not $_c2rConfig.CDNBaseUrl) {
                return @{ Status = 'Warning'; Message = "C2R update channel (CDNBaseUrl) not configured. Version: $version." }
            }
            return @{ Status = 'Passed'; Message = "C2R updates enabled. Version: $version." }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine --
$activeSteps = @($Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order })
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output "`r`n-- Invoke-AutoRemediate$_app -------------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   User: $(if ($_loggedOnUser) { $_loggedOnUser } else { 'unknown' })   Office $($_c2rConfig.VersionToReport)"
Write-Output '----------------------------------------------------------------'

foreach ($step in $activeSteps) {
    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    $shouldRemediate = ($status -eq 'Failed') -or ($status -eq 'Warning' -and $step.ResolveOnWarning)
    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            $rr = & $step.ResolutionScript | Select-Object -Last 1
            if ($rr -is [hashtable]) {
                $remediated = [bool]$rr.Remediated
                if ($rr.Status)  { $status  = $rr.Status }
                if ($rr.Message) { $message = $rr.Message }
            } else { $remediated = $true }
        } catch {
            $remError = $_.Exception.Message
        }
    }

    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }
    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$remNote"

    $results.Add([PSCustomObject]@{ Order = $step.Order; Name = $step.Name; Status = $status; Message = $message; Remediated = $remediated; RemError = $remError })
}

# -- Summary --
$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count

Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Output "----------------------------------------------------------------`r`n"

# -- Registry Reporting --
try {
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null }
    (Get-Item -Path $regPath).GetValueNames() | ForEach-Object { Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue }
    Set-ItemProperty -Path $regPath -Name 'LastScanTime'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'ScriptVersion'   -Value '1.0.0'       -Type String
    Set-ItemProperty -Path $regPath -Name 'TotalSteps'      -Value $results.Count -Type DWord
    Set-ItemProperty -Path $regPath -Name 'PassedCount'     -Value $passed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'WarningCount'    -Value $warnings      -Type DWord
    Set-ItemProperty -Path $regPath -Name 'FailedCount'     -Value $failed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'RemediatedCount' -Value $remCount      -Type DWord
    Set-ItemProperty -Path $regPath -Name 'CrashCount7d'    -Value $script:_crash.Count -Type DWord
    if ($script:_crash.Module) { Set-ItemProperty -Path $regPath -Name 'LastFaultModule' -Value $script:_crash.Module -Type String }

    $results | Where-Object { $_.Status -ne 'Passed' } | ForEach-Object {
        $valueName = 'Step{0:D2}_{1}' -f $_.Order, ($_.Name -replace '[^A-Za-z0-9]', '')
        $tag       = if ($_.Remediated) { '[Remediated]' } else { "[$($_.Status)]" }
        Set-ItemProperty -Path $regPath -Name $valueName -Value "$tag $($_.Message)" -Type String
    }
    Write-Output "  [Registry] Results written to $regPath"
} catch {
    Write-Output "  [Registry] Write failed: $($_.Exception.Message)"
}

if ($failed -gt 0) { exit 1 }
exit 0
}

# -- entry point (params live inside the function: UEM ignores script-scope params)

Invoke-AutoRemediateOneNote
Exit 0
