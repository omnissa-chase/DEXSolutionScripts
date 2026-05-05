# Smart Reboot — v1.0.0.0

A lightweight reboot trigger deployed as a **Workspace ONE UEM Application Package**. Smart Reboot leverages the native Workspace ONE application lifecycle — including user-facing install deferral prompts, deadline enforcement, and detection logic — without requiring any custom notification infrastructure.

---

## Overview

Smart Reboot works by exiting with reboot exit code `1641` on first install, which signals Workspace ONE to initiate a device restart. A registry key is written as the detection method, allowing the app to be uninstalled and reinstalled to re-trigger the reboot on demand.

### Key Characteristics

| Property | Detail |
|---|---|
| **Deployment Method** | Workspace ONE App Package (ZIP) |
| **Execution Context** | SYSTEM |
| **Enrollment Required** | Hub-Managed or Fully Managed (not Registered-only) |
| **User Notifications** | Native Workspace ONE UEM deferral prompts |
| **PowerShell Version** | 5.1+ |

---

## How It Works

1. Script runs as SYSTEM.
2. On first execution, the registry key `HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot` does **not** exist.
3. Script creates the key with `InstallComplete = 0` and exits with code `1641` (reboot required).
4. Workspace ONE interprets exit code `1641` and initiates a device restart according to your assignment's reboot configuration.
5. If the key already exists (i.e., the reboot has already been triggered), the script exits `0` — no second reboot.
6. To re-trigger: uninstall the app (which removes the registry key) then reinstall.

---

## Workspace ONE UEM Configuration

### App Package Contents

| File | Purpose |
|---|---|
| `SmartReboot.ps1` | Main script — creates registry key and exits `1641` |
| `setup.exe` | Stub file required by WS1 UEM 2511 and below (rename a text file) — not needed on 2602+ |

> ⚠️ When zipping, select the **files** — not the folder containing them — so all files sit at the root of the ZIP archive.

### Upload & Configuration

**Name:** `Required Reboot` *(or your preferred display name)*

**Execution Context:** System (with admin privileges)

**Install Command:**
```
PowerShell.exe -ExecutionPolicy Bypass -File ".\SmartReboot.ps1"
```

**Uninstall Command:**
```
PowerShell.exe -ExecutionPolicy Bypass -Command { Remove-Item -Path "HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot" -Force -Recurse | Out-Null }
```

**Detection Method:**

| Field | Value |
|---|---|
| Type | Registry Value Exists |
| Key | `HKEY_LOCAL_MACHINE\SOFTWARE\AirWatch\Extensions\SmartReboot` |
| Name | `InstallComplete` |
| Value | `0` |

### Assignment Settings

| Setting | Value | Notes |
|---|---|---|
| App Delivery | On Demand | Allows admins to push on-demand; not auto-pushed |
| Display in App Catalog | Disabled | Keep hidden from users |
| Allow User Install Deferral | **Enabled** | Lets user postpone — WS1 enforces deadline |
| Override Reboot Handling | **Enabled** | |
| Device Restart | **Force Restart** | |
| Uninstall Device Restart | Do Not Restart | Uninstall just removes the key |
| Installer Reboot Exit Code | `1641` | |
| Installer Success Exit Code | `0` | |

---

## Re-Triggering the Reboot

To push a second reboot to the same device:
1. Go to the device's **Apps** tab in the WS1 UEM console.
2. Uninstall **Required Reboot** (removes the registry key).
3. Reinstall **Required Reboot** (re-runs the script → exits `1641` again).

---

## See Also

- [Runbook-Agent.md](Runbook-Agent.md) — Step-by-step agent guide for deploying and triggering Smart Reboot
- [../InteractiveReboot/readme.md](../InteractiveReboot/readme.md) — For scenarios requiring user-facing toast notifications and deferral windows

