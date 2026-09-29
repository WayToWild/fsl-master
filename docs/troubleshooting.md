# Troubleshooting

## The scripts will not run ("is not digitally signed")
The PowerShell execution policy blocks the scripts, typically because they came from a downloaded ZIP (Mark of the Web).

```powershell
Get-ChildItem -Recurse . | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned   # this window only
```

If the policy is enforced by Group Policy (`Get-ExecutionPolicy -List` shows `MachinePolicy`/`UserPolicy`) or is `AllSigned`, these do not help:
sign the scripts or ask your administrator for an exception.

## The application does not start or is blocked
- The executable is not signed. Antivirus, EDR or WDAC/AppLocker may block it ("Access is denied" when starting).
  Request an exception or sign the exe with your own certificate. As a temporary alternative the source can be started with
  `start-dev.ps1` from an elevated Windows PowerShell 5.1.
- Verify the hash against `fsl-master.exe.sha256`.
- After downloading a ZIP: *Properties → Unblock* (Mark of the Web).

## "Administrator rights required"
The application must run elevated. Choose *Yes* to restart elevated, or start with *Run as administrator*.

## A component shows "Not installed" or "Not available"
- FSLogix was not found (no `HKLM\SOFTWARE\FSLogix\Apps\InstallPath`, no `Program Files\FSLogix\Apps`, no service `frxsvc`). This is
  not an error; FSLogix-specific checks become *N/A* and the score gets the status *Unknown*.
- An event log is missing (for example `Microsoft-FSLogix-Apps/Admin`): this is noted under the event list.

## No containers or sessions visible
- Without active users there are no mounted containers.
- Open *Containers and redirects → frx output (raw)*: if there is output but the parser recognises no records, the output
  format of your FSLogix version differs. Open an issue with the (sanitized) output.
- Check that the application runs elevated; `Get-Disk`/`Get-SmbConnection` require it.

## "Timeout" for file servers
DNS, port 445 or the UNC path did not answer within `NetworkTimeoutMs` (default 3000 ms). Check DNS, firewall/NSG, the
file server and the permissions of the computer account. Optionally increase `NetworkTimeoutMs` in the configuration file.

## Data source errors
The *Data source errors (n)* button in the status bar shows the message and technical detail per source (copyable). The other sources
are not affected. See also the log file.

## Log file
`%ProgramData%\FSL-Master\Logs\fsl-master-<date>.log`; the exact path is shown under *About FSL Master*.

## The refresh takes long
A full refresh normally takes 10–30 s (Windows Update history, volume and SMB information). Slow DNS or unreachable
file servers can extend this by the timeouts. The GUI stays usable meanwhile.

## Development: testing without FSLogix
- `start-dev.ps1 -AllowNonElevated -CaptureScreenshots <folder>` renders all pages to PNG.
- The Pester tests use mocks for registry, services and event logs.
