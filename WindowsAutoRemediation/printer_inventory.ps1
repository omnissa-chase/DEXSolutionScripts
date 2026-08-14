#Requires -Version 5.1
<#
.NOTES
    Script Name  : printer_inventory.ps1
    Data Type    : String (JSON)
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-13
    Timeout      : < 5 seconds

    Lists every printer registered with the local print spooler as a single
    JSON object -- name, driver, port, default/shared/network flags, offline
    state, and current status/error condition. Read-only counterpart to
    Invoke-AutoRemediatePrinter.ps1's "Printers Installed" and related checks;
    this script makes no changes.

    Running as SYSTEM enumerates the machine-wide spooler (local printers and
    any printer connection registered at the machine level via Point and
    Print/GPO). A network printer connected purely inside the interactive
    user's own session may not appear here if it was never registered at the
    machine level -- see Invoke-AutoRemediatePrinter.ps1 for the same caveat.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop)

    $list = foreach ($p in $printers) {
        # WMI Win32_Printer.PrinterStatus: 1=Other 2=Unknown 3=Idle 4=Printing 5=Warmup 6=Stopped Printing 7=Offline
        $statusText = switch ([int]$p.PrinterStatus) {
            1 { 'Other' }
            2 { 'Unknown' }
            3 { 'Idle' }
            4 { 'Printing' }
            5 { 'Warmup' }
            6 { 'Stopped Printing' }
            7 { 'Offline' }
            default { 'Unknown' }
        }
        # DetectedErrorState: same code table Invoke-AutoRemediatePrinter.ps1 uses for condition signals.
        $errorState = switch ([int]$p.DetectedErrorState) {
            3 { 'Low paper' }
            4 { 'No paper' }
            5 { 'Low toner' }
            6 { 'No toner' }
            7 { 'Door open' }
            8 { 'Paper jammed' }
            9 { 'Offline' }
            10 { 'Service required' }
            11 { 'Output bin full' }
            default { $null }
        }

        [ordered]@{
            Name        = $p.Name
            DriverName  = $p.DriverName
            PortName    = $p.PortName
            Default     = [bool]$p.Default
            Network     = [bool]$p.Network
            Shared      = [bool]$p.Shared
            ShareName   = if ($p.Shared) { $p.ShareName } else { $null }
            Location    = if ([string]::IsNullOrWhiteSpace($p.Location)) { $null } else { $p.Location }
            Comment     = if ([string]::IsNullOrWhiteSpace($p.Comment)) { $null } else { $p.Comment }
            WorkOffline = [bool]$p.WorkOffline
            Status      = $statusText
            ErrorState  = $errorState
        }
    }

    $default = $printers | Where-Object { $_.Default } | Select-Object -First 1

    $result = [ordered]@{
        Status          = 'OK'
        DataCollectedAt = (Get-Date).ToString('s')
        PrinterCount    = $printers.Count
        DefaultPrinter  = if ($default) { $default.Name } else { $null }
        Printers        = @($list)
    }

    Write-Output ($result | ConvertTo-Json -Compress -Depth 4)
    return
}
catch {
    Write-Output ([PSCustomObject]@{ Status = 'Failed'; Error = $_.Exception.Message } | ConvertTo-Json -Compress)
    return
}
