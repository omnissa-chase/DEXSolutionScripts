#Requires -Version 5.1
<#
.SYNOPSIS
    Turns BitLocker protection back on for volumes that are fully encrypted but
    left with protection suspended, resumes a paused encryption, and reports
    volumes whose recovery key has never been backed up.

.DESCRIPTION
    Pairs with GenericTroubleshooting\PerfomanceSensors\performance_bitlockerstatus.ps1.
    The common fleet fault is VolumeStatus FullyEncrypted with ProtectionStatus Off:
    protection was suspended for a firmware or OS update and never resumed, so the
    data sits unprotected and compliance reports the device as unencrypted.

    +------+----------------------------------+------------------------------------------+
    | Step | Name                             | Action                                   |
    +------+----------------------------------+------------------------------------------+
    |  1   | Suspended Protection             | Resume-BitLocker on qualifying volumes   |
    |  2   | Paused Encryption                | Resume a paused encryption               |
    |  3   | Recovery Key Backup              | Report only (escrow on request)          |
    +------+----------------------------------+------------------------------------------+

    Step 1 deliberately leaves two kinds of suspension alone, because resuming them
    at the wrong moment would send the device into BitLocker recovery at next boot:
      - A suspension with a reboot count still pending (manage-bde -protectors
        -disable -RebootCount), which is how firmware and feature updates suspend.
      - Any suspension while the device has a reboot pending from servicing or
        Windows Update. Protection is resumed on the next run after the restart.
    Both are reported as warnings with the reason.

    Never starts encryption, never decrypts, never adds or removes key protectors.
    Step 3 only escrows an existing recovery password when EscrowRecoveryKey=true,
    to Entra ID on an Entra-joined device or to Active Directory on a domain member.

    Results are written to HKLM:\Software\AirWatch\Extensions\BitLockerProtection\Remediation.

.PARAMETER EscrowRecoveryKey
    Back up an un-escrowed recovery password to Entra ID or Active Directory in
    step 3. Defaults to $env:EscrowRecoveryKey, then false (report only).

.PARAMETER IncludeDataVolumes
    Also act on fixed data volumes, not just the operating system volume. Defaults
    to $env:IncludeDataVolumes, then true. Removable (BitLocker To Go) volumes are
    never touched.

.EXAMPLE
    $env:WhatIf = 'true'; .\Invoke-AutoRemediateBitLockerProtection.ps1

    Reports what would change without touching the device. The intended first run.

.NOTES
    Script Name  : Invoke-AutoRemediateBitLockerProtection.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : 60 seconds

    Environment variables:
      WhatIf             = true   Dry run. Absent/unparseable => live run.
      EscrowRecoveryKey  = false
      IncludeDataVolumes = true

    Explicit parameters win over environment variables.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateBitLockerProtection {
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [bool]$EscrowRecoveryKey = $(
        $env:EscrowRecoveryKey -and $env:EscrowRecoveryKey.Trim() -in @('true', '1', 'yes', 'y')
    ),

    [bool]$IncludeDataVolumes = $(
        -not ($env:IncludeDataVolumes -and $env:IncludeDataVolumes.Trim() -in @('false', '0', 'no', 'n'))
    )
)

$SCRIPT_VERSION = "1.0.0"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\BitLockerProtection\Remediation"
$DexRecordsPath = "HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\BitLockerProtection"
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateBitLockerProtection.log"

# Modules are loaded before the WhatIf bridge: auto-loading them afterwards makes
# PowerShell print a "What if: Set Alias" line for every alias they define.
Import-Module CimCmdlets, BitLocker -DisableNameChecking -ErrorAction SilentlyContinue

# -- WhatIf bridge -------------------------------------------------------------
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing Invoke-AutoRemediateBitLockerProtection, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

Write-Log "Settings: EscrowRecoveryKey=$EscrowRecoveryKey IncludeDataVolumes=$IncludeDataVolumes"

# -- Pre-flight ------------------------------------------------------------------
if (-not (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
    Write-Output "$HEAD The BitLocker module is not available on this edition. Nothing to do."
    Write-Log 'BitLocker module unavailable. Exiting without changes.'
    exit 0
}

try {
    $AllVolumes = @(Get-BitLockerVolume -ErrorAction Stop)
} catch {
    Write-Output "$HEAD Could not query BitLocker volumes: $($_.Exception.Message). This script must run elevated (SYSTEM)."
    Write-Log "Get-BitLockerVolume failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

# Operating system and fixed data volumes only. Removable media is the user's.
$Volumes = @($AllVolumes | Where-Object {
    $_.VolumeType -eq 'OperatingSystem' -or ($IncludeDataVolumes -and $_.VolumeType -eq 'Data')
})

if ($Volumes.Count -eq 0 -or -not ($Volumes | Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' })) {
    Write-Output "$HEAD No BitLocker-encrypted volumes found. Nothing to do."
    Write-Log 'No encrypted volumes. Exiting without changes.'
    exit 0
}

Write-Log ("Volumes: " + (($Volumes | ForEach-Object { "$($_.MountPoint) $($_.VolumeType) $($_.VolumeStatus)/$($_.ProtectionStatus)" }) -join '; '))

# -- Helpers -----------------------------------------------------------------------
function Test-PendingReboot {
    # The signals servicing and Windows Update leave behind. Resuming protection
    # before that reboot risks a recovery prompt when the measured boot changes.
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'servicing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    $pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfro) { $reasons += 'pending file renames' }
    return $reasons
}

function Get-SuspendRebootCount {
    # manage-bde reports a counted suspension as "Protection Off (N reboots left)";
    # Get-BitLockerVolume does not expose the count. Null when there is no count.
    param([string]$MountPoint)
    try {
        $text = (& "$env:SystemRoot\System32\manage-bde.exe" -status $MountPoint 2>&1 | Out-String)
        if ($text -match '\((\d+)\s+reboots?\s+left\)') { return [int]$Matches[1] }
    } catch { }
    return $null
}

function Get-JoinState {
    $entra = $false
    try {
        $out = (& "$env:SystemRoot\System32\dsregcmd.exe" /status 2>&1 | Out-String)
        $entra = $out -match 'AzureAdJoined\s*:\s*YES'
    } catch { }
    $domain = $false
    try { $domain = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { }
    return [PSCustomObject]@{ Entra = $entra; Domain = $domain }
}

$PendingReboot = Test-PendingReboot

# Volumes that are encrypted but unprotected, split into those safe to resume now
# and those that must wait, with the reason.
$Suspended = @($Volumes | Where-Object { $_.VolumeStatus -eq 'FullyEncrypted' -and $_.ProtectionStatus -eq 'Off' -and @($_.KeyProtector).Count -gt 0 })
$ToResume  = @()
$Deferred  = @()
foreach ($v in $Suspended) {
    $count = Get-SuspendRebootCount -MountPoint $v.MountPoint
    if ($null -ne $count -and $count -gt 0) {
        $Deferred += "$($v.MountPoint) suspended for $count more reboot(s) (update in progress)"
    } elseif ($PendingReboot.Count -gt 0) {
        $Deferred += "$($v.MountPoint) reboot pending ($($PendingReboot -join ', '))"
    } else {
        $ToResume += $v
    }
}

$script:ResumeFailures = @()

# -- Step Definitions -----------------------------------------------------------
$Steps = @(

    @{
        Name             = 'Suspended Protection'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if ($ToResume.Count -gt 0) {
                $list = ($ToResume | ForEach-Object { $_.MountPoint }) -join ', '
                $note = if ($Deferred.Count -gt 0) { " Deferred: $($Deferred -join '; ')." } else { '' }
                return @{ Status = 'Failed'; Message = "Encrypted but protection is off on $list.$note" }
            }
            if ($Deferred.Count -gt 0) {
                return @{ Status = 'Warning'; Message = "Protection off but left alone: $($Deferred -join '; '). Will resume after the restart; not auto-remediated now" }
            }
            $on = @($Volumes | Where-Object { $_.VolumeStatus -eq 'FullyEncrypted' -and $_.ProtectionStatus -eq 'On' }).Count
            return @{ Status = 'Passed'; Message = "Protection on for $on encrypted volume(s)" }
        }
        ResolutionScript = {
            foreach ($v in $ToResume) {
                try {
                    Resume-BitLocker -MountPoint $v.MountPoint -ErrorAction Stop | Out-Null
                    $after = Get-BitLockerVolume -MountPoint $v.MountPoint -ErrorAction Stop
                    if ($after.ProtectionStatus -ne 'On') { throw "protection still $($after.ProtectionStatus) after Resume-BitLocker" }
                } catch {
                    $script:ResumeFailures += "$($v.MountPoint): $($_.Exception.Message)"
                }
            }
            if ($script:ResumeFailures.Count -gt 0) {
                throw "$($script:ResumeFailures.Count) of $($ToResume.Count) volume(s) failed: $($script:ResumeFailures -join '; ')"
            }
        }
    },

    @{
        # A paused encryption leaves part of the volume in clear text until someone
        # resumes it. A paused decryption is left alone: that is a deliberate act.
        Name             = 'Paused Encryption'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $paused = @($Volumes | Where-Object { $_.VolumeStatus -eq 'EncryptionPaused' })
            $decrypting = @($Volumes | Where-Object { $_.VolumeStatus -eq 'DecryptionPaused' -or $_.VolumeStatus -eq 'DecryptionInProgress' })
            if ($paused.Count -gt 0) {
                $list = ($paused | ForEach-Object { "$($_.MountPoint) at $($_.EncryptionPercentage)%" }) -join ', '
                return @{ Status = 'Failed'; Message = "Encryption paused on $list" }
            }
            if ($decrypting.Count -gt 0) {
                $list = ($decrypting | ForEach-Object { "$($_.MountPoint) ($($_.VolumeStatus))" }) -join ', '
                return @{ Status = 'Warning'; Message = "Decryption in progress or paused on $list; deliberate, not auto-remediated" }
            }
            $inProgress = @($Volumes | Where-Object { $_.VolumeStatus -eq 'EncryptionInProgress' })
            if ($inProgress.Count -gt 0) {
                $list = ($inProgress | ForEach-Object { "$($_.MountPoint) at $($_.EncryptionPercentage)%" }) -join ', '
                return @{ Status = 'Passed'; Message = "Encryption running on $list" }
            }
            return @{ Status = 'Passed'; Message = 'No paused encryption' }
        }
        ResolutionScript = {
            $failures = @()
            foreach ($v in @($Volumes | Where-Object { $_.VolumeStatus -eq 'EncryptionPaused' })) {
                $out = & "$env:SystemRoot\System32\manage-bde.exe" -resume $v.MountPoint 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { $failures += "$($v.MountPoint): $($out.Trim())" }
            }
            if ($failures.Count -gt 0) { throw ($failures -join '; ') }
        }
    },

    @{
        Name             = 'Recovery Key Backup'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $EscrowRecoveryKey
        DetectionScript  = {
            $encrypted = @($Volumes | Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' })
            $noPassword = @($encrypted | Where-Object { -not ($_.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }) })
            if ($noPassword.Count -gt 0) {
                $list = ($noPassword | ForEach-Object { $_.MountPoint }) -join ', '
                return @{ Status = 'Warning'; Message = "No recovery password protector on $list; nothing to escrow. Add one through your BitLocker policy; not auto-remediated" }
            }
            $join = Get-JoinState
            if (-not $join.Entra -and -not $join.Domain) {
                return @{ Status = 'Passed'; Message = 'Recovery password present; device is not Entra or domain joined, so there is no escrow target' }
            }
            # Whether a password has already been escrowed is not readable locally, so
            # this step can only offer to escrow when asked.
            if ($EscrowRecoveryKey) {
                $target = if ($join.Entra) { 'Entra ID' } else { 'Active Directory' }
                return @{ Status = 'Warning'; Message = "Recovery password present; escrowing to $target as requested" }
            }
            return @{ Status = 'Passed'; Message = 'Recovery password present. Set EscrowRecoveryKey=true to back it up to Entra ID or Active Directory on each run' }
        }
        ResolutionScript = {
            $join = Get-JoinState
            $failures = @()
            foreach ($v in @($Volumes | Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' })) {
                foreach ($kp in @($v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })) {
                    try {
                        if ($join.Entra) {
                            BackupToAAD-BitLockerKeyProtector -MountPoint $v.MountPoint -KeyProtectorId $kp.KeyProtectorId -ErrorAction Stop | Out-Null
                        } elseif ($join.Domain) {
                            Backup-BitLockerKeyProtector -MountPoint $v.MountPoint -KeyProtectorId $kp.KeyProtectorId -ErrorAction Stop | Out-Null
                        }
                    } catch {
                        $failures += "$($v.MountPoint): $($_.Exception.Message)"
                    }
                }
            }
            if ($failures.Count -gt 0) { throw ($failures -join '; ') }
        }
    }
)

# -- Execution Engine ------------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Output "`r`n-- Invoke-AutoRemediateBitLockerProtection ---------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   Volumes: $(($Volumes | ForEach-Object { $_.MountPoint }) -join ', ')"
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
        if ($PSCmdlet.ShouldProcess($step.Name, 'Repair BitLocker protection')) {
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
Write-Log "Summary: Passed=$passed Warnings=$warnings Failed=$failed RemediationsApplied=$remCount RemediationErrors=$remErrs VolumesResumed=$($ToResume.Count - $script:ResumeFailures.Count) Deferred=$($Deferred.Count)"

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
        Set-ItemProperty -Path $RegPath -Name 'VolumesResumed'    -Value ($ToResume.Count - $script:ResumeFailures.Count) -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'VolumesDeferred'   -Value $Deferred.Count -Type DWord
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

Invoke-AutoRemediateBitLockerProtection
Exit 0
