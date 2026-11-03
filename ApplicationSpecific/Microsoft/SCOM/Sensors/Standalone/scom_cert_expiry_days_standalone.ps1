#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_cert_expiry_days_standalone
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 2 seconds
    Requires     : nothing -- measures the device directly, no cache, no sweep script

    Days until the agent's channel certificate expires. There is no cached twin --
    the sweep records CertExpiryDays but exposes it only through the health score --
    so this is new here rather than a replacement.

    Negative values other than the sentinels are real and mean already expired: -3 is
    a certificate that lapsed three days ago and an agent that cannot authenticate.

    Sentinels:
      -1    Not measured. No agent, or the certificate store could not be read.
      -9999 A serial number IS configured but no matching certificate exists in
            LocalMachine\My. The agent is configured for certificate authentication
            and has nothing to authenticate with -- the worst state this sensor can
            report, and it is invisible to a plain expiry check because there is no
            date to compare. PKI action: re-issue and re-import with MOMCertImport.
      -9998 Not applicable: no channel certificate is configured. Domain-joined agents
            authenticate with Kerberos and legitimately have none. This is the
            expected value across most fleets and is NOT a finding.

    Sort ascending to triage and the order falls out correctly: missing certificate
    first, then expired, then expiring, then healthy -- with the not-applicable
    population parked at -9998 where a range filter of "less than 30" would otherwise
    swallow it. Filter -9998 out before counting anything.

    Certificate renewal is a PKI action. Nothing on the endpoint can fix a lapsed
    channel certificate, which is why the sweep reports this step and never
    remediates it.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $agentRoot = $null
    foreach ($candidate in @('HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0',
                             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft Operations Manager\3.0')) {
        if (Test-Path $candidate -ErrorAction SilentlyContinue) { $agentRoot = $candidate; break }
    }
    if (-not $agentRoot) { Write-Output -1; return }

    $machineSettings = Get-ItemProperty -Path (Join-Path $agentRoot 'Machine Settings') -ErrorAction SilentlyContinue
    $serial = if ($machineSettings) { $machineSettings.ChannelCertificateSerialNumber } else { $null }

    if (-not $serial) { Write-Output -9998; return }

    # The registry stores the serial as a reversed byte array on every build seen in
    # the field, but treat a string value as already-formatted rather than throwing
    # the whole reading away on an unexpected type.
    $serialHex = ''
    if ($serial -is [byte[]]) {
        $bytes = [byte[]]::new($serial.Length)
        [array]::Copy($serial, $bytes, $serial.Length)
        [array]::Reverse($bytes)
        $serialHex = (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join '')
    }
    else {
        $serialHex = ([string]$serial).Replace(' ', '').ToUpperInvariant()
    }

    if ([string]::IsNullOrWhiteSpace($serialHex)) { Write-Output -1; return }

    $cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
            Where-Object { $_.SerialNumber -eq $serialHex } | Select-Object -First 1

    if (-not $cert) { Write-Output -9999; return }

    Write-Output ([int][math]::Round(($cert.NotAfter - (Get-Date)).TotalDays))
    return
}
catch {
    Write-Output -1
    return
}
