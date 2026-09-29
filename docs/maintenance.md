# Host maintenance and Windows updates

FSL Master can run a small, curated set of maintenance tasks on the local AVD session host and shows how the Windows build is
holding up. The design goal is **zero to low risk**: nothing runs unless you start it, every task has a visible risk level,
cleanup only touches old files in a fixed whitelist of folders, and the riskiest classic tricks are deliberately not offered.

## Risk levels

| Risk | Meaning | Examples |
|---|---|---|
| **None** | Read-only. Nothing on the host is changed. | DISM CheckHealth/ScanHealth/AnalyzeComponentStore, SFC verify-only, CHKDSK online scan, disk health, best-practice scan |
| **Low** | Removes old, non-critical files or does harmless housekeeping. Runs as a **dry run** unless you switch that off. | Clean old `Windows\Temp` files, WER files, FSLogix logs, minidumps; DISM StartComponentCleanup; DNS flush; ReTrim |
| **Medium** | Repairs system files. Confirmation required; only in the *Full* preset. | DISM RestoreHealth, SFC /scannow |

## Tasks

| Task | Risk | What it does |
|---|---|---|
| AVD best-practice scan | None | Free space, temp/log/update-cache/CBS folder sizes, page file, uptime, pending reboot, Defender status and FSLogix exclusions (VHD/VHDX), stale local profiles (report only) |
| Disk and volume health | None | `Get-PhysicalDisk` / `Get-Volume` health and free space |
| DISM CheckHealth | None | `dism /Online /Cleanup-Image /CheckHealth` (falls back to the DISM API for non-English Windows) |
| DISM ScanHealth | None | `dism /Online /Cleanup-Image /ScanHealth` – a few minutes, generates disk I/O |
| DISM AnalyzeComponentStore | None | Component store size and whether cleanup is recommended |
| SFC verify only | None | `sfc /verifyonly` – nothing is repaired |
| CHKDSK online scan | None | `chkdsk C: /scan` – **never** `/f` or `/r`, never schedules an offline check |
| DISM RestoreHealth | Medium | `dism /Online /Cleanup-Image /RestoreHealth` – needs the configured update source |
| SFC /scannow | Medium | Repairs protected system files; run it after RestoreHealth |
| Clean Windows\Temp | Low | Files older than `MaintTempAgeDays` (default 7); files in use are skipped |
| Clean WER files | Low | `ProgramData\Microsoft\Windows\WER\{ReportArchive,ReportQueue,Temp}` older than `MaintLogAgeDays` (30) |
| Clean FSLogix logs | Low | `ProgramData\FSLogix\Logs\*.log` older than `MaintLogAgeDays` (30) |
| Clean minidumps | Low | `Windows\Minidump\*.dmp` older than `MaintDumpAgeDays` (30). `MEMORY.DMP` is never touched |
| DISM StartComponentCleanup | Low | Removes superseded components (without `/ResetBase`) |
| Flush DNS cache | Low | `Clear-DnsClientCache` |
| Optimize system volume | Low | `Optimize-Volume -ReTrim` only (no defrag); *N/A* if the disk does not support it |

## Not offered on purpose

`chkdsk /f` or `/r` (needs an offline pass / reboot and can run for hours), `DISM /ResetBase` (makes updates uninstallable), resetting
`SoftwareDistribution`/`catroot2`, clearing event logs (destroys evidence), deleting user profiles or FSLogix containers, changing
services or registry settings, and automatic reboots. If a CHKDSK scan reports problems, FSL Master tells you to schedule an offline
`chkdsk /f` yourself in a maintenance window with a recent snapshot.

## Presets

| Preset | Content |
|---|---|
| **Diagnostics** | All risk-*None* tasks. Nothing is changed. |
| **Routine** | Quick checks (best practice, disk health, CheckHealth, AnalyzeComponentStore, SFC verify-only) plus the low-risk cleanup tasks. |
| **Full** | Diagnostics + DISM RestoreHealth + SFC /scannow + cleanup + ReTrim. Run in a maintenance window. |

You can also tick individual tasks. Tasks always execute in a safe order (diagnostics → repair (DISM before SFC) → cleanup).

## Safety mechanisms

- **Dry run is on by default** (`MaintDefaultDryRun`). In a dry run, cleanup shows how many files/bytes *would* be removed and repair/cleanup
  tools are not started; read-only diagnostics still run. Switching it off shows a warning and a final confirmation.
- **Preflight** before every run: administrator rights, another run in progress (system-wide mutex), free space on the system drive
  (blocks below 1 GB, warns below 5 GB for DISM), signed-in users, pending reboot, CPU load, and Windows servicing (TiWorker) activity.
  Blockers stop the run; warnings are shown in the confirmation dialog.
- **Low impact:** child tools run at *BelowNormal* priority, have a per-task timeout, and can be **cancelled** (the process tree is stopped).
  Put the host in **drain mode** before maintenance so no new sessions arrive.
- **Cleanup path whitelist:** only `Windows\Temp`, `Windows\Minidump`, `ProgramData\Microsoft\Windows\WER` and `ProgramData\FSLogix\Logs`.
  Drive roots, relative paths and `..` traversal are refused. Junctions/symlinks are never followed, files in use are skipped, and the ages
  can never be configured below 1 day.
- **Stop on first error** (default) skips the remaining tasks after a failure.
- **No reboot, ever.** If a task suggests one, the result says *reboot recommended*.
- **Audit trail:** every task start/finish is written to the log (`[ACTION]`), and every run saves `maintenance-<timestamp>.json` (results, output,
  preflight) in the FSL Master log folder; the page lists previous runs.

## Recommended workflow

1. Put the session host in drain mode and make sure no important sessions remain.
2. Take a snapshot/backup if you plan to run repair tasks.
3. Run **Diagnostics** and read the results (the output pane shows the raw tool output).
4. If DISM/SFC report corruption: run **Full** (dry run first, then live). DISM RestoreHealth needs access to the update source.
5. Run **Routine** regularly (for example weekly) to keep the host lean.
6. Restart the host if the report says *reboot recommended*, then take it out of drain mode.

## Headless / scheduled runs

```powershell
fsl-master.exe -RunMaintenance Routine                      # dry run (default!)
fsl-master.exe -RunMaintenance Routine -Apply               # really clean up
fsl-master.exe -RunMaintenance Full -Apply -IncludeRepair   # includes DISM RestoreHealth + SFC /scannow
fsl-master.exe -RunMaintenance diag.dism.check,clean.temp -Apply -MaintenanceReport C:\Reports\run.json
```

`-RunMaintenance` takes a preset name or a comma-separated list of task ids (see the *Run* column ids in the results grid or
`Get-FslMaintenanceCatalog`). Without `-Apply` everything is a dry run; without `-IncludeRepair` repair tasks are dropped. Exit codes:
`0` finished without errors, `1` finished with task errors, `2` blocked/aborted (for example not elevated, invalid task id, preflight blocker).
Run from an elevated Task Scheduler task ("Run with highest privileges"); the same preflight, timeouts and audit report apply.

## Windows updates page

Shows how your Windows build is holding up. Everything is **read-only** – the page searches for updates and reads history; it never
downloads or installs anything.

- **Local information (instant):** product, version, build and UBR, servicing status of the build, last cumulative update and its age, update
  history (failed installs in the last 30 days), last successful update check, update policy/source (WSUS or Windows Update), service health, pending reboot.
- **Check for updates (online, can take a minute):** searches the host's own update source (WSUS, Windows Update, Windows Update for Business
  as configured) with a timeout and lists pending updates classified as *Critical / Security / Other / Feature / Driver / Definition*.
- **Score:** the same weighted score model as the health check. Pending critical updates, failed installs, an old cumulative update or an
  unsupported build turn the status to Warning/Error; an unreachable update source is *Unknown*, not a failure.
- **Servicing status of the build:** compared with a small reference table of end-of-servicing dates (Windows 10 22H2, Windows 11 21H2–25H2,
  Server 2016/2019/2022/2025 builds). It is reference data – verify it with Microsoft's lifecycle pages and add or override entries with
  `BuildLifecycle` in `fsl-master.config.json`. Builds that are not in the table show *Unknown*.

## Configuration keys

| Key | Default | Meaning |
|---|---|---|
| `MaintTempAgeDays` | 7 | Minimum age of files removed from `Windows\Temp` (minimum 1) |
| `MaintLogAgeDays` | 30 | Minimum age of WER and FSLogix log files removed (minimum 1) |
| `MaintDumpAgeDays` | 30 | Minimum age of minidumps removed (minimum 1) |
| `MaintDefaultDryRun` | `true` | Initial state of the *Dry run* checkbox |
| `BuildLifecycle` | `[]` | Extra/overriding entries: `{ "Build": 26200, "Name": "…", "EndOfServicing": "2028-10-10" }` |

## Limitations

- DISM, SFC and CHKDSK result texts are recognised for English Windows; on other languages the result is *Unknown* (raw output shown;
  DISM CheckHealth uses the DISM API as a fallback). CHKDSK is judged by its exit code.
- DISM RestoreHealth needs the update source; on hosts without internet/WSUS access it fails with `0x800f081f` (explained in the result).
- A running DISM/SFC cannot report fine-grained progress; the page shows elapsed time.
- The maintenance page is a manual/scheduled tool for **one host**. It does not orchestrate drain mode or reboots.
