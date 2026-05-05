# Windows Reboot Scripts

A collection of PowerShell scripts for managing Windows endpoint reboots in a controlled, user-aware way. These scripts are designed for deployment via **Omnissa Workspace ONE UEM** and support **DEX resolution workflows** where a reboot is determined to be the appropriate remediation action.

---

## Why Reboots Matter for DEX

Workspace ONE DEX surfaces a wide range of endpoint health issues — memory pressure, stale uptime, hung services, failed patches, and degraded performance scores — where the fastest and lowest-risk remediation is a reboot. These scripts provide the right tool for the right scenario depending on your management context and how disruptive a forced reboot would be to the end user.

---

## Scripts in This Folder

| Subfolder | Script | Deployment Method | Description |
|---|---|---|---|
| `SmartReboot/` | `SmartReboot.ps1` | **App Package** (ZIP) | Lightweight reboot trigger deployed as a Workspace ONE application. Uses native UEM deferral and notification capabilities. |
| `InteractiveReboot/` | `Invoke_RebootWithUserDefer_1.2.0.7.ps1` | **Product Provisioning** | Full-featured interactive reboot with toast notifications, user deferral support, and automatic enforcement deadlines. Exceeds the WS1 Script size threshold — must be deployed via Product Provisioning. |

---

## Choosing the Right Script

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

## Deployment Methods

### SmartReboot — Workspace ONE App Package
Deployed as a standard application (ZIP containing a PowerShell script and a stub EXE). Workspace ONE's built-in application lifecycle handles:
- User-facing install deferral prompts
- Deadline enforcement
- Detection (registry key presence)
- Reboot via installer exit code `1641`

➡ See [SmartReboot/readme.md](SmartReboot/readme.md) and [SmartReboot/Runbook-Agent.md](SmartReboot/Runbook-Agent.md)

### InteractiveReboot — Product Provisioning
Deployed as a Product Provisioning object because the script size exceeds the Workspace ONE UEM Script upload threshold. This script self-installs helper scripts to disk, registers a SYSTEM-context scheduled task orchestrator, and fires per-user toast notifications through a separate user-context task. It enforces a hard deadline after a configurable number of hours.

➡ See [InteractiveReboot/readme.md](InteractiveReboot/readme.md) and [InteractiveReboot/Runbook-Agent.md](InteractiveReboot/Runbook-Agent.md)

---

## General Requirements

| Requirement | Detail |
|---|---|
| OS | Windows 10 / Windows 11 |
| Management | Workspace ONE UEM with Intelligent Hub (Hub-Managed or Fully Managed) |
| Execution Context | SYSTEM |
| PowerShell | 5.1+ |

---

## Related Reference

`WindowsRebootData.txt` in this folder contains a comprehensive reference guide covering all Workspace ONE reboot methods, enrollment type requirements, deferral options, and use-case guidance.
