

$LockDevice={
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    manage-bde -protectors -disable C:
    shutdown /s /f /t 0
}

Try{   
    $rslt=Invoke-Command $LockDevice | Out-String
    echo $rslt
    Exit 0
}Catch{
    $rslt="An error has occured $($_.Exception.Message)"
}
Exit 1