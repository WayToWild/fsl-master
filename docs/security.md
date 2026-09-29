# Security

## Principles

- **Read-only by default.** No registry values are changed, no containers are detached, no VHDs are repaired and no profiles
  are deleted. The health check and the *Windows updates* page never run `DISM /RestoreHealth`, `sfc /scannow` or `chkdsk /f`
  and never download or install updates.
- **Management actions** are (1) start/stop/restart of the services `frxsvc` and `frxccds` and (2) the tasks of the *Host maintenance*
  page. They are clearly marked, ask for explicit confirmation (default button *No*, extra warnings for stop/restart and repair),
  run locally and are logged (`[ACTION]` in the log file). The service function accepts no other service names (`ValidateSet`).
- **Maintenance safety** (details in [maintenance.md](maintenance.md)): risk levels per task, dry run on by default, preflight checks,
  reduced process priority with timeouts and cancellation, a fixed whitelist of cleanup folders (no junction following, files in use are
  skipped, minimum age of 1 day), a run-wide mutex, no automatic reboot, and deliberately no `chkdsk /f`, `DISM /ResetBase`, event log
  clearing or profile deletion. Headless runs default to dry run and exclude repair tasks unless `-Apply` / `-IncludeRepair` are given.
- **Local only.** No PowerShell Remoting, WinRM, `Invoke-Command` to other hosts, central databases, Azure APIs or
  mandatory internet connection. `build.ps1` fails when such constructs appear in the source.
- **No telemetry, no automatic uploads, no dynamically downloaded code.**
- **No ExecutionPolicy bypass** in the application. Background runspaces use the effective ExecutionPolicy of the process.
- **No secrets.** No passwords, tokens or credentials are read, stored or logged. The repository contains none;
  `.gitignore` excludes common secret files (`.env`, `*.pfx`, `*token*`, …) and runtime artefacts (logs, exports, local config).

## Administrator rights

`fsl-master.exe` has the manifest `requestedExecutionLevel level="requireAdministrator"`. When started non-elevated (for example
from source) the application shows a message and offers to restart elevated; the non-elevated instance exits.
The `-AllowNonElevated` switch is only meant for development/tests.

## Input and output

- **HTML:** all values are escaped with `[System.Net.WebUtility]::HtmlEncode` (`ConvertTo-FslHtmlEncoded`); tested with
  markup in data.
- **Export paths** (`Test-FslExportPath`): full path required, invalid characters and wildcards rejected, expected extension enforced,
  the target folder must exist, exporting to the Windows folder is not allowed.
- **Configuration file:** invalid JSON or values fall back to safe defaults (tested); numbers are validated and bounded.
- **Sanitized report:** consistently masks user names, SIDs, server names, host name, domain names and UNC paths
  (`User01`, `SID-01`, `SERVER01`, `\\SERVER01\SHARE01`). Always review the result before sharing it outside your organisation;
  free text in event messages may contain other sensitive data that is not recognised as such.

## Logging

Log file: `%ProgramData%\FSL-Master\Logs\fsl-master-<yyyyMMdd>.log` (fallback `%TEMP%\FSL-Master\Logs`). Contains application start and
version, administrator status, refreshes, data source errors, timeouts, exports, service actions and unexpected exceptions. Contains no
credentials. Log files are not deleted or sent automatically.

## Known risks

- The exe is not signed; sign it in managed environments (see [building.md](building.md)).
- PS2EXE executables are flagged as false positives by some antivirus products or blocked by policy.
- The log file and exports may contain user names and paths; protect the folders with appropriate NTFS permissions.
