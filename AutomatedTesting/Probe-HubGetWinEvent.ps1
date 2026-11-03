<#
.SYNOPSIS
    Diagnostic sensor: which Get-WinEvent forms work on the engine that runs this file.

.DESCRIPTION
    Hub runs scripts and sensors under its embedded PowerShell 7.2.24 (TEST-VALIDATION.md 13.2.t).
    Two scripts failed there with "Cannot marshal 'parameter #8': Non-blittable generic types
    cannot be marshaled" from Get-WinEvent (13.2.v, 13.2.z) while passing on Windows PowerShell
    5.1 and pwsh 7.5. This probe tries ten query forms and reports each as OK<count> or ERR<text>
    on ONE line under 1 KB, so it can be published as a STRING sensor and read back from UEM, or
    run by hand under any engine:

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Probe-HubGetWinEvent.ps1
        pwsh -NoProfile -File .\Probe-HubGetWinEvent.ps1

    Form I reads the Group Policy operational log and needs elevation; ERR "unauthorized" from a
    non-elevated console is expected and says nothing about the engine.

    Forms: A hashtable LogName+StartTime; B +ProviderName wildcard; C +Level array; D +Level single;
    E ProviderName exact+Id+StartTime (the VPN collector's form, known good under Hub);
    F +EndTime; G the Outlook step 3 form; H -LogName -MaxEvents (Defender sensor);
    I -FilterXPath -MaxEvents (logon sensor); J .NET EventLogReader with XPath (candidate rewrite).

.NOTES
    Script Name  : Probe-HubGetWinEvent.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System or user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03 (1.0.0)
    Timeout      : < 20 seconds
    Diagnostic only; not part of the remediation inventory. Reads event logs, writes nothing.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
$cutoff = (Get-Date).AddDays(-7)
$forms = [ordered]@{
    A = { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $cutoff } -MaxEvents 50 -ErrorAction Stop }
    B = { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = '*Outlook*'; StartTime = $cutoff } -ErrorAction Stop }
    C = { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2, 3; StartTime = $cutoff } -MaxEvents 50 -ErrorAction Stop }
    D = { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 2; StartTime = $cutoff } -MaxEvents 50 -ErrorAction Stop }
    E = { Get-WinEvent -FilterHashtable @{ ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 12; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop }
    F = { Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $cutoff; EndTime = (Get-Date) } -MaxEvents 50 -ErrorAction Stop }
    G = { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = '*Outlook*'; Level = 1, 2, 3; StartTime = $cutoff } -ErrorAction Stop }
    H = { Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -MaxEvents 100 -ErrorAction Stop }
    I = { Get-WinEvent -LogName 'Microsoft-Windows-GroupPolicy/Operational' -FilterXPath "*[System[EventID=4001]]" -MaxEvents 20 -ErrorAction Stop }
    J = {
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Application', [System.Diagnostics.Eventing.Reader.PathType]::LogName, "*[System[(Level=1 or Level=2 or Level=3) and TimeCreated[timediff(@SystemTime) <= 604800000]]]")
        $r = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        $hits = New-Object System.Collections.Generic.List[object]
        try { while ($null -ne ($e = $r.ReadEvent())) { if ($e.ProviderName -like '*Outlook*') { $hits.Add($e.Id) }; $e.Dispose() } } finally { $r.Dispose() }
        $hits
    }
}
$parts = New-Object System.Collections.Generic.List[string]
$parts.Add("engine=$($PSVersionTable.PSVersion)")
foreach ($k in $forms.Keys) {
    try { $parts.Add("$k=OK$(@(& $forms[$k]).Count)") }
    catch {
        $m = ($_.Exception.Message -replace "`r?`n", ' ')
        if ($m.Length -gt 60) { $m = $m.Substring(0, 60) }
        $parts.Add("$k=ERR[$m]")
    }
}
$line = $parts -join ' '
if ($line.Length -gt 1000) { $line = $line.Substring(0, 1000) }
Write-Output $line
