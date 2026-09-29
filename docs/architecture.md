# Architecture

## Overview

```
                +--------------------------------------------------------------+
                |  App.ps1  (params, elevation check, load XAML, wiring)        |
                +-------------------------------+------------------------------+
                                                |
                     UI thread (STA, WPF)       |         background runspaces (MTA)
   +--------------------------------------+     |     +------------------------------------------+
   | UI\Ui.ps1  Update-FslUi*, grids,     |<----+---->| Collect.ps1  Invoke-FslCollectAll         |
   | dashboard cards, dialogs, export     | jobs|      |  -> Collectors\*.ps1 (SystemInfo, FSLogix, |
   | DispatcherTimer polls jobs (150 ms)  |     |      |     Sessions, Containers, Events, Health)  |
   +--------------------------------------+     |     |  -> Core\Core.ps1 (log, config, timeouts)  |
                      ^                          |     +------------------------------------------+
                      |                          |
   Export\Report.ps1 (sanitize, JSON/CSV/HTML/TXT)   all functions without "FslUi" in their name are
                                                     injected into every background runspace
```

## Layers

| Layer | Folder | Responsibility |
|---|---|---|
| Core | `src\Core` | result model (`New-FslResult`), logging, configuration, timeout helpers, export path validation, HTML encoding |
| Data collection | `src\Collectors` | read-only access to the local host; no UI dependencies, no `$script:` variables |
| Export | `src\Export` | report model, sanitizing, JSON/CSV/HTML/TXT |
| GUI | `src\UI` | WPF XAML + helpers; runs on the UI thread only |
| Start | `src\App.ps1` | parameters, elevation, window, event wiring, development/test modes |

## Threading

- The GUI runs on an STA thread. Every long-running task (full refresh, reading/filtering a log file, service action, listing log files)
  starts its **own runspace** (`Start-FslUiJob`) with an `InitialSessionState` that contains all `*-Fsl*` functions (except `FslUi`).
  The UI thread never waits for results.
- A `DispatcherTimer` (150 ms) checks `IAsyncResult.IsCompleted`, processes the result on the UI thread (`OnDone`) and cleans up.
  No cross-thread dispatcher calls are needed and the GUI stays responsive.
- Progress: a synchronized hashtable (`Step`, `Progress`) is updated by the collector and displayed by the same timer.
- Overlap: `Start-FslUiRefresh` returns immediately when a refresh is already running (including auto-refresh ticks).
- Network probes (DNS, TCP 445, `Test-Path` on UNC) have hard timeouts (`Invoke-FslWithTimeout`, `Test-FslTcpPort`,
  `Resolve-FslDnsName`); the result is then *Timeout* instead of a hanging refresh.

## Error isolation

`Invoke-FslCollectAll` runs each data source in `Invoke-FslStep`: an exception is logged and added to the snapshot as a
*data source error* (visible through the status bar button); the other sources continue. Missing FSLogix components are not an error:
services become *N/A*, event logs are reported as *not present*.

## Data sources

| Area | Source |
|---|---|
| Windows/uptime/UBR | `Win32_OperatingSystem`, registry `CurrentVersion` |
| Last update | Windows Update history (COM, with timeout), fallback `Get-HotFix` |
| AVD Agent/Boot Loader | Uninstall registry (64/32-bit), services `RDAgentBootLoader`/`RdAgent` |
| FSLogix installation | registry `HKLM\SOFTWARE\FSLogix\Apps`, `Program Files\FSLogix\Apps`, file version of `frxsvc.exe` |
| Configuration | `HKLM\SOFTWARE\FSLogix\{Profiles,ODFC}` and `HKLM\SOFTWARE\Policies\FSLogix\…` (policy > local) |
| Services | `Win32_Service`, `Win32_SystemDriver`, `Get-Process` |
| Sessions | WTS API (`wtsapi32.dll`, own `Add-Type`), fallback `quser.exe`; profiles via `Win32_UserProfile` + ProfileList |
| Containers | `frx.exe list-redirects`, `Profiles\Sessions\<SID>`, `Get-Disk` (BusType *File Backed Virtual*) + `Get-Volume`, `Get-SmbConnection` |
| Events | `Get-WinEvent -FilterHashtable` (existence is checked first with `Get-WinEvent -ListLog`) |
| Logs | `%ProgramData%\FSLogix\Logs\*` through `FileStream` (shared read access, end of file only) |

## Packaging

`build.ps1` merges `App.ps1`, all modules and the XAML (as here-string `$script:FslMainXaml`) into `build\work\fsl-master.bundle.ps1`
and compiles that with PS2EXE. When the bundle runs, `$script:FslBundled = $true`, so `App.ps1` loads nothing from disk.
From source, `App.ps1` loads the same files through dot-sourcing (`start-dev.ps1`).

## Development/test modes of `App.ps1`

| Parameter | Purpose |
|---|---|
| `-AllowNonElevated` | runs without administrator rights (limited data) |
| `-SelfTest <file>` | headless data collection, JSON summary, exit 0/1 |
| `-CaptureScreenshots <folder>` | renders every page to PNG and exits (used by `build.ps1` as the GUI smoke test) |
