# TroubleshootWizard

JSON-driven, WPF-based self-service diagnostics for Windows endpoints. Deployed with Workspace ONE, launched from an `omniwiz:` link (Intelligent Hub, portal, email) or from any Workspace ONE script/sensor, and shown in the logged-on user's session.

This folder is a self-contained project: everything needed to build, sign, deploy and run the wizard lives here.

---

## How a launch works

```
 user clicks                 runs as the user                 Application log                 scheduled task (runs as the
 omniwiz://Network   --->    Send-TroubleshootWizardEvent   --->  source TroubleshootingWizard  --->  interactive user, BUILTIN\Users)
                             validates name -> writes event        event ID 9001                       Invoke-TroubleshootWizardFromEvent
                                                                                                         reads newest event, validates,
 WS1 script as SYSTEM  --->  Send-TroubleshootWizardEvent -DiagSteps Network ------------------^        launches TroubleshootWizard.ps1
```

* The **event** is the only hand-off. Anything that can write to the Application log can pop the wizard for the user, including scripts running as SYSTEM that cannot show UI themselves.
* The event carries a **name**, never a path or code. The name must match `^[A-Za-z0-9_-]{1,64}$` and must resolve to an existing file in `<install>\DiagSteps`. `Network` and `NetworkDiagSteps` both resolve to `NetworkDiagSteps.json`.
* The **task command line is fixed** by the installer; no event data is placed on it.
* The install folder is **ACL-locked** (SYSTEM/Administrators write, Users read), so only an admin can change what the wizard can run.

See [SECURITY-AND-SIGNING.md](SECURITY-AND-SIGNING.md) for the threat model, the compile question and code signing.

---

## Contents

| File / folder | Purpose |
|---|---|
| `TroubleshootWizard.ps1` | Diagnostic engine (PowerShell 5.1+). Runs steps, saves results, shows UI. |
| `TroubleshootWizard-UI.ps1` | WPF UI library (progress dialog, results window, Fix / Fix All). |
| `TroubleshootWizard-Common.ps1` | Shared validation/parsing for the launch pipeline. |
| `Send-TroubleshootWizardEvent.ps1` | URL protocol handler and direct trigger. Writes event 9001. |
| `Invoke-TroubleshootWizardFromEvent.ps1` | Scheduled-task action. Reads event 9001, launches the engine. |
| `UI-Modern.xaml` / `UI-Modern-Light.xaml` | Dark / light layouts. |
| `Branding.json` | Logo, accent colour, default theme, Hub link, support text. |
| `DiagSteps\*.json` | Diagnostic step definitions (Network, Printer, VPN, Windows Update, Audio/Bluetooth). |
| `Resources\` | Logo images referenced by `Branding.json`. |
| `Install-TroubleshootWizard.ps1` | Installer: files, ACL, event source, URL protocol, scheduled task, detection key. |
| `Uninstall-TroubleshootWizard.ps1` | Removes everything the installer created. |
| `Create-ZipPackage.ps1` | Builds the SFD and Product Provisioning artifacts into `Releases\v<version>\`. |
| `Sign-Package.ps1` | Authenticode-signs / verifies all scripts. |

**Install destination:** `C:\ProgramData\AirWatch\Extensions\TroubleshootWizard`

---

## Build

```powershell
.\Create-ZipPackage.ps1                                   # unsigned
.\Create-ZipPackage.ps1 -CertificateThumbprint <thumb>    # scripts signed before zipping
```

Output (version read from `$AppVersion` in the installer):

```
Releases\v1.1.0\SFD\TroubleshootWizard_v1.1.0.zip          one zip: payload + installer + uninstaller
Releases\v1.1.0\ProductProvisioning\
    Install-TroubleshootWizard.ps1
    Uninstall-TroubleshootWizard.ps1
    TroubleshootWizard.zip                                  payload only
```

---

## Deploy with Workspace ONE

The installer **must run as SYSTEM** (or an administrator). It refuses otherwise.

### Software Distribution (SFD)

1. Upload `Releases\v<ver>\SFD\TroubleshootWizard_v<ver>.zip` as the application file.
2. Install command: `powershell.exe -ExecutionPolicy Bypass -File Install-TroubleshootWizard.ps1`
3. Uninstall command: `powershell.exe -ExecutionPolicy Bypass -File Uninstall-TroubleshootWizard.ps1`
4. Detection: registry value exists, `HKLM\SOFTWARE\AirWatch\Extensions\TroubleshootWizard`, value `Version` (compare to the release version).
5. Install context: Device.

### Product Provisioning (Files/Actions)

1. Upload the three files from `Releases\v<ver>\ProductProvisioning\`.
2. Manifest install action: `powershell.exe -ExecutionPolicy Bypass -File Install-TroubleshootWizard.ps1`
3. The installer finds `TroubleshootWizard.zip` next to itself and switches to ZIP mode.

### What the installer does

| Step | Detail |
|---|---|
| Files | Copies payload, removes files from the old flat layout, clears Mark-of-the-Web. |
| ACL | Removes inheritance. SYSTEM + Administrators: Full. Users: Read & Execute. Owner: Administrators. Verified after applying. |
| Event source | `TroubleshootingWizard` in the Application log. |
| URL protocol | `HKLM\SOFTWARE\Classes\omniwiz` -> `conhost.exe --headless powershell.exe ... -File Send-TroubleshootWizardEvent.ps1 -Url "%1"` |
| Scheduled task | `\Omnissa\TroubleshootWizard\TroubleshootWizard-OnEvent`. Event trigger (Application, source TroubleshootingWizard, ID 9001). Principal BUILTIN\Users. Run level HighestAvailable. IgnoreNew, 1 h limit, not stopped on battery. |
| Registry | `Version`, `InstallPath`, `InstallDate`, `UrlScheme`, `TaskName`, `EventSource`. |

### Installer parameters

| Parameter | Default | Notes |
|---|---|---|
| `-Mode` | `Auto` | `SFD`, `ZIP`. |
| `-Destination` | `C:\ProgramData\AirWatch\Extensions\TroubleshootWizard` | |
| `-ScriptExecutionPolicy` | `Bypass` | Baked into the task and protocol-handler command lines. Use `AllSigned` once the package is signed and the publisher is trusted. |
| `-TaskRunLevel` | `Highest` | `Highest`: admins get an elevated wizard without a UAC prompt (service/firewall fixes work). Standard users are never elevated. `Limited`: never elevate. |
| `-UrlScheme` | `omniwiz` | |
| `-SkipUrlProtocol` / `-SkipScheduledTask` | off | Files only. |

Exit codes: `0` success, `1` fatal, `2` completed with errors. Log: `%TEMP%\TroubleshootWizard_Install.log` (`C:\Windows\Temp` when run as SYSTEM).

---

## Launching

### From a link (Hub custom tab, portal, email, shortcut)

```
omniwiz://Network
omniwiz://Printer
omniwiz://run?diagsteps=VPN&theme=Dark&title=VPN%20Health
```

| Query key | Values |
|---|---|
| `diagsteps` (or `steps`) | Steps-file name with or without the `DiagSteps` suffix / `.json`. |
| `theme` | `Dark`, `Light`. Default: `Theme` in `Branding.json`, else Light. |
| `title` | Window title. Letters, digits, space, `. _ ( ) & / -`, max 60. Default is derived from the file name ("Network Diagnostics"). |

Browsers (Edge/Chrome) ask "Open omniwiz?" the first time. For links hosted on a known portal, push the `AutoLaunchProtocolsFromOrigins` browser policy to suppress the prompt.

### From a Workspace ONE script or sensor (SYSTEM)

```powershell
& 'C:\ProgramData\AirWatch\Extensions\TroubleshootWizard\Send-TroubleshootWizardEvent.ps1' -DiagSteps Network -Theme Light
```

Exit `0` event written, `2` request rejected, `1` event log error. The wizard appears in the interactive user's session.

### Direct (testing)

```powershell
cd 'C:\ProgramData\AirWatch\Extensions\TroubleshootWizard'
.\TroubleshootWizard.ps1 -StepsJson .\DiagSteps\NetworkDiagSteps.json -XamlFile UI-Modern.xaml
.\TroubleshootWizard.ps1 -StepsJson .\DiagSteps\NetworkDiagSteps.json -SkipUI      # headless
.\Invoke-TroubleshootWizardFromEvent.ps1 -SkipUI                                     # what the task runs
```

### Logs

| Component | Location |
|---|---|
| Engine, protocol handler, task action | `%LOCALAPPDATA%\TroubleshootWizard\*.log` (per user; the install folder is read-only) |
| Results | `HKCU\Software\Diagnostics\<StepsName>\LastResults` (JSON) |
| Installer / uninstaller | `%TEMP%\TroubleshootWizard_Install.log`, `_Uninstall.log` |

---

## Adding a diagnostic

1. Copy an existing `DiagSteps\*DiagSteps.json`, name it `<Thing>DiagSteps.json`.
2. Each step: `Name`, `Description`, `Enabled`, `Order`, `UserFeedback`, `DetectionScript` (returns `@{ Status = 'Passed'|'Failed'|'Warning'; Message = '...' }`), optional `ResolutionScript`, `ResolutionText`, `TestResultText`.
3. Rebuild and redeploy. The name is then addressable as `omniwiz://<Thing>`.

Steps files are code. They run with the user's rights (elevated for admins). Review them like scripts.

---

## Branding

```json
{
    "CompanyName":  "Your Company",
    "LogoFile":     ".\\Resources\\logo.png",
    "AccentColor":  "#7C6AF7",
    "Theme":        "Light",
    "HubUrl":       "ws1winhub:",
    "SupportText":  "Contact IT Support",
    "SupportUrl":   ""
}
```

---

## Requirements

| Requirement | Minimum |
|---|---|
| OS | Windows 10 2004+ / Windows 11 (`conhost --headless`, Task Scheduler event triggers) |
| PowerShell | 5.1 (engine and launchers also run under 7+) |
| .NET Framework | 4.5+ (WPF) |
| Install | SYSTEM or administrator |
| Run | Any interactive user. Admin-only fixes need an admin user (see security doc). |
