

$LockDevice={
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    if(-not $WhatIfPreference){
        tsdiscon.exe console
    }else{
        Write-Host "Locking machine, using soft lock."
    }
}
Try{   
    $rslt=Invoke-Command $LockDevice | Out-String
    echo $rslt
    Exit 0
}Catch{
    $rslt="An error has occured $($_.Exception.Message)"
}
Exit 1