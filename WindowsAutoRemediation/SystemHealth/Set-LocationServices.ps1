<#
.SYNOPSIS
    Set-LocationServices -- Turns Windows location services on or off for the device and
    for every signed-in user.

.DESCRIPTION
    Location has two layers, and both must agree for apps to get a location:

      Device  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\
              ConsentStore\location  Value = Allow | Deny
              The Settings > Privacy & security > Location "Location services" switch.
              Deny here blocks location for every user, whatever their own setting.

      User    HKU\<SID>\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\
              ConsentStore\location  Value = Allow | Deny
              (and ...\location\NonPackaged for "Let desktop apps access your location")
              The per-user "Let apps access your location" switch. Under SYSTEM, HKCU is
              SYSTEM's own hive, so each user is reached through HKEY_USERS by SID.

    The script writes the device value, then the user values in every loaded user hive
    (local and domain S-1-5-21-* and Entra ID S-1-12-1-* SIDs). Users who are signed out
    are not loaded and are skipped: on Disable the device Deny already covers them; on
    Enable a user with no value of their own defaults to Allow.

    On Enable it also sets the Geolocation service (lfsvc) back to Manual if it was
    Disabled. Policy (GPO or MDM) wins over these values; the script reports
    DisableLocation or LetAppsAccessLocation policies but does not remove them.

.NOTES
    Script Name  : Set-LocationServices.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System (elevation required for the HKLM value)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Timeout      : 30 seconds

    Script variables (UEM environment variables):
      LocationServices  Enable | Disable   (required; anything else exits 1)
      WhatIf            true | false       (default false; report only, change nothing)

    Exit codes: 0 = values set (or already set); 1 = bad input, not elevated, or a write failed.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$ErrorActionPreference = 'Stop'
$SCRIPT_VERSION = '1.0.0'

Write-Output "-- Set-LocationServices $SCRIPT_VERSION ---------------------------------"

# -- Input ----------------------------------------------------------------------
$mode = "$env:LocationServices".Trim()
if ($mode -notmatch '^(?i)(enable|disable)$') {
    Write-Output "  Script variable LocationServices must be Enable or Disable (got '$mode')."
    exit 1
}
$enable = $mode -match '^(?i)enable$'
$target = if ($enable) { 'Allow' } else { 'Deny' }
$whatIf = "$env:WhatIf" -match '^(?i)(true|1|yes)$'

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "  Not elevated: the device value is under HKLM. Run as SYSTEM or an administrator."
    exit 1
}

Write-Output ("  Requested: {0} (Value={1}){2}" -f $mode, $target, $(if ($whatIf) { '  [WhatIf: no changes]' } else { '' }))

$consentSubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$failed = 0

# Writes its status line to the output stream and counts a failed write in $script:failed.
# It returns nothing: a bool return would join the status line in an array that is always truthy.
function Set-ConsentValue {
    param([string]$KeyPath, [string]$Label)
    $current = $null
    try { $current = (Get-ItemProperty -Path $KeyPath -Name Value -ErrorAction Stop).Value } catch { }
    if ($current -eq $target) {
        Write-Output ("  {0}: already {1}" -f $Label, $target)
        return
    }
    $shown = if ($null -eq $current) { '(not set)' } else { $current }
    if ($whatIf) {
        Write-Output ("  {0}: {1} -> {2} (WhatIf)" -f $Label, $shown, $target)
        return
    }
    try {
        if (-not (Test-Path $KeyPath)) { New-Item -Path $KeyPath -Force | Out-Null }
        New-ItemProperty -Path $KeyPath -Name Value -PropertyType String -Value $target -Force | Out-Null
        Write-Output ("  {0}: {1} -> {2}" -f $Label, $shown, $target)
    } catch {
        Write-Output ("  {0}: FAILED to set {1}: {2}" -f $Label, $target, $_.Exception.Message)
        $script:failed++
    }
}

# -- Device ---------------------------------------------------------------------
Set-ConsentValue -KeyPath "HKLM:\$consentSubPath" -Label 'Device'

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
    if (-not (Set-ConsentValue -KeyPath $userKey -Label "User $name")) { $failed++ }
    if (-not (Set-ConsentValue -KeyPath "$userKey\NonPackaged" -Label "User $name desktop apps")) { $failed++ }
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
