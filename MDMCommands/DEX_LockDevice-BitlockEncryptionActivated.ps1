<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>


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