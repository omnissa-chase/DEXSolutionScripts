# The Definitive Guide to Rebooting Windows with Workspace ONE UEM and Omnissa DEX

> *"Always reboot at least 3 times."* — anonymous IT guy

A collection of PowerShell scripts for managing Windows endpoint reboots in a controlled, user-aware way. These scripts are designed for deployment via **Omnissa Workspace ONE UEM** and support **DEX resolution workflows** where a reboot is determined to be the appropriate remediation action.

---

## Scripts in This Folder

| Subfolder | Script | Deployment Method | Description |
|---|---|---|---|
| `SmartReboot/` | `SmartReboot.ps1` | **App Package** (ZIP) | Lightweight reboot trigger deployed as a Workspace ONE application. Uses native UEM deferral and notification capabilities. |
| `InteractiveReboot/` | `Invoke_RebootWithUserDefer_1.2.0.7.ps1` | **Product Provisioning** | Full-featured interactive reboot with toast notifications, user deferral support, and automatic enforcement deadlines. Exceeds the WS1 Script size threshold — must be deployed via Product Provisioning. |

---

## Use Cases for Rebooting a Windows Machine Using Workspace ONE

There are a surprising number of situations where a simple reboot ends up being the cleanest and fastest fix for a slow or unresponsive Windows Desktop endpoint. Workspace ONE gives you several ways to handle reboots — from gentle, user-friendly nudges to severe, immediate, forced machine reboots — and each can be deployed depending on what the scenario calls for.

### 1. Issues Detected by Digital Employee Experience (DEX)

Workspace ONE's DEX tools can surface all sorts of oddities: memory pressure, unresponsive services, stale uptime, pending patches, weird app hangs, and other things that gradually turn a Windows device into a potato. When these issues hit certain thresholds, a reboot is often the lowest-impact way to get everything back to a healthy state.

### 2. Troubleshooting Random Windows Quirks

Anyone who has supported Windows for more than ten minutes knows the magic fix. Reboots tend to resolve many of the issues that can arise from keeping a Windows session going for too long. These include:

- Stuck background tasks
- Windows services that crash or hang
- UI elements that stop responding
- Broken sleep/hibernate transitions
- Processes that simply refuse to die

Most of these issues are caused by either bugs (memory leaks) with software or drivers, or by pending driver/software updates.

### 3. Completing Application Installations or Updates

Some applications can update quietly in the background, but others insist on a reboot before they'll behave properly. Workspace ONE can handle reboots as part of the software deployment workflow so you don't end up with:

- Apps half-installed
- DLLs still in use
- Processes that won't restart cleanly
- Registry keys needed by Windows Explorer

This is especially helpful for apps that rely on drivers, kernel-level components, or system services that can't be updated while running.

### 4. Completing Application Uninstalls

Sometimes uninstalling an app leaves behind locked files or services that don't fully shut down until the next restart. If you're doing a remove-and-replace deployment — basically uninstalling something just to immediately reinstall a newer version — rebooting in the middle ensures the new version isn't fighting stale leftovers.

### 5. Anti-Virus or Threat Remediation Steps

After a malware cleanup or AV remediation event, it's often necessary to reboot so that quarantined items are cleared, services restart in a clean state, and Windows finishes whatever it needed to do during the disinfection. This prevents the machine from drifting into an "inconsistent but technically running" condition.

### 6. Driver Updates

Driver installs often require a reboot before Windows is able to use the new version even if their driver update package does not specify that a reboot is required. Rather than relying on users to reboot "whenever they get around to it," you can automate it and keep firmware consistent across the fleet.

### 7. Windows Updates

Windows Update has gotten a lot better over the years, but reboots are still unavoidable for cumulative updates, feature updates, platform updates, and certain patches. Workspace ONE can enforce the reboot in a controlled, predictable way instead of letting Windows decide at inconvenient moments. This is where time windows and user deferrals become especially important.

### 8. Registry Key Changes or System Configuration Updates

There are still plenty of registry values, policy updates, and low-level system changes that don't fully apply until after a restart. If you're pushing something that touches:

- Shell behavior
- Network stack behavior
- Authentication components
- File system drivers
- Hardware configuration

…a reboot ensures the device applies the change instead of limping along until the next natural restart (which might be weeks away).

### 9. General Health and Maintenance

Some organizations simply want devices to restart regularly — not because something is broken, but because uptime of 40+ days tends to correlate with "odd performance issues the help desk has to pretend not to hate." Workspace ONE can enforce a healthy reboot cadence without babysitting every machine.

---

## Prerequisites & Requirements

### Windows Device Management Levels

Workspace ONE can manage Windows devices in a few different ways, and the reboot options you get depend heavily on which bucket a particular device falls into.

#### Fully Managed (MDM + Intelligent Hub)

This is the ideal state for anything involving remote control, including rebooting. A fully managed Windows device is one that has been enrolled into MDM and has the Intelligent Hub installed and running. Devices in this state can receive reboot commands from the console, react to reboot requirements coming from profiles or ADMX policies, and participate in more advanced workflows like deferrals or custom reboot applications.

This is the level you want if your goal is predictable reboot behavior at scale.

#### Agent-Managed Only (Available in 2602+)

Sometimes organizations choose to install the Intelligent Hub without enrolling the device in MDM. This is typically done to allow Workspace ONE to have compatibility with MECM and/or Intune. In this mode, you can still reboot the machine.

#### Registered-Only

This is the most limited state. The machine won't accept a standard hub-initiated reboot command, and there's no concept of user-facing deferrals or policy-based triggers.

You can still initiate a reboot using a custom script or packaged tool, but only in scenarios where the user is actually logged in and the script has the right permissions. This is good to understand but not usually the mode you would choose for any structured reboot workflow.

---

## Different Ways to Reboot Windows in Workspace ONE and Omnissa DEX

There are several ways to reboot a Windows device through Workspace ONE, and each method comes with its own style of user interaction, timing, and enforcement. Some approaches are very gentle and user-friendly; others are more direct and don't give the user much choice.

### 1. Standard Reboot (Console Command)

This is the simplest method and is the best place to start. From the device list or device details page in the console, you can hit the **Restart** command and Workspace ONE will tell the device to reboot the next time it checks in.

If the user has unsaved work, Windows will still prompt them, but that's coming from the OS — not Workspace ONE. There's no built-in concept of user deferral here. This method is straightforward but offers the least flexibility, unless you pair it with Omnissa's Intelligence Workflows and Hub Services notifications to provide some warning to end users.

| | |
|---|---|
| **Enrollment Type** | Agent Enrollment and Full Enrollment |
| **DEX** | Can deploy through the Workspace ONE API integration |
| **User Deferral** | Essentially none from WS1. Any prompts are native Windows behavior. |
| **Use Cases** | Emergency reboots during troubleshooting; help desk "quick fix" after a remediation step; one-off restarts for a specific endpoint |

---

### 2. Windows Updates Reboot Options

For administrators managing Windows Update through Workspace ONE, you can let Windows handle reboot timing using policies like active hours, deadlines, and automatic restart rules. The behavior feels native because it is — Windows surfaces its usual notifications, counts down when needed, and enforces reboots according to your policy.

| | |
|---|---|
| **Enrollment Type** | Requires fully managed (MDM + Hub) for OMA-DM profiles; requires Hub-managed or fully managed for ADMX profiles |
| **User Deferral** | Controlled by Windows Update settings (active hours, deadlines, grace periods). Users see familiar Windows prompts and can snooze within the limits you set. |
| **Use Cases** | Patch Tuesday and cumulative updates; feature updates where you want Microsoft's standard UX; environments that prefer native behavior to custom tooling |

---

### 3. Application Install-Driven Reboots

When you deploy software via Workspace ONE, you can tie reboot behavior to the app lifecycle — after install, after uninstall, only if the installer requests it, or not at all. The installer's logic takes the lead here; some packages insist on a reboot, others can delay or suppress it.

Reboot timing options:
- Immediately after install
- Only if the installer requests it
- Only after uninstall
- Not at all (and let WS1 handle reboot logic separately)

| | |
|---|---|
| **Enrollment Type** | Fully Managed or Hub-Managed devices |
| **User Deferral** | Varies by installer. While most MSI packages have standardized the exit code for when a reboot is required (and can be intercepted), not all do. The entire install/update can be deferred if a reboot is a hard requirement, providing end users with some flexibility. |
| **Use Cases** | Drivers or kernel-level components that need a restart to load; "uninstall old → reboot → install new" swap-outs; complex app upgrades that leave files locked until after a restart |

---

### 4. Custom Reboots

This is the most flexible category in terms of delivery or enrollment options. The scripts in this repository fall into this category. There are generally three flavors:

#### Custom Reboot Application (SmartReboot)

This option provides the most flexibility with the least amount of effort, and works with all but Hub Registered mode. A ZIP file containing a `.ps1` script exits with reboot exit code `1641` on first install, while also adding a registry key to allow easy application install detection — limiting the reboot to a single event.

➡ See [SmartReboot/readme.md](SmartReboot/readme.md) and [SmartReboot/Runbook-Agent.md](SmartReboot/Runbook-Agent.md)

#### Simple Reboot Script

Useful for one-off restarts or for devices that aren't fully managed. Doesn't typically include user deferrals.

```powershell
# Optional delay before reboot (in seconds). Set to 0 for immediate.
$DelaySeconds = 300

# Reboot command (SYSTEM-safe)
shutdown.exe /r /t $DelaySeconds /f
```

#### Advanced Reboot Script with User Deferral (InteractiveReboot)

Designed to let users snooze, postpone, or pick a time — great for organizations that want to enforce reboots without being heavy-handed. Because the script exceeds the Workspace ONE UEM Script upload size threshold, it must be deployed via **Product Provisioning**.

➡ See [InteractiveReboot/readme.md](InteractiveReboot/readme.md) and [InteractiveReboot/Runbook-Agent.md](InteractiveReboot/Runbook-Agent.md)

---

## Reboot Method Comparison

| Reboot Method | Enrollment Type Required | Delay Options | Deferral Options |
|---|---|---|---|
| Console Reboot (Device Page) | Fully managed or Hub-managed | None beyond Windows' own behavior | No WS1 deferrals; only native Windows prompts if apps are open |
| Windows Update / ADMX Policy Reboots | Fully managed or Hub-managed | Active hours, deadlines, grace periods configured via policy | Windows Update's built-in snooze/deferral system (not customizable by WS1) |
| Application-Driven Reboot (Installer Logic) | Fully managed or Hub-managed | Controlled by installer flags | Depends entirely on installer; some support postponement, others do not |
| Scripts — Simple Restart | All | Script can schedule timed restart | Typically none unless added manually in script logic |
| Scripts — Advanced (with custom UX) | All | Fully customizable: timers, countdowns, scheduled reboot | Custom-built deferrals, snoozes, retries, enforcement deadlines |
| Custom Reboot Application (SmartReboot) | Fully managed or Hub-only; registered devices if user logged in | Any behavior the app is designed for | Full user-facing deferral experience: snooze buttons, limited deferrals, enforcement dates |

---

## Choosing the Right Method

```
Is the device Fully Managed or Hub-Managed?
├── YES
│   ├── Do you need user-facing toast notifications and deferral options?
│   │   ├── YES → InteractiveReboot (Product Provisioning)
│   │   └── NO  → SmartReboot (App Package) or Console Reboot command
│   └── Is this a bulk fleet reboot (e.g., post-patch, DEX auto-remediation)?
│       ├── LOW user impact window → SmartReboot with UEM deferral settings
│       └── HIGH impact / business hours → InteractiveReboot with MaxHours deadline
└── NO (Registered Mode)
    └── InteractiveReboot (Product Provisioning supports Registered mode)
```

---

## General Requirements

| Requirement | Detail |
|---|---|
| OS | Windows 10 / Windows 11 |
| Management | Workspace ONE UEM with Intelligent Hub (Hub-Managed or Fully Managed) |
| Execution Context | SYSTEM |
| PowerShell | 5.1+ |
