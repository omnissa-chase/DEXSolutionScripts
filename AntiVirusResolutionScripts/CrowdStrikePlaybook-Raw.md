1. Is this a known CrowdStrike sensor/content issue?
   Yes -> Reboot after vendor rollback/update guidance.
   No  -> Continue.

2. Is the host on an old sensor version or bad update ring?
   Yes -> Move host to corrected Sensor Update Policy ring, then reboot if needed.
   No  -> Continue.

3. Is CPU tied to a specific workload?
   Yes -> Create a narrow Falcon exclusion from the console/API.
   No  -> Continue.

4. Is the issue reproducible and persistent?
   Yes -> Collect CSWinDiag, ProcMon/WPR if requested, open CrowdStrike Support case.