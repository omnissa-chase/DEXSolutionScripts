#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_folder_redirection_latency_probe
    Data Type    : String (JSON)
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-14
    Timeout      : < 15 seconds (one-time/run-once sensor; MUST NOT be scheduled as a recurring sensor)

    Companion to logon_folder_redirection_map.ps1. That sensor is registry-only and
    tells you WHERE each redirected known folder points; this one tells you whether
    the target is actually healthy. For every UNC-redirected folder it:
      1. Times a TCP:445 (SMB) connect to the target server -- a fast, firewall-
         friendly proxy for "is this file server reachable" and round-trip latency,
         without a real file read.
      2. Times a bounded folder-existence check. If the server is unreachable but
         the path still resolves instantly, that's a strong signal the client is
         being served from the local Offline Files (CSC) cache rather than the
         network -- exactly the "relying on caching" question this was built to
         answer. [System.IO.Directory]::Exists() has no native timeout on a dead
         UNC path, so it's run on a background runspace and hard-capped with
         AsyncWaitHandle.WaitOne() rather than trusted to fail fast.
      3. Combines reachability + latency with a static per-folder impact weight
         (AppData/Desktop/Start Menu are read synchronously during shell init and
         weighted highest; Documents/Pictures/etc. are lazy-loaded and weighted low)
         into a per-folder and overall Folder Redirection risk score.

    This is a one-time/run-once sensor (not recurring) because it makes network
    calls, which this repo's sensor conventions reserve for one-time sensors only.
    It self-enforces its own wall-clock budget below the 30 s UEM hard ceiling.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables --
$script:TimeoutSeconds  = 15
$script:TcpTimeoutMs    = 1500   # per-target SMB port connect timeout
$script:ExistsTimeoutMs = 1500   # per-target bounded existence-check timeout

# Same known-folder map as logon_folder_redirection_map.ps1, duplicated here so
# this sensor stays a single self-contained file (repo convention for sensors).
$script:KnownFolders = [ordered]@{
    'Desktop'        = 'Desktop'
    'StartMenu'      = 'Start Menu'
    'Documents'      = 'Personal'
    'Pictures'       = 'My Pictures'
    'Music'          = 'My Music'
    'Videos'         = 'My Video'
    'Favorites'      = 'Favorites'
    'AppDataRoaming' = 'AppData'
    'Downloads'      = '{374DE290-123F-4565-9164-39C4925E467B}'
    'Contacts'       = '{56784854-C6CB-462b-8169-88E350ACB882}'
    'Links'          = '{BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968}'
    'Searches'       = '{7D1D3A04-DEBB-4115-95CB-2F7A5E1BE45B}'
    'SavedGames'     = '{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}'
}

# Static impact weight: how much each folder typically costs at logon/app-start
# if its network target is slow or unreachable. Desktop/Start Menu/AppData are
# read synchronously during shell init; the rest are lazy-loaded on first open.
$script:ImpactWeight = @{
    'AppDataRoaming' = 40
    'Desktop'        = 25
    'StartMenu'      = 20
    'Documents'      = 10
    'Favorites'      = 5
    'Pictures'       = 3
    'Music'          = 3
    'Videos'         = 3
    'Downloads'      = 2
    'Contacts'       = 1
    'Links'          = 1
    'Searches'       = 1
    'SavedGames'     = 1
}

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs)
    $client = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $connected = $async.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($connected -and $client.Connected) {
            $client.EndConnect($async)
            $sw.Stop()
            return [PSCustomObject]@{ Reachable = $true; Ms = [int]$sw.ElapsedMilliseconds }
        }
        return [PSCustomObject]@{ Reachable = $false; Ms = $null }
    }
    catch {
        return [PSCustomObject]@{ Reachable = $false; Ms = $null }
    }
    finally {
        $client.Close()
    }
}

function Test-PathWithTimeout {
    param([string]$Path, [int]$TimeoutMs)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({ param($p) [System.IO.Directory]::Exists($p) }).AddArgument($Path)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $handle = $ps.BeginInvoke()
    try {
        if ($handle.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $exists = $false
            try { $exists = [bool]($ps.EndInvoke($handle) | Select-Object -First 1) } catch { }
            $sw.Stop()
            return [PSCustomObject]@{ Exists = $exists; Ms = [int]$sw.ElapsedMilliseconds; TimedOut = $false }
        }
        $ps.Stop()
        return [PSCustomObject]@{ Exists = $false; Ms = $TimeoutMs; TimedOut = $true }
    }
    finally {
        $ps.Dispose()
    }
}

function Get-SeverityLabel {
    param([bool]$Reachable, [Nullable[int]]$ConnectMs)
    if (-not $Reachable) { return 'Critical' }
    if ($ConnectMs -ge 150) { return 'Elevated' }
    return 'Normal'
}

try {
    $overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $budgetMs = $script:TimeoutSeconds * 1000

    $loggedOnUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    if ([string]::IsNullOrEmpty($loggedOnUser)) {
        throw 'No interactive user detected.'
    }

    $userSID = ([System.Security.Principal.NTAccount]$loggedOnUser).Translate(
        [System.Security.Principal.SecurityIdentifier]
    ).Value

    $shellFolders     = "Registry::HKEY_USERS\$userSID\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
    $userShellFolders = "Registry::HKEY_USERS\$userSID\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

    $results = foreach ($name in $script:KnownFolders.Keys) {
        $valueName = $script:KnownFolders[$name]
        $path = $null

        try { $path = (Get-ItemProperty -Path $shellFolders -Name $valueName -ErrorAction Stop).$valueName } catch { }
        if ([string]::IsNullOrWhiteSpace($path)) {
            try {
                $raw = (Get-ItemProperty -Path $userShellFolders -Name $valueName -ErrorAction Stop).$valueName
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $path = [System.Environment]::ExpandEnvironmentVariables($raw)
                }
            } catch { }
        }

        $redirected = ($path -like '\\*')
        if (-not $redirected) {
            [PSCustomObject][ordered]@{
                Folder             = $name
                Path               = if ([string]::IsNullOrWhiteSpace($path)) { $null } else { $path }
                Redirected         = $false
                Reachable          = $null
                ConnectMs          = $null
                LikelyServedByCache = $null
                Severity           = 'NotApplicable'
                RiskScore          = 0
            }
            continue
        }

        if ($overallStopwatch.ElapsedMilliseconds -ge $budgetMs) {
            [PSCustomObject][ordered]@{
                Folder             = $name
                Path               = $path
                Redirected         = $true
                Reachable          = $null
                ConnectMs          = $null
                LikelyServedByCache = $null
                Severity           = 'TimedOut'
                RiskScore          = -4
            }
            continue
        }

        $server = ($path -replace '^\\\\([^\\]+)\\.*$', '$1')
        $tcp = Test-TcpPort -ComputerName $server -Port 445 -TimeoutMs $script:TcpTimeoutMs

        $remainingMs = $budgetMs - $overallStopwatch.ElapsedMilliseconds
        $existsTimeout = [Math]::Min($script:ExistsTimeoutMs, [Math]::Max(0, $remainingMs))
        $exists = if ($existsTimeout -gt 0) { Test-PathWithTimeout -Path $path -TimeoutMs $existsTimeout } else { $null }

        $likelyCached = (-not $tcp.Reachable) -and $exists -and $exists.Exists -and (-not $exists.TimedOut)
        $severity = Get-SeverityLabel -Reachable $tcp.Reachable -ConnectMs $tcp.Ms
        $weight = if ($script:ImpactWeight.ContainsKey($name)) { $script:ImpactWeight[$name] } else { 1 }
        $riskScore = switch ($severity) {
            'Critical' { $weight * 3 }
            'Elevated' { [int]($weight * 1.5) }
            default    { $weight }
        }

        [PSCustomObject][ordered]@{
            Folder              = $name
            Path                = $path
            Redirected          = $true
            Reachable           = $tcp.Reachable
            ConnectMs           = $tcp.Ms
            LikelyServedByCache = $likelyCached
            Severity            = $severity
            RiskScore           = $riskScore
        }
    }

    $totalRiskScore = ($results | Measure-Object -Property RiskScore -Sum).Sum
    $overallSeverity =
        if ($totalRiskScore -ge 80) { 'Critical' }
        elseif ($totalRiskScore -ge 40) { 'Elevated' }
        elseif ($totalRiskScore -gt 0) { 'Normal' }
        else { 'NotApplicable' }

    $payload = [ordered]@{
        Status          = 'OK'
        DataCollectedAt = (Get-Date).ToString('s')
        Username        = $loggedOnUser
        TimedOut        = ($overallStopwatch.ElapsedMilliseconds -ge $budgetMs)
        OverallRiskScore = $totalRiskScore
        OverallSeverity  = $overallSeverity
        Folders         = @($results)
    }

    Write-Output ($payload | ConvertTo-Json -Compress -Depth 4)
    return
}
catch {
    Write-Output ([PSCustomObject]@{ Status = 'Failed'; Error = $_.Exception.Message } | ConvertTo-Json -Compress)
    return
}
