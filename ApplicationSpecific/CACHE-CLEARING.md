# Cache-clearing action scripts

Twelve `Clear-<App>Cache.ps1` scripts, one per product, built from one shared engine so they behave
the same and differ only in their catalogue. Added 2026-11-12 at the request of a customer who asked
for a "generic clear-application-cache script"; the answer is a catalogue per product, because
Windows has no notion of an application cache and the only way a script knows a folder is safe to
delete is that someone wrote it down for that app.

## Contract (every script)

| Aspect | Behaviour |
|---|---|
| Kind | Action: no threshold, no detection. Clears the catalogue's folders and reports MB freed. |
| Scope | Contents of the listed folders only; the folders stay so the app finds them. Nothing outside the catalogue is read or deleted. |
| Users | `Users=Console` (default): the signed-in user from `Win32_ComputerSystem.UserName`, profile path from `ProfileList`. `Users=All`: every local profile. Never `$env:LOCALAPPDATA`, which is SYSTEM's under Hub. |
| Gate | If the product's process runs for the user, that user is `[Skipped]` and reported. `CloseApp=true` asks it to close (`CloseMainWindow`, 20 s) and still skips if it stays open. Nothing is killed. |
| WhatIf | `WhatIf=true` measures and reports, deletes nothing. The UEM sweep manifest runs every script this way. |
| Optional | Entries marked optional (offline web storage, add-in caches, large package stores) need `IncludeOptional=true`. |
| Destructive | OneNote only: clears nothing without `AllowDestructiveActions=true`, because its cache holds notebook content until it has synced. |
| Budget | Stops deleting after 50 s, reports `Partial`; the next run finishes. Keeps the report inside Hub's 60 s timeout. |
| Locked files | Counted and left; reported per user and in the summary. |
| Output | One line per user (`[Cleared]`, `[WhatIf ]`, `[Skipped]` with the reason) and a summary line. |
| Cache | `HKLM\Software\AirWatch\Extensions\AppCache\<App>`: LastRun, Status (Cleared, Partial, Skipped, WhatIf, NotInstalled, NoUser, Error), MBFreed, MBMeasured, UsersCleared, UsersSkipped, LockedFiles, BudgetHit, WhatIf, ScriptVersion. |
| Exit | 0 always, 1 only when the script itself fails. |
| Engines | Windows PowerShell 5.1 and PowerShell 7.2 (Hub on ARM64), no event log reads, no child processes. |

## Products and catalogues

| Script | Clears | Never touches | Gate |
|---|---|---|---|
| `Chrome\Clear-ChromeCache.ps1` | Cache, Code Cache, GPUCache, Dawn caches of every profile; ShaderCache, GrShaderCache, GraphiteDawnCache; optional Service Worker storage | cookies, logins, history, bookmarks, Local Storage, sessions, extensions | chrome |
| `Microsoft\Edge\Clear-EdgeCache.ps1` | same layout under `Microsoft\Edge\User Data` | same, plus Collections; WebView2 caches other apps own | msedge |
| `Microsoft\Teams\Clear-TeamsCache.ps1` | classic: Cache, blob_storage, IndexedDB, databases, Code Cache, GPUCache (the remediation's list); new: WebView2 Cache, Code Cache, GPUCache, Dawn and shader caches under the MSTeams package | new Teams Local Storage and IndexedDB, sign-in tokens, logs | Teams, ms-teams |
| `Zoom\Clear-ZoomCache.ps1` | `data\cache`, `logs` | the rest of `data` (databases, config, SSO tokens), binaries | Zoom |
| `Microsoft\Office\Clear-OfficeCache.ps1` | OfficeFileCache, WebServiceCache, BackstageInAppNavCache, INetCache Content.MSO and Content.Word; optional Wef | OST and PST, `%AppData%\Microsoft\Office`, Templates, UProof, licensing | every Office process incl. Outlook and MSOSYNC |
| `Microsoft\OneNote\Clear-OneNoteCache.ps1` | `OneNote\16.0\cache`, only with AllowDestructiveActions | Backup, `%AppData%\Microsoft\OneNote` | ONENOTE, ONENOTEM |
| `Microsoft\VSCode\Clear-VSCodeCache.ps1` | Cache, Code Cache, GPUCache, Dawn caches, CachedData, CachedExtensionVSIXs, CachedProfilesData, Service Worker storage, Crashpad reports (stable and Insiders); optional logs, CachedConfigurations | User (settings, keybindings, snippets, globalStorage, workspaceStorage, History), Backups (hot exit), Local Storage, extensions | Code |
| `Anthropic\Claude\Clear-ClaudeCache.ps1` | desktop app Cache, Code Cache, GPUCache, Dawn caches, Service Worker storage, logs; Claude Code `.claude\debug`; optional installer packages | Local Storage, Session Storage, IndexedDB, `claude_desktop_config.json`; `.claude` projects, memory, settings, plugins, shell-snapshots; `%Temp%\claude` session scratch | Claude, claude |
| `GitHub\Clear-GitHubDesktopCache.ps1` | Cache, Code Cache, GPUCache, Dawn caches, logs; optional installer packages | Local Storage, IndexedDB (accounts, repos), the app, repositories, `.gitconfig`, credential stores | GitHubDesktop |
| `Microsoft\VisualStudio\Clear-VisualStudioCache.ps1` | ComponentModelCache and Designer\ShadowCache of every instance, WebsiteCache; optional telemetry and ActivityLog | Extensions, Settings, privateregistry.bin, `%AppData%\Microsoft\VisualStudio`, `.vs` folders | devenv |
| `JetBrains\Clear-JetBrainsCache.ps1` | `<Product><ver>\caches`, `\tmp`; optional `\log` (Toolbox excluded by regex) | `%AppData%\JetBrains`, Toolbox and its IDEs, projects | idea64, pycharm64, webstorm64, rider64, clion64, goland64, phpstorm64, datagrip64, rubymine64, dataspell64, fleet |
| `DeveloperTools\Clear-DevPackageCache.ps1` | npm `_cacache` and `_logs`, Yarn Cache, pip cache, NuGet v3-cache, plugins-cache, Cache, Go build cache; optional `.nuget\packages`, `.gradle\caches`, `.m2\repository`, `.cargo\registry\cache`, pnpm store | global installs, config files, Gradle wrapper, project folders | none |

## Sensors

- `<app>_cache_mb.ps1` (Integer, recurring) for the caches that grow large: Chrome, Edge, Teams,
  Office, VS Code, JetBrains, package managers. Same catalogue (non-optional entries), console user
  only, -1 when not installed or nobody signed in. Thresholds documented in each header (500 MB for
  the browsers and Teams, 1,000 for Office and VS Code, 2,000 for JetBrains and the package caches).
- `OneTimeSensor\app_cache_health.ps1` (JSON, run once from the console): every product's MB, folder
  count, whether its process runs, and the last clear's Status and MB freed from the AppCache keys,
  plus `Over`, the products at or above their threshold. Under 1 KB by a trim ladder; 25 s budget.
  First run on `CBRADLEYSWIN11` 2026-11-12: 9 products installed, 1,055 MB in all, VS Code 507 MB
  (CachedData), package caches 349 MB, Chrome 101 MB, 22.7 s of measurement.

## Testing

`AutomatedTesting\Test-ClearCacheScripts.ps1` (elevated, as the console user): for each product it
plants a fixture inside a catalogue folder and a sentinel in a never-touch folder, checks the size
sensor counts the fixture, runs the script with WhatIf (fixture intact), runs it for real (fixture
gone and sentinel intact when the app is closed; `[Skipped]` and fixture intact when it is running),
checks the AppCache key, and cleans up only what it created. Then runs `app_cache_health` and asserts
one line of JSON under 1,000 bytes. Full Pass for these action scripts is `PASS - UEM` plus that
observed effect (TEST-VALIDATION.md section 1.3).

## Maintenance

The scripts are generated: `AutomatedTesting\Tools\New-ClearCacheScripts.ps1` holds the engine
template, the sensor templates and the per-product table. Edit there and re-run; never hand-edit a
generated file, the next run overwrites it. Adding a product is one table entry (key, folder,
processes, install markers, catalogue entries with optional flags, the three header lists).
