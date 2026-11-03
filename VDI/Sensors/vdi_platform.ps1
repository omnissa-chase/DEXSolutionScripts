#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vdi_platform
    Data Type    : String
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 2 seconds (registry and service presence only; no cache dependency)
    Requires     : nothing. Safe to assign fleet-wide.

    Which VDI platform this device belongs to, judged by what is installed on it:
      Horizon   Horizon Agent or Horizon Client
      Citrix    Citrix VDA or Citrix Workspace app
      AVD       Azure Virtual Desktop / Windows 365 agent, or a Microsoft client (MSRDC, Windows App)
      RDS       classic Remote Desktop Session Host role with no AVD agent (mstsc alone does not count)
      Multiple  more than one of the above
      None      nothing found

    Pairs with vdi_role (SessionHost / Client / Both / None). Together they build the
    smart groups for the platform-specific collectors and are the first branch in every
    VDI runbook. Detection matrix: VDI/DESIGN.md section 2.3. Candidate paths are KB
    resolution points (VDI/Horizon/SPEC.md section 3); add to the lists, do not replace.

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

    $found = New-Object System.Collections.Generic.List[string]

    # Horizon (KB-HZN-01, 02, 14)
    $hznHost   = (Test-AnyPath @('HKLM:\SOFTWARE\Omnissa\Horizon\Agent', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent')) -or
                 (Test-Svc -Names @('wsnm') -Display '(?i)Horizon.*Agent|VMware View Agent') -or
                 (Test-Uninstall '(?i)^(Omnissa|VMware) Horizon.*Agent')
    $hznClient = (Test-Uninstall '(?i)^(Omnissa|VMware) Horizon Client') -or
                 (Test-AnyPath @('HKLM:\SOFTWARE\Omnissa\Horizon\Client', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Client'))
    if ($hznHost -or $hznClient) { $found.Add('Horizon') }

    # Citrix
    $ctxHost   = (Test-AnyPath @('HKLM:\SOFTWARE\Citrix\VirtualDesktopAgent')) -or
                 (Test-Svc -Names @('BrokerAgent') -Display '(?i)^Citrix Desktop Service')
    $ctxClient = (Test-Uninstall '(?i)^Citrix Workspace|^Citrix Receiver') -or
                 (Test-AnyPath @('HKLM:\SOFTWARE\WOW6432Node\Citrix\ICA Client', 'HKLM:\SOFTWARE\Citrix\ICA Client'))
    if ($ctxHost -or $ctxClient) { $found.Add('Citrix') }

    # Microsoft: AVD / Windows 365 agent, MSRDC, Windows App (Store package registration, read from the registry so no Get-AppxPackage cost)
    $avdHost   = (Test-AnyPath @('HKLM:\SOFTWARE\Microsoft\RDInfraAgent')) -or
                 (Test-Svc -Names @('RDAgentBootLoader') -Display '(?i)Remote Desktop Agent Loader')
    $appx      = @(Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications' -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSChildName -match '(?i)^MicrosoftCorporationII\.Windows365|WindowsApp|MicrosoftCorporationII\.AzureVirtualDesktop' })
    $avdClient = (Test-AnyPath @('HKLM:\SOFTWARE\Microsoft\MSRDC')) -or
                 (Test-Uninstall '(?i)^Remote Desktop$|^Windows App$') -or
                 ($appx.Count -gt 0)
    if ($avdHost -or $avdClient) { $found.Add('AVD') }

    # Classic RDS: Server SKU with the Session Host role and no AVD agent
    if (-not $avdHost) {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $isServer = ($os -and [int]$os.ProductType -ne 1)
        $rdsh = Test-AnyPath @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppCompat')
        if ($isServer -and $rdsh -and (Test-Svc -Names @('TermService'))) { $found.Add('RDS') }
    }

    $value = if ($found.Count -eq 0) { 'None' } elseif ($found.Count -eq 1) { $found[0] } else { 'Multiple' }
    Write-Output $value
    return
}
catch {
    Write-Output ''
    return
}
