# FSL Master - AVD host maintenance: task catalog, preflight checks, low-impact process runner, guarded cleanup engine and run orchestration.
#
# Safety model (see docs/maintenance.md):
#   * Every task has a risk level: None (read-only), Low (removes only old, non-critical files / harmless housekeeping),
#     Medium (repairs system files; explicit confirmation, never part of the default presets).
#   * Nothing here runs automatically. A run is always started by the user (GUI) or by an explicit command-line switch.
#   * Not offered on purpose: chkdsk /f or /r, DISM /ResetBase, resetting SoftwareDistribution, clearing event logs,
#     deleting profiles, and automatic reboots.
#   * Child processes run at BelowNormal priority with a timeout and can be cancelled.

function Get-FslMaintenanceCatalog {
    $t = New-Object System.Collections.Generic.List[object]
    $add = {
        param($order, $id, $name, $cat, $risk, $mins, $presets, $kind, $desc)
        $t.Add([pscustomobject]@{ Order = $order; Id = $id; Name = $name; Category = $cat; Risk = $risk; EstMinutes = $mins; Presets = $presets; Kind = $kind; Description = $desc })
    }
    & $add 10 'diag.bestpractice' 'AVD best-practice scan' 'Diagnose' 'None' 1 @('Diagnostics', 'Routine', 'Full') 'Script' 'Read-only scan: free space, temp/log folder sizes, page file, uptime, pending reboot, Defender and FSLogix exclusions, stale local profiles.'
    & $add 20 'diag.disk.health' 'Disk and volume health' 'Diagnose' 'None' 1 @('Diagnostics', 'Routine', 'Full') 'Script' 'Read-only: physical disk and volume health status and free space.'
    & $add 30 'diag.dism.check' 'DISM CheckHealth' 'Diagnose' 'None' 1 @('Diagnostics', 'Routine', 'Full') 'Process' 'Read-only: quick check for a flagged component store corruption (dism /Online /Cleanup-Image /CheckHealth).'
    & $add 40 'diag.dism.scan' 'DISM ScanHealth' 'Diagnose' 'None' 10 @('Diagnostics', 'Full') 'Process' 'Read-only: full component store scan (dism /Online /Cleanup-Image /ScanHealth). Takes a few minutes and generates disk I/O.'
    & $add 50 'diag.dism.analyze' 'DISM AnalyzeComponentStore' 'Diagnose' 'None' 2 @('Diagnostics', 'Routine', 'Full') 'Process' 'Read-only: reports the component store size and whether a cleanup is recommended.'
    & $add 60 'diag.sfc.verify' 'SFC verify only' 'Diagnose' 'None' 8 @('Diagnostics', 'Routine', 'Full') 'Process' 'Read-only: sfc /verifyonly checks protected system files without repairing anything.'
    & $add 70 'diag.chkdsk.scan' 'CHKDSK online scan (read-only)' 'Diagnose' 'None' 10 @('Diagnostics', 'Full') 'Process' 'Read-only: chkdsk /scan on the system drive. Never uses /f or /r, never schedules an offline check.'
    & $add 100 'repair.dism.restore' 'DISM RestoreHealth' 'Repair' 'Medium' 30 @('Full') 'Process' 'REPAIRS the component store (dism /Online /Cleanup-Image /RestoreHealth). Needs the configured update source. Run in a maintenance window.'
    & $add 110 'repair.sfc.scannow' 'SFC /scannow (repair)' 'Repair' 'Medium' 15 @('Full') 'Process' 'REPAIRS corrupted system files (sfc /scannow). Best run after DISM RestoreHealth. Run in a maintenance window.'
    & $add 200 'clean.temp' 'Clean old files in Windows\Temp' 'Cleanup' 'Low' 2 @('Routine', 'Full') 'Script' 'Removes files older than the configured age (default 7 days) from C:\Windows\Temp. Files in use are skipped.'
    & $add 210 'clean.wer' 'Clean old Windows Error Reporting files' 'Cleanup' 'Low' 1 @('Routine', 'Full') 'Script' 'Removes old WER report archive/queue/temp files (default older than 30 days).'
    & $add 220 'clean.fslogixlogs' 'Clean old FSLogix log files' 'Cleanup' 'Low' 1 @('Routine', 'Full') 'Script' 'Removes FSLogix *.log files older than the configured age (default 30 days) from C:\ProgramData\FSLogix\Logs.'
    & $add 230 'clean.dumps' 'Clean old minidumps' 'Cleanup' 'Low' 1 @('Routine', 'Full') 'Script' 'Removes minidump files older than the configured age (default 30 days) from C:\Windows\Minidump. MEMORY.DMP is never touched.'
    & $add 240 'clean.dism.component' 'DISM StartComponentCleanup' 'Cleanup' 'Low' 10 @('Routine', 'Full') 'Process' 'Removes superseded Windows components (dism /Online /Cleanup-Image /StartComponentCleanup, without /ResetBase).'
    & $add 250 'clean.dns' 'Flush DNS resolver cache' 'Cleanup' 'Low' 1 @('Routine', 'Full') 'Script' 'Clears the local DNS client cache (harmless; entries are re-resolved on demand).'
    & $add 260 'opt.trim' 'Optimize system volume (ReTrim)' 'Optimize' 'Low' 3 @('Full') 'Script' 'Sends TRIM/UNMAP for free space (Optimize-Volume -ReTrim). No defragmentation. Reported as N/A when the disk does not support it.'
    ($t.ToArray() | Sort-Object Order)
}

function Get-FslMaintenancePresets {
    @(
        [pscustomobject]@{ Name = 'Diagnostics'; Description = 'Read-only checks only. Nothing is changed.' }
        [pscustomobject]@{ Name = 'Routine'; Description = 'Quick health checks plus low-risk cleanup of old temp/log/dump files.' }
        [pscustomobject]@{ Name = 'Full'; Description = 'Diagnostics, DISM/SFC repair and cleanup. Run in a maintenance window.' }
    )
}

function Get-FslMaintenancePresetIds {
    param([string]$Preset)
    @(Get-FslMaintenanceCatalog | Where-Object { $_.Presets -contains $Preset } | ForEach-Object { $_.Id })
}

# ------------------------------------------------------------------ result helpers
function New-FslMaintResult {
    param($Task, [ValidateSet('OK', 'Warning', 'Error', 'Unknown', 'NA')][string]$Status, [string]$Summary, [string]$Recommendation = '',
        [string]$Output = '', $ExitCode = $null, [double]$Seconds = 0, [bool]$RebootRecommended = $false, [bool]$Skipped = $false)
    [pscustomobject]@{
        Id = $Task.Id; Name = $Task.Name; Category = $Task.Category; Risk = $Task.Risk
        Status = $Status; StatusText = (Get-FslStatusText $Status); Glyph = (Get-FslStatusGlyph $Status)
        Summary = $Summary; Recommendation = $Recommendation; Output = $Output; ExitCode = $ExitCode
        Seconds = [math]::Round($Seconds, 1); Duration = ([timespan]::FromSeconds($Seconds)).ToString('hh\:mm\:ss')
        RebootRecommended = $RebootRecommended; Skipped = $Skipped; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}

# ------------------------------------------------------------------ low-impact process runner
function Get-FslOemEncoding {
    try { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { [Text.Encoding]::UTF8 }
}

function ConvertTo-FslCleanProcessOutput {
    # Removes NULs (UTF-16 leftovers), splits carriage-return progress bars into lines and keeps only the last progress line.
    param([string]$Text, [int]$MaxChars = 200000)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace "`0", ''
    $t = $t -replace "`r(?!`n)", "`n"
    $lines = $t -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $lastProgress = $null
    foreach ($l in $lines) {
        if ($l -match '^\s*\[[= ]*[\d.]+%[= ]*\]\s*$') { $lastProgress = $l; continue }
        if ($lastProgress) { $out.Add($lastProgress.Trim()); $lastProgress = $null }
        if ($l.Trim() -ne '' -or ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '')) { $out.Add($l.TrimEnd()) }
    }
    if ($lastProgress) { $out.Add($lastProgress.Trim()) }
    $res = ($out -join "`r`n").Trim()
    if ($res.Length -gt $MaxChars) { $res = '...(truncated)...' + "`r`n" + $res.Substring($res.Length - $MaxChars) }
    $res
}

function Invoke-FslProcess {
    # Runs a console tool at reduced priority with timeout and cancellation. Returns Started, ExitCode, TimedOut, Cancelled, Output, Seconds, Error.
    param([string]$FilePath, [string]$Arguments = '', [int]$TimeoutSec = 600, [ValidateSet('OEM', 'Unicode', 'UTF8')][string]$Encoding = 'OEM',
        [hashtable]$Sync, [ValidateSet('Idle', 'BelowNormal', 'Normal')][string]$Priority = 'BelowNormal')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $enc = switch ($Encoding) { 'Unicode' { [Text.Encoding]::Unicode } 'UTF8' { [Text.Encoding]::UTF8 } default { Get-FslOemEncoding } }
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath; $psi.Arguments = $Arguments; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.StandardOutputEncoding = $enc
        $p = [Diagnostics.Process]::Start($psi)
    } catch {
        return [pscustomobject]@{ Started = $false; ExitCode = $null; TimedOut = $false; Cancelled = $false; Output = ''; Seconds = 0; Error = $_.Exception.Message }
    }
    try { $p.PriorityClass = [Diagnostics.ProcessPriorityClass]$Priority } catch { }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = $false; $cancelled = $false
    while (-not $p.WaitForExit(400)) {
        if ($Sync -and $Sync.Cancel) { $cancelled = $true }
        elseif ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $timedOut = $true }
        if ($cancelled -or $timedOut) {
            try { & (Join-Path $env:windir 'System32\taskkill.exe') /PID $p.Id /T /F 2>&1 | Out-Null } catch { }
            try { $p.Kill() } catch { }
            break
        }
    }
    try { $null = $p.WaitForExit(5000) } catch { }
    $text = ''
    try { if ($outTask.Wait(5000)) { $text = $outTask.Result } } catch { }
    if ([string]::IsNullOrWhiteSpace($text)) { try { if ($errTask.Wait(2000)) { $text = $errTask.Result } } catch { } }
    $code = $null; try { if ($p.HasExited) { $code = $p.ExitCode } } catch { }
    [pscustomobject]@{ Started = $true; ExitCode = $code; TimedOut = $timedOut; Cancelled = $cancelled; Output = (ConvertTo-FslCleanProcessOutput $text); Seconds = $sw.Elapsed.TotalSeconds; Error = $null }
}

# ------------------------------------------------------------------ output interpreters (pure functions, unit tested)
function ConvertFrom-FslDismOutput {
    # Mode: check | scan | analyze | restore | cleanup. English messages are recognised; otherwise the exit code decides.
    param([ValidateSet('check', 'scan', 'analyze', 'restore', 'cleanup')][string]$Mode, [string]$Text, $ExitCode)
    $reboot = ($ExitCode -eq 3010)
    $r = @{ Status = 'Unknown'; Summary = ''; Recommendation = ''; Reboot = $reboot }
    $hex = if ($Text -match '(?i)Error:\s*(0x[0-9a-f]+)') { $Matches[1].ToLowerInvariant() } else { $null }
    if ($ExitCode -ne 0 -and $ExitCode -ne 3010) {
        $r.Status = 'Error'
        $r.Summary = "DISM failed (exit code $ExitCode$(if ($hex) { ", $hex" }))."
        if ($ExitCode -eq 740) { $r.Recommendation = 'DISM needs an elevated (administrator) process. Start FSL Master as administrator.' }
        elseif ($hex -in '0x800f081f', '0x800f0906', '0x800f0907', '0x800f0950') { $r.Recommendation = 'DISM could not find the source files. Check the Windows Update source (WSUS/internet access) or supply /Source, then retry.' }
        elseif ($hex -eq '0x800f0922') { $r.Recommendation = 'Servicing failed (not enough free space or pending operations). Free disk space, reboot and retry.' }
        else { $r.Recommendation = 'Review the output and C:\Windows\Logs\DISM\dism.log.' }
        return [pscustomobject]$r
    }
    switch ($Mode) {
        { $_ -in 'check', 'scan' } {
            if ($Text -match '(?i)No component store corruption detected') { $r.Status = 'OK'; $r.Summary = 'No component store corruption detected.' }
            elseif ($Text -match '(?i)component store is repairable') { $r.Status = 'Warning'; $r.Summary = 'The component store is corrupted but repairable.'; $r.Recommendation = 'Run DISM RestoreHealth (in a maintenance window), then SFC /scannow.' }
            elseif ($Text -match '(?i)cannot be repaired|not repairable|is not repairable') { $r.Status = 'Error'; $r.Summary = 'The component store is corrupted and cannot be repaired.'; $r.Recommendation = 'Consider redeploying or rebuilding the host from the image.' }
            else { $r.Summary = 'DISM finished (exit code 0) but the result text was not recognised (non-English Windows?). Review the output.' }
        }
        'analyze' {
            $rec = if ($Text -match '(?i)Component Store Cleanup Recommended\s*:\s*(\w+)') { $Matches[1] } else { $null }
            $size = if ($Text -match '(?i)Actual Size of Component Store\s*:\s*(.+)') { $Matches[1].Trim() } else { $null }
            if ($rec -match '^(?i)yes$') { $r.Status = 'Warning'; $r.Summary = "Component store cleanup is recommended$(if ($size) { " (size $size)" })."; $r.Recommendation = 'Run DISM StartComponentCleanup (low risk).' }
            elseif ($rec -match '^(?i)no$') { $r.Status = 'OK'; $r.Summary = "No component store cleanup needed$(if ($size) { " (size $size)" })." }
            else { $r.Summary = 'Component store analysed; recommendation text not recognised. Review the output.' }
        }
        'restore' {
            if ($Text -match '(?i)restore operation completed successfully') { $r.Status = 'OK'; $r.Summary = 'The restore operation completed successfully.'; if ($Text -match '(?i)corruption was repaired') { $r.Summary = 'Component store corruption was repaired.'; $r.Reboot = $true } }
            else { $r.Summary = 'DISM finished (exit code 0); success text not recognised. Review the output.' }
            if ($r.Status -eq 'OK') { $r.Recommendation = 'Run SFC /scannow next; a reboot is recommended if anything was repaired.' }
        }
        'cleanup' {
            if ($Text -match '(?i)operation completed successfully') { $r.Status = 'OK'; $r.Summary = 'Component cleanup completed.' }
            else { $r.Status = 'OK'; $r.Summary = 'Component cleanup finished (exit code 0).' }
        }
    }
    [pscustomobject]$r
}

function ConvertFrom-FslSfcOutput {
    param([ValidateSet('verify', 'scan')][string]$Mode, [string]$Text, $ExitCode)
    $r = @{ Status = 'Unknown'; Summary = ''; Recommendation = ''; Reboot = $false }
    if ($Text -match '(?i)did not find any integrity violations') { $r.Status = 'OK'; $r.Summary = 'No integrity violations found.' }
    elseif ($Text -match '(?i)found corrupt files and successfully repaired') { $r.Status = 'OK'; $r.Summary = 'Corrupt files were found and repaired.'; $r.Reboot = $true; $r.Recommendation = 'Reboot the host; re-run SFC to confirm.' }
    elseif ($Text -match '(?i)found corrupt files but was unable to fix') { $r.Status = 'Error'; $r.Summary = 'Corrupt files were found that could not be repaired.'; $r.Recommendation = 'Run DISM RestoreHealth, reboot, then SFC /scannow again. Details: C:\Windows\Logs\CBS\CBS.log.' }
    elseif ($Text -match '(?i)found integrity violations') { $r.Status = 'Warning'; $r.Summary = 'Integrity violations found (nothing was repaired in verify-only mode).'; $r.Recommendation = 'Run DISM RestoreHealth, then SFC /scannow. Details: C:\Windows\Logs\CBS\CBS.log.' }
    elseif ($Text -match '(?i)system repair pending') { $r.Status = 'Warning'; $r.Summary = 'A system repair is pending; a reboot is required first.'; $r.Recommendation = 'Reboot the host and retry.'; $r.Reboot = $true }
    elseif ($Text -match '(?i)could not perform the requested operation') { $r.Status = 'Error'; $r.Summary = 'SFC could not perform the requested operation.'; $r.Recommendation = 'Ensure no other servicing operation is running; check CBS.log.' }
    else { $r.Summary = 'SFC finished but the result text was not recognised (non-English Windows?). Review the output and CBS.log.' }
    [pscustomobject]$r
}

function ConvertFrom-FslChkdskOutput {
    # chkdsk exit codes: 0 = no errors, 1 = errors found and fixed, 2 = cleanup/errors (not fixed in read-only mode), 3 = could not check / errors could not be fixed.
    param([string]$Text, $ExitCode)
    $r = @{ Status = 'Unknown'; Summary = ''; Recommendation = ''; Reboot = $false }
    switch ($ExitCode) {
        0 { $r.Status = 'OK'; $r.Summary = 'Online scan found no file system errors.' }
        1 { $r.Status = 'Warning'; $r.Summary = 'Errors were found and fixed by the online scan.'; $r.Recommendation = 'Re-run the scan to confirm.' }
        2 { $r.Status = 'Warning'; $r.Summary = 'The scan reported issues (read-only mode).'; $r.Recommendation = 'Review the output. If problems persist, schedule an offline chkdsk /f in a maintenance window (not automated by FSL Master).' }
        3 { $r.Status = 'Error'; $r.Summary = 'The scan found errors or could not complete.'; $r.Recommendation = 'Review the output. Schedule an offline chkdsk /f in a maintenance window and make sure a recent backup/snapshot exists (not automated by FSL Master).' }
        default { $r.Summary = "chkdsk finished with exit code $ExitCode. Review the output." }
    }
    [pscustomobject]$r
}

# ------------------------------------------------------------------ guarded cleanup engine
function Get-FslCleanupAllowedRoots {
    $roots = @()
    if ($env:windir) { $roots += (Join-Path $env:windir 'Temp'); $roots += (Join-Path $env:windir 'Minidump') }
    if ($env:ProgramData) { $roots += (Join-Path $env:ProgramData 'Microsoft\Windows\WER'); $roots += (Join-Path $env:ProgramData 'FSLogix\Logs') }
    $roots
}

function Test-FslCleanupPathAllowed {
    # A cleanup root must be one of (or inside) the whitelisted folders; drive roots, relative and traversal paths are rejected.
    param([string]$Path, [string[]]$AllowedRoots = (Get-FslCleanupAllowedRoots))
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '\.\.' -or -not [IO.Path]::IsPathRooted($Path)) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($full.Length -le 3) { return $false }
    foreach ($r in $AllowedRoots) {
        $rf = [IO.Path]::GetFullPath($r).TrimEnd('\')
        if ($full.Equals($rf, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($rf + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Remove-FslOldFiles {
    # Deletes (or, with -DryRun, only counts) files older than AgeDays. Never follows reparse points, skips files in use,
    # refuses paths outside the whitelist and stops on cancellation.
    param([string]$Root, [int]$AgeDays, [string]$Filter = '*', [switch]$DryRun, [string[]]$AllowedRoots = (Get-FslCleanupAllowedRoots), [hashtable]$Sync)
    $res = [ordered]@{ Root = $Root; Files = 0; Bytes = [int64]0; Skipped = 0; Errors = 0; DryRun = [bool]$DryRun; Blocked = $false; Cancelled = $false }
    if (-not (Test-FslCleanupPathAllowed -Path $Root -AllowedRoots $AllowedRoots)) { $res.Blocked = $true; return [pscustomobject]$res }
    if ($AgeDays -lt 1) { $AgeDays = 1 }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return [pscustomobject]$res }
    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    $dirs = New-Object System.Collections.Generic.List[string]
    while ($stack.Count -gt 0) {
        if ($Sync -and $Sync.Cancel) { $res.Cancelled = $true; break }
        $dir = $stack.Pop()
        $dirs.Add($dir)
        try { $di = New-Object IO.DirectoryInfo($dir); $subs = $di.GetDirectories(); $files = $di.GetFiles($Filter) } catch { $res.Errors++; continue }
        foreach ($s in $subs) { if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) } else { $res.Skipped++ } }
        foreach ($f in $files) {
            if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { $res.Skipped++; continue }
            if ($f.LastWriteTime -gt $cutoff) { continue }
            if ($DryRun) { $res.Files++; $res.Bytes += $f.Length; continue }
            try {
                if ($f.IsReadOnly) { $f.IsReadOnly = $false }
                $len = $f.Length
                [IO.File]::Delete($f.FullName)
                $res.Files++; $res.Bytes += $len
            } catch { $res.Skipped++ }   # in use or access denied: leave it alone
        }
    }
    if (-not $DryRun -and -not $res.Cancelled) {
        # remove empty sub-folders that are also older than the cutoff (deepest first); the root itself is kept
        foreach ($d in ($dirs | Sort-Object { $_.Length } -Descending)) {
            if ($d -eq $Root) { continue }
            try {
                $di = New-Object IO.DirectoryInfo($d)
                if ($di.LastWriteTime -lt $cutoff -and -not ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -and @($di.GetFileSystemInfos()).Count -eq 0) { $di.Delete() }
            } catch { }
        }
    }
    [pscustomobject]$res
}

# ------------------------------------------------------------------ preflight
function Get-FslMaintenancePreflight {
    # Returns Blockers (must be fixed), Warnings (shown, run allowed) and Info. Read-only.
    param([string[]]$TaskIds, [hashtable]$Options = @{})
    $catalog = @(Get-FslMaintenanceCatalog)
    $tasks = @($catalog | Where-Object { $TaskIds -contains $_.Id })
    $blockers = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $info = New-Object System.Collections.Generic.List[string]
    $changes = @($tasks | Where-Object { $_.Risk -ne 'None' })
    $repair = @($tasks | Where-Object { $_.Category -eq 'Repair' })
    $heavy = @($tasks | Where-Object { $_.Kind -eq 'Process' })
    if ($tasks.Count -eq 0) { $blockers.Add('No tasks selected.') }
    if (-not $Options.AllowNonElevated -and -not (Test-FslIsAdministrator)) { $blockers.Add('Administrator rights are required to run maintenance tasks.') }
    # another run?
    $m = $null
    try { $m = New-Object Threading.Mutex($false, 'Global\FSLMaster.Maintenance'); if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $blockers.Add('Another FSL Master maintenance run is already in progress on this host.') } } catch { } finally { if ($m) { $m.Dispose() } }
    # system drive space
    try {
        $sysDrive = $env:SystemDrive
        $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$sysDrive'" -ErrorAction Stop
        $freeGb = [math]::Round($d.FreeSpace / 1GB, 1)
        if ($changes.Count -gt 0 -and $freeGb -lt 1) { $blockers.Add("Only $freeGb GB free on $sysDrive; servicing tasks need free space. Free up space first.") }
        elseif (($repair.Count -gt 0 -or @($tasks | Where-Object { $_.Id -eq 'clean.dism.component' }).Count -gt 0) -and $freeGb -lt 5) { $warnings.Add("Only $freeGb GB free on $sysDrive; DISM servicing may fail.") }
        else { $info.Add("$freeGb GB free on $sysDrive.") }
    } catch { $warnings.Add('Free space on the system drive could not be determined.') }
    # sessions
    try {
        $sess = @(Get-FslRawSessions | Where-Object { $_.User })
        if ($sess.Count -gt 0 -and ($heavy.Count -gt 0 -or $changes.Count -gt 0)) {
            $warnings.Add("$($sess.Count) user session(s) present. Tasks run at reduced priority, but consider putting the host in drain mode first.")
        } else { $info.Add("$($sess.Count) user session(s).") }
    } catch { }
    # pending reboot
    try {
        $pr = Get-FslPendingReboot
        if ($pr.Pending -and ($repair.Count -gt 0 -or @($tasks | Where-Object { $_.Id -in 'clean.dism.component', 'diag.sfc.verify' }).Count -gt 0)) {
            $warnings.Add('A reboot is pending (' + ($pr.Reasons -join '; ') + '). DISM/SFC results can be unreliable until the host is restarted.')
        }
    } catch { }
    # CPU load
    try {
        $cpu = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
        if ($cpu -gt 80 -and $heavy.Count -gt 0) { $warnings.Add("CPU load is high ($([math]::Round($cpu))%). Consider running maintenance later.") }
    } catch { }
    # servicing already busy
    try { if (Get-Process -Name 'TiWorker', 'TrustedInstaller' -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'TiWorker' }) { $warnings.Add('Windows servicing (TiWorker) is currently active - an update installation may be running.') } } catch { }
    if ($repair.Count -gt 0) { $warnings.Add('Repair tasks modify system files. Make sure you have a recent snapshot/backup and run them in a maintenance window.') }
    [pscustomobject]@{ Blockers = $blockers.ToArray(); Warnings = $warnings.ToArray(); Info = $info.ToArray(); Ok = ($blockers.Count -eq 0) }
}

# ------------------------------------------------------------------ best-practice scan
function Get-FslFolderSize {
    param([string]$Path, [int]$MaxSeconds = 20)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $total = [int64]0; $count = 0
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Path)
    while ($stack.Count -gt 0) {
        if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds) { return [pscustomobject]@{ Bytes = $total; Files = $count; Partial = $true } }
        $dir = $stack.Pop()
        try {
            $di = New-Object IO.DirectoryInfo($dir)
            foreach ($s in $di.GetDirectories()) { if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) } }
            foreach ($f in $di.GetFiles()) { $total += $f.Length; $count++ }
        } catch { }
    }
    [pscustomobject]@{ Bytes = $total; Files = $count; Partial = $false }
}

function Get-FslBestPracticeFindings {
    param([hashtable]$Config)
    $res = New-Object System.Collections.Generic.List[object]
    $cat = 'Best practice'
    $add = { param($chk, $st, $r, $ev, $rec) $res.Add((New-FslResult -Category $cat -Check $chk -Status $st -Result $r -Evidence $ev -Recommendation $rec)) }
    $warnPct = if ($Config -and $Config.LowDiskWarnPercent) { [double]$Config.LowDiskWarnPercent } else { 10 }
    $errPct = if ($Config -and $Config.LowDiskErrorPercent) { [double]$Config.LowDiskErrorPercent } else { 5 }
    foreach ($v in @(Get-FslLocalVolumes)) {
        if ($null -eq $v.FreePercent) { continue }
        $s = if ($v.FreePercent -lt $errPct) { 'Error' } elseif ($v.FreePercent -lt $warnPct) { 'Warning' } else { 'OK' }
        & $add "Free space $($v.Drive)" $s ('{0:N1}% free ({1} of {2})' -f $v.FreePercent, (Format-FslBytes $v.Free), (Format-FslBytes $v.Size)) 'Win32_LogicalDisk' $(if ($s -ne 'OK') { 'Free up disk space (run the Routine cleanup preset).' } else { '' })
    }
    foreach ($f in @(
            @{ N = 'Windows\Temp'; P = (Join-Path $env:windir 'Temp'); Warn = 2GB }
            @{ N = 'Windows Error Reporting'; P = (Join-Path $env:ProgramData 'Microsoft\Windows\WER'); Warn = 1GB }
            @{ N = 'FSLogix logs'; P = (Join-Path $env:ProgramData 'FSLogix\Logs'); Warn = 2GB }
            @{ N = 'Windows Update download cache'; P = (Join-Path $env:windir 'SoftwareDistribution\Download'); Warn = 10GB }
            @{ N = 'CBS logs'; P = (Join-Path $env:windir 'Logs\CBS'); Warn = 2GB })) {
        $sz = Get-FslFolderSize -Path $f.P -MaxSeconds 15
        if ($null -eq $sz) { continue }
        $s = if ($sz.Bytes -gt $f.Warn) { 'Warning' } else { 'OK' }
        & $add "Folder size: $($f.N)" $s "$(Format-FslBytes $sz.Bytes) in $($sz.Files) files$(if ($sz.Partial) { ' (partial scan)' })" $f.P $(if ($s -ne 'OK') { 'Consider the matching cleanup task or investigate why the folder grows.' } else { '' })
    }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $pf = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue)
        if ($cs.AutomaticManagedPagefile) { & $add 'Page file' 'OK' 'System managed' 'Win32_ComputerSystem' '' }
        elseif ($pf.Count -gt 0) { & $add 'Page file' 'OK' ("Custom page file: " + (($pf | ForEach-Object { "$($_.Name) ($($_.AllocatedBaseSize) MB)" }) -join ', ')) 'Win32_PageFileUsage' '' }
        else { & $add 'Page file' 'Warning' 'No page file configured' 'Win32_PageFileUsage' 'Session hosts normally need a page file (system managed is the safe default).' }
    } catch { & $add 'Page file' 'Unknown' 'Could not be determined' '' '' }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $days = ((Get-Date) - $os.LastBootUpTime).TotalDays
        $s = if ($days -gt 60) { 'Error' } elseif ($days -gt 30) { 'Warning' } else { 'OK' }
        & $add 'Uptime' $s ('{0:N0} days since last boot' -f $days) 'Win32_OperatingSystem' $(if ($s -ne 'OK') { 'Session hosts are typically restarted regularly (for example weekly) to apply updates and free resources.' } else { '' })
    } catch { }
    try {
        $pr = Get-FslPendingReboot
        & $add 'Pending reboot' $(if ($pr.Pending) { 'Warning' } else { 'OK' }) $(if ($pr.Pending) { $pr.Reasons -join '; ' } else { 'None' }) 'Registry' $(if ($pr.Pending) { 'Schedule a restart (use drain mode).' } else { '' })
    } catch { }
    # Defender + FSLogix exclusions
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $age = [int]$mp.AntivirusSignatureAge
        $s = if (-not $mp.RealTimeProtectionEnabled) { 'Warning' } elseif ($age -gt 7) { 'Warning' } else { 'OK' }
        & $add 'Microsoft Defender' $s "Real-time protection: $($mp.RealTimeProtectionEnabled); signatures $age day(s) old" 'Get-MpComputerStatus' $(if ($s -ne 'OK') { 'Enable real-time protection and update signatures (or confirm another AV product manages this host).' } else { '' })
        $fsl = Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'FSLogix\Apps')
        if ($fsl) {
            $pref = Get-MpPreference -ErrorAction Stop
            $ext = @($pref.ExclusionExtension | ForEach-Object { "$_".ToLowerInvariant().TrimStart('.') })
            $paths = @($pref.ExclusionPath | ForEach-Object { "$_" })
            $hasVhd = ($ext -contains 'vhd') -and ($ext -contains 'vhdx') -or (@($paths | Where-Object { $_ -match '(?i)\.vhdx?$' }).Count -ge 1)
            & $add 'Defender exclusions for FSLogix' $(if ($hasVhd) { 'OK' } else { 'Warning' }) $(if ($hasVhd) { 'VHD/VHDX exclusions present' } else { 'No VHD/VHDX exclusions found' }) 'Get-MpPreference' $(if ($hasVhd) { '' } else { 'Microsoft recommends excluding FSLogix VHD/VHDX containers and FSLogix processes/drivers from real-time scanning. Verify against the current Microsoft guidance and your security policy.' })
        }
    } catch { & $add 'Microsoft Defender' 'Unknown' 'Status not available (Defender not present or not readable)' '' '' }
    # stale local profiles (report only)
    try {
        $stale = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and -not $_.Loaded -and $_.LastUseTime -and $_.LastUseTime -lt (Get-Date).AddDays(-30) })
        $s = if ($stale.Count -gt 10) { 'Warning' } else { 'OK' }
        & $add 'Stale local profiles (> 30 days, not loaded)' $s "$($stale.Count) profile(s)" 'Win32_UserProfile (report only - nothing is deleted)' $(if ($s -ne 'OK') { 'With FSLogix these usually indicate profiles that were not cleaned up at sign-out. Consider the GPO "Delete user profiles older than a specified number of days" or FSLogix DeleteLocalProfileWhenVHDShouldApply.' } else { '' })
    } catch { }
    $res.ToArray()
}

function Format-FslFindingsText {
    param($Findings)
    (@($Findings) | ForEach-Object { '[{0}] {1}: {2}{3}' -f $_.StatusText, $_.Check, $_.Result, $(if ($_.Recommendation) { "`r`n        -> $($_.Recommendation)" } else { '' }) }) -join "`r`n"
}

# ------------------------------------------------------------------ single task execution
function Invoke-FslMaintenanceTask {
    param($Task, [hashtable]$Options = @{}, [hashtable]$Sync)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $dry = [bool]$Options.DryRun
    $cfg = if ($Options.Config) { $Options.Config } else { Get-FslDefaultConfig }
    $sys32 = Join-Path $env:windir 'System32'
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $mk = { param($st, $sum, $rec, $out, $code, $reboot) New-FslMaintResult -Task $Task -Status $st -Summary $sum -Recommendation $rec -Output $out -ExitCode $code -Seconds $sw.Elapsed.TotalSeconds -RebootRecommended ([bool]$reboot) }
    $skip = { param($what) New-FslMaintResult -Task $Task -Status 'NA' -Summary "Dry run: would $what" -Skipped $true -Seconds 0 }
    $runProc = {
        param($exe, $args2, $mode, $enc, $timeoutMin)
        $r = Invoke-FslProcess -FilePath (Join-Path $sys32 $exe) -Arguments $args2 -TimeoutSec ($timeoutMin * 60) -Encoding $enc -Sync $Sync
        if (-not $r.Started) { return @{ Res = (& $mk 'Error' "Could not start $exe : $($r.Error)" '' '' $null $false); Raw = $r } }
        if ($r.Cancelled) { return @{ Res = (& $mk 'Warning' 'Cancelled by the user.' 'Cancelling servicing tools mid-way is usually safe but a reboot is recommended before retrying.' $r.Output $r.ExitCode $true); Raw = $r } }
        if ($r.TimedOut) { return @{ Res = (& $mk 'Error' "Timed out after $timeoutMin minutes and was stopped." 'Retry in a quieter period; check disk performance.' $r.Output $r.ExitCode $false); Raw = $r } }
        @{ Res = $null; Raw = $r }
    }
    $fromParsed = { param($p, $raw) & $mk $p.Status $p.Summary $p.Recommendation $raw.Output $raw.ExitCode $p.Reboot }
    try {
        switch ($Task.Id) {
            'diag.bestpractice' {
                $f = @(Get-FslBestPracticeFindings -Config $cfg)
                $bad = @($f | Where-Object { $_.Status -eq 'Error' }).Count; $warn = @($f | Where-Object { $_.Status -eq 'Warning' }).Count
                $st = if ($bad) { 'Error' } elseif ($warn) { 'Warning' } else { 'OK' }
                return (& $mk $st "$($f.Count) checks: $bad error(s), $warn warning(s)." $(if ($st -ne 'OK') { 'See the findings below.' } else { '' }) (Format-FslFindingsText $f) $null $false)
            }
            'diag.disk.health' {
                $lines = New-Object System.Collections.Generic.List[string]; $worst = 'OK'
                try {
                    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
                        $lines.Add("Disk $($d.DeviceId) '$($d.FriendlyName)': health $($d.HealthStatus), status $($d.OperationalStatus)")
                        if ("$($d.HealthStatus)" -eq 'Unhealthy') { $worst = 'Error' } elseif ("$($d.HealthStatus)" -notin 'Healthy', '' -and $worst -ne 'Error') { $worst = 'Warning' }
                    }
                } catch { $lines.Add('Physical disk information not available.') }
                try {
                    foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter })) {
                        $lines.Add("Volume $($v.DriveLetter): health $($v.HealthStatus), $([math]::Round($v.SizeRemaining / 1GB, 1)) GB free of $([math]::Round($v.Size / 1GB, 1)) GB")
                        if ("$($v.HealthStatus)" -eq 'Unhealthy') { $worst = 'Error' } elseif ("$($v.HealthStatus)" -notin 'Healthy', '' -and $worst -ne 'Error') { $worst = 'Warning' }
                    }
                } catch { $lines.Add('Volume information not available.') }
                $txt = $lines -join "`r`n"
                return (& $mk $worst $(if ($worst -eq 'OK') { 'All disks and volumes report healthy.' } else { 'A disk or volume reports a problem.' }) $(if ($worst -ne 'OK') { 'Check the disk in the Azure portal / hypervisor and back up data.' } else { '' }) $txt $null $false)
            }
            'diag.dism.check' {
                $x = & $runProc 'dism.exe' '/Online /Cleanup-Image /CheckHealth /NoRestart' 'check' 'OEM' 10
                if ($x.Res) { return $x.Res }
                $p = ConvertFrom-FslDismOutput -Mode check -Text $x.Raw.Output -ExitCode $x.Raw.ExitCode
                if ($p.Status -eq 'Unknown' -and $x.Raw.ExitCode -eq 0) {   # locale fallback: ask the DISM API
                    try { $h = "$((Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState)"; $p.Status = switch ($h) { 'Healthy' { 'OK' } 'Repairable' { 'Warning' } 'NonRepairable' { 'Error' } default { 'Unknown' } }; $p.Summary = "ImageHealthState: $h"; if ($h -eq 'Repairable') { $p.Recommendation = 'Run DISM RestoreHealth (in a maintenance window), then SFC /scannow.' } } catch { }
                }
                return (& $fromParsed $p $x.Raw)
            }
            'diag.dism.scan' {
                $x = & $runProc 'dism.exe' '/Online /Cleanup-Image /ScanHealth /NoRestart' 'scan' 'OEM' 60
                if ($x.Res) { return $x.Res }
                return (& $fromParsed (ConvertFrom-FslDismOutput -Mode scan -Text $x.Raw.Output -ExitCode $x.Raw.ExitCode) $x.Raw)
            }
            'diag.dism.analyze' {
                $x = & $runProc 'dism.exe' '/Online /Cleanup-Image /AnalyzeComponentStore /NoRestart' 'analyze' 'OEM' 20
                if ($x.Res) { return $x.Res }
                return (& $fromParsed (ConvertFrom-FslDismOutput -Mode analyze -Text $x.Raw.Output -ExitCode $x.Raw.ExitCode) $x.Raw)
            }
            'diag.sfc.verify' {
                $x = & $runProc 'sfc.exe' '/verifyonly' 'verify' 'Unicode' 60
                if ($x.Res) { return $x.Res }
                return (& $fromParsed (ConvertFrom-FslSfcOutput -Mode verify -Text $x.Raw.Output -ExitCode $x.Raw.ExitCode) $x.Raw)
            }
            'diag.chkdsk.scan' {
                $x = & $runProc 'chkdsk.exe' "$sysDrive /scan" 'chkdsk' 'OEM' 120
                if ($x.Res) { return $x.Res }
                return (& $fromParsed (ConvertFrom-FslChkdskOutput -Text $x.Raw.Output -ExitCode $x.Raw.ExitCode) $x.Raw)
            }
            'repair.dism.restore' {
                if ($dry) { return (& $skip 'run dism /Online /Cleanup-Image /RestoreHealth') }
                $x = & $runProc 'dism.exe' '/Online /Cleanup-Image /RestoreHealth /NoRestart' 'restore' 'OEM' 90
                if ($x.Res) { return $x.Res }
                return (& $fromParsed (ConvertFrom-FslDismOutput -Mode restore -Text $x.Raw.Output -ExitCode $x.Raw.ExitCode) $x.Raw)
            }
            'repair.sfc.scannow' {
                if ($dry) { return (& $skip 'run sfc /scannow') }
                $x = & $runProc 'sfc.exe' '/scannow' 'scan' 'Unicode' 90
                if ($x.Res) { return $x.Res }
                return (& $fromParsed (ConvertFrom-FslSfcOutput -Mode scan -Text $x.Raw.Output -ExitCode $x.Raw.ExitCode) $x.Raw)
            }
            'clean.dism.component' {
                if ($dry) { return (& $skip 'run dism /Online /Cleanup-Image /StartComponentCleanup') }
                $x = & $runProc 'dism.exe' '/Online /Cleanup-Image /StartComponentCleanup /NoRestart' 'cleanup' 'OEM' 45
                if ($x.Res) { return $x.Res }
                return (& $fromParsed (ConvertFrom-FslDismOutput -Mode cleanup -Text $x.Raw.Output -ExitCode $x.Raw.ExitCode) $x.Raw)
            }
            { $_ -in 'clean.temp', 'clean.wer', 'clean.fslogixlogs', 'clean.dumps' } {
                $targets = switch ($Task.Id) {
                    'clean.temp' { @(@{ P = (Join-Path $env:windir 'Temp'); F = '*'; D = [int]$cfg.MaintTempAgeDays }) }
                    'clean.wer' { $w = Join-Path $env:ProgramData 'Microsoft\Windows\WER'; @(@{ P = (Join-Path $w 'ReportArchive'); F = '*'; D = [int]$cfg.MaintLogAgeDays }, @{ P = (Join-Path $w 'ReportQueue'); F = '*'; D = [int]$cfg.MaintLogAgeDays }, @{ P = (Join-Path $w 'Temp'); F = '*'; D = [int]$cfg.MaintLogAgeDays }) }
                    'clean.fslogixlogs' { @(@{ P = (Join-Path $env:ProgramData 'FSLogix\Logs'); F = '*.log'; D = [int]$cfg.MaintLogAgeDays }) }
                    'clean.dumps' { @(@{ P = (Join-Path $env:windir 'Minidump'); F = '*.dmp'; D = [int]$cfg.MaintDumpAgeDays }) }
                }
                $files = 0; $bytes = [int64]0; $lines = @(); $blocked = 0; $skipped = 0
                foreach ($t in $targets) {
                    $r = Remove-FslOldFiles -Root $t.P -AgeDays $t.D -Filter $t.F -DryRun:$dry -Sync $Sync
                    if ($r.Blocked) { $blocked++; $lines += "$($t.P): blocked by the path whitelist" ; continue }
                    $files += $r.Files; $bytes += $r.Bytes; $skipped += $r.Skipped
                    $lines += "$($t.P): $($r.Files) file(s), $(Format-FslBytes $r.Bytes) older than $($t.D) days$(if ($r.Skipped) { "; $($r.Skipped) skipped (in use/links)" })$(if ($r.Errors) { "; $($r.Errors) folder(s) unreadable (run as administrator)" })"
                }
                $verb = if ($dry) { 'would remove' } else { 'removed' }
                $st = if ($blocked -gt 0) { 'Error' } else { 'OK' }
                return (& $mk $st "$($(if ($dry) { 'Dry run: ' }))$verb $files file(s), $(Format-FslBytes $bytes)." '' ($lines -join "`r`n") $null $false)
            }
            'clean.dns' {
                if ($dry) { return (& $skip 'flush the DNS client cache') }
                Clear-DnsClientCache -ErrorAction Stop
                return (& $mk 'OK' 'DNS client cache flushed.' '' '' $null $false)
            }
            'opt.trim' {
                if ($dry) { return (& $skip "run Optimize-Volume -DriveLetter $($sysDrive.TrimEnd(':')) -ReTrim") }
                try { Optimize-Volume -DriveLetter $sysDrive.TrimEnd(':') -ReTrim -ErrorAction Stop | Out-Null; return (& $mk 'OK' 'ReTrim completed.' '' '' $null $false) }
                catch { return (& $mk 'NA' "Not supported or not needed: $($_.Exception.Message)" '' '' $null $false) }
            }
            default { return (& $mk 'Unknown' "Unknown task '$($Task.Id)'." '' '' $null $false) }
        }
    } catch {
        Write-FslLog -Level ERROR -Message "Maintenance task '$($Task.Id)' failed" -Exception $_
        return (& $mk 'Error' "Task failed: $($_.Exception.Message)" 'See the log file for details.' ($_ | Out-String) $null $false)
    }
}

# ------------------------------------------------------------------ run orchestration
function Get-FslMaintenanceReportDir {
    if ($env:FSLM_LOGDIR) { return $env:FSLM_LOGDIR }
    Join-Path $env:TEMP 'FSL-Master\Logs'
}

function Invoke-FslMaintenanceRun {
    # Runs the selected tasks in catalog order. Sync (synchronized hashtable) receives Index/Total/TaskName/TaskStart/Cancel.
    param([string[]]$TaskIds, [hashtable]$Options = @{}, [hashtable]$Sync)
    if (-not $Sync) { $Sync = [hashtable]::Synchronized(@{}) }
    $runId = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $started = Get-Date
    $catalog = @(Get-FslMaintenanceCatalog)
    $tasks = @($catalog | Where-Object { $TaskIds -contains $_.Id })
    $dry = [bool]$Options.DryRun
    Write-FslLog -Level ACTION -Message "Maintenance run $runId requested: $($tasks.Id -join ', ') (dry run: $dry)"
    $pre = Get-FslMaintenancePreflight -TaskIds $TaskIds -Options $Options
    $results = New-Object System.Collections.Generic.List[object]
    $aborted = $null
    $mutex = $null; $haveMutex = $false
    if (-not $pre.Ok) { $aborted = 'Preflight blocked the run: ' + ($pre.Blockers -join ' ') }
    else {
        try { $mutex = New-Object Threading.Mutex($false, 'Global\FSLMaster.Maintenance'); $haveMutex = $mutex.WaitOne(0) } catch { $haveMutex = $false }
        if (-not $haveMutex) { $aborted = 'Another maintenance run is already in progress.' }
    }
    if (-not $aborted) {
        try {
            $i = 0
            $stop = $false
            foreach ($t in $tasks) {
                $i++
                $Sync.Index = $i; $Sync.Total = $tasks.Count; $Sync.TaskName = $t.Name; $Sync.TaskStart = Get-Date
                if ($Sync.Cancel -or $stop) {
                    $results.Add((New-FslMaintResult -Task $t -Status 'NA' -Summary $(if ($Sync.Cancel) { 'Skipped (run cancelled).' } else { 'Skipped (stopped after an error).' }) -Skipped $true))
                    continue
                }
                Write-FslLog -Level ACTION -Message "Maintenance task started: $($t.Id) [$($t.Risk)]"
                $r = Invoke-FslMaintenanceTask -Task $t -Options $Options -Sync $Sync
                Write-FslLog -Level ACTION -Message "Maintenance task finished: $($t.Id) -> $($r.Status) in $($r.Duration): $($r.Summary)"
                $results.Add($r)
                if ($Options.StopOnError -and $r.Status -eq 'Error') { $stop = $true }
            }
        } finally { if ($haveMutex) { try { $mutex.ReleaseMutex() } catch { } }; if ($mutex) { $mutex.Dispose() } }
    }
    $arr = $results.ToArray()
    $run = [pscustomobject]@{
        RunId = $runId; Started = $started; Ended = (Get-Date); DryRun = $dry; Aborted = $aborted; Cancelled = [bool]$Sync.Cancel
        Computer = $env:COMPUTERNAME; Preflight = $pre; Results = $arr
        Errors = @($arr | Where-Object { $_.Status -eq 'Error' }).Count; Warnings = @($arr | Where-Object { $_.Status -eq 'Warning' }).Count
        Ok = @($arr | Where-Object { $_.Status -eq 'OK' }).Count
        RebootRecommended = [bool](@($arr | Where-Object { $_.RebootRecommended }).Count -gt 0)
        ReportPath = $null
    }
    try {
        $dir = Get-FslMaintenanceReportDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $path = Join-Path $dir "maintenance-$runId.json"
        $slim = $run | Select-Object * -ExcludeProperty ReportPath
        ($slim | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
        $run.ReportPath = $path
    } catch { Write-FslLog -Level WARN -Message 'Maintenance report could not be written.' -Exception $_ }
    Write-FslLog -Level ACTION -Message "Maintenance run $runId finished: $($run.Ok) ok, $($run.Warnings) warning(s), $($run.Errors) error(s)$(if ($aborted) { '; ' + $aborted })"
    $run
}

function Get-FslMaintenanceHistory {
    param([int]$Max = 20)
    $dir = Get-FslMaintenanceReportDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Filter 'maintenance-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $Max | ForEach-Object {
            try {
                $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                [pscustomobject]@{ Started = [datetime]$j.Started; RunId = $j.RunId; Tasks = @($j.Results).Count; Ok = $j.Ok; Warnings = $j.Warnings; Errors = $j.Errors; DryRun = [bool]$j.DryRun; Aborted = $j.Aborted; Path = $_.FullName }
            } catch { }
        })
}
