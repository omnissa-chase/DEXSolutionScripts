# TroubleshootWizard — Published Deployment Package

Modern WPF-based diagnostic troubleshooter with dark/light themes, branding support, and auto-remediation. This folder is the deployment-ready distribution package.

---

## Contents

| File | Purpose |
|---|---|
| `Troubleshooter-Modular.ps1` | Main troubleshooter engine (50 KB) |
| `UI-Modern.xaml` | Dark theme WPF layout |
| `UI-Modern-Light.xaml` | Light theme WPF layout |
| `Branding.json` | Customizable logo, accent color, Hub URL |
| `omnissa.png` | Default company logo |
| `hub.png` | Intelligent Hub icon |
| `NetworkDiagSteps.json` | Network diagnostic steps |
| `AudioBluetoothDiagSteps.json` | Audio/Bluetooth diagnostic steps |
| `PrinterDiagSteps.json` | Printer diagnostic steps |
| `VPNDiagSteps.json` | VPN diagnostic steps |
| `WindowsUpdateDiagSteps.json` | Windows Update diagnostic steps |
| `Install-TroubleshootWizard.ps1` | Dual-mode installer (SFD + ZIP) |
| `Create-ZipPackage.ps1` | Builds the Product Provisioning bundle |
| `Uninstall-TroubleshootWizard.ps1` | Removes the installed files |

**Install destination:** `C:\ProgramData\AirWatch\Extensions\TroubleshootWizard`

---

## Deployment Methods

### Method 1 — Workspace ONE SFD (Software Distribution)

All payload files are delivered alongside the installer via SFD. The installer detects and copies them to the destination folder.

**Steps:**
1. Upload all files in this folder to your WS1 SFD application.
2. Set the install command to:
   ```
   powershell.exe -ExecutionPolicy Bypass -File Install-TroubleshootWizard.ps1
   ```
3. Set the uninstall command to:
   ```
   powershell.exe -ExecutionPolicy Bypass -File Uninstall-TroubleshootWizard.ps1
   ```
4. Set a detection rule (registry value exists):
   ```
   Key:   HKLM\SOFTWARE\AirWatch\Extensions\TroubleshootWizard
   Value: Version
   ```

**How it works:** The installer finds `Troubleshooter-Modular.ps1` next to itself, recognizes SFD mode, and copies all 11 payload files to the destination.

---

### Method 2 — Workspace ONE Product Provisioning (Registered Mode)

All payload files are bundled into a single ZIP archive. Only two files need to be uploaded to Product Provisioning.

**Step 1 — Build the package** (run once on your workstation from this folder):
```powershell
.\Create-ZipPackage.ps1
```

This creates a `ProductProvisioning\` folder alongside `Published\` containing:
- `TroubleshootWizard.zip` — all 11 payload files
- `Install-TroubleshootWizard.ps1` — the installer

**Step 2 — Upload to WS1 Product Provisioning:**
- Upload both files: `Install-TroubleshootWizard.ps1` and `TroubleshootWizard.zip`
- Set the install command to:
  ```
  powershell.exe -ExecutionPolicy Bypass -File Install-TroubleshootWizard.ps1
  ```

**How it works:** The installer finds `TroubleshootWizard.zip` next to itself, extracts it to a temp folder, validates all files, copies them to the destination, then cleans up.

---

## Installer Details

`Install-TroubleshootWizard.ps1` auto-detects the deployment mode based on what it finds next to itself:

| Found next to installer | Mode selected |
|---|---|
| `TroubleshootWizard.zip` | ZIP (Product Provisioning) |
| `Troubleshooter-Modular.ps1` | SFD (flat files) |
| Neither | Error — exits `1` |

You can also force a mode explicitly:
```powershell
.\Install-TroubleshootWizard.ps1 -Mode SFD
.\Install-TroubleshootWizard.ps1 -Mode ZIP
```

**Parameters:**

| Parameter | Default | Description |
|---|---|---|
| `-Mode` | `Auto` | `Auto`, `SFD`, or `ZIP` |
| `-Destination` | `C:\ProgramData\AirWatch\Extensions\TroubleshootWizard` | Override install path |
| `-ZipName` | `TroubleshootWizard.zip` | ZIP archive filename to look for |

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Fatal error (missing files, extraction failed, etc.) |
| `2` | Partial failure (some files failed to copy) |

**Log file:** `%TEMP%\TroubleshootWizard_Install.log`

**Registry values written on install:**

| Key path | Value name | Example data |
|---|---|---|
| `HKLM:\SOFTWARE\AirWatch\Extensions\TroubleshootWizard` | `Version` | `1.0.0` |
| `HKLM:\SOFTWARE\AirWatch\Extensions\TroubleshootWizard` | `InstallPath` | `C:\ProgramData\AirWatch\Extensions\TroubleshootWizard` |
| `HKLM:\SOFTWARE\AirWatch\Extensions\TroubleshootWizard` | `InstallDate` | `2026-04-28` |

---

## Running the Troubleshooter

After installation, launch from the destination folder:

```powershell
# Network diagnostics — dark theme
powershell.exe -ExecutionPolicy Bypass -File "C:\ProgramData\AirWatch\Extensions\TroubleshootWizard\Troubleshooter-Modular.ps1" -StepsJson ".\NetworkDiagSteps.json" -XamlFile ".\UI-Modern.xaml"

# Network diagnostics — light theme
powershell.exe -ExecutionPolicy Bypass -File "C:\ProgramData\AirWatch\Extensions\TroubleshootWizard\Troubleshooter-Modular.ps1" -StepsJson ".\NetworkDiagSteps.json" -XamlFile ".\UI-Modern-Light.xaml"

# Quiet / headless mode (no UI — for scheduled tasks or SYSTEM context)
powershell.exe -ExecutionPolicy Bypass -File "C:\ProgramData\AirWatch\Extensions\TroubleshootWizard\Troubleshooter-Modular.ps1" -StepsJson ".\NetworkDiagSteps.json" -SkipUI
```

**Available `-StepsJson` values:**

| File | Scenario |
|---|---|
| `NetworkDiagSteps.json` | DNS, gateway, proxy, internet connectivity |
| `AudioBluetoothDiagSteps.json` | Audio devices, Bluetooth pairing |
| `PrinterDiagSteps.json` | Print spooler, driver, queue |
| `VPNDiagSteps.json` | VPN client, tunnel, split-tunnel |
| `WindowsUpdateDiagSteps.json` | WU service, WSUS, pending updates |

---

## Branding Customization

Edit `Branding.json` before deploying to customize the UI appearance:

```json
{
    "CompanyName":      "Your Company",
    "LogoFile":         ".\\your-logo.png",
    "AccentColor":      "#7C6AF7",
    "HeaderBackground": "#16162A",
    "HubUrl":           "ws1winhub:",
    "SupportText":      "Contact IT Support",
    "SupportUrl":       ""
}
```

| Key | Description |
|---|---|
| `LogoFile` | Relative path to a PNG logo (displayed top-left). Omit or leave blank to hide. |
| `AccentColor` | Hex color for the Fix All button, progress bar, and accent stripe. |
| `HeaderBackground` | Hex color for the title bar (dark theme). |
| `HubUrl` | URI launched when a user clicks "Open Intelligent Hub" on a warning card. Use `ws1winhub:` to open the Hub app directly. |
| `SupportText` | Label shown below the Hub button on warning cards. |

---

## Requirements

| Requirement | Minimum |
|---|---|
| OS | Windows 10 / Windows 11 |
| PowerShell | 5.1 (Windows PowerShell) |
| .NET Framework | 4.5+ (WPF required for UI) |
| Permissions | Administrator (for remediation scripts) |
| Execution Policy | `RemoteSigned` or `Bypass` |
