#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vdi_role
    Data Type    : String
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 2 seconds (registry and service presence only; no cache dependency)
    Requires     : nothing. Safe to assign fleet-wide.

    Whether this device is a VDI session host, a VDI client endpoint, both, or neither:
      SessionHost   a Horizon Agent, Citrix VDA, AVD / Windows 365 agent, or RDSH role is installed
      Client        a Horizon Client, Citrix Workspace app, MSRDC or Windows App is installed
      Both          at least one of each (a session host that also carries a client, e.g. a
                    jump host or a double-hop configuration)
      None          nothing found

    Same evidence as vdi_platform; the two sensors are kept separate so each returns
    one scalar. Candidate paths are KB resolution points (VDI/Horizon/SPEC.md section 3).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $services  = @(Get-Service -ErrorAction SilentlyContinue)
    $uninstall = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName } | Select-Object -ExpandProperty DisplayName)

    function Test-AnyPath   { param([string[]]$P) foreach ($x in $P) { if (Test-Path -LiteralPath $x) { return $true } }; return $false }
    function Test-Svc       { param([string[]]$Names, [string]$Display)
        foreach ($s in $services) {
            if ($Names -contains $s.Name) { return $true }
            if ($Display -and $s.DisplayName -match $Display) { return $true }
        }
        return $false
    }
    function Test-Uninstall { param([string]$Pattern) foreach ($n in $uninstall) { if ($n -match $Pattern) { return $true } }; return $false }

    $isHost = $false
    $isClient = $false

    if ((Test-AnyPath @('HKLM:\SOFTWARE\Omnissa\Horizon\Agent', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent')) -or
        (Test-Svc -Names @('wsnm') -Display '(?i)Horizon.*Agent|VMware View Agent') -or
        (Test-Uninstall '(?i)^(Omnissa|VMware) Horizon.*Agent')) { $isHost = $true }
    if ((Test-AnyPath @('HKLM:\SOFTWARE\Citrix\VirtualDesktopAgent')) -or
        (Test-Svc -Names @('BrokerAgent') -Display '(?i)^Citrix Desktop Service')) { $isHost = $true }
    $avdHost = (Test-AnyPath @('HKLM:\SOFTWARE\Microsoft\RDInfraAgent')) -or
               (Test-Svc -Names @('RDAgentBootLoader') -Display '(?i)Remote Desktop Agent Loader')
    if ($avdHost) { $isHost = $true }
    if (-not $avdHost) {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os -and [int]$os.ProductType -ne 1 -and
            (Test-AnyPath @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppCompat')) -and
            (Test-Svc -Names @('TermService'))) { $isHost = $true }
    }

    if ((Test-Uninstall '(?i)^(Omnissa|VMware) Horizon Client') -or
        (Test-AnyPath @('HKLM:\SOFTWARE\Omnissa\Horizon\Client', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Client'))) { $isClient = $true }
    if ((Test-Uninstall '(?i)^Citrix Workspace|^Citrix Receiver') -or
        (Test-AnyPath @('HKLM:\SOFTWARE\WOW6432Node\Citrix\ICA Client', 'HKLM:\SOFTWARE\Citrix\ICA Client'))) { $isClient = $true }
    $appx = @(Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications' -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -match '(?i)^MicrosoftCorporationII\.Windows365|WindowsApp|MicrosoftCorporationII\.AzureVirtualDesktop' })
    if ((Test-AnyPath @('HKLM:\SOFTWARE\Microsoft\MSRDC')) -or
        (Test-Uninstall '(?i)^Remote Desktop$|^Windows App$') -or
        ($appx.Count -gt 0)) { $isClient = $true }

    $value = if ($isHost -and $isClient) { 'Both' } elseif ($isHost) { 'SessionHost' } elseif ($isClient) { 'Client' } else { 'None' }
    Write-Output $value
    return
}
catch {
    Write-Output ''
    return
}
