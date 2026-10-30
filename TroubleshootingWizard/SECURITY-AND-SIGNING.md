# TroubleshootWizard: security model, the compile question, and code signing

Written for administrators deploying the wizard and for whoever maintains it.

---

## 1. What runs where

| Component | Runs as | Trust level |
|---|---|---|
| `Install-TroubleshootWizard.ps1` | SYSTEM (Workspace ONE) | Admin. Creates everything below. |
| `Send-TroubleshootWizardEvent.ps1` (omniwiz: handler) | The user who clicked | Untrusted input (the URL). Output: one event with a validated name. |
| Application log event 9001 | Anyone in an interactive session can write one | Untrusted input to the task. |
| Scheduled task `TroubleshootWizard-OnEvent` | Interactive user (BUILTIN\Users principal), HighestAvailable | Elevated only if that user is an admin. Command line fixed by installer. |
| `Invoke-TroubleshootWizardFromEvent.ps1` | Same as task | Validates the event, launches engine. |
| `TroubleshootWizard.ps1` + `DiagSteps\*.json` | Same as task | **Steps JSON is code.** Protected by folder ACL. |

### Trust boundary

Everything that arrives via URL or event is treated as data. The only thing extracted is a *name*:

1. Must match `^[A-Za-z0-9_-]{1,64}$` (no path separators, no dots, no quotes, no whitespace).
2. Must resolve to `<install>\DiagSteps\<name>.json` or `<name>DiagSteps.json`.
3. The resolved file must sit directly in `DiagSteps` and must not be a reparse point.
4. `Theme` is matched against a fixed list; `Title` against a tight character set.

Everything else (full paths in legacy messages, extra query keys, injected text) is dropped. Validation is done **twice**: in the handler (fail early, nothing written) and in the task action (the actual boundary). The engine itself no longer reads the event log.

### Why the ACL matters most

`C:\ProgramData` grants **Users: create files / create folders** on every subfolder by inheritance. Without intervention a standard user could drop `DiagSteps\Mine.json` and then launch `omniwiz://Mine`, running arbitrary PowerShell under the task's token. If that user is an admin, that is a silent UAC bypass; with a SYSTEM task it would be full local privilege escalation.

The installer therefore removes inheritance and sets:

| Principal | Rights |
|---|---|
| SYSTEM, Administrators | Full control, owner Administrators |
| Users | Read & Execute only |

and verifies afterwards that no non-admin principal holds a write-capable right. Logs are written to `%LOCALAPPDATA%` because the install folder is read-only for users.

### Why the task runs as the user and not SYSTEM

* WPF needs the interactive desktop. A SYSTEM task lives in session 0 and shows nothing.
* Running as the user means the wizard can only do what the user can do. For admins, HighestAvailable gives an elevated token without a UAC prompt, so service and firewall fixes work. For standard users nothing is elevated.
* Trade-off: on a standard-user device, admin-only resolution scripts fail ("requires elevation"). If you need those, the safe pattern is a second SYSTEM task triggered by a different event ID that runs **only a named step from a named file** (never code from the event) and reports back through the registry. Not implemented yet.

### Residual risks (accepted, documented)

| Risk | Mitigation / note |
|---|---|
| Any process in the user's session can pop the wizard (write event 9001). | It can only trigger admin-authored diagnostics. Annoyance, not escalation. Task uses IgnoreNew so repeated events do not stack windows. |
| Admin users run diagnostics elevated without a prompt. | By design for self-service. Use `-TaskRunLevel Limited` if unacceptable. |
| Steps JSON is unsigned. | Integrity relies on the ACL. A signed hash manifest could be added later if WDAC-grade integrity is required. |
| `-ExecutionPolicy Bypass` in the command lines. | Execution policy is not a security boundary. Switch to `AllSigned` once scripts are signed and the publisher is trusted; see section 3. |
| Edge/Chrome protocol prompt. | Cosmetic. `AutoLaunchProtocolsFromOrigins` policy for known portal origins. |
| `conhost.exe --headless` needs Windows 10 2004+. | Older builds: replace with `powershell.exe -WindowStyle Hidden` (brief console flash). |

---

## 2. Should this be compiled?

**No, not the wizard itself.** Reasons:

* Compiling PowerShell (PS2EXE and similar) just embeds the script in a .NET stub. It is extracted in seconds and gives no confidentiality or integrity benefit, while triggering antivirus false positives far more often than a signed `.ps1`.
* The integrity properties people want from "compiled" are delivered on Windows by **Authenticode signatures + ACLs + (optionally) WDAC/AppLocker**, which work on scripts as well as binaries.
* The JSON steps would still be plain text and still be code, so nothing is gained there either.

Where a small compiled piece *would* help, later, if desired:

* A tiny C#/.NET protocol-handler EXE (`omniwiz` -> event) instead of `conhost --headless powershell.exe`. Benefits: no console process at all, strongly typed URL parsing, a signed binary that SmartScreen can build reputation on, and it keeps working under Constrained Language Mode. It would be ~100 lines and replaces only `Send-TroubleshootWizardEvent.ps1`.

---

## 3. Code signing

### What "trusted developer" means on Windows

There is no registry of trusted developers. A script or binary is trusted when its Authenticode signature chains to a certificate the **device** trusts, and (for PowerShell `AllSigned`) when the signing certificate is in the device's **Trusted Publishers** store. So "becoming trusted" is really "getting a code-signing certificate that the target devices will chain to":

| Route | Who trusts it | Cost / effort | When to use |
|---|---|---|---|
| **Azure Artifact Signing** (formerly Trusted Signing), *individual* validation | Any Windows device (Microsoft-issued public certs) | Around USD 10/month. Individual validation is currently open to developers in the US and Canada (organisations: US, Canada, EU, UK). Government-ID check. Signs anything `signtool.exe` can; short-lived certs plus timestamp. Needs `signtool` + the Artifact Signing dlib, so a GitHub Actions workflow is the natural fit. | **Recommended for this project.** The author signs releases under their own verified name; publicly trusted on every Windows device with no customer-side cert push. Confirm `.ps1` support in the tenant before relying on it. |
| **SignPath Foundation** | Any Windows device | Free for open-source projects with an OSI licence, public repo and an existing release history; builds must run in their pipeline. Signer name is "SignPath Foundation", with the project named in the certificate. | Good fallback if the Azure individual route is unavailable. Downside: the publisher shown is SignPath, not you. |
| **Certum Open Source code-signing cert** | Any Windows device | Roughly EUR 25 to 69/year, individually validated, cloud key (SimplySign) or card and reader. Revoked if used for commercial software. | Cheapest personal cert in your own name. Check current pricing and validity terms; they change. |
| **Public OV / EV cert** (DigiCert, Sectigo, GlobalSign, SSL.com) | Any Windows device | A few hundred USD/year. Since 1 June 2023 the CA/Browser Forum requires the private key on FIPS 140-2 Level 2 hardware: USB token or cloud HSM. EV adds immediate SmartScreen reputation, which only matters for EXE/MSI, not `.ps1`. | Organisations publishing under a company name. Overkill for an individual OSS project. |
| **Internal CA** or **self-signed** cert pushed by MDM to Trusted Root + Trusted Publishers | Only that managed fleet | Free. | A customer who wants to re-sign the package for its own devices (for example after editing `Branding.json` or steps files). `Sign-Package.ps1` supports this. |

Whichever route: **always timestamp** (`-TimestampServer`). A timestamped signature stays valid after the certificate expires.

Note on identity: this is the author's open-source project, so releases are signed under the author's own verified name. The signature says who published the code; it does not say that Omnissa or any employer endorses it. Customers who need a signer they control can re-sign with their own certificate.

### Suggested path for the author

1. Apply for Azure Artifact Signing with individual validation (Azure subscription, identity validation resource, certificate profile of type Public Trust).
2. Install `signtool.exe` (Windows SDK) and the `Microsoft.Trusted.Signing.Client` package (NuGet) that provides the dlib.
3. Sign the staged scripts in CI with the `signtool` command below, then run `Create-ZipPackage.ps1` on the signed tree (or add a `-SignTool` step to it).
4. Publish the zips as GitHub release assets. Run `.\Sign-Package.ps1 -Verify` on a clean machine; every script should show `Valid` and `timestamped`.
5. Keep the rotation in mind: Artifact Signing certificates are short-lived, so an un-timestamped signature would die within days. Never skip `/tr`.

### Signing this package

```powershell
# One-off, with a certificate in CurrentUser\My or LocalMachine\My
.\Sign-Package.ps1 -CertificateThumbprint <thumbprint>

# As part of the build
.\Create-ZipPackage.ps1 -CertificateThumbprint <thumbprint>

# Check
.\Sign-Package.ps1 -Verify
```

`Sign-Package.ps1` normalises each script to UTF-8 with BOM first (BOM-less files with non-ASCII characters are the classic cause of `HashMismatch`), signs with SHA-256 and an RFC 3161 timestamp, then verifies every file.

For hosted signing services use `signtool.exe` instead, for example with Azure Artifact Signing:

```
signtool sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 ^
  /dlib "Microsoft.Trusted.Signing.Client\bin\x64\Azure.CodeSigning.Dlib.dll" ^
  /dmdf metadata.json  *.ps1
```

### Turning signatures on at the endpoint

1. Push the signing certificate (public part) to **Trusted Root** (if private CA) and **Trusted Publishers** on the devices.
2. Deploy with `Install-TroubleshootWizard.ps1 -ScriptExecutionPolicy AllSigned`. The task and protocol handler then refuse unsigned or tampered scripts.
3. Keep the Workspace ONE install command on `-ExecutionPolicy Bypass`; the installer itself is signed too, but the WS1 agent's own process policy is outside your control.
4. If the fleet runs **WDAC or AppLocker with script enforcement**, unsigned PowerShell drops into Constrained Language Mode, which breaks WPF (`Add-Type`, arbitrary .NET types). A signed package whose publisher is allowed by the policy is the only way the wizard runs there.

### What signing does not do

* It does not protect `DiagSteps\*.json`. The ACL does.
* It does not stop an admin on the device from editing the scripts; a signature check then fails, which is the point.
* It does not influence SmartScreen for scripts; SmartScreen reputation applies to downloaded executables and installers.
