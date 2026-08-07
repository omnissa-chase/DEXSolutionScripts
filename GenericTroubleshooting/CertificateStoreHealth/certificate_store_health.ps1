<#
.NOTES
    Script Name  : certificate_store_health.ps1
    Data Type    : String (JSON)
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07
    Timeout      : < 5 seconds

    Reports on the health of the machine certificate stores (LocalMachine\My,
    Root, CA) without any network calls -- no CRL/OCSP revocation checking, which
    would make this sensor's runtime depend on a CA endpoint's availability.

    LocalMachine\My holds the certs that actually break something when they expire
    -- device/computer auth for VPN, Wi-Fi, SCCM, and WS1/Intune -- so it gets full
    expiry and weak-algorithm detail. Root/CA are counted and checked for expiry
    only: an expired root or intermediate is rare but breaks trust fleet-wide (see
    the 2021 Sectigo/Let's Encrypt root-expiry incidents). Windows never purges
    old roots though, so a handful of expired ones sitting unused is completely
    normal cruft -- ExpiredRootOrCACount only escalates past a noise threshold.

    Running as SYSTEM reads SYSTEM's own CurrentUser store, not the logged-on
    user's -- LocalMachine stores are used deliberately so context doesn't matter.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $ExpiringSoonDays        = 30
    # Windows accumulates expired roots for years without purging them; only an
    # unusually large pile suggests a trust store that has stopped updating.
    $ExpiredRootOrCANoiseMax = 20
    $Now = Get-Date

    function Get-StoreCerts {
        param([string]$StorePath)
        Get-ChildItem -Path $StorePath -ErrorAction SilentlyContinue
    }

    $personalCerts = @(Get-StoreCerts -StorePath 'Cert:\LocalMachine\My')
    $rootCerts     = @(Get-StoreCerts -StorePath 'Cert:\LocalMachine\Root')
    $caCerts       = @(Get-StoreCerts -StorePath 'Cert:\LocalMachine\CA')

    $weakAlgoPattern = 'md5|sha1'

    $expiredPersonal   = @($personalCerts | Where-Object { $_.NotAfter -lt $Now })
    $expiringSoon      = @($personalCerts | Where-Object { $_.NotAfter -ge $Now -and $_.NotAfter -le $Now.AddDays($ExpiringSoonDays) })
    $weakAlgoPersonal  = @($personalCerts | Where-Object { $_.SignatureAlgorithm.FriendlyName -match $weakAlgoPattern })
    $selfSignedCount   = @($personalCerts | Where-Object { $_.Subject -eq $_.Issuer }).Count

    $daysUntilNextExpiry = -1
    $upcoming = $personalCerts | Where-Object { $_.NotAfter -ge $Now } | Sort-Object NotAfter | Select-Object -First 1
    if ($upcoming) {
        $daysUntilNextExpiry = [int][math]::Ceiling(($upcoming.NotAfter - $Now).TotalDays)
    }

    $expiredRootOrCA = @(($rootCerts + $caCerts) | Where-Object { $_.NotAfter -lt $Now })

    $overallStatus = if ($expiredPersonal.Count -gt 0 -or $expiredRootOrCA.Count -gt $ExpiredRootOrCANoiseMax) {
        'Critical'
    } elseif ($expiringSoon.Count -gt 0 -or $weakAlgoPersonal.Count -gt 0 -or $expiredRootOrCA.Count -gt 0) {
        'Warning'
    } else {
        'Healthy'
    }

    $result = [PSCustomObject]@{
        GeneratedAt                 = $Now.ToString('yyyy-MM-dd HH:mm:ss')
        OverallStatus               = $overallStatus
        PersonalStoreCount          = $personalCerts.Count
        ExpiredPersonalCount        = $expiredPersonal.Count
        ExpiringSoonCount           = $expiringSoon.Count
        DaysUntilNextExpiry         = $daysUntilNextExpiry
        WeakSignatureAlgorithmCount = $weakAlgoPersonal.Count
        SelfSignedPersonalCount     = $selfSignedCount
        RootStoreCount              = $rootCerts.Count
        CAStoreCount                = $caCerts.Count
        ExpiredRootOrCACount        = $expiredRootOrCA.Count
    }

    Write-Output ($result | ConvertTo-Json -Compress)
}
catch {
    Write-Output ([PSCustomObject]@{ OverallStatus = 'Unknown'; Error = $_.Exception.Message } | ConvertTo-Json -Compress)
}
