<#
.SYNOPSIS
    Installs TroubleshootWizard and wires up the launch pipeline:
    files -> locked-down folder, event source, omniwiz: URL protocol, event-triggered scheduled task.

.DESCRIPTION
    Must run elevated (Workspace ONE runs it as SYSTEM). What it does:

      1. Copies the payload to C:\ProgramData\AirWatch\Extensions\TroubleshootWizard
         (flat files + DiagSteps\ + Resources\), removing files from older layouts.
      2. Clears Mark-of-the-Web (Unblock-File) so RemoteSigned policies don't block it.
      3. Locks the folder ACL: SYSTEM + Administrators = Full, Users = Read/Execute.
         Inheritance from C:\ProgramData is removed (by default it lets any user CREATE
         files there, which would let a standard user drop a steps JSON of their own).
      4. Registers the Application-log event source 'TroubleshootingWizard'.
      5. Registers the omniwiz: URL protocol machine-wide (HKLM\SOFTWARE\Classes\omniwiz).
         Clicking omniwiz://Network runs Send-TroubleshootWizardEvent.ps1 as the user,
         which validates the name and writes event 9001.
      6. Registers scheduled task \Omnissa\TroubleshootWizard\TroubleshootWizard-OnEvent.
         Trigger: Application log, source TroubleshootingWizard, ID 9001.
         Principal: BUILTIN\Users (runs in the interactive user's session).
         Action: Invoke-TroubleshootWizardFromEvent.ps1 (fixed command line, no event data).
      7. Writes HKLM\SOFTWARE\AirWatch\Extensions\TroubleshootWizard\Version for detection.

    Deployment modes (auto-detected or forced with -Mode):
      SFD  - payload files sit next to this script (Workspace ONE Software Distribution).
      ZIP  - TroubleshootWizard.zip sits next to this script (Product Provisioning).

.PARAMETER Mode
    'Auto' (default), 'SFD' or 'ZIP'.

.PARAMETER Destination
    Install folder. Default: C:\ProgramData\AirWatch\Extensions\TroubleshootWizard

.PARAMETER ZipName
    Payload archive name in ZIP mode. Default: TroubleshootWizard.zip

.PARAMETER ScriptExecutionPolicy
    Execution policy baked into the task and protocol-handler command lines.
    'Bypass' (default) for unsigned scripts; 'AllSigned' once you sign the package.

.PARAMETER TaskRunLevel
    'Highest' (default): admins get an elevated wizard without a UAC prompt, so
    service/firewall fixes work; standard users run unelevated regardless.
    'Limited': never elevate.

.PARAMETER UrlScheme
    URL protocol scheme to register. Default: omniwiz

.PARAMETER SkipUrlProtocol
    Don't register the URL protocol (e.g. you only trigger from WS1 scripts).

.PARAMETER SkipScheduledTask
    Don't register the scheduled task (files only).

.EXAMPLE
    .\Install-TroubleshootWizard.ps1
.EXAMPLE
    .\Install-TroubleshootWizard.ps1 -Mode ZIP -ScriptExecutionPolicy AllSigned

.NOTES
    Exit codes: 0 success, 1 fatal, 2 completed with non-fatal errors.
    Log: %TEMP%\TroubleshootWizard_Install.log  (C:\Windows\Temp when run as SYSTEM)

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding()]
param(
    [ValidateSet('Auto','SFD','ZIP')]
    [string] $Mode                  = 'Auto',
    [string] $Destination           = 'C:\ProgramData\AirWatch\Extensions\TroubleshootWizard',
    [string] $ZipName               = 'TroubleshootWizard.zip',
    [ValidateSet('Bypass','RemoteSigned','AllSigned')]
    [string] $ScriptExecutionPolicy = 'Bypass',
    [ValidateSet('Highest','Limited')]
    [string] $TaskRunLevel          = 'Highest',
    [ValidatePattern('^[a-z][a-z0-9+.-]{1,30}$')]
    [string] $UrlScheme             = 'omniwiz',
    [switch] $SkipUrlProtocol,
    [switch] $SkipScheduledTask
)

$AppVersion   = '1.1.0'
$RegKeyPath   = 'HKLM:\SOFTWARE\AirWatch\Extensions\TroubleshootWizard'
$EventSource  = 'TroubleshootingWizard'
$EventLogName = 'Application'
$EventId      = 9001
$TaskPath     = '\Omnissa\TroubleshootWizard\'
$TaskName     = 'TroubleshootWizard-OnEvent'

$ErrorActionPreference = 'Stop'
$nonFatalErrors = 0

# ---------------------------------------------
#  LOGGING
# ---------------------------------------------
$logFile = Join-Path $env:TEMP 'TroubleshootWizard_Install.log'
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    Write-Output $line
}

Write-Log "====== TroubleshootWizard Installer v$AppVersion ======"
Write-Log "Script root : $PSScriptRoot"
Write-Log "Destination : $Destination"
Write-Log "Mode param  : $Mode"
Write-Log "Exec policy : $ScriptExecutionPolicy"
Write-Log "Task level  : $TaskRunLevel"
Write-Log "Log file    : $logFile"

# ---------------------------------------------
#  ELEVATION CHECK
# ---------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Installer must run elevated (SYSTEM or an administrator). Current: $($identity.Name)" 'ERROR'
    exit 1
}
Write-Log "Running as   : $($identity.Name)"

# ---------------------------------------------
#  AUTO-DETECT MODE
# ---------------------------------------------
$zipPath     = Join-Path $PSScriptRoot $ZipName
$probeScript = Join-Path $PSScriptRoot 'TroubleshootWizard.ps1'

if ($Mode -eq 'Auto') {
    if (Test-Path $zipPath) {
        $Mode = 'ZIP';  Write-Log "Auto-detected mode: ZIP (found $ZipName)"
    } elseif (Test-Path $probeScript) {
        $Mode = 'SFD';  Write-Log 'Auto-detected mode: SFD (found TroubleshootWizard.ps1)'
    } else {
        Write-Log "Cannot determine install mode. Neither '$ZipName' nor 'TroubleshootWizard.ps1' found next to this script." 'ERROR'
        exit 1
    }
}

# ---------------------------------------------
#  PAYLOAD DEFINITION
# ---------------------------------------------
$requiredFiles = @(
    'TroubleshootWizard.ps1',
    'TroubleshootWizard-UI.ps1',
    'TroubleshootWizard-Common.ps1',
    'Send-TroubleshootWizardEvent.ps1',
    'Invoke-TroubleshootWizardFromEvent.ps1',
    'UI-Modern.xaml',
    'UI-Modern-Light.xaml',
    'Branding.json'
)
$requiredFolders = @('DiagSteps')
$optionalFolders = @('Resources')

# Files from older layouts that must not linger in the install folder.
$legacyFiles = @(
    'Troubleshooter-Modular.ps1', 'Troubleshooter-Modular-Ex.ps1', 'Troubleshooter-Modular.log',
    'LaunchScheduledTask.ps1', 'LaunchScheduledTask.cmd', 'LaunchScheduledTask.vbs', 'LaunchScheduledTaskPrint.vbs',
    'LaunchTroubleshooter.ps1', 'LaunchTroubleshooter.vbs', 'DiagStep.log', 'TroubleshootWizard.log',
    'omnissa.png', 'hub.png',
    'NetworkDiagSteps.json', 'AudioBluetoothDiagSteps.json', 'PrinterDiagSteps.json',
    'VPNDiagSteps.json', 'WindowsUpdateDiagSteps.json'
)

# ---------------------------------------------
#  PREPARE SOURCE FOLDER
# ---------------------------------------------
$sourceDir  = $PSScriptRoot
$extractDir = Join-Path $env:TEMP 'TroubleshootWizard_Extract'

if ($Mode -eq 'ZIP') {
    Write-Log "ZIP mode - extracting $ZipName..."
    if (-not (Test-Path $zipPath)) { Write-Log "ZIP file not found: $zipPath" 'ERROR'; exit 1 }

    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
        Write-Log "Extracted to: $extractDir"
    } catch {
        Write-Log "Extraction failed: $_" 'ERROR'; exit 1
    }
    $children = @(Get-ChildItem $extractDir)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) { $sourceDir = $children[0].FullName } else { $sourceDir = $extractDir }
    Write-Log "Source folder: $sourceDir"
}

# ---------------------------------------------
#  VALIDATE SOURCE
# ---------------------------------------------
Write-Log "Validating payload in: $sourceDir"
$missing = @()
foreach ($f in $requiredFiles) {
    if (Test-Path (Join-Path $sourceDir $f)) { Write-Log "  OK      : $f" } else { $missing += $f; Write-Log "  MISSING : $f" 'WARNING' }
}
foreach ($d in $requiredFolders) {
    $p = Join-Path $sourceDir $d
    $jsonCount = if (Test-Path $p) { @(Get-ChildItem $p -Filter *.json -File).Count } else { 0 }
    if ($jsonCount -gt 0) { Write-Log "  OK      : $d\ ($jsonCount steps file(s))" } else { $missing += "$d\"; Write-Log "  MISSING : $d\ (needs at least one *.json)" 'WARNING' }
}
foreach ($d in $optionalFolders) {
    if (Test-Path (Join-Path $sourceDir $d)) { Write-Log "  OK      : $d\" } else { Write-Log "  absent  : $d\ (optional)" }
}
if ($missing.Count -gt 0) {
    Write-Log "$($missing.Count) required item(s) missing. Aborting." 'ERROR'
    exit 1
}

# ---------------------------------------------
#  COPY FILES
# ---------------------------------------------
Write-Log "Creating destination: $Destination"
try { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
catch { Write-Log "Could not create destination folder: $_" 'ERROR'; exit 1 }

foreach ($f in $legacyFiles) {
    $p = Join-Path $Destination $f
    if (Test-Path $p) {
        try { Remove-Item $p -Force; Write-Log "  Removed legacy file: $f" }
        catch { Write-Log "  Could not remove legacy file $f : $_" 'WARNING'; $nonFatalErrors++ }
    }
}

Write-Log 'Copying files...'
$copied = 0
foreach ($f in $requiredFiles) {
    try { Copy-Item -Path (Join-Path $sourceDir $f) -Destination (Join-Path $Destination $f) -Force; $copied++; Write-Log "  Copied : $f" }
    catch { Write-Log "  FAILED : $f - $_" 'ERROR'; $nonFatalErrors++ }
}
foreach ($d in ($requiredFolders + $optionalFolders)) {
    $src = Join-Path $sourceDir $d
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $Destination $d
    try {
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        Copy-Item -Path $src -Destination $dst -Recurse -Force
        $n = @(Get-ChildItem $dst -Recurse -File).Count
        $copied += $n
        Write-Log "  Copied : $d\ ($n file(s))"
    } catch { Write-Log "  FAILED : $d\ - $_" 'ERROR'; $nonFatalErrors++ }
}

# Clear Mark-of-the-Web so RemoteSigned policies treat the scripts as local.
try { Get-ChildItem $Destination -Recurse -File | Unblock-File -ErrorAction SilentlyContinue; Write-Log 'Cleared Mark-of-the-Web on payload.' }
catch { Write-Log "Unblock-File: $_" 'WARNING' }

# ---------------------------------------------
#  LOCK DOWN FOLDER ACL
# ---------------------------------------------
# SYSTEM (S-1-5-18) and Administrators (S-1-5-32-544): Full. Users (S-1-5-32-545): Read & Execute.
# Inheritance removed so the ProgramData "Users can create files" ACE no longer applies.
Write-Log 'Hardening folder permissions...'
try {
    # Path passed unquoted on purpose: PowerShell quotes it when needed in both 5.1 and 7.x.
    $icaclsArgs = @(
        $Destination, '/inheritance:r',
        '/grant:r', '*S-1-5-18:(OI)(CI)(F)', '*S-1-5-32-544:(OI)(CI)(F)', '*S-1-5-32-545:(OI)(CI)(RX)',
        '/T', '/C', '/Q'
    )
    $out = & icacls.exe @icaclsArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls exit $LASTEXITCODE : $out" }
    $out = & icacls.exe $Destination /setowner '*S-1-5-32-544' /T /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Log "icacls /setowner exit $LASTEXITCODE : $out" 'WARNING' }

    # Verify: no write-capable ACE for Users/Everyone/Authenticated Users.
    $writeMask = [System.Security.AccessControl.FileSystemRights]'CreateFiles, CreateDirectories, WriteData, AppendData, Delete, WriteDacl, WriteOwner, ChangePermissions, TakeOwnership'
    $bad = (Get-Acl $Destination).Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and
        $_.IdentityReference.Value -match '^(BUILTIN\\Users|Everyone|NT AUTHORITY\\Authenticated Users|S-1-5-32-545|S-1-1-0|S-1-5-11)$' -and
        ($_.FileSystemRights -band $writeMask)
    }
    if ($bad) { Write-Log 'ACL verification FAILED: non-admin principals still have write rights.' 'ERROR'; $nonFatalErrors++ }
    else      { Write-Log 'ACL verified: SYSTEM/Administrators full, Users read-only.' }
} catch {
    Write-Log "ACL hardening failed: $_" 'ERROR'; $nonFatalErrors++
}

# ---------------------------------------------
#  EVENT SOURCE
# ---------------------------------------------
try {
    $exists = $false
    try { $exists = [System.Diagnostics.EventLog]::SourceExists($EventSource) } catch { $exists = $false }
    if (-not $exists) {
        [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $EventLogName)
        Write-Log "Event source '$EventSource' registered in the $EventLogName log."
    } else {
        Write-Log "Event source '$EventSource' already registered."
    }
} catch {
    Write-Log "Failed to register event source: $_" 'ERROR'; $nonFatalErrors++
}

# ---------------------------------------------
#  URL PROTOCOL  (HKLM, machine-wide)
# ---------------------------------------------
$sendScript   = Join-Path $Destination 'Send-TroubleshootWizardEvent.ps1'
$invokeScript = Join-Path $Destination 'Invoke-TroubleshootWizardFromEvent.ps1'
$psCommon     = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy $ScriptExecutionPolicy -WindowStyle Hidden"

if (-not $SkipUrlProtocol) {
    try {
        $baseKey = "HKLM:\SOFTWARE\Classes\$UrlScheme"
        $cmdKey  = "$baseKey\shell\open\command"
        New-Item -Path $cmdKey -Force | Out-Null
        Set-ItemProperty -Path $baseKey -Name '(default)'    -Value "URL:$UrlScheme Protocol (TroubleshootWizard)"
        Set-ItemProperty -Path $baseKey -Name 'URL Protocol' -Value ''
        Set-ItemProperty -Path $cmdKey  -Name '(default)'    -Value "conhost.exe --headless $psCommon -File `"$sendScript`" -Url `"%1`""
        Write-Log "URL protocol '$UrlScheme`:' registered (HKLM)."

        # A per-user key would override the machine key; drop a stale one for the current user if present.
        $hkcu = "HKCU:\Software\Classes\$UrlScheme"
        if (Test-Path $hkcu) { Remove-Item $hkcu -Recurse -Force; Write-Log "Removed per-user override $hkcu" 'WARNING' }
    } catch {
        Write-Log "Failed to register URL protocol: $_" 'ERROR'; $nonFatalErrors++
    }
} else { Write-Log 'URL protocol registration skipped.' }

# ---------------------------------------------
#  SCHEDULED TASK  (event-triggered, runs as the interactive user)
# ---------------------------------------------
if (-not $SkipScheduledTask) {
    $runLevelXml  = if ($TaskRunLevel -eq 'Highest') { 'HighestAvailable' } else { 'LeastPrivilege' }
    $subscription = "<QueryList><Query Id=`"0`" Path=`"$EventLogName`"><Select Path=`"$EventLogName`">*[System[Provider[@Name='$EventSource'] and EventID=$EventId]]</Select></Query></QueryList>"
    $subscriptionXml = [System.Security.SecurityElement]::Escape($subscription)
    $argsXml = [System.Security.SecurityElement]::Escape("--headless $psCommon -File `"$invokeScript`"")
    $destXml = [System.Security.SecurityElement]::Escape($Destination)

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>TroubleshootWizard installer</Author>
    <Description>Shows the TroubleshootWizard in the logged-on user's session when event $EventId from source '$EventSource' is written to the $EventLogName log. The command line is fixed; the script validates the event and only launches steps files that exist in the ACL-locked install folder.</Description>
    <Version>$AppVersion</Version>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$subscriptionXml</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="InteractiveUsers">
      <GroupId>S-1-5-32-545</GroupId>
      <RunLevel>$runLevelXml</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="InteractiveUsers">
    <Exec>
      <Command>conhost.exe</Command>
      <Arguments>$argsXml</Arguments>
      <WorkingDirectory>$destXml</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    try {
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Xml $taskXml -Force | Out-Null
        } else {
            $tmpXml = Join-Path $env:TEMP 'TroubleshootWizard-Task.xml'
            [IO.File]::WriteAllText($tmpXml, $taskXml, [Text.Encoding]::Unicode)
            $out = & schtasks.exe /Create /TN "$TaskPath$TaskName" /XML "$tmpXml" /F 2>&1
            Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) { throw "schtasks exit $LASTEXITCODE : $out" }
        }
        Write-Log "Scheduled task registered: $TaskPath$TaskName (principal BUILTIN\Users, $runLevelXml)"
    } catch {
        Write-Log "Failed to register scheduled task: $_" 'ERROR'; $nonFatalErrors++
    }
} else { Write-Log 'Scheduled task registration skipped.' }

# ---------------------------------------------
#  REGISTRY (detection + metadata)
# ---------------------------------------------
try {
    if (-not (Test-Path $RegKeyPath)) { New-Item $RegKeyPath -Force | Out-Null }
    Set-ItemProperty -Path $RegKeyPath -Name 'Version'     -Value $AppVersion -Force
    Set-ItemProperty -Path $RegKeyPath -Name 'InstallPath' -Value $Destination -Force
    Set-ItemProperty -Path $RegKeyPath -Name 'InstallDate' -Value (Get-Date -Format 'yyyy-MM-dd') -Force
    Set-ItemProperty -Path $RegKeyPath -Name 'UrlScheme'   -Value $(if ($SkipUrlProtocol) { '' } else { $UrlScheme }) -Force
    Set-ItemProperty -Path $RegKeyPath -Name 'TaskName'    -Value $(if ($SkipScheduledTask) { '' } else { "$TaskPath$TaskName" }) -Force
    Set-ItemProperty -Path $RegKeyPath -Name 'EventSource' -Value $EventSource -Force
    Write-Log "Registry key written: $RegKeyPath"
} catch {
    Write-Log "Failed to write registry key: $_" 'WARNING'; $nonFatalErrors++
}

# ---------------------------------------------
#  CLEANUP + RESULT
# ---------------------------------------------
if ($Mode -eq 'ZIP' -and (Test-Path $extractDir)) {
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log 'Cleaned up temp extract folder.'
}

Write-Log "====== Install complete - $copied file(s) copied, $nonFatalErrors error(s) ======"
if ($nonFatalErrors -gt 0) {
    Write-Log "Installation completed with errors. Review: $logFile" 'WARNING'
    exit 2
}
Write-Log "TroubleshootWizard v$AppVersion installed to: $Destination"
Write-Log "Test it: start $UrlScheme`://Network   (or)   powershell -File `"$sendScript`" -DiagSteps Network"
exit 0
