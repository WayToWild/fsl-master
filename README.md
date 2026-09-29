# FSL Master

**Local FSLogix diagnostics and monitoring for Azure Virtual Desktop**

FSL Master is a modern, portable replacement for the old Microsoft *FRXTray*. An administrator starts it on a Windows or
Azure Virtual Desktop session host and immediately sees the state of FSLogix on **that one host**: configuration, services,
sessions, containers, events, log files and a health score. By default the application is **read-only**.

![Dashboard](docs/screenshots/01-dashboard.png)

> The screenshots in this repository were made with **synthetic sample data** (fictitious host `AVDHOST-01`, domain
> `contoso.local`, fictitious users) because the development machine had no FSLogix. See [Known limitations](#known-limitations).

| | |
|---|---|
| ![Containers](docs/screenshots/05-containers.png) | ![Events](docs/screenshots/06-events.png) |
| ![Health check](docs/screenshots/08-health.png) | ![Light theme](docs/screenshots/11-dashboard-light.png) |

## Features

- **Dashboard** – computer name, Windows product/version/build+UBR, last cumulative update, uptime, FSLogix version and service,
  AVD Agent and Boot Loader version, active sessions, mounted containers, FSLogix errors in the selected period, last refresh and
  overall health. Missing components are shown as *Not installed* / *Not available* – never a crash.
- **FSLogix configuration** – Profiles, ODFC and Cloud Cache from `HKLM\SOFTWARE\FSLogix` and `HKLM\SOFTWARE\Policies\FSLogix`, distinguishing
  *not configured / local / via policy*, the effective value (policy wins), registry path, description, assessment and
  include/exclude groups. Export to JSON and CSV. Unknown defaults are shown as *Unknown*, not invented.
- **Services and components** – `frxsvc`, `frxccds`, `frxdrv`, `frxdrvvt`, `frxdrvlt`, binaries and file versions, start type, process info.
  Optionally (with confirmation and logging): start/stop/restart of `frxsvc` and `frxccds`.
- **Users and sessions** – local sessions through the WTS API (object based, locale independent), `quser.exe` only as a fallback;
  user, domain, SID, session state, logon time, idle time, profile path, temporary-profile detection and mounted container.
- **Containers and redirects** – `frx.exe list-redirects`, registry (`Profiles\Sessions`), mounted VHD(X) volumes, SMB connections and local
  profiles; size/modification date, file server/share, volume health, network checks with timeouts (*Timeout* instead of hanging).
  Export to CSV, JSON and HTML.
- **Events** – `Microsoft-FSLogix-Apps/Operational`, `…/Admin`, `Application` and `System` (existing logs only; missing logs are
  reported). Filters for period, ID, log, level, user/SID and free text; configurable highlighted Event IDs
  (default 25, 26, 27, 28, 57, 58, 59, 60); detail window with copy.
- **FSLogix log files** – `C:\ProgramData\FSLogix\Logs\{Profile,ODFC,CloudCache}`; newest first, only the end of large files
  is read (256 KB – 20 MB), search, filter by level/user/SID/date, quick filters (ERROR, WARN, attach, detach, failed,
  timeout, locked, LoadProfile, VHD, VHDX, Cloud Cache), copy lines and export a fragment.
- **Health check** – read-only checks for FSLogix, storage, network (DNS, port 445, UNC access), Windows and AVD, with status, result,
  evidence, recommendation, timestamp and a score of 0–100 ([calculation](#health-score-calculation)).
- **Reporting** – HTML, JSON, CSV (per section) and TXT, optionally as a **Sanitized report** (user names, SIDs, server names,
  domain names and UNC paths masked).
- **Other** – auto-refresh (off/30 s/60 s/5 min) without overlapping runs, progress per data source, error isolation per data source,
  dark and light theme, copy/refresh/export buttons, structured log file.

Colour is never the only carrier of information: every status also has text and an icon
(✔ Healthy, ⚠ Warning, ✖ Error, ? Unknown, – N/A).

## System requirements

| | |
|---|---|
| Operating system | Windows 10/11 (also multi-session) and Windows Server 2016/2019/2022/2025, 64-bit |
| PowerShell | **Windows PowerShell 5.1** (in-box). PowerShell 7 is not supported |
| Rights | Local administrator (UAC elevation) |
| Runtime | .NET Framework 4.x (in-box); no extra PowerShell modules or installation needed |
| Network | No internet connection needed; only SMB/DNS to your own container locations |

Tested on: Windows 11 Enterprise 25H2 (build 26200), Windows PowerShell 5.1. Other Windows versions have not been tested.

## Using the portable executable

1. Copy `fsl-master.exe` (from `fsl-master.zip`) to the session host, for example to `C:\Tools\FSL-Master`.
2. Verify the hash: `Get-FileHash .\fsl-master.exe -Algorithm SHA256` against `fsl-master.exe.sha256`.
3. Double-click. Windows asks for UAC elevation (the exe has the manifest `requireAdministrator`).
4. Click *Refresh* for a new measurement or pick an auto-refresh interval.

There is no installation, no service and no entry in *Programs and Features*. The application only writes to:

- `%ProgramData%\FSL-Master\Logs` (fallback: `%TEMP%\FSL-Master\Logs`) – application log;
- export locations chosen by the user;
- optionally `fsl-master.config.json` next to the exe (fallback: `%ProgramData%\FSL-Master\config.json`) when the highlighted Event IDs
  are saved.

### Why administrator rights?

Without elevation, things like `Get-Disk`/`Get-Volume` for mounted VHDs, `Get-SmbConnection`, service and driver details, reading
FSLogix logs under `C:\ProgramData` and the FSLogix event log may be limited or impossible (depending on your security settings).
If the application is started non-elevated anyway (source/test mode) it says so immediately and offers to restart elevated; the
non-elevated instance then exits.

### Configuration file

`fsl-master.config.json` (all keys optional; missing or invalid = defaults):

```json
{
  "MarkedEventIds": [25, 26, 27, 28, 57, 58, 59, 60],
  "LookbackHours": 24,
  "MaxEvents": 2000,
  "AutoRefreshSeconds": 0,
  "LowDiskWarnPercent": 10,
  "LowDiskErrorPercent": 5,
  "NetworkTimeoutMs": 3000
}
```

The meaning of an Event ID is deliberately **not** assumed: the list only highlights; provider, log and message text remain authoritative.

## Running from source

```powershell
git clone https://github.com/WayToWild/fsl-master.git
cd fsl-master
.\start-dev.ps1                      # from an elevated Windows PowerShell 5.1
.\start-dev.ps1 -AllowNonElevated    # development/test mode, limited data
.\start-dev.ps1 -SelfTest out.json   # headless self-test, writes a JSON summary
```

If PowerShell refuses to run the scripts (`is not digitally signed`), unblock the downloaded files and/or relax the policy for the
current session only:

```powershell
Get-ChildItem -Recurse . | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
```

## Building the executable

```powershell
.\build.ps1
```

Requires on the build machine: Windows PowerShell 5.1, the module **ps2exe 1.0.18** (pinned) and preferably Pester. See
[docs/building.md](docs/building.md). Output: `dist\fsl-master.exe`, `dist\fsl-master.exe.sha256`, `dist\fsl-master.zip`,
`dist\build-info.json`.

**Packaging:** `build.ps1` bundles all scripts, the XAML and the logic into one script and compiles it with **PS2EXE** (x64, STA,
`-noConsole`, `-requireAdmin`) into a single portable `fsl-master.exe`. No loose files are needed. This was chosen because the scripts
stay in PowerShell 5.1 (maximum compatibility with AVD hosts), no installer is needed and the source stays readable.

## Project structure

```
fsl-master\
├── src\
│   ├── App.ps1                 entry point (params, elevation check, window, wiring)
│   ├── Core\Core.ps1           constants, result model, logging, config, timeouts, export path validation
│   ├── Collectors\             SystemInfo, FSLogix, Sessions, Containers, Events, Health, Collect (orchestrator)
│   ├── Export\Report.ps1       sanitizing, report model, JSON/CSV/HTML/TXT
│   └── UI\                     MainWindow.xaml and Ui.ps1 (WPF helpers)
├── tests\FslMaster.Tests.ps1   Pester tests
├── build\                      helper scripts (icon, BOM), work folder
├── dist\                       build output (not in Git)
├── assets\                     icon
├── docs\                       architecture, building, security, troubleshooting, screenshots
├── build.ps1  start-dev.ps1  README.md  CHANGELOG.md  LICENSE
```

## Health score calculation

Every health check has a status and a weight. Only `Healthy`, `Warning` and `Error` are scored:

| Status | Points |
|---|---|
| Healthy | 1 |
| Warning | 0.5 |
| Error | 0 |
| **Unknown** | *not counted* – so it does **not** count as an error |
| **N/A** | *not counted* |

```
score = round( 100 × Σ(weight × points) / Σ(weight)  over all scored checks )
```

- **Weight 2 (critical):** FSLogix installed, service `frxsvc` running, Profile Containers enabled, container location
  configured, SMB port 445 to the file server, access to the UNC path. All other checks have weight 1.
- **Overall status:** *Error* when the score is < 60 or a critical check has an `Error`; otherwise *Warning* when the score is < 90 or
  at least one warning/error exists; otherwise *Healthy*. **Unknown** when nothing could be scored, the coverage
  (scored ÷ non-N/A) is below 50 %, or FSLogix is not installed.
- **Thresholds:** free disk space < 10 % = warning, < 5 % = error (configurable); recent FSLogix events: 0 = healthy,
  1–9 errors or ≥ 1 warning = warning, ≥ 10 errors = error; last update > 45 days = warning, > 90 = error;
  uptime > 60 days = warning.
- The coverage is shown next to the score so a high score with many *Unknown* results is not falsely reassuring.

## Known limitations

- **The development machine had no FSLogix.** All code paths that need FSLogix (containers, redirects, FSLogix event logs,
  log files, service actions) were tested with mocks and synthetic samples, not against a real FSLogix installation.
  The GUI was fully rendered and checked with synthetic data.
- **`frx list-redirects` has no documented, stable output format.** The parser recognises records by SID, VHD(X) path and
  redirect target (best effort). The raw output is always visible on the *frx output (raw)* tab.
- Which values exist under `HKLM\SOFTWARE\FSLogix\Profiles\Sessions\<SID>` differs per FSLogix version; therefore all
  values are read and the VHD(X) path is recognised by content.
- Default values are only shown when they appear in the Microsoft documentation; they may differ per FSLogix version.
- The compiled `fsl-master.exe` is **not signed**. Antivirus/EDR or WDAC may block or flag unsigned (PS2EXE) executables.
  On the development machine, starting (even trivial, self-compiled) unsigned executables was almost always blocked
  (*Access is denied*). Once, a non-elevated self-test of a compiled twin of the same bundle succeeded (host data, runspaces and
  health check worked in the PS2EXE host); the GUI from the exe and the real, elevated `fsl-master.exe` were **not** started by the
  developer. The GUI was rendered and checked with the exact same bundle as a script. Test the exe on the target host first and
  sign it with your own code-signing certificate in managed environments.
- Local host only; no multi-host, no remoting, no history between sessions.
- Cloud Cache: only SMB locations (`type=smb`) are tested for reachability; Azure Blob providers are not.
- Supported: Windows PowerShell 5.1. PowerShell 7 has not been tested.

## Security information

In short: read-only by default, every management action with confirmation + logging, no telemetry, no runtime downloads, no
ExecutionPolicy bypass, all HTML output escaped, export paths validated. Details in [docs/security.md](docs/security.md).

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md). Log file: `%ProgramData%\FSL-Master\Logs\fsl-master-<date>.log`
(the path is shown under *About FSL Master*). Data source errors can be opened from the status bar after each refresh.

## Privacy statement

FSL Master only reads data from the local computer. Nothing is sent anywhere: **no telemetry, no automatic uploads,
no hidden network communication**. Network traffic is limited to DNS, TCP 445 and file access to the container locations named by your own
FSLogix configuration (health check). Reports and exports may contain personal data
(user names, SIDs, paths); use *Sanitized report* before sharing a report. No passwords, tokens or
credentials are stored.

## Disclaimer for production use

The software is provided "as is", without warranty (see [LICENSE](LICENSE)). Service actions (stopping/restarting `frxsvc`/
`frxccds`) can disrupt active user sessions and profile containers. Test on a non-production host first, review the
data against your own FSLogix configuration and use the results as an aid, not as the single source of truth.

## License

[MIT](LICENSE) – https://github.com/WayToWild/fsl-master
