#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps machine certificate enrollment working: re-enables the autoenrollment
    tasks, triggers renewal for expiring AD CS certificates, and reports what
    only the issuing system can fix.

.DESCRIPTION
    Pairs with GenericTroubleshooting\CertificateStoreHealth\certificate_store_health.ps1.

    An endpoint cannot make an expired certificate valid again. What it can do is
    make sure the channels that renew certificates are alive and nudge them: the
    CertificateServicesClient scheduled tasks and the autoenrollment pulse for
    certificates issued by an Active Directory Certificate Services template.
    Certificates delivered by Workspace ONE profiles, SCEP, or a third-party PKI
    are renewed by those systems; this script reports them with the detail a ticket
    needs and leaves them alone.

    +------+----------------------------------+------------------------------------------+
    | Step | Name                             | Action                                   |
    +------+----------------------------------+------------------------------------------+
    |  1   | Autoenrollment Tasks             | Enable disabled CertificateServicesClient|
    |      |                                  | tasks                                    |
    |  2   | Machine Certificate Expiry       | AD CS template certs: trigger autoenroll |
    |      |                                  | Others: report with subject and template |
    |  3   | Weak Signature Algorithms        | Report only                              |
    |  4   | Root Store Auto-Update           | Report only                              |
    |  5   | Autoenrollment Policy            | Report only                              |
    +------+----------------------------------+------------------------------------------+

    Never deletes a certificate from LocalMachine\My (an application may pin the
    thumbprint, and an expired certificate still decrypts data it protected) and
    never changes the Root or CA stores. Never changes a policy registry value.

    Results are written to HKLM:\Software\AirWatch\Extensions\CertEnrollment\Remediation.

.PARAMETER ExpiringSoonDays
    A machine certificate expiring within this many days counts as needing renewal.
    Defaults to $env:ExpiringSoonDays, then 30.

.PARAMETER RootSyncStaleDays
    Age of the last automatic root certificate update beyond which step 4 warns.
    Defaults to $env:RootSyncStaleDays, then 90.

.PARAMETER ExpiredRootNoiseMax
    Windows never purges expired roots, so a few are normal. Step 4 warns only past
    this count. Defaults to $env:ExpiredRootNoiseMax, then 20.

.EXAMPLE
    $env:WhatIf = 'true'; .\Invoke-AutoRemediateCertEnrollment.ps1

    Reports what would change without touching the device. The intended first run.

.NOTES
    Script Name  : Invoke-AutoRemediateCertEnrollment.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03 (1.0.1: scheduled tasks are read, enabled and started
                   through the Task Scheduler COM API; Get-ScheduledTask cost 5 s per
                   call on the lab host and pushed the run past its budget)
    Timeout      : 30 seconds

    Environment variables:
      WhatIf              = true   Dry run. Absent/unparseable => live run.
      ExpiringSoonDays    = 30
      RootSyncStaleDays   = 90
      ExpiredRootNoiseMax = 20

    Explicit parameters win over environment variables.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateCertEnrollment {
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1, 365)]
    [int]$ExpiringSoonDays = $(
        $v = 0
        if ([int]::TryParse("$env:ExpiringSoonDays".Trim(), [ref]$v) -and $v -ge 1 -and $v -le 365) { $v } else { 30 }
    ),

    [ValidateRange(7, 730)]
    [int]$RootSyncStaleDays = $(
        $v = 0
        if ([int]::TryParse("$env:RootSyncStaleDays".Trim(), [ref]$v) -and $v -ge 7 -and $v -le 730) { $v } else { 90 }
    ),

    [ValidateRange(0, 500)]
    [int]$ExpiredRootNoiseMax = $(
        $v = 0
        if ([int]::TryParse("$env:ExpiredRootNoiseMax".Trim(), [ref]$v) -and $v -ge 0) { $v } else { 20 }
    )
)

$SCRIPT_VERSION = "1.0.1"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\CertEnrollment\Remediation"
$DexRecordsPath = "HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\CertEnrollment"
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateCertEnrollment.log"
$AeTaskPath     = '\Microsoft\Windows\CertificateServicesClient\'

# Modules are loaded before the WhatIf bridge: auto-loading them afterwards makes
# PowerShell print a "What if: Set Alias" line for every alias they define.
Import-Module CimCmdlets -ErrorAction SilentlyContinue

# -- WhatIf bridge -------------------------------------------------------------
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing Invoke-AutoRemediateCertEnrollment, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

Write-Log "Settings: ExpiringSoonDays=$ExpiringSoonDays RootSyncStaleDays=$RootSyncStaleDays ExpiredRootNoiseMax=$ExpiredRootNoiseMax"

# -- Pre-flight ------------------------------------------------------------------
$cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$IsDomainJoined = [bool]($cs -and $cs.PartOfDomain)
$Now = Get-Date

# -- Helpers -----------------------------------------------------------------------
# Certificate Template extensions: 1.3.6.1.4.1.311.21.7 (v2 templates, carries the
# template OID) and 1.3.6.1.4.1.311.20.2 (v1 templates, carries the name). Either
# one means an AD CS template issued the certificate, which is what autoenrollment
# can renew.
function Get-TemplateName {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    foreach ($ext in $Cert.Extensions) {
        if ($ext.Oid.Value -eq '1.3.6.1.4.1.311.20.2' -or $ext.Oid.Value -eq '1.3.6.1.4.1.311.21.7') {
            try {
                $text = $ext.Format($false)
                if ($text -match 'Template=([^\(,]+)') { return $Matches[1].Trim() }
                return $text.Trim()
            } catch { return 'template' }
        }
    }
    return $null
}

function Format-CertLine {
    param($Cert)
    $subject = if ([string]::IsNullOrWhiteSpace($Cert.Subject)) { '(no subject)' } else { $Cert.Subject }
    $template = Get-TemplateName -Cert $Cert
    $src = if ($template) { "template '$template'" } else { "issuer '$($Cert.Issuer)'" }
    return "$subject [$($Cert.Thumbprint.Substring(0, 8))] expires $($Cert.NotAfter.ToString('yyyy-MM-dd')), $src"
}

$PersonalCerts = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue)
$Expired       = @($PersonalCerts | Where-Object { $_.NotAfter -lt $Now })
$ExpiringSoon  = @($PersonalCerts | Where-Object { $_.NotAfter -ge $Now -and $_.NotAfter -le $Now.AddDays($ExpiringSoonDays) })
$NeedsRenewal  = @($Expired + $ExpiringSoon)
$AdCsRenewable = @($NeedsRenewal | Where-Object { $null -ne (Get-TemplateName -Cert $_) })
$OtherRenewal  = @($NeedsRenewal | Where-Object { $null -eq (Get-TemplateName -Cert $_) })

# The Task Scheduler COM API is used instead of Get-ScheduledTask: the CIM path took
# 5 s per call on the lab host against 0.1 s for COM (1.0.1, 2026-11-03), and this
# script has a 30 s budget. Each entry keeps its COM object for enabling and starting.
function Get-AeTasks {
    $out = @()
    try {
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        $folder = $svc.GetFolder($AeTaskPath.TrimEnd('\'))
        foreach ($t in @($folder.GetTasks(1))) {
            $out += [PSCustomObject]@{
                TaskName = [string]$t.Name
                TaskPath = $AeTaskPath
                State    = if ($t.Enabled) { 'Ready' } else { 'Disabled' }
                Com      = $t
            }
        }
    } catch {
        # Folder absent on this build, or COM unavailable: fall back to CIM.
        $out = @(Get-ScheduledTask -TaskPath $AeTaskPath -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ TaskName = $_.TaskName; TaskPath = $_.TaskPath; State = [string]$_.State; Com = $null }
        })
    }
    return $out
}

$AeTasks = @(Get-AeTasks)
$AeTasksDisabled = @($AeTasks | Where-Object { $_.State -eq 'Disabled' })

Write-Log "LocalMachine\My: $($PersonalCerts.Count) cert(s), $($Expired.Count) expired, $($ExpiringSoon.Count) expiring within $ExpiringSoonDays d ($($AdCsRenewable.Count) AD CS renewable). Autoenrollment tasks: $($AeTasks.Count) ($($AeTasksDisabled.Count) disabled). DomainJoined=$IsDomainJoined"

# -- Step Definitions -----------------------------------------------------------
$Steps = @(

    @{
        Name             = 'Autoenrollment Tasks'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if ($AeTasks.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No CertificateServicesClient tasks on this build' }
            }
            if ($AeTasksDisabled.Count -gt 0) {
                $names = ($AeTasksDisabled | ForEach-Object { $_.TaskName }) -join ', '
                return @{ Status = 'Failed'; Message = "Autoenrollment task(s) disabled: $names. Nothing will renew until they run" }
            }
            return @{ Status = 'Passed'; Message = "$($AeTasks.Count) CertificateServicesClient task(s) enabled" }
        }
        ResolutionScript = {
            $failures = @()
            foreach ($t in $AeTasksDisabled) {
                try {
                    if ($t.Com) {
                        $t.Com.Enabled = $true
                    } else {
                        Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
                    }
                    $after = Get-AeTasks | Where-Object { $_.TaskName -eq $t.TaskName } | Select-Object -First 1
                    if (-not $after -or $after.State -eq 'Disabled') { throw 'still disabled after enabling' }
                } catch {
                    $failures += "$($t.TaskName): $($_.Exception.Message)"
                }
            }
            if ($failures.Count -gt 0) { throw ($failures -join '; ') }
        }
    },

    @{
        # Renewal can only be triggered for certificates an AD CS template issued.
        # Everything else is reported with enough detail to open the right ticket.
        Name             = 'Machine Certificate Expiry'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if ($NeedsRenewal.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "$($PersonalCerts.Count) machine certificate(s); none expired or expiring within $ExpiringSoonDays days" }
            }
            $detail = ($NeedsRenewal | ForEach-Object { Format-CertLine $_ }) -join '; '
            if ($AdCsRenewable.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "$($Expired.Count) expired, $($ExpiringSoon.Count) expiring soon; $($AdCsRenewable.Count) renewable by autoenrollment: $detail" }
            }
            return @{ Status = 'Warning'; Message = "$($Expired.Count) expired, $($ExpiringSoon.Count) expiring soon, none issued by an AD CS template. Renew through the issuing system (Workspace ONE profile, SCEP, vendor PKI): $detail. Not auto-remediated" }
        }
        ResolutionScript = {
            # certutil -pulse signals the autoenrollment client to run now; starting the
            # machine task is the same request through Task Scheduler. Issuance is
            # asynchronous, so the outcome shows up on the next run of this script.
            $out = & "$env:SystemRoot\System32\certutil.exe" -pulse 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "certutil -pulse failed: $($out.Trim())" }
            $sysTask = $AeTasks | Where-Object { $_.TaskName -eq 'SystemTask' } | Select-Object -First 1
            if ($sysTask) {
                try {
                    if ($sysTask.Com) { $null = $sysTask.Com.Run($null) }
                    else { Start-ScheduledTask -TaskPath $sysTask.TaskPath -TaskName $sysTask.TaskName -ErrorAction Stop }
                } catch { }
            }
            if ($OtherRenewal.Count -gt 0) {
                Write-Log "Not renewable here ($($OtherRenewal.Count)): $(($OtherRenewal | ForEach-Object { Format-CertLine $_ }) -join '; ')" 'WARN'
            }
        }
    },

    @{
        Name             = 'Weak Signature Algorithms'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $weak = @($PersonalCerts | Where-Object { $_.SignatureAlgorithm.FriendlyName -match 'md5|sha1' -and $_.NotAfter -ge $Now })
            if ($weak.Count -gt 0) {
                $detail = ($weak | ForEach-Object { "$(Format-CertLine $_) ($($_.SignatureAlgorithm.FriendlyName))" }) -join '; '
                return @{ Status = 'Warning'; Message = "$($weak.Count) valid machine certificate(s) signed with a weak algorithm: $detail. Reissue from the CA; not auto-remediated" }
            }
            return @{ Status = 'Passed'; Message = 'No MD5 or SHA-1 signed machine certificates' }
        }
        ResolutionScript = $null
    },

    @{
        # Policy values are an admin's decision and are never changed here. The
        # root store is reported, not edited: importing or removing roots is a
        # trust decision, not a repair.
        Name             = 'Root Store Auto-Update'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $findings = @()
            $disabled = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\AuthRoot' -Name 'DisableRootAutoUpdate' -ErrorAction SilentlyContinue).DisableRootAutoUpdate
            if ($disabled -eq 1) { $findings += 'automatic root updates are disabled by policy (DisableRootAutoUpdate=1)' }

            $raw = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate' -Name 'LastSyncTime' -ErrorAction SilentlyContinue).LastSyncTime
            if ($raw -and $raw.Length -ge 8) {
                try {
                    $last = [datetime]::FromFileTime([BitConverter]::ToInt64($raw, 0))
                    if ($last -lt $Now.AddDays(-$RootSyncStaleDays)) { $findings += "last root update was $($last.ToString('yyyy-MM-dd')) (older than $RootSyncStaleDays days)" }
                } catch { }
            }

            $expiredRoots = @((Get-ChildItem 'Cert:\LocalMachine\Root', 'Cert:\LocalMachine\CA' -ErrorAction SilentlyContinue) | Where-Object { $_.NotAfter -lt $Now }).Count
            if ($expiredRoots -gt $ExpiredRootNoiseMax) { $findings += "$expiredRoots expired root/intermediate certificates (noise threshold $ExpiredRootNoiseMax)" }

            if ($findings.Count -gt 0) {
                return @{ Status = 'Warning'; Message = "$($findings -join '; '). Review the trust store configuration; not auto-remediated" }
            }
            return @{ Status = 'Passed'; Message = 'Root auto-update enabled and recent; expired roots within normal noise' }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Autoenrollment Policy'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $IsDomainJoined) {
                return @{ Status = 'Passed'; Message = 'Not domain joined; AD CS autoenrollment policy does not apply' }
            }
            $ae = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment' -Name 'AEPolicy' -ErrorAction SilentlyContinue).AEPolicy
            if ($null -eq $ae) {
                return @{ Status = 'Warning'; Message = 'No computer autoenrollment policy applied (AEPolicy absent). Expiring AD CS certificates will not renew on their own; check the GPO; not auto-remediated' }
            }
            if (($ae -band 0x8000) -ne 0) {
                return @{ Status = 'Warning'; Message = "Computer autoenrollment is disabled by policy (AEPolicy=$ae); not auto-remediated" }
            }
            $renew = if (($ae -band 0x1) -ne 0) { 'renew expired, update pending, remove revoked' } else { 'enabled without renewal flags' }
            return @{ Status = 'Passed'; Message = "Autoenrollment policy applied (AEPolicy=$ae): $renew" }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine ------------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Output "`r`n-- Invoke-AutoRemediateCertEnrollment --------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   Machine certificates: $($PersonalCerts.Count)"
Write-Output '--------------------------------------------------------------------'

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

    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        if ($PSCmdlet.ShouldProcess($step.Name, 'Repair certificate enrollment')) {
            try {
                & $step.ResolutionScript | Out-Null
                $remediated = $true
            } catch {
                $remError = $_.Exception.Message
            }
        }
    }

    $remNote = if ($remediated)   { '  -> Remediated' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$remNote"
    Write-Log "$($step.Name): $status - $message$remNote"

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -----------------------------------------------------------------
$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count
$remErrs  = @($results | Where-Object { $_.RemError }).Count

Write-Output "`r`n--------------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations applied: $remCount"
Write-Output "--------------------------------------------------------------------`r`n"
Write-Log "Summary: Passed=$passed Warnings=$warnings Failed=$failed RemediationsApplied=$remCount RemediationErrors=$remErrs Expired=$($Expired.Count) ExpiringSoon=$($ExpiringSoon.Count) AdCsRenewable=$($AdCsRenewable.Count)"

# -- Registry Reporting --------------------------------------------------------
if (-not $WhatIfPreference) {
    try {
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $RegPath -Name 'LastRun'           -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion'     -Value $SCRIPT_VERSION -Type String
        Set-ItemProperty -Path $RegPath -Name 'Passed'            -Value $passed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Warnings'          -Value $warnings -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Failed'            -Value $failed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationsRun'   -Value $remCount -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationErrors' -Value $remErrs  -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'ExpiredCount'      -Value $Expired.Count      -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'ExpiringSoonCount' -Value $ExpiringSoon.Count -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'AdCsRenewableCount' -Value $AdCsRenewable.Count -Type DWord
        Write-Log "Results cached to $RegPath"
    } catch {
        Write-Log "Registry cache write failed: $($_.Exception.Message)" 'WARN'
    }

    try {
        if (-not (Test-Path $DexRecordsPath)) {
            New-Item -Path $DexRecordsPath -Force -ErrorAction Stop | Out-Null
        }
        $existing = Get-Item -Path $DexRecordsPath -ErrorAction SilentlyContinue
        if ($existing) {
            $existing.GetValueNames() | ForEach-Object {
                Remove-ItemProperty -Path $DexRecordsPath -Name $_ -ErrorAction SilentlyContinue
            }
        }
        Set-ItemProperty -Path $DexRecordsPath -Name 'LastScanTime'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ItemProperty -Path $DexRecordsPath -Name 'ScriptVersion'   -Value $SCRIPT_VERSION -Type String
        Set-ItemProperty -Path $DexRecordsPath -Name 'TotalSteps'      -Value $results.Count -Type DWord
        Set-ItemProperty -Path $DexRecordsPath -Name 'PassedCount'     -Value $passed        -Type DWord
        Set-ItemProperty -Path $DexRecordsPath -Name 'WarningCount'    -Value $warnings      -Type DWord
        Set-ItemProperty -Path $DexRecordsPath -Name 'FailedCount'     -Value $failed        -Type DWord
        Set-ItemProperty -Path $DexRecordsPath -Name 'RemediatedCount' -Value $remCount      -Type DWord
        foreach ($r in $results) {
            $valueName = 'Step{0:D2}_{1}' -f $r.Order, ($r.Name -replace '[^A-Za-z0-9]', '')
            $tag       = if ($r.Remediated) { '[Remediated]' } else { "[$($r.Status)]" }
            $text      = "$tag $($r.Name): $($r.Message)"
            if ($r.RemError) { $text += "  -> Remediation ERROR: $($r.RemError)" }
            if ($text.Length -gt 500) { $text = $text.Substring(0, 497) + '...' }
            Set-ItemProperty -Path $DexRecordsPath -Name $valueName -Value $text -Type String
        }
        Write-Log "Per-step results written to $DexRecordsPath"
    } catch {
        Write-Log "DEXRecords write failed: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-Log 'WhatIf run -- registry cache left untouched.'
}

exit $(if ($remErrs -gt 0) { 1 } else { 0 })
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

Invoke-AutoRemediateCertEnrollment
Exit 0
