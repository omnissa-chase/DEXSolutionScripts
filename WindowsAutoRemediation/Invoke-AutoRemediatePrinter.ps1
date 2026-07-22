<#
.SYNOPSIS
    Invoke-AutoRemediatePrinter -- Automated printer diagnostic and remediation.

@TODO -  need to add a way to report the status to Omnissa UEM and if its a driver issue
prompt the admin if they want to fix the driver
    
.DESCRIPTION
    Runs a hard-coded sequence of printer health checks and automatically
    executes the corresponding remediation for any step that fails (or warns,
    when ResolveOnWarning is set). Fully self-contained -- no JSON, no UI, no
    external dependencies. Designed for deployment as a Workspace ONE MDM
    remediation script or standalone admin tool.

    +------+----------------------------------+----------------------------------+
    | Step | Name                             | Remediates On                    |
    +------+----------------------------------+----------------------------------+
    |  1   | Print Spooler Service            | Failed                           |
    |  2   | Printers Installed               | -- (informational only)           |
    |  3   | Printer Offline State            | Failed                           |
    |  4   | Default Printer Set              | -- (informational only)           |
    |  5   | Print Spooler Queue              | Failed                           |
    |  6   | Printer Driver Health            | -- (informational only)           |
    |  7   | Network Printer Connectivity     | -- (informational only)           |
    |  8   | Windows Print & Scan Feature     | Failed                           |
    |  9   | Device Condition Signals         | -- (informational only)           |
    +------+----------------------------------+----------------------------------+

    Each step returns @{ Status = 'Passed'|'Warning'|'Failed'; Message = '...' }
    Resolution scripts run silently; errors are captured and reported at the end.

.NOTES
    Script Name  : Invoke-AutoRemediatePrinter.ps1
    Version      : 1.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-17
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Print Spooler Service'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
            if (-not $svc) {
                return @{ Status = 'Failed'; Message = 'Spooler service not found' }
            }
            if ($svc.Status -eq 'Running') {
                return @{ Status = 'Passed'; Message = 'Spooler is running' }
            }
            return @{ Status = 'Failed'; Message = "Spooler is $($svc.Status)" }
        }
        ResolutionScript = {
            Set-Service   -Name Spooler -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name Spooler                        -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Printers Installed'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false   # Cannot silently install printers -- informational only
        DetectionScript  = {
            $printers = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue
            if (-not $printers) {
                return @{ Status = 'Failed'; Message = 'No printers installed' }
            }
            # PrinterStatus > 3 indicates an error condition
            $errored = $printers | Where-Object { $_.PrinterStatus -gt 3 }
            $names   = ($printers | Select-Object -ExpandProperty Name) -join ', '
            if ($errored) {
                $errNames = ($errored | Select-Object -ExpandProperty Name) -join ', '
                return @{ Status = 'Warning'; Message = "$($printers.Count) printer(s) installed, errors on: $errNames" }
            }
            return @{ Status = 'Passed'; Message = "$($printers.Count) printer(s) installed: $names" }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- requires user/IT action to install printers
    },

    @{
        Name             = 'Printer Offline State'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $offline = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue |
                       Where-Object { $_.WorkOffline -eq $true }
            if ($offline) {
                $names = ($offline | Select-Object -ExpandProperty Name) -join ', '
                return @{ Status = 'Failed'; Message = "Offline flag set on: $names" }
            }
            return @{ Status = 'Passed'; Message = 'No printers set to offline mode' }
        }
        ResolutionScript = {
            # Clear the WorkOffline flag on all printers that have it set
            $offline = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue |
                       Where-Object { $_.WorkOffline -eq $true }
            foreach ($p in $offline) {
                $p.WorkOffline = $false
                $p.Put() | Out-Null
            }
        }
    },

    @{
        Name             = 'Default Printer Set'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false   # Cannot silently set default -- informational only
        DetectionScript  = {
            $default = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue |
                       Where-Object { $_.Default -eq $true }
            if ($default) {
                return @{ Status = 'Passed'; Message = "Default printer: $($default.Name)" }
            }
            return @{ Status = 'Warning'; Message = 'No default printer set' }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- requires user selection in Printer settings
    },

    @{
        Name             = 'Print Spooler Queue'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $jobs = Get-WmiObject -Class Win32_PrintJob -ErrorAction SilentlyContinue
            if (-not $jobs) {
                return @{ Status = 'Passed'; Message = 'Print queue is clear' }
            }
            # StatusMask bit 0x1000 indicates a stuck/error job
            $stuck = $jobs | Where-Object { $_.StatusMask -band 0x1000 }
            if ($stuck) {
                return @{ Status = 'Failed'; Message = "$($stuck.Count) stuck job(s) detected" }
            }
            return @{ Status = 'Warning'; Message = "$($jobs.Count) job(s) pending in queue" }
        }
        ResolutionScript = {
            # Stop spooler, purge all spool files, restart spooler to clear stuck jobs
            Stop-Service  -Name Spooler -Force -ErrorAction SilentlyContinue
            Remove-Item   -Path "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
            Start-Service -Name Spooler       -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Printer Driver Health'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $false   # Cannot silently reinstall drivers -- informational only
        DetectionScript  = {
            try {
                $drivers = Get-PrinterDriver -ErrorAction Stop
                if (-not $drivers) {
                    return @{ Status = 'Warning'; Message = 'No printer drivers found' }
                }
                $names = ($drivers | Select-Object -ExpandProperty Name) -join ', '
                return @{ Status = 'Passed'; Message = "$($drivers.Count) driver(s) loaded: $names" }
            } catch {
                return @{ Status = 'Warning'; Message = 'Unable to enumerate printer drivers' }
            }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- driver repair requires Print Management or IT action
    },

    @{
        Name             = 'Network Printer Connectivity'
        Order            = 7
        Enabled          = $true
        ResolveOnWarning = $false   # Cannot auto-fix network routing -- informational only
        DetectionScript  = {
            $netPrinters = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue |
                Where-Object { $_.PortName -match '^(\d{1,3}\.){3}\d{1,3}|^\\\\' }
            if (-not $netPrinters) {
                return @{ Status = 'Warning'; Message = 'No network printers found (USB only)' }
            }
            $failed = @()
            foreach ($p in $netPrinters) {
                # Extract the IP or hostname from the port name
                $target = if ($p.PortName -match '^(\d{1,3}\.){3}\d{1,3}') {
                    $p.PortName
                } else {
                    $p.PortName -replace '^\\\\([^\\]+)\\.*', '$1'
                }
                if ($target -and -not (Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
                    $failed += $p.Name
                }
            }
            if ($failed) {
                return @{ Status = 'Failed'; Message = "Unreachable: $($failed -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = "$($netPrinters.Count) network printer(s) reachable" }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- requires network/VPN troubleshooting
    },

    @{
        Name             = 'Windows Print & Scan Feature'
        Order            = 8
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $feat = Get-WindowsOptionalFeature -Online -FeatureName 'Printing-Foundation-Features' -ErrorAction SilentlyContinue
            if (-not $feat) {
                return @{ Status = 'Warning'; Message = 'Unable to check feature state' }
            }
            if ($feat.State -eq 'Enabled') {
                return @{ Status = 'Passed'; Message = 'Print feature enabled' }
            }
            return @{ Status = 'Failed'; Message = "Print feature state: $($feat.State)" }
        }
        ResolutionScript = {
            # Enable the Windows Printing Foundation Features silently without restart
            Enable-WindowsOptionalFeature -Online -FeatureName 'Printing-Foundation-Features' -NoRestart -ErrorAction SilentlyContinue | Out-Null
        }
    },

    @{
        Name             = 'Device Condition Signals'
        Order            = 9
        Enabled          = $true
        ResolveOnWarning = $false   # Hardware states (toner, paper, jams) cannot be auto-remediated -- informational only
        DetectionScript  = {
            $printers = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue
            if (-not $printers) {
                return @{ Status = 'Warning'; Message = 'No printers found for condition check' }
            }
            $issues = @()
            foreach ($p in $printers) {
                # DetectedErrorState: 2=No Error, 3=Low Paper, 4=No Paper, 5=Low Toner, 6=No Toner,
                #                    7=Door Open, 8=Jammed, 9=Offline, 10=Service Requested, 11=Output Bin Full
                $desc = switch ($p.DetectedErrorState) {
                    3  { 'Low paper'        }
                    4  { 'No paper'         }
                    5  { 'Low toner'        }
                    6  { 'No toner'         }
                    7  { 'Door open'        }
                    8  { 'Paper jammed'     }
                    9  { 'Offline'          }
                    10 { 'Service required' }
                    11 { 'Output bin full'  }
                    default { $null }
                }
                if ($desc) { $issues += "$($p.Name): $desc" }
            }
            if ($issues) {
                return @{ Status = 'Warning'; Message = $issues -join '; ' }
            }
            return @{ Status = 'Passed'; Message = 'No hardware error conditions detected' }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- hardware conditions require physical intervention
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Invoke-AutoRemediatePrinter ----------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation ----------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # -- Output ---------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

# -- Registry Reporting -------------------------------------------------------
# Writes all non-Passed results to HKLM for DEX agent pickup.
# Informational steps (ResolutionScript = $null) surface here as persistent signals
# that require user or IT action; remediated steps are flagged [Remediated].
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\PrinterErrors'
try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    }

    # Clear values from the previous scan (preserve the key itself)
    $existing = Get-Item -Path $regPath -ErrorAction SilentlyContinue
    if ($existing) {
        $existing.GetValueNames() | ForEach-Object {
            Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue
        }
    }

    Set-ItemProperty -Path $regPath -Name 'LastScanTime'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'TotalSteps'      -Value $results.Count -Type DWord
    Set-ItemProperty -Path $regPath -Name 'PassedCount'     -Value $passed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'WarningCount'    -Value $warnings      -Type DWord
    Set-ItemProperty -Path $regPath -Name 'FailedCount'     -Value $failed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'RemediatedCount' -Value $remCount      -Type DWord

    # Write one value per non-Passed result; step order prefix keeps them sortable
    $openIssues = $results | Where-Object { $_.Status -ne 'Passed' }
    foreach ($issue in $openIssues) {
        $valueName = 'Step{0:D2}_{1}' -f $issue.Order, ($issue.Name -replace '[^A-Za-z0-9]', '')
        $tag       = if ($issue.Remediated) { '[Remediated]' } else { "[$($issue.Status)]" }
        Set-ItemProperty -Path $regPath -Name $valueName -Value "$tag $($issue.Message)" -Type String
    }

    Write-Host "  [Registry] Results written to $regPath" -ForegroundColor DarkCyan
} catch {
    Write-Host "  [Registry] Write failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
