$services = ConvertTo-Json (Get-Service -ErrorAction SilentlyContinue | Where Status -eq "Running" | Select Name) -Compress -ErrorAction SilentlyContinue
echo $services