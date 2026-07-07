
$SignoffDevice={
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    if(-not $WhatIfPreference){
        $console = (Get-CimInstance Win32_ComputerSystem).UserName.Split('\')[-1]
        $sessionId = (quser | Select-String $console).ToString().Trim().Split()[2]
        logoff $sessionId
    }Else{
        Write-Host "WhatIf: Would sign off the active console user session"
    }
}

Try{   
    $rslt=Invoke-Command $SignoffDevice | Out-String
    echo $rslt
    Exit 0
}Catch{
    $rslt="An error has occured $($_.Exception.Message)"
}
Exit 1