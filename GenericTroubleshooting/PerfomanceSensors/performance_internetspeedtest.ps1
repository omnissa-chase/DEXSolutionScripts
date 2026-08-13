#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : performance_internetspeedtest
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-11
    Timeout      : One-time / run-once sensor only. Target < 15 s, hard ceiling 30 s (UEM max).
                   MUST NOT be scheduled as a recurring sensor. See
                   GENERAL-SCRIPTS-SENSORS_RUNBOOK.md §10, "One-Time / Run-Once Sensors".

    Measures real download/upload throughput against Cloudflare's public speed-test
    endpoints and reports both figures as a single compact JSON string.

    This sensor performs live network I/O, which is normally forbidden for a sensor.
    That is only acceptable here because it is deployed as a one-time ("run-once")
    collection, never on a recurring schedule. Each phase is bounded by wall-clock
    time (read/write for N seconds, not until a fixed byte count completes) plus
    its own request timeouts, so a slow or dead link cannot stall the sensor past
    its self-enforced deadline.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables --
$DownloadTestSeconds = 4                                              # wall-clock seconds spent measuring download
$UploadTestSeconds   = 4                                              # wall-clock seconds spent measuring upload
$DownloadBaseUrl     = 'https://speed.cloudflare.com/__down'
$DownloadChunkBytes  = 26214400                                       # 25 MiB per request; larger values 403 (server-side abuse cap observed >50MB)
$UploadUrl           = 'https://speed.cloudflare.com/__up'
$RequestTimeoutMs    = 4000                                           # connect / headers timeout per request
$ReadWriteTimeoutMs  = 4000                                           # per Read()/Write() call timeout once streaming

function Get-DownloadMbps {
    param([string]$BaseUrl, [int]$ChunkBytes, [int]$DurationSeconds, [int]$RequestTimeoutMs, [int]$ReadWriteTimeoutMs)

    $buffer     = New-Object byte[] 65536
    $totalBytes = 0L
    $sw         = [System.Diagnostics.Stopwatch]::StartNew()

    # Chained bounded-size requests, not one giant request: avoids the server-side cap and lets fast links keep pulling.
    while ($sw.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $request = [System.Net.HttpWebRequest]::Create("$BaseUrl`?bytes=$ChunkBytes")
        $request.Method           = 'GET'
        $request.Timeout          = $RequestTimeoutMs
        $request.ReadWriteTimeout = $ReadWriteTimeoutMs

        $response = $request.GetResponse()
        try {
            $stream = $response.GetResponseStream()
            while ($sw.Elapsed.TotalSeconds -lt $DurationSeconds) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $totalBytes += $read
            }
        }
        finally {
            $response.Close()
        }
    }
    $sw.Stop()

    if ($sw.Elapsed.TotalSeconds -le 0) { return 0 }
    return [math]::Round((($totalBytes * 8) / $sw.Elapsed.TotalSeconds) / 1MB, 2)
}

function Get-UploadMbps {
    param([string]$Url, [int]$DurationSeconds, [int]$RequestTimeoutMs, [int]$ReadWriteTimeoutMs)

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method                  = 'POST'
    $request.ContentType             = 'application/octet-stream'
    $request.SendChunked             = $true
    $request.AllowWriteStreamBuffering = $false
    $request.Timeout                 = $RequestTimeoutMs
    $request.ReadWriteTimeout        = $ReadWriteTimeoutMs

    $buffer = New-Object byte[] 65536
    (New-Object System.Random).NextBytes($buffer)

    $totalBytes = 0L
    $sw         = [System.Diagnostics.Stopwatch]::StartNew()
    $reqStream  = $request.GetRequestStream()
    try {
        while ($sw.Elapsed.TotalSeconds -lt $DurationSeconds) {
            $reqStream.Write($buffer, 0, $buffer.Length)
            $totalBytes += $buffer.Length
        }
    }
    finally {
        $reqStream.Close()
    }
    $sw.Stop()

    try {
        $response = $request.GetResponse()
        $response.Close()
    }
    catch {
        # Response body isn't needed - throughput is measured client-side from the write loop.
    }

    if ($sw.Elapsed.TotalSeconds -le 0) { return 0 }
    return [math]::Round((($totalBytes * 8) / $sw.Elapsed.TotalSeconds) / 1MB, 2)
}

try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}
catch {}

try {
    $downloadMbps = Get-DownloadMbps -BaseUrl $DownloadBaseUrl -ChunkBytes $DownloadChunkBytes -DurationSeconds $DownloadTestSeconds `
                        -RequestTimeoutMs $RequestTimeoutMs -ReadWriteTimeoutMs $ReadWriteTimeoutMs

    $uploadMbps = Get-UploadMbps -Url $UploadUrl -DurationSeconds $UploadTestSeconds `
                      -RequestTimeoutMs $RequestTimeoutMs -ReadWriteTimeoutMs $ReadWriteTimeoutMs

    $result = [PSCustomObject]@{
        Status       = 'Success'
        DownloadMbps = $downloadMbps
        UploadMbps   = $uploadMbps
        TestedAt     = (Get-Date -Format 's')
    }

    Write-Output ($result | ConvertTo-Json -Compress)
    return
}
catch {
    $result = [PSCustomObject]@{
        Status = 'Failed'
        Error  = $_.Exception.Message
    }

    Write-Output ($result | ConvertTo-Json -Compress)
    return
}
