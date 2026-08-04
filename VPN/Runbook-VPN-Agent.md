# Agent Runbook — VPN Health and Remediation (Omnissa Intelligent Hub)

**Trigger:** A VPN health sensor crosses a threshold in DEX (vpn_health_score declining,
vpn_connected = false, vpn_flap_count_24h elevated), a user-initiated "I can't access
anything on VPN" Hub interaction, or a network-dependent experience score drop on a
device where VPN is expected to be active.

**Agent context:** The agent runs inside the Omnissa Intelligent Hub on the end user's
device. It has read access to DEX telemetry and sensor history, and can build and
execute Quickflows to run scripts, MDM commands, install/remove apps, and push profiles.

**Goal:** Autonomously identify why VPN health is degraded, remediate the layers Windows
owns, clearly communicate what was done and what it cannot fix, and escalate when the
root cause requires a vendor client action or an administrator decision.

---

## Scope -- What This Runbook Can and Cannot Fix

**The fundamental constraint:** A VPN tunnel is two things at once -- a Windows network
interface, and a session owned by a vendor client. Windows owns the interface, so MTU,
DNS registration, routing, and the supporting services are all fixable by running
`Invoke-AutoRemediateGenericVPN.ps1`. Windows does not own the session. There is no
OS-level "reconnect the VPN" -- initiating a connection is a vendor CLI call, every
vendor spells it differently, and generic code cannot safely bridge that gap.

| Health Reason | Fixable Generically? | Approach |
|---|---|---|
| `Healthy` | N/A | No action needed |
| `NoVpnClient` | No | Report only; VPN client deployment is an ADMIN decision |
| `TunnelDown` | No | Generic can only check/fix prerequisites; reconnect is vendor |
| `MtuNotReducedForTunnel` | Yes | AUTO -- set MTU on the tunnel interface |
| `MtuBelowMinimum` | Yes | AUTO -- set MTU to safe value |
| `NoDnsOnTunnel` | Partially | AUTO -- flush and re-register; servers come from vendor profile |
| `HighPacketDiscardRate` | Partially | AUTO -- MTU fix may resolve; otherwise flag for ADMIN |
| `FrequentReconnects` | No | AUTO can verify prerequisites; reconnect trigger is vendor |
| `IntermittentReconnects` | No | Same as FrequentReconnects |
| `RepeatedConnectFailures` | No | AUTO can verify service health; connection attempt is vendor |
| `MultipleVpnClients` | No | Report only -- removal requires admin decision |
| `CollectionError` | Yes | AUTO -- re-run collection script |

---

## Intervention Key

| Symbol | Meaning |
|--------|---------|
| AUTO   | Agent can resolve autonomously via Quickflow |
| USER   | Requires the end user to take action |
| ADMIN  | Requires an IT administrator to intervene |
| INFORM | Informational step only -- no remediation needed |

---

## Sensor Reference

The following sensors are read from the registry cache written by
`Invoke-VpnStateCollection.ps1` (HKLM:\Software\AirWatch\Extensions\VPN).
Quickflows that read these must schedule or pre-run the collection script first.

| Sensor | Data Type | Key Question It Answers |
|---|---|---|
| `vpn_health_score` | Integer (0-100, -1 = no client) | Is this device's VPN healthy overall? |
| `vpn_health_reason` | String | What is the single largest problem? |
| `vpn_connected` | Boolean | Is a tunnel active right now? |
| `vpn_tunnel_mode` | String (Full / Split / None) | Is all traffic tunnelled or just some? |
| `vpn_adapter_name` | String | Which VPN client is actually carrying traffic? |
| `vpn_tunnel_mtu` | Integer | Is encapsulation overhead accounted for? |
| `vpn_last_connect_time` | Date Time | When did the tunnel last come up? |
| `vpn_session_duration_minutes` | Integer | Has the session been stable? |
| `vpn_flap_count_24h` | Integer | How many times has the tunnel dropped today? |
| `vpn_connect_failure_count_24h` | Integer | How many connection attempts failed today? |
| `vpn_dns_configured` | Boolean | Will internal names resolve over the tunnel? |
| `vpn_discard_rate_ppm` | Integer | Is the tunnel dropping packets? |
| `vpn_client_count` | Integer | Are multiple VPN clients competing? |

---

## Phase 1 -- Triage: Confirm and Characterize the Problem

### 1.1 Establish VPN Baseline

**AUTO** -- Run Quickflow to ensure `Invoke-VpnStateCollection.ps1` has run recently.
If `LastRun` in the registry is older than 30 minutes, run the collection script now
before reading any sensor values.

Pull from DEX sensors:

- `vpn_health_score` -- overall health
- `vpn_connected` -- current tunnel state
- `vpn_health_reason` -- leading problem
- `vpn_client_count` -- how many clients are installed

**Decision:**

| Condition | Action |
|---|---|
| `vpn_health_score` = -1 OR `vpn_client_count` = 0 | No VPN client present. Skip to Phase 7. |
| `vpn_health_score` >= 80 | Score is healthy; issue may be transient. Notify user and close. |
| `vpn_health_score` 50-79 | Moderate degradation. Proceed -- likely a fixable configuration problem. |
| `vpn_health_score` < 50 OR `vpn_connected` = false | Severe degradation or tunnel down. Proceed urgently. |

> Agent message to user: "I'm checking your VPN connection now. I'll update you shortly."

### 1.2 Read the Leading Health Reason

Read `vpn_health_reason` and route to the corresponding phase:

| Health Reason | Next Phase |
|---|---|
| `TunnelDown` | Phase 2 |
| `FrequentReconnects` / `IntermittentReconnects` | Phase 3 |
| `RepeatedConnectFailures` | Phase 4 |
| `MtuNotReducedForTunnel` / `MtuBelowMinimum` | Phase 5 |
| `NoDnsOnTunnel` | Phase 6 |
| `HighPacketDiscardRate` | Phase 5 (MTU likely cause), then Phase 6 |
| `MultipleVpnClients` | Phase 7 |
| `CollectionError` | Phase 8 |

The health reason is the single largest deduction. Other deductions may also be present --
after resolving the leading reason, re-run the collection script and re-read the score
to determine whether secondary issues remain.

---

## Phase 2 -- Tunnel Down

**Indicator:** `vpn_connected` = false, or `vpn_health_reason` = `TunnelDown`.

The tunnel is not up. The generic layer can verify and repair prerequisites, but it
cannot reconnect the tunnel -- that is the vendor client's job.

### 2.1 Verify VPN Support Services

**AUTO** -- Quickflow: run `Invoke-AutoRemediateGenericVPN.ps1`.

This script checks and corrects:
- RasMan, IKEEXT, and BFE service state
- Orphaned routes left by a previous session that crashed
- Tunnel MTU and DNS if a tunnel is active

If the script remediates service issues, wait 60 seconds, then re-run
`Invoke-VpnStateCollection.ps1` and re-read `vpn_connected`.

### 2.2 Check Network Prerequisites

**AUTO** -- If tunnel is still down after service check, run
`Invoke-AutoRemediateNetworkStack.ps1` to verify:
- DNS resolution to external names is working
- The default gateway is reachable
- The underlying physical adapter is healthy

If the network stack itself is broken, no VPN client can establish a tunnel regardless
of its own health. Fix the underlying network first.

### 2.3 Ask the User to Reconnect

Once prerequisites are confirmed healthy:

**USER** -- Instruct the user to manually open the VPN client and connect.

> Agent message to user: "Your VPN isn't currently connected. I've checked the
> underlying network connection and everything on your device looks healthy. Please open
> your VPN application and connect. Let me know if you get an error message when you try."

**AUTO** -- After 2 minutes, re-read `vpn_connected`. If still false:

> Agent message to user: "I'm still not seeing an active VPN connection. Could you tell
> me what happens when you try to connect -- do you get an error message?"

### 2.4 If User Reports an Error Message

Capture the error text if possible (user describes it or Hub can read a vendor log).
Pass to Phase 4 (connect failure analysis) with the error context.

### 2.5 Escalation

**ADMIN** -- If tunnel remains down after service remediation, network checks, and
one user reconnection attempt: raise a ticket with:
- `vpn_health_score` history (last 24h if available in DEX)
- `vpn_adapter_name` (which client)
- `vpn_connect_failure_count_24h`
- Output of `Invoke-AutoRemediateGenericVPN.ps1`
- Any error message captured from the user

---

## Phase 3 -- Frequent or Intermittent Reconnects

**Indicator:** `vpn_flap_count_24h` >= 4, or `vpn_health_reason` is
`FrequentReconnects` or `IntermittentReconnects`.

The tunnel is reconnecting -- possibly too quickly to notice in any single check,
but enough to break in-flight sessions (RDP disconnects, file transfers, application
session timeouts) throughout the day. This is frequently more disruptive than a tunnel
that is simply down, because each individual check finds the tunnel "connected".

### 3.1 Correlate with MTU and Packet Loss

**AUTO** -- Read `vpn_discard_rate_ppm` and `vpn_tunnel_mtu`.

| Condition | Action |
|---|---|
| `vpn_tunnel_mtu` >= 1500 | MTU is likely causing session resets. Go to Phase 5. |
| `vpn_discard_rate_ppm` > 1000 | Elevated packet loss. MTU fix is the first lever. Go to Phase 5. |
| Both healthy | Reconnects are not MTU-driven. Proceed to 3.2. |

### 3.2 Check Physical Network Stability

**AUTO** -- Quickflow sensor: check Wi-Fi signal quality and adapter statistics.

- If the device is on Wi-Fi and the signal is weak or fluctuating, the VPN tunnel
  will flap with the underlying connection. The VPN is a symptom here, not the cause.
- If the device is wired, check for duplex mismatch or driver issues.

**USER** -- If on Wi-Fi with poor signal:
> Agent message to user: "Your VPN appears to be reconnecting frequently, which is often
> caused by an unstable Wi-Fi connection. Try moving closer to your Wi-Fi access point,
> or connecting via an ethernet cable if possible."

### 3.3 Check Session Duration Pattern

**AUTO** -- Read `vpn_session_duration_minutes` and `vpn_last_connect_time`.

If `vpn_session_duration_minutes` is consistently very short (< 10 minutes) across
multiple DEX samples, the client may be hitting a session timeout configured in the
VPN gateway profile. This is a gateway policy setting, not a device fault.

**ADMIN** -- If sessions are consistently short and the physical network is stable:
raise a ticket to the VPN team to review session timeout and re-authentication
settings in the gateway profile.

### 3.4 Run Generic Remediation

**AUTO** -- Run `Invoke-AutoRemediateGenericVPN.ps1` to clear any orphaned routes
from prior sessions and verify service health. Orphaned routes from crashed sessions
can interfere with reconnection negotiation on some clients.

**ADMIN** -- If flap count remains high after MTU fix and orphaned route cleanup:
escalate. The reconnect trigger is inside the vendor client or the gateway.

---

## Phase 4 -- Repeated Connection Failures

**Indicator:** `vpn_connect_failure_count_24h` >= 5, or `vpn_health_reason` =
`RepeatedConnectFailures`.

Note: `vpn_connect_failure_count_24h` is sourced from the RasClient event log, which
only covers the Windows built-in VPN stack. A device running a third-party client (Cisco
Secure, GlobalProtect, Zscaler, etc.) will show 0 here even if the client is failing.
Treat 0 on a third-party client as "unknown", not "no failures".

### 4.1 Check Service Health First

**AUTO** -- Run `Invoke-AutoRemediateGenericVPN.ps1`. A stopped IKEEXT or RasMan
service will cause IKEv2 and L2TP connection attempts to fail immediately.

If services were stopped or disabled and are now restarted:
- Ask user to retry the connection
- Re-read sensors after 2 minutes

### 4.2 Check Network Prerequisites

**AUTO** -- Run `Invoke-AutoRemediateNetworkStack.ps1` to confirm DNS resolution,
gateway reachability, and internet connectivity are intact.

VPN connection failures where the network stack is also broken are almost always
a network problem, not a VPN problem. Fix the network first.

### 4.3 Identify the Client

**AUTO** -- Read `vpn_adapter_name`. Pass to the vendor-specific runbook if one exists:

| Adapter Name Contains | Vendor Runbook |
|---|---|
| CrowdStrike ZTNA / Falcon | N/A (not a traditional VPN) |
| Cisco | Cisco AnyConnect / Secure Client runbook |
| Palo Alto / GlobalProtect | GlobalProtect runbook |
| Zscaler | Zscaler Client Connector runbook |
| Juniper / Pulse | Pulse Secure runbook |
| Windows Built-in (IKEv2/L2TP) | Consult RasClient event log errors |
| Unknown / Not on list | Generic escalation |

**ADMIN** -- If vendor runbook applies: trigger it. If not: raise a ticket with
the full output of `Invoke-AutoRemediateGenericVPN.ps1`, `vpn_adapter_name`, and
`vpn_connect_failure_count_24h`.

---

## Phase 5 -- MTU Problem (MtuNotReducedForTunnel / MtuBelowMinimum / HighPacketDiscardRate)

**Indicator:** `vpn_tunnel_mtu` >= 1500, `vpn_tunnel_mtu` < 1280, or
`vpn_discard_rate_ppm` > 1000 with a healthy physical connection.

The MTU mismatch is the VPN problem that affects the most users without anyone
realising that the VPN is the cause. The tunnel connects and pings succeed, but any
transfer of significant size stalls, hangs, or fails. Where firewalls filter ICMP
"Fragmentation Needed" responses (which many corporate firewalls do), the sender is
never told the packet was too large -- it simply disappears.

**User symptoms:** "VPN works but everything is slow", "Teams video drops out",
"I can ping things but I can't open pages", "Large file transfers just stop".

### 5.1 Apply MTU Correction

**AUTO** -- Quickflow: run `Invoke-AutoRemediateGenericVPN.ps1`.

The script sets the active tunnel interface MTU to 1400 -- safe for IPsec, WireGuard,
and most SSL VPNs. WhatIf is not set; this is a live run.

Wait 2 minutes for traffic to resume, then re-read `vpn_discard_rate_ppm` and
ask the user if performance has improved.

> Agent message to user: "I've found a likely cause of the slowness. Your VPN tunnel's
> MTU was not correctly set, which means large packets were being dropped in transit.
> I've corrected this and the change is active now. Does everything feel faster?"

### 5.2 Important Caveat to Communicate

**INFORM** -- The MTU correction is session-scoped. Most VPN clients reassert their own
MTU when the tunnel reconnects, which means the problem will return after the next
reconnect. A permanent fix requires the VPN gateway administrator to set the MTU in
the connection profile.

**ADMIN** -- If the MTU fix improves symptoms but the problem recurs: raise a ticket
to the VPN team with the gateway profile MTU setting as the target. Note the
`vpn_adapter_name` so the team knows which client and which profile is affected.

### 5.3 If Discard Rate Remains High After MTU Fix

**ADMIN** -- Persistent packet discards on a correctly configured tunnel indicate a
path problem outside the device: a saturated WAN link, a packet-dropping middlebox,
or a quality-of-service misconfiguration in the corporate network. Escalate to the
network team with `vpn_discard_rate_ppm` history from DEX.

---

## Phase 6 -- No DNS on Tunnel (NoDnsOnTunnel)

**Indicator:** `vpn_dns_configured` = false, `vpn_health_reason` = `NoDnsOnTunnel`.

The tunnel is up but has no DNS servers assigned to it. Name resolution falls back
to the physical adapter's public resolvers (typically 8.8.8.8 or the ISP), so
internal hostnames -- corporate intranets, SharePoint, internal APIs -- fail while
the tunnel itself looks healthy. This is the "VPN says connected but nothing works"
failure.

### 6.1 Flush and Re-register

**AUTO** -- Quickflow: run `Invoke-AutoRemediateGenericVPN.ps1`.

The script runs `ipconfig /flushdns` and `ipconfig /registerdns`. This resolves
cases where the DNS assignment from the vendor client did not propagate correctly
to the Windows resolver due to a race condition at connect time.

Re-read `vpn_dns_configured` after 60 seconds.

> Agent message to user: "I've refreshed your DNS settings over the VPN. Internal
> sites should now be reachable. Please try accessing an internal resource."

### 6.2 If vpn_dns_configured Remains False

The DNS servers themselves are assigned by the vendor client from the gateway's
connection profile. If the flush did not resolve the issue, the profile may not
be assigning DNS at all -- which is a gateway configuration problem, not a device
problem.

**USER** -- Ask the user to disconnect and reconnect the VPN, which forces the
client to re-negotiate and re-apply the DNS assignment from the profile.

**ADMIN** -- If the problem persists after reconnect: raise a ticket to the VPN
team with `vpn_adapter_name`, confirming that the gateway profile needs to be
verified for DNS assignment settings.

---

## Phase 7 -- Multiple VPN Clients (MultipleVpnClients)

**Indicator:** `vpn_client_count` > 1, `vpn_health_reason` = `MultipleVpnClients`.

Multiple VPN adapters are installed on the device. They compete for the default
route, for DNS, and for the gateway -- each one tries to claim ownership of these
resources when its tunnel is active. The result is intermittent and
non-reproducible: whoever wins the race on a given connect determines what works.

> Do not attempt to remove a VPN client autonomously. A remote uninstall is how
> you strand a user off-network with no path back in.

### 7.1 Identify the Installed Clients

**AUTO** -- Quickflow sensor: collect `vpn_adapter_name` (the active one) plus a
list of all candidate adapter descriptions from the registry cache
(`HKLM:\Software\AirWatch\Extensions\VPN\ClientCount`).

**INFORM** -- Report all installed clients to DEX.

**ADMIN** -- Raise a ticket with the list of installed clients. The administrator
needs to determine which client is authorised and coordinate removal of the legacy
one. Include `vpn_adapter_name` to identify which client is currently active.

> Agent message to user: "I've found that your device has more than one VPN
> application installed. This can cause connection problems because they interfere
> with each other. I've flagged this with IT, who will be in touch to clean up the
> extra VPN software."

---

## Phase 8 -- Collection Error

**Indicator:** `vpn_health_reason` = `CollectionError`, or the registry key is
missing / `LastRun` is absent.

The collection script (`Invoke-VpnStateCollection.ps1`) failed on its last run.
All sensor readings are stale or absent, so no other phase can be trusted.

### 8.1 Re-run the Collection Script

**AUTO** -- Quickflow: run `Invoke-VpnStateCollection.ps1` with output captured.

If it succeeds: re-read `vpn_health_reason` and route to the appropriate phase.

If it fails again: capture the script exit code and the last line of output.
Common causes:

| Symptom | Likely Cause | Action |
|---|---|---|
| `Get-NetAdapter` fails or returns empty | Network subsystem fault | Run `Invoke-AutoRemediateNetworkStack.ps1`, then retry |
| Event log access denied | SYSTEM context issue -- script not running as SYSTEM | Verify UEM script execution context setting |
| Registry write failed | `HKLM:\Software\AirWatch\Extensions` key permission issue | ADMIN -- verify UEM MDM enrollment health |
| Script times out | Device under extreme load | Run during a low-activity window |

---

## Phase 9 -- No VPN Client Present

**Indicator:** `vpn_health_score` = -1, or `vpn_client_count` = 0.

There is no VPN client on this device. This is deliberate for many device types
(shared workstations, kiosk devices, always-on-campus devices). Confirm before
treating this as a problem.

**INFORM** -- If VPN is expected on this device class:

**ADMIN** -- Raise a ticket to the endpoint team to deploy the authorised VPN client
via UEM app management. Note the device model, OS version, and enrolled user.

> Agent message to user: "Your device doesn't appear to have a VPN application
> installed. If you need VPN access for your work, please reach out to IT and they
> can get it set up for you."

---

## Quickflow Summary

| Quickflow | Type | Phase | Intervention |
|---|---|---|---|
| Run `Invoke-VpnStateCollection.ps1` | Script | 1.1, 8.1 | AUTO |
| Run `Invoke-AutoRemediateGenericVPN.ps1` | Script | 2.1, 3.4, 4.1, 5.1, 6.1 | AUTO |
| Run `Invoke-AutoRemediateNetworkStack.ps1` | Script | 2.2, 4.2 | AUTO |
| Collect VPN adapter list sensor | Script/Sensor | 7.1 | AUTO |
| Raise IT support ticket | Ticket automation | 2.5, 3.3, 4.3, 5.2, 6.2, 7.1 | AUTO |
| Vendor-specific VPN client runbook | Script | 4.3 | ADMIN approval |

---

## Decision Tree (Quick Reference)

```
vpn_health_score = -1 or vpn_client_count = 0?
  └─ Yes → Phase 9 (No client)
  └─ No ↓

vpn_client_count > 1?
  └─ Yes → Phase 7 (Multiple clients) [also continue below]

vpn_health_score >= 80?
  └─ Yes → No action; score is healthy

vpn_health_reason = CollectionError?
  └─ Yes → Phase 8 (Re-run collection)

vpn_connected = false?
  └─ Yes → Phase 2 (Tunnel down)

vpn_flap_count_24h >= 4?
  └─ Yes → Phase 3 (Frequent reconnects)

vpn_connect_failure_count_24h >= 5?
  └─ Yes → Phase 4 (Connection failures)

vpn_tunnel_mtu >= 1500 or < 1280?
  └─ Yes → Phase 5 (MTU problem)

vpn_discard_rate_ppm > 1000?
  └─ Yes → Phase 5 (MTU probable cause)

vpn_dns_configured = false?
  └─ Yes → Phase 6 (DNS on tunnel)

Score is low but no leading reason matches above?
  └─ Re-run Invoke-VpnStateCollection.ps1, re-read, escalate to ADMIN
```

---

## Escalation Criteria

Escalate to an IT administrator (ADMIN) when any of the following are true:

- Tunnel remains down after generic remediation and user reconnect attempt
- `vpn_connect_failure_count_24h` >= 5 and service health is confirmed good
- `vpn_flap_count_24h` >= 10 after MTU correction
- `vpn_client_count` > 1 (removal is an admin decision)
- `vpn_discard_rate_ppm` remains high after MTU fix (path problem)
- `vpn_dns_configured` remains false after flush and reconnect (profile problem)
- Health reason is still `CollectionError` after retry

When escalating, always include:
- Current `vpn_health_score` and `vpn_health_reason`
- `vpn_adapter_name` (which VPN client is active)
- `vpn_flap_count_24h` and `vpn_connect_failure_count_24h`
- Output log from `Invoke-AutoRemediateGenericVPN.ps1`
- Whether generic remediation ran and what it reported
