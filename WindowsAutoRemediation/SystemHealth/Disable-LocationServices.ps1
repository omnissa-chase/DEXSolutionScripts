<#
.SYNOPSIS
    Disable-LocationServices -- Set-LocationServices.ps1 with LocationServices preset to Disable, so it
    runs with no script variable. Keep it in step with that file: the PRESET block is
    the only difference. Turns Windows location services on or off for the device and
    for every signed-in user, with separate control of desktop (Win32) and modern
    (packaged) app access.

.DESCRIPTION
    Location is layered, and every layer above an app must say Allow for it to get a fix:

      Device  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\
              ConsentStore\location  Value = Allow | Deny
              The Settings > Privacy & security > Location "Location services" switch.
              Deny here blocks location for every user, whatever their own settings.

      User    HKU\<SID>\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\
              ConsentStore\location  Value = Allow | Deny
              The per-user "Let apps access your location" switch. Under SYSTEM, HKCU is
              SYSTEM's own hive, so each user is reached through HKEY_USERS by SID.

      Desktop ...\location\NonPackaged  Value = Allow | Deny
              "Let desktop apps access your location": one switch for every Win32 app.
              Its subkeys are per-exe usage records and are left alone.

      Modern  ...\location\<PackageFamilyName>  Value = Allow | Deny | Prompt
              One entry per packaged app that has asked for location, e.g.
              Microsoft.WindowsMaps_8wekyb3d8bbwe. An app with no entry follows the
              user switch until it first asks.

    The script writes the device value, then for every loaded user hive (local and domain
    S-1-5-21-* and Entra ID S-1-12-1-* SIDs) the user switch, the desktop switch and the
    modern app entries as the script variables direct. Users who are signed out are not
    loaded and are skipped: on Disable the device Deny already covers them.

    On Enable it also sets the Geolocation service (lfsvc) back to Manual if it was
    Disabled. Policy (GPO or MDM) wins over these values; the script reports
    DisableLocation or LetAppsAccessLocation policies but does not remove them.

.NOTES
    Script Name  : Disable-LocationServices.ps1
    Version      : 1.2.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System (elevation required for the HKLM value)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Timeout      : 30 seconds

    Script variables (UEM environment variables):
      LocationServices  Enable | Disable   Required. Device switch and each user's switch.
      DesktopApps       Allow | Deny | Keep
                        Win32 apps. Empty = follows LocationServices (Allow on Enable,
                        Deny on Disable). Keep leaves the current value.
      ModernApps        Allow | Deny | Keep | <list>
                        Allow or Deny sets every existing app entry. <list> is package
                        family names separated by commas or semicolons, wildcards allowed
                        (Microsoft.WindowsMaps_8wekyb3d8bbwe;Microsoft.Outlook*): listed
                        apps Allow, every other existing entry Deny; a listed exact name
                        with no entry yet gets one so the Allow holds before first use.
                        Empty = Keep: per-app entries hold the user's own choices and are
                        only rewritten when asked.
      WhatIf            true | false       Default false; report only, change nothing.

    Examples:
      Everything on                 LocationServices=Enable
      Win32 only, no modern apps    LocationServices=Enable  ModernApps=Deny
      Maps and Weather only         LocationServices=Enable  DesktopApps=Deny
                                    ModernApps=Microsoft.WindowsMaps*;Microsoft.BingWeather*
      Everything off                LocationServices=Disable

    Exit codes: 0 = values set (or already set); 1 = bad input, not elevated, or a write failed.

    1.2.0: PRESET block: each variable falls back to an in-script preset, so a copy
    with the preset filled in runs with no variables (Enable-LocationServices.ps1,
    Disable-LocationServices.ps1). 1.1.0: DesktopApps and ModernApps variables; per-app entries under each user's
    location key. 1.0.1: helper writes status lines only. 1.0.0: device and user switches.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$ErrorActionPreference = 'Stop'
$SCRIPT_VERSION = '1.2.0'
$SCRIPT_NAME    = 'Disable-LocationServices'

# ==============================================================================
# PRESET -- used when the script variable of the same name is not passed. Empty
# means the variable is required (LocationServices) or takes its default.
# Enable-LocationServices.ps1 and Disable-LocationServices.ps1 are this file with
# $PresetLocationServices filled in, for use where no script variable can be passed.
# ==============================================================================
$PresetLocationServices = 'Disable'
$PresetDesktopApps      = ''
$PresetModernApps       = ''

Write-Output "-- $SCRIPT_NAME $SCRIPT_VERSION ---------------------------------"

# -- Input ----------------------------------------------------------------------
if (-not "$env:LocationServices".Trim()) { $env:LocationServices = $PresetLocationServices }
if (-not "$env:DesktopApps".Trim())      { $env:DesktopApps      = $PresetDesktopApps }
if (-not "$env:ModernApps".Trim())       { $env:ModernApps       = $PresetModernApps }
$mode = "$env:LocationServices".Trim()
if ($mode -notmatch '^(?i)(enable|disable)$') {
    Write-Output "  Script variable LocationServices must be Enable or Disable (got '$mode')."
    exit 1
}
$enable = $mode -match '^(?i)enable$'
$target = if ($enable) { 'Allow' } else { 'Deny' }
$whatIf = "$env:WhatIf" -match '^(?i)(true|1|yes)$'

$desktop = "$env:DesktopApps".Trim()
if ($desktop -eq '') { $desktop = $target }
elseif ($desktop -notmatch '^(?i)(allow|deny|keep)$') {
    Write-Output "  Script variable DesktopApps must be Allow, Deny or Keep (got '$desktop')."
    exit 1
}
$desktop = (Get-Culture).TextInfo.ToTitleCase($desktop.ToLower())

$modern = "$env:ModernApps".Trim()
$modernList = @()
if ($modern -eq '') { $modern = 'Keep' }
elseif ($modern -match '^(?i)(allow|deny|keep)$') { $modern = (Get-Culture).TextInfo.ToTitleCase($modern.ToLower()) }
else {
    $modernList = @($modern -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $modern = 'List'
}

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "  Not elevated: the device value is under HKLM. Run as SYSTEM or an administrator."
    exit 1
}

Write-Output ("  Requested: {0} (Value={1}); desktop apps {2}; modern apps {3}{4}" -f $mode, $target, $desktop,
    $(if ($modern -eq 'List') { 'Allow only: ' + ($modernList -join ', ') } else { $modern }),
    $(if ($whatIf) { '  [WhatIf: no changes]' } else { '' }))

$consentSubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$failed = 0

# Writes its status line to the output stream and counts a failed write in $script:failed.
# It returns nothing: a bool return would join the status line in an array that is always truthy.
function Set-ConsentValue {
    param([string]$KeyPath, [string]$Label, [string]$Value)
    $current = $null
    try { $current = (Get-ItemProperty -Path $KeyPath -Name Value -ErrorAction Stop).Value } catch { }
    if ($current -eq $Value) {
        Write-Output ("  {0}: already {1}" -f $Label, $Value)
        return
    }
    $shown = if ([string]::IsNullOrEmpty($current)) { '(not set)' } else { $current }
    if ($whatIf) {
        Write-Output ("  {0}: {1} -> {2} (WhatIf)" -f $Label, $shown, $Value)
        return
    }
    try {
        if (-not (Test-Path $KeyPath)) { New-Item -Path $KeyPath -Force | Out-Null }
        New-ItemProperty -Path $KeyPath -Name Value -PropertyType String -Value $Value -Force | Out-Null
        Write-Output ("  {0}: {1} -> {2}" -f $Label, $shown, $Value)
    } catch {
        Write-Output ("  {0}: FAILED to set {1}: {2}" -f $Label, $Value, $_.Exception.Message)
        $script:failed++
    }
}

# -- Device ---------------------------------------------------------------------
Set-ConsentValue -KeyPath "HKLM:\$consentSubPath" -Label 'Device' -Value $target

# -- Users (loaded hives only) ----------------------------------------------------
$sids = @(Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.PSChildName } |
    Where-Object { $_ -match '^S-1-(5-21|12-1)-[\d-]+$' })

if ($sids.Count -eq 0) {
    Write-Output "  Users: no user hives loaded (nobody signed in); device value only."
}
foreach ($sid in $sids) {
    $name = $sid
    try { $name = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
    $userKey = "Registry::HKEY_USERS\$sid\$consentSubPath"
    Set-ConsentValue -KeyPath $userKey -Label "User $name" -Value $target

    if ($desktop -ne 'Keep') {
        Set-ConsentValue -KeyPath "$userKey\NonPackaged" -Label "User $name desktop apps" -Value $desktop
    }

    if ($modern -eq 'Keep') { continue }
    # Every packaged app that has asked for location; NonPackaged is the desktop switch, not an app.
    $apps = @(Get-ChildItem -Path $userKey -ErrorAction SilentlyContinue |
        ForEach-Object { $_.PSChildName } | Where-Object { $_ -ne 'NonPackaged' })
    if ($modern -eq 'List') {
        # A listed exact name with no entry gets one, so the Allow is in place before first use.
        foreach ($entry in $modernList) {
            if ($entry -notmatch '[\*\?]' -and $apps -notcontains $entry) { $apps += $entry }
        }
    }
    if ($apps.Count -eq 0) {
        Write-Output "  User $name modern apps: no app entries"
        continue
    }
    foreach ($app in $apps) {
        $value = $modern
        if ($modern -eq 'List') {
            $value = 'Deny'
            foreach ($entry in $modernList) { if ($app -like $entry) { $value = 'Allow'; break } }
        }
        Set-ConsentValue -KeyPath "$userKey\$app" -Label "User $name app $app" -Value $value
    }
}

# -- Geolocation service (Enable only) --------------------------------------------
if ($enable) {
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='lfsvc'" -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Output "  Service lfsvc: not present"
    } elseif ($svc.StartMode -eq 'Disabled') {
        if ($whatIf) {
            Write-Output "  Service lfsvc: Disabled -> Manual (WhatIf)"
        } else {
            try {
                Set-Service -Name lfsvc -StartupType Manual
                Write-Output "  Service lfsvc: Disabled -> Manual"
            } catch {
                Write-Output "  Service lfsvc: FAILED to set Manual: $($_.Exception.Message)"
                $failed++
            }
        }
    } else {
        Write-Output ("  Service lfsvc: {0}, {1}" -f $svc.StartMode, $svc.State)
    }
}

# -- Policy check (report only) ---------------------------------------------------
$policyNotes = @()
try {
    $p = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' -ErrorAction Stop
    if ($p.DisableLocation -eq 1) { $policyNotes += 'LocationAndSensors\DisableLocation=1 (location forced off)' }
} catch { }
try {
    $p = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -ErrorAction Stop
    if ($p.LetAppsAccessLocation -eq 1) { $policyNotes += 'AppPrivacy\LetAppsAccessLocation=1 (apps forced allow)' }
    if ($p.LetAppsAccessLocation -eq 2) { $policyNotes += 'AppPrivacy\LetAppsAccessLocation=2 (apps forced deny)' }
} catch { }
foreach ($n in $policyNotes) {
    Write-Output "  Policy: $n. Policy overrides this script; change it at its source (GPO/MDM)."
}

if ($failed -gt 0) {
    Write-Output "  Result: $failed write(s) failed."
    exit 1
}
Write-Output "  Result: location services $($mode.ToLower())d$(if ($whatIf) { ' (WhatIf)' })."
exit 0
