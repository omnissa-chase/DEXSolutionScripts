# SystemHealth

Check-then-apply remediations for the device-health sensors in
`GenericTroubleshooting`. Each script is self-contained, deployed through
**Omnissa Workspace ONE UEM** as SYSTEM, and reports into the DEXRecords registry
tree for **Workspace ONE DEX**. None of them require the paired sensor to have run.

| Script | Pairs with sensor | Fixes | Reports only |
|---|---|---|---|
| `Invoke-AutoRemediateTimeSync.ps1` | `TimeSyncHealth\time_sync_health.ps1` | W32Time service state and start type; domain time source (NT5DS); stale or missing sync; clock offset past the Kerberos skew limit, including clocks too far out for W32Time's own correction limit | Workgroup device with no NTP peer (unless `ConfigureWorkgroupNtp=true`); hypervisor and W32Time both syncing the clock |
| `Invoke-AutoRemediateBitLockerProtection.ps1` | `PerfomanceSensors\performance_bitlockerstatus.ps1` | Encrypted volume left with protection suspended; paused encryption | Suspension with a reboot count or a pending reboot (resumed on a later run); missing recovery password protector; escrow to Entra ID or AD on request |
| `Invoke-AutoRemediateCertEnrollment.ps1` | `CertificateStoreHealth\certificate_store_health.ps1` | Disabled CertificateServicesClient tasks; triggers autoenrollment for expiring AD CS template certificates | Expired or expiring certificates from any other issuer, with subject and template; weak signature algorithms; root auto-update disabled or stale; autoenrollment policy missing |

All three follow the family conventions:

- **WhatIf-first**: set the `WhatIf` environment variable to `true` for a dry run
  that changes nothing but still logs what it would have done. Run this first in
  any new environment.
- **Check-then-apply steps**: ordered Detection/Resolution steps with a
  Passed/Warning/Failed summary.
- **Self-gating**: each exits `0` with no changes when its subject is absent
  (no W32Time service, no BitLocker module or encrypted volume). Domain
  controllers are skipped by the time sync script.
- **Logging**: `%SystemRoot%\Temp\UEM_<ScriptName>.log`, appended every run.
- **Result caching**: summary counters under
  `HKLM:\Software\AirWatch\Extensions\<Name>\Remediation` and per-step values
  under `HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\<Name>`,
  both skipped on a WhatIf run.
- **Env-var parameters**: every tunable can be set through an identically named
  environment variable (for UEM) or passed explicitly, which wins.
- **Exit codes**: `0` success or nothing to do, `1` a remediation failed (or, for
  BitLocker, the volumes could not be queried because the script was not elevated).

## What each one will not do

- Time sync never moves the clock by hand. It configures the service and asks it
  to resync; when the source is unreachable it reports that as the error.
- BitLocker never starts encryption, decrypts, or adds or removes key protectors.
  It will not resume protection while an update's reboot-count suspension or a
  pending reboot is in place, because that is how recovery-key prompts happen.
- Certificate enrollment never deletes a certificate or touches the Root and CA
  stores, and never changes a policy registry value. It cannot renew a certificate
  that Workspace ONE, SCEP, or a vendor PKI issued; it tells you which ones those are.

## Testing

`_AutomatedTesting\` holds break tests for time sync and certificate enrollment,
built on `AutomatedTesting\DEXTestFramework.psm1`: break, verify the break,
remediate, validate, restore, with a JSON result under `C:\Temp\FixReport\`.
They need an elevated session, the test-host marker, and `-Force`.

```powershell
.\_AutomatedTesting\Invoke-AutoRemediateTimeSync_BreakTest.ps1 -RemediationTest -Force
.\_AutomatedTesting\Invoke-AutoRemediateCertEnrollment_BreakTest.ps1 -RemediationTest -Force
```

The BitLocker script has no break test. Exercising it needs a volume that is
already BitLocker-encrypted with protection suspended, which a generic harness
cannot create on an arbitrary lab host. Validate it by hand on a device in that
state: run with `WhatIf=true` first, confirm step 1 names the volume, then run
live and confirm `Get-BitLockerVolume` reports protection On.
