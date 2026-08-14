#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_folder_redirection_map
    Data Type    : String (JSON)
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-14
    Timeout      : < 5 seconds (recurring sensor)

    Lists every Folder Redirection-eligible known folder for the active interactive
    user and where it currently points -- local path or UNC target -- as a single
    JSON object. Registry-only (HKU\<SID>\...\Explorer\Shell Folders / User Shell
    Folders), no disk enumeration or network calls, so this is a recurring sensor
    unlike logon_duration_measure.ps1/profile_size_inventory.ps1. It complements
    this repo's FolderRedirectMs timing signal (event IDs 501/502) with the actual
    per-folder target paths that timing alone doesn't show.

    "Shell Folders" holds the already-expanded literal path Explorer resolved (what
    a redirected folder's GPO target actually is); "User Shell Folders" can hold an
    unexpanded %VAR% string and is only used as a fallback when a value is missing
    from "Shell Folders".

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables --
# Registry value name per Folder Redirection-eligible known folder (GPMC's "Folder
# Redirection" node). GUID-named values never had a classic name -- they were added
# with Windows 7's library-based known folders.
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

try {
    $loggedOnUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    if ([string]::IsNullOrEmpty($loggedOnUser)) {
        throw 'No interactive user detected.'
    }

    $userSID = ([System.Security.Principal.NTAccount]$loggedOnUser).Translate(
        [System.Security.Principal.SecurityIdentifier]
    ).Value

    $shellFolders     = "Registry::HKEY_USERS\$userSID\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
    $userShellFolders = "Registry::HKEY_USERS\$userSID\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

    $folders = foreach ($name in $script:KnownFolders.Keys) {
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

        [PSCustomObject][ordered]@{
            Folder     = $name
            Path       = if ([string]::IsNullOrWhiteSpace($path)) { $null } else { $path }
            Redirected = ($path -like '\\*')
        }
    }

    $payload = [ordered]@{
        Status           = 'OK'
        DataCollectedAt  = (Get-Date).ToString('s')
        Username         = $loggedOnUser
        RedirectedCount  = @($folders | Where-Object { $_.Redirected }).Count
        Folders          = @($folders)
    }

    Write-Output ($payload | ConvertTo-Json -Compress -Depth 4)
    return
}
catch {
    Write-Output ([PSCustomObject]@{ Status = 'Failed'; Error = $_.Exception.Message } | ConvertTo-Json -Compress)
    return
}
