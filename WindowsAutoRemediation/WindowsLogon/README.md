# WindowsLogon

A collection of PowerShell scripts that target the specific phases of Windows logon most likely to add measurable delay: FSLogix container attach, per-user cache bloat, contention from third-party `AtLogOn` scheduled tasks, and inbox AppX registration. Each script is a self-contained check-then-apply remediation intended for deployment via **Omnissa Workspace ONE UEM** and monitored through **Omnissa Workspace ONE DEX**.

Pairs with `GenericTroubleshooting\WindowsStartup\Measure-LogonDuration.ps1`, which reports the phase-by-phase timings these scripts address, but none of the scripts below require it to have run first.

---

## Scripts Overview

| Script | Targets | Default Behavior |
|---|---|---|
| `Invoke-AutoRemediateFSLogixExclusions.ps1` | Slow FSLogix VHD(X) attach caused by real-time AV scanning | Adds Defender exclusions only |
| `Invoke-AutoRemediateProfileBloat.ps1` | Bloated per-user cache data inflating profile load | Deletes aged, regenerable caches |
| `Invoke-AutoRemediateLogonTaskContention.ps1` | Third-party `AtLogOn` scheduled tasks competing with the shell | Staggers task trigger delays |
| `Invoke-AutoRemediateAppXBloat.ps1` | Inbox AppX packages adding AppReadiness registration load | Deprovisions for future users only |

All four follow the same conventions:

- **WhatIf-first**: set the `WhatIf` environment variable to `true` for a dry run that changes nothing but still logs what it would have done. This is the recommended first execution in any new environment.
- **Check-then-apply steps**: each script runs a small set of ordered Detection/Resolution steps and prints a Passed/Warning/Failed summary per step.
- **Self-gating**: each script exits cleanly (exit code `0`) with no changes if its prerequisite (FSLogix, `Get-ScheduledTask`, `Get-AppxProvisionedPackage`) isn't present on the device.
- **Logging**: writes to `%SystemRoot%\Temp\UEM_<ScriptName>.log`, appended on every run including WhatIf.
- **Result caching**: writes a summary to a script-specific `HKLM:\Software\AirWatch\Extensions\<Name>\Remediation` key — skipped entirely on a WhatIf run so a dry run can't be mistaken for an applied one.
- **Env-var parameters**: every tunable parameter can be set via an identically-named environment variable (for UEM deployment) or passed explicitly (which always wins).

---

## Invoke-AutoRemediateFSLogixExclusions.ps1

Applies Microsoft's documented Defender exclusions for FSLogix (processes, VHD/VHDX paths read from FSLogix's own `VHDLocations` config, Cache/Proxy paths). Purely additive — never removes an exclusion and touches no user data.

| Parameter | Default | Description |
|---|---|---|
| *(none — reads FSLogix config directly)* | | |

Registry: `HKLM:\Software\AirWatch\Extensions\FSLogix\Remediation`

---

## Invoke-AutoRemediateProfileBloat.ps1

Deletes aged temp files, browser caches (Chrome/Edge/Firefox), Teams cache, Explorer thumbnail/icon caches, crash dumps, RDP/shader caches, and Recent items/jump lists. Reports (does not remediate) oversized roaming AppData and oversized registry hives (`NTUSER.DAT`/`UsrClass.dat`).

| Parameter | Default | Description |
|---|---|---|
| `MinFileAgeDays` | `7` | Minimum file age before a cache item is eligible for deletion |
| `MinSizeThresholdMB` | `50` | Minimum size a cache category must reach before cleanup runs |
| `RoamingWarnMB` | `500` | Roaming AppData size that triggers a warning (report-only) |
| `HiveWarnMB` | `100` | Registry hive size that triggers a warning (report-only) |

Registry: `HKLM:\Software\AirWatch\Extensions\ProfileBloat\Remediation`

Never touches Documents, Desktop, Downloads, bookmarks, browser history, saved credentials, or Outlook data files. Complements (does not duplicate) `DiskCleanup\Start-UserProfileCleanup.ps1`, which deletes whole inactive profiles.

---

## Invoke-AutoRemediateLogonTaskContention.ps1

Finds enabled, non-`\Microsoft\`-namespace scheduled tasks with an `AtLogOn` trigger and raises/staggers each qualifying trigger's `Delay` so they don't all fire at once against the shell/profile load. Reports (does not remediate) when the number of qualifying tasks exceeds a warn threshold.

| Parameter | Default | Description |
|---|---|---|
| `MinDelaySeconds` | `60` | Minimum logon-trigger delay a task must have |
| `StaggerSeconds` | `30` | Additional delay applied per task, in trigger order, above `MinDelaySeconds` |
| `TaskVolumeWarnCount` | `8` | Qualifying task count that triggers a report-only warning |

Registry: `HKLM:\Software\AirWatch\Extensions\LogonTaskContention\Remediation`

Only ever adds or increases a trigger's `Delay` — never disables, deletes, or changes what a task runs. OS-owned (`\Microsoft\*`) tasks are never touched.

---

## Invoke-AutoRemediateAppXBloat.ps1

Deprovisions non-essential inbox AppX packages (Xbox companion apps, Solitaire, Weather, News, People, Mixed Reality Portal, Messaging, Skype, Feedback Hub, 3D tools, Maps, Wallet, Family Safety, Clipchamp) via a curated deny list, reducing AppReadiness registration work at logon.

| Parameter | Default | Description |
|---|---|---|
| `DenyListExtra` | *(empty)* | Comma-separated extra `DisplayName` wildcard patterns to remove, in addition to the built-in default list |
| `RemoveForExistingUsers` | `false` | When `true`, also removes matching packages already installed for existing users, not just future ones |

Registry: `HKLM:\Software\AirWatch\Extensions\AppXBloat\Remediation`

A hard-coded safelist (Calculator, Camera, Notepad, Paint, Snip & Sketch, Store, Photos, Terminal, To Do, Widgets host, Defender UI, shell/framework components) **cannot be overridden** by `DenyListExtra` — it's a fixed safety net, not a configurable option. By default, only future user profiles are affected; enable `RemoveForExistingUsers` only after reviewing the deny list for the environment, since it removes Start Menu tiles from already-installed profiles. Deliberately excludes Cortana, Phone Link, and Widgets from the default list due to ambiguous enterprise use — add them via `DenyListExtra` only after confirming they're unused.

Complements (does not duplicate) `UnmanagedAppReport\Get-StartupApps.ps1`, which only covers Run-key/Startup-folder apps, not AppX.

---

## Deployment (Workspace ONE UEM)

- **Script Type:** PowerShell
- **Execution Context:** System
- **Timeout:** 60–90 seconds is sufficient for all four scripts
- **Recommended rollout:** deploy each script with `WhatIf=true` first, review the logs and registry-reported findings, then remove `WhatIf` (or set it to `false`) once the findings look expected for the target ring.
