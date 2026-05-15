# Name: performance_network_test
# Type: PowerShell 
# Context: System 
# Data Type: String 

#These are the Workspace ONE assist servers in each Geo
$Targets = @{"NorthAmerica"="https://rm01.awmdm.com"; "Singapore"="https://rmsg01.awmdm.com"}


$Results = ""
ForEach($TargetGeo in $Targets.Keys){
    $Target=$Targets[$TargetGeo]
    $WindowSizeKB = 64 # Common default window size (in KB)
    $MeasureRequest =  (Measure-Command { Invoke-WebRequest -Uri $Target -Method Get -UseBasicParsing -ErrorAction SilentlyContinue } -ErrorAction SilentlyContinue)
    if(-not ($MeasureRequest)){
        continue
    }
    $LatencyMs = $MeasureRequest.TotalMilliseconds
    if (![string]::IsNullOrEmpty($Results)){
        $Results += ";"
    }
    if ($LatencyMs -gt 0) {
        # 2. Convert Window Size to bits
        $WindowSizeBits = $WindowSizeKB * 1024 * 8

        # 3. Calculate Throughput: (WindowSize / Latency) * 1000 (to convert ms to s)
        $ThroughputBps = ($WindowSizeBits / $LatencyMs) * 1000
        $ThroughputMbps = [math]::Round($ThroughputBps / 1mb, 2)
        
        $Results += "$TargetGeo`:$ThroughputMbps Mbps"
    } else {
        $Results += "Failed to measure latency for $Target."
    }
}

echo $Results

