
$SignoffDevice={
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    if(-not $WhatIfPreference){
        $sessionId = (quser | Select-String $console).ToString().Split()[2]
        logoff $sessionId
        $console = (Get-CimInstance Win32_LogonSession -Filter "LogonType=2" |
            Get-CimAssociatedInstance -ResultClassName Win32_LoggedOnUser |
            Select-Object -ExpandProperty Antecedent |
            ForEach-Object { $_.ToString().Split('"')[1] })
    }Else{

    }
}

