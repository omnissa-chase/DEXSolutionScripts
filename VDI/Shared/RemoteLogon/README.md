# Remote Desktop logon rights

Tools for one fault that looks like a broken session host and is not: the host is
healthy, the connection reaches it, the password is accepted, and the logon is still
refused.

Applies to any Windows device reached over RDP: Azure Virtual Desktop and Windows 365
session hosts, Horizon and RDS hosts, and machines reached through Azure Bastion.

| File | Type | What it does |
|---|---|---|
| [OneTimeSensor/rdp_logon_health.ps1](OneTimeSensor/rdp_logon_health.ps1) | One-time sensor (String, JSON) | Triage. One JSON line with the RDP state, both logon rights, refused and successful remote logons, a 0-100 score, the leading reason and the next step. Read-only. |
| [Invoke-AutoRemediateRdpLogonRights.ps1](Invoke-AutoRemediateRdpLogonRights.ps1) | Script | Fix. Clears population-wide entries from the deny right and restores the default allow entries. |

Both run as SYSTEM under Windows PowerShell 5.1 and fit the pre-2607 script size limit.

## The fault

A security baseline or GPO writes the user right **Deny log on through Remote Desktop
Services** (`SeDenyRemoteInteractiveLogonRight`) with a broad entry such as *Local
account* (`S-1-5-113`). Every account in that population is then refused at logon.

Baselines tattoo. Removing the baseline from the device does not remove the setting, so
the lockout outlives the policy that caused it.

How it shows up:

| Where | What you see |
|---|---|
| The user | Credentials are accepted, then "the sign-in method you're trying to use isn't allowed" or an immediate disconnect. |
| AVD portal | Session host **Available**, all health checks passing. |
| Security log on the host | Event 4625, logon type 10, status `0xC000015B` (the user has not been granted the requested logon type). |
| RemoteConnectionManager log | Event 1149, "User authentication succeeded", moments before each refusal. |

Console access through Workspace ONE Assist keeps working, because it is not a Remote
Desktop logon.

## Triage: `rdp_logon_health`

Run it on demand from the DEX console. It reads the logon rights straight from the LSA
policy store, so it launches no process and returns in about two seconds.

| `Reason` | Points | Meaning | `Next` |
|---|---:|---|---|
| `LogonDeniedByRight` | 40 | The deny right holds a population-wide entry (`DenyR` lists them). | Run the remediation with `ConfirmHighImpact = true`. |
| `RdpDisabled` | 40 | `fDenyTSConnections = 1`. | Admin: enable Remote Desktop or fix the policy that turned it off. |
| `AllowRightMissingDefaults` | 30 | Administrators or Remote Desktop Users is missing from the allow right (`AllowMiss`). | Run the remediation. |
| `ListenerDisabled` | 30 | The RDP-Tcp listener is disabled. | Admin. |
| `PkuDisabled` | 30 | PKU2U online identities are refused on an Entra-joined host, which blocks Entra sign-in over RDP. | Admin. |
| `RefusedForRights` | 25 | Users were refused with `0xC000015B`, have not logged on since (`RefU`), and both rights look clean. | Check Remote Desktop Users membership and the host pool assignment. |
| `AgentCheckFailing` | 20 | The AVD agent's own health report lists a failing check (`AvdChk`). | AVD session host remediation. |
| `FirewallIgnoresRules` | 15 | A firewall profile blocks all inbound connections, allowed rules included. Not scored on AVD hosts, which use reverse connect and need no inbound rule. | Admin. |
| `BadCredentials` | 10 | Five or more refusals for a wrong password or unknown user. | User. |
| `RdpCertExpired` | 10 | The RDP listener certificate has expired. | Admin. |

`Ref`, `Ref15B` and `RefS` count refused remote logons in the last 48 hours by status
code. `Ok` and `OkAt` give the successful ones, so a refusal that was followed by a good
logon does not score.

## Fix: `Invoke-AutoRemediateRdpLogonRights.ps1`

| Step | Name | Behaviour |
|---|---|---|
| 1 | Deny Remote Desktop Logon Right | Removes Local account, Everyone, Authenticated Users, Users, Administrators, Remote Desktop Users and Domain Users from the deny right. Guest and named accounts stay. |
| 2 | Allow Remote Desktop Logon Right | Restores Administrators and Remote Desktop Users when missing. |
| 3 | Refused Remote Logons | Report: refusals by status code with the users affected. |
| 4 | Remote Desktop Users Membership | Report: who can log on when the rights are clean and logons are still refused. |
| 5 | Policy Reapply Check | Report: a fix made by this script was undone since the last run. |

Step 1 loosens a security setting, so it has three gates. All three must pass or the
step reports and changes nothing:

1. **Confirmation.** The script variable `ConfirmHighImpact` is `true`.
2. **Evidence.** The Security log holds at least one `0xC000015B` remote-logon refusal
   in the last 48 hours. A deny entry nobody has tripped over is left alone.
3. **Cap.** Fewer than two fixes in the last 24 hours. After that the step is held: a
   setting that keeps coming back is being enforced, and the fix belongs at the source.

| Script variable | Default | Effect |
|---|---|---|
| `ConfirmHighImpact` | absent (off) | `true` lets step 1 change the deny right. |
| `WhatIf` | absent (live) | `true` reports what would change and changes nothing. |

Exit code 1 only when a fix was attempted and failed. Results are cached under
`HKLM:\Software\AirWatch\Extensions\VDI\Shared\RemoteLogon\Remediation`; the log is
`%SystemRoot%\Temp\UEM_AutoRemediateRdpLogonRights.log`.

## Runbook: the baseline was removed and the lockout stayed

1. **Confirm.** Run `rdp_logon_health`. `Reason = LogonDeniedByRight` with `Ref15B > 0`
   confirms the fault. If the reason is anything else, follow its `Next` value instead.
2. **Stop the source first.** Unassign the baseline or GPO that sets the deny right, or
   change it to the entry you actually want (for example Guests only). If the source
   stays assigned, it writes the entry back at its next refresh and the fix will not hold.
3. **Fix.** Run `Invoke-AutoRemediateRdpLogonRights.ps1` with `ConfirmHighImpact = true`.
   The change takes effect at the next logon; no restart is needed.
4. **Verify.** Run `rdp_logon_health` again. Expect `DenyR` empty and the reason no
   longer `LogonDeniedByRight`. Ask the user to connect.
5. **If it returns.** Step 5 of the remediation reports a fix that was undone, and step 1
   holds after two fixes in 24 hours. Go back to step 2: something still enforces the
   setting.

Deploy the remediation to a smart group of affected hosts, not fleet-wide. On a host
where the deny entry is intended (a hardened server where local accounts must never use
RDP), leave `ConfirmHighImpact` unset and the script only reports.
