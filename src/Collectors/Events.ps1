# FSL Master - Windows event logs and FSLogix log files.

function Test-FslEventLogExists {
    param([string]$LogName)
    try { $null = Get-WinEvent -ListLog $LogName -ErrorAction Stop; return $true } catch { return $false }
}

function Test-FslBenignEventError {
    # Get-WinEvent throws these when a filter simply matches nothing: no events, no such provider, or a provider that does not
    # write to the queried log (LogsAndProvidersDontOverlap). Those mean "no FSLogix events here", not a failure.
    # The error id is language independent; the message texts are English fallbacks.
    param($ErrorRecord)
    $id = "$($ErrorRecord.FullyQualifiedErrorId)"
    $msg = "$($ErrorRecord.Exception.Message)"
    ($id -like '*NoMatchingEventsFound*' -or $id -like '*NoMatchingProvider*' -or $id -like '*DontOverlap*') -or
    ($msg -like '*No events were found*' -or $msg -like '*There is not an event provider*' -or $msg -like '*do not write events to any of the specified logs*')
}

function Get-FslEventUserName {
    param($Sid, [hashtable]$Cache)
    if (-not $Sid) { return '' }
    $s = $Sid.Value
    if ($Cache.ContainsKey($s)) { return $Cache[$s] }
    $n = $null
    try { $n = $Sid.Translate([Security.Principal.NTAccount]).Value } catch { }
    $Cache[$s] = if ($n) { $n } else { $s }
    $Cache[$s]
}

function ConvertTo-FslEventRow {
    param($Event, [int[]]$MarkedIds, [hashtable]$UserCache)
    $msg = $null
    try { $msg = $Event.Message } catch { }
    if ([string]::IsNullOrEmpty($msg)) {
        try { $msg = '(message not available) ' + (($Event.Properties | ForEach-Object { "$($_.Value)" }) -join ' | ') } catch { $msg = '(message not available)' }
    }
    $level = if ($Event.LevelDisplayName) { $Event.LevelDisplayName } else { switch ($Event.Level) { 1 { 'Critical' } 2 { 'Error' } 3 { 'Warning' } 4 { 'Information' } 5 { 'Verbose' } default { 'LogAlways' } } }
    $corr = ''
    try { if ($Event.ActivityId -and $Event.ActivityId -ne [guid]::Empty) { $corr = "$($Event.ActivityId)" } } catch { }
    $status = switch ([int]$Event.Level) { 1 { 'Error' } 2 { 'Error' } 3 { 'Warning' } default { 'OK' } }
    $summary = ($msg -split "\r?\n")[0]
    if ($summary.Length -gt 220) { $summary = $summary.Substring(0, 220) + '...' }
    [pscustomobject]@{
        Time = $Event.TimeCreated; LogName = $Event.LogName; Provider = $Event.ProviderName; EventId = [int]$Event.Id
        Level = $level; LevelNumber = [int]$Event.Level; User = (Get-FslEventUserName -Sid $Event.UserId -Cache $UserCache)
        Summary = $summary; Message = $msg; Correlation = $corr; Marked = [bool]($MarkedIds -contains [int]$Event.Id)
        MarkedText = $(if ($MarkedIds -contains [int]$Event.Id) { 'Yes' } else { '' })
        Status = $status; StatusText = (Get-FslStatusText $status); Glyph = (Get-FslStatusGlyph $status)
    }
}

function Get-FslEvents {
    param([datetime]$StartTime = (Get-Date).AddHours(-24), [int]$MaxEvents = 2000, [int[]]$MarkedIds = @(25, 26, 27, 28, 57, 58, 59, 60))
    $rows = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $present = New-Object System.Collections.Generic.List[string]
    $userCache = @{}
    $specs = @(
        @{ Log = 'Microsoft-FSLogix-Apps/Operational'; Filter = $null }
        @{ Log = 'Microsoft-FSLogix-Apps/Admin'; Filter = $null }
        @{ Log = 'Application'; Filter = 'FSLogix|frx' }
        @{ Log = 'System'; Filter = 'FSLogix|frx' }
    )
    foreach ($spec in $specs) {
        $log = $spec.Log
        if (-not (Test-FslEventLogExists -LogName $log)) { $missing.Add($log); continue }
        $present.Add($log)
        try {
            $events = @()
            if ($spec.Filter) {
                # Application/System are large: filter on provider name first (cheap). A pattern without any matching provider is not an error.
                foreach ($pattern in '*FSLogix*', 'frx*') {
                    try { $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $StartTime; ProviderName = $pattern } -MaxEvents $MaxEvents -ErrorAction Stop) }
                    catch {
                        if (Test-FslBenignEventError $_) { continue }
                        throw
                    }
                }
                if ($log -eq 'System') {
                    try {
                        $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $StartTime; ProviderName = 'Service Control Manager'; Level = 1, 2, 3 } -MaxEvents $MaxEvents -ErrorAction Stop |
                                Where-Object { $_.Message -match $spec.Filter })
                    } catch {
                        if (-not (Test-FslBenignEventError $_)) { throw }
                    }
                }
            } else {
                $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $StartTime } -MaxEvents $MaxEvents -ErrorAction Stop)
            }
            foreach ($e in $events) { $rows.Add((ConvertTo-FslEventRow -Event $e -MarkedIds $MarkedIds -UserCache $userCache)) }
        } catch {
            $fq = "$($_.FullyQualifiedErrorId)"
            if (Test-FslBenignEventError $_) { continue }
            if ($fq -like '*NoMatchingLogsFound*') { $missing.Add($log); $null = $present.Remove($log); continue }
            $errors.Add("${log}: $($_.Exception.Message)")
        }
    }
    $sorted = @($rows | Sort-Object Time -Descending)
    $fslErrors = @($sorted | Where-Object { $_.LevelNumber -le 2 -and $_.LevelNumber -ge 1 -and ($_.LogName -like '*FSLogix*' -or $_.Provider -match 'FSLogix|frx') }).Count
    $fslWarnings = @($sorted | Where-Object { $_.LevelNumber -eq 3 -and ($_.LogName -like '*FSLogix*' -or $_.Provider -match 'FSLogix|frx') }).Count
    [pscustomobject]@{
        Rows = $sorted; MissingLogs = @($missing); PresentLogs = @($present); Errors = @($errors)
        ErrorCount = $fslErrors; WarningCount = $fslWarnings; Start = $StartTime
    }
}

# ------------------------------------------------------------------ FSLogix log files
function Get-FslLogFolders {
    $base = Join-Path $env:ProgramData 'FSLogix\Logs'
    foreach ($n in 'Profile', 'ODFC', 'CloudCache') { [pscustomobject]@{ Name = $n; Path = (Join-Path $base $n); Exists = (Test-Path -LiteralPath (Join-Path $base $n)) } }
}

function Get-FslLogFiles {
    param([string]$BasePath)
    $rows = @()
    $folders = if ($BasePath) { foreach ($n in 'Profile', 'ODFC', 'CloudCache') { [pscustomobject]@{ Name = $n; Path = (Join-Path $BasePath $n); Exists = (Test-Path -LiteralPath (Join-Path $BasePath $n)) } } } else { Get-FslLogFolders }
    foreach ($f in $folders) {
        if (-not $f.Exists) { continue }
        try {
            $rows += Get-ChildItem -LiteralPath $f.Path -File -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ Folder = $f.Name; Name = $_.Name; Path = $_.FullName; SizeBytes = [int64]$_.Length; SizeText = (Format-FslBytes $_.Length); Modified = $_.LastWriteTime }
            }
        } catch { }
    }
    @($rows | Sort-Object Modified -Descending)
}

function Get-FslLogLevel {
    param([string]$Line)
    if ($Line -match '\[(?i:error|fatal)[:\]]|\bERROR\b') { return 'ERROR' }
    if ($Line -match '\[(?i:warn)[a-z]*[:\]]|\bWARN(?:ING)?\b') { return 'WARN' }
    'INFO'
}

function Read-FslLogTail {
    # Reads at most MaxBytes from the end of the file without loading the whole file. Shared read (log may be in use).
    param([string]$Path, [int64]$MaxBytes = 1MB)
    $fs = $null
    try {
        $share = [IO.FileShare]([int][IO.FileShare]::ReadWrite + [int][IO.FileShare]::Delete)
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $len = $fs.Length
        $head = New-Object byte[] 4
        $n = $fs.Read($head, 0, 4)
        $enc = [Text.Encoding]::UTF8
        if ($n -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) { $enc = [Text.Encoding]::Unicode }
        elseif ($n -ge 2 -and $head[0] -eq 0xFE -and $head[1] -eq 0xFF) { $enc = [Text.Encoding]::BigEndianUnicode }
        $truncated = $false
        $start = 0
        if ($len -gt $MaxBytes) { $start = $len - $MaxBytes; if ($enc -ne [Text.Encoding]::UTF8) { $start = $start - ($start % 2) }; $truncated = $true }
        $fs.Seek($start, [IO.SeekOrigin]::Begin) | Out-Null
        $sr = New-Object IO.StreamReader($fs, $enc, $true)
        $text = $sr.ReadToEnd()
        $lines = $text -split "\r?\n"
        if ($truncated -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }
        [pscustomobject]@{ Lines = @($lines | Where-Object { $_ -ne '' }); Truncated = $truncated; FileBytes = $len; ReadBytes = ($len - $start); Error = $null }
    } catch {
        [pscustomobject]@{ Lines = @(); Truncated = $false; FileBytes = 0; ReadBytes = 0; Error = $_.Exception.Message }
    } finally { if ($fs) { $fs.Dispose() } }
}

function Select-FslLogLines {
    param([string[]]$Lines, [string]$Search, [string]$User, [string[]]$Levels = @('ERROR', 'WARN', 'INFO'), [int]$MaxLines = 20000)
    $out = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($l in $Lines) {
        $n++
        $lvl = Get-FslLogLevel $l
        if ($Levels -notcontains $lvl) { continue }
        if ($Search -and $l.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($User -and $l.IndexOf($User, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $out.Add([pscustomobject]@{ Number = $n; Level = $lvl; Text = $l })
    }
    if ($out.Count -gt $MaxLines) { return $out.GetRange($out.Count - $MaxLines, $MaxLines).ToArray() }
    $out.ToArray()
}
