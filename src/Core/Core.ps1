# FSL Master - core helpers: constants, results, logging, configuration, timeouts, path/HTML helpers.
# NOTE: every function here (and in the collectors) may run inside a background runspace, so no function
# may depend on $script: variables. Runtime state is passed via parameters or process environment variables.

function Get-FslAppInfo {
    [pscustomobject]@{
        Name        = 'FSL Master'
        Description = 'Local FSLogix diagnostics and monitoring for Azure Virtual Desktop'
        Version     = '0.2.0'
        License     = 'MIT'
        RepoUrl     = 'https://github.com/WayToWild/fsl-master'
    }
}

function Get-FslStatusText {
    param([string]$Status)
    switch ($Status) {
        'OK'      { 'Healthy' }
        'Warning' { 'Warning' }
        'Error'   { 'Error' }
        'NA'      { 'N/A' }
        default   { 'Unknown' }
    }
}

function Get-FslStatusGlyph {
    param([string]$Status)
    switch ($Status) {
        'OK'      { [string][char]0x2714 }
        'Warning' { [string][char]0x26A0 }
        'Error'   { [string][char]0x2716 }
        'NA'      { [string][char]0x2013 }
        default   { '?' }
    }
}

function New-FslResult {
    param(
        [string]$Category,
        [string]$Check,
        [ValidateSet('OK', 'Warning', 'Error', 'Unknown', 'NA')][string]$Status,
        [string]$Result,
        [string]$Evidence,
        [string]$Recommendation = '',
        [double]$Weight = 1
    )
    [pscustomobject]@{
        Category       = $Category
        Check          = $Check
        Status         = $Status
        StatusText     = (Get-FslStatusText $Status)
        Glyph          = (Get-FslStatusGlyph $Status)
        Result         = $Result
        Evidence       = $Evidence
        Recommendation = $Recommendation
        Weight         = $Weight
        Time           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}

# ---------------------------------------------------------------- logging
function Initialize-FslLog {
    $candidates = @()
    if ($env:ProgramData) { $candidates += (Join-Path $env:ProgramData 'FSL-Master\Logs') }
    if ($env:TEMP) { $candidates += (Join-Path $env:TEMP 'FSL-Master\Logs') }
    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            $probe = Join-Path $dir ('.probe' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($probe, 'x')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $env:FSLM_LOGDIR = $dir
            return $dir
        } catch { }
    }
    $env:FSLM_LOGDIR = ''
    return $null
}

function Write-FslLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')][string]$Level = 'INFO',
        [string]$Message,
        $Exception
    )
    $dir = $env:FSLM_LOGDIR
    if ([string]::IsNullOrEmpty($dir)) { return }
    $text = '{0} [{1}] [t{2}] {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, [Threading.Thread]::CurrentThread.ManagedThreadId, $Message
    if ($Exception) { $text += [Environment]::NewLine + ($Exception | Out-String).TrimEnd() }
    $file = Join-Path $dir ('fsl-master-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
    for ($i = 0; $i -lt 3; $i++) {
        try { [IO.File]::AppendAllText($file, $text + [Environment]::NewLine, [Text.Encoding]::UTF8); return } catch { Start-Sleep -Milliseconds 30 }
    }
}

# ---------------------------------------------------------------- application folder and configuration
function Get-FslAppDir {
    if ($env:FSLM_APPDIR) { return $env:FSLM_APPDIR }
    return [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}

function Get-FslConfigCandidates {
    $c = @((Join-Path (Get-FslAppDir) 'fsl-master.config.json'))
    if ($env:ProgramData) { $c += (Join-Path $env:ProgramData 'FSL-Master\config.json') }
    $c
}

function Get-FslDefaultConfig {
    @{
        MarkedEventIds     = @(25, 26, 27, 28, 57, 58, 59, 60)
        EventIdNotes       = @{}
        LookbackHours      = 24
        MaxEvents          = 2000
        Theme              = 'Dark'
        AutoRefreshSeconds = 0
        LowDiskWarnPercent = 10
        LowDiskErrorPercent = 5
        NetworkTimeoutMs   = 3000
        MaintTempAgeDays   = 7
        MaintLogAgeDays    = 30
        MaintDumpAgeDays   = 30
        MaintDefaultDryRun = $true
        BuildLifecycle     = @()
    }
}

function Get-FslConfig {
    param([string[]]$Paths = (Get-FslConfigCandidates))
    $cfg = Get-FslDefaultConfig
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $json = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) {
                if ($cfg.ContainsKey($prop.Name) -and $prop.Name -ne 'EventIdNotes') { $cfg[$prop.Name] = $prop.Value }
                elseif ($prop.Name -eq 'EventIdNotes' -and $prop.Value) {
                    $notes = @{}; foreach ($n in $prop.Value.PSObject.Properties) { $notes[$n.Name] = [string]$n.Value }
                    $cfg.EventIdNotes = $notes
                }
            }
            break
        } catch { Write-FslLog -Level WARN -Message "Configuration file '$p' could not be read." -Exception $_ }
    }
    $ids = @()
    foreach ($i in @($cfg.MarkedEventIds)) { $n = 0; if ([int]::TryParse("$i", [ref]$n) -and $n -gt 0) { $ids += $n } }
    $cfg.MarkedEventIds = $ids
    foreach ($k in 'LookbackHours', 'MaxEvents', 'AutoRefreshSeconds', 'LowDiskWarnPercent', 'LowDiskErrorPercent', 'NetworkTimeoutMs', 'MaintTempAgeDays', 'MaintLogAgeDays', 'MaintDumpAgeDays') {
        $n = 0; if (-not [int]::TryParse("$($cfg[$k])", [ref]$n) -or $n -lt 0) { $cfg[$k] = (Get-FslDefaultConfig)[$k] } else { $cfg[$k] = $n }
    }
    foreach ($k in 'MaintTempAgeDays', 'MaintLogAgeDays', 'MaintDumpAgeDays') { if ($cfg[$k] -lt 1) { $cfg[$k] = (Get-FslDefaultConfig)[$k] } }   # never allow "delete everything now"
    $cfg.MaintDefaultDryRun = [bool]$cfg.MaintDefaultDryRun
    if ($cfg.LookbackHours -lt 1) { $cfg.LookbackHours = 24 }
    if ($cfg.MaxEvents -lt 100) { $cfg.MaxEvents = 100 }
    if ($cfg.MaxEvents -gt 20000) { $cfg.MaxEvents = 20000 }
    if ($cfg.Theme -notin 'Dark', 'Light') { $cfg.Theme = 'Dark' }
    $cfg
}

function Save-FslConfig {
    param([hashtable]$Config, [string[]]$Paths = (Get-FslConfigCandidates))
    foreach ($p in $Paths) {
        try {
            $dir = Split-Path -Parent $p
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $p -Encoding UTF8 -ErrorAction Stop
            return $p
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------- privileges
function Get-FslCurrentPrincipal {
    New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
}

function Test-FslIsAdministrator {
    try { return [bool](Get-FslCurrentPrincipal).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

# ---------------------------------------------------------------- formatting and encoding
function ConvertTo-FslHtmlEncoded {
    param($Value)
    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-FslBytes {
    param($Bytes)
    if ($null -eq $Bytes -or "$Bytes" -eq '') { return '' }
    $b = [double]$Bytes
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($b -ge 1024 -and $i -lt 4) { $b = $b / 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} {1}' -f $b, $units[$i]) }
    ('{0:N1} {1}' -f $b, $units[$i])
}

function Format-FslTimeSpan {
    param([timespan]$Span)
    if ($Span.TotalDays -ge 1) { return ('{0}d {1}h {2}m' -f [int]$Span.Days, $Span.Hours, $Span.Minutes) }
    ('{0}h {1}m' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes)
}

function Format-FslValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) { return (($Value | ForEach-Object { $_.ToString('X2') }) -join ' ') }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return (($Value | ForEach-Object { "$_" }) -join '; ') }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    "$Value"
}

# ---------------------------------------------------------------- timeouts (keep network probes from blocking)
function Invoke-FslWithTimeout {
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [int]$TimeoutMs = 5000)
    $ps = [powershell]::Create()
    $null = $ps.AddScript($ScriptBlock.ToString())
    foreach ($a in $ArgumentList) { $null = $ps.AddArgument($a) }
    $h = $ps.BeginInvoke()
    if ($h.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        try {
            $res = $ps.EndInvoke($h)
            $err = $ps.Streams.Error | Select-Object -First 1
            return [pscustomobject]@{ TimedOut = $false; Result = @($res); Error = $(if ($err) { $err.ToString() } else { $null }) }
        } catch {
            return [pscustomobject]@{ TimedOut = $false; Result = @(); Error = $_.Exception.Message }
        } finally { $ps.Dispose() }
    }
    try { $null = $ps.BeginStop($null, $null) } catch { }
    [pscustomobject]@{ TimedOut = $true; Result = @(); Error = 'Timeout' }
}

function Test-FslPathReachable {
    # Returns Reachable | NotFound | Timeout | Error
    param([string]$Path, [int]$TimeoutMs = 3000)
    $r = Invoke-FslWithTimeout -TimeoutMs $TimeoutMs -ArgumentList @($Path) -ScriptBlock {
        param($p)
        try { Test-Path -LiteralPath $p -ErrorAction Stop } catch { 'ERR:' + $_.Exception.Message }
    }
    if ($r.TimedOut) { return 'Timeout' }
    if ($r.Error) { return 'Error' }
    $v = $r.Result | Select-Object -First 1
    if ($v -is [string] -and $v.StartsWith('ERR:')) { return 'Error' }
    if ($v -eq $true) { return 'Reachable' }
    'NotFound'
}

function Test-FslTcpPort {
    param([string]$ComputerName, [int]$Port = 445, [int]$TimeoutMs = 3000)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return 'Timeout' }
        try { $client.EndConnect($iar); return 'Open' } catch { return 'Closed' }
    } catch { return 'Closed' } finally { $client.Close() }
}

function Resolve-FslDnsName {
    # Returns @{ Status = Resolved|Failed|Timeout; Addresses = @() }
    param([string]$Name, [int]$TimeoutMs = 3000)
    try {
        $ip = $null
        if ([Net.IPAddress]::TryParse($Name, [ref]$ip)) { return [pscustomobject]@{ Status = 'Resolved'; Addresses = @($ip.ToString()) } }
        $task = [Net.Dns]::GetHostAddressesAsync($Name)
        if (-not $task.Wait($TimeoutMs)) { return [pscustomobject]@{ Status = 'Timeout'; Addresses = @() } }
        [pscustomobject]@{ Status = 'Resolved'; Addresses = @($task.Result | ForEach-Object { $_.ToString() }) }
    } catch { [pscustomobject]@{ Status = 'Failed'; Addresses = @() } }
}

function Get-FslUncParts {
    param([string]$Path)
    if ($Path -match '^\\\\([^\\]+)\\([^\\]+)(?:\\(.*))?$') {
        return [pscustomobject]@{ Server = $Matches[1]; Share = $Matches[2]; Rest = $Matches[3]; Root = "\\$($Matches[1])\$($Matches[2])" }
    }
    $null
}

# ---------------------------------------------------------------- export path validation
function Test-FslExportPath {
    # Returns @{ Valid; Reason; Path }
    param([string]$Path, [string[]]$AllowedExtensions = @())
    $fail = { param($m) [pscustomobject]@{ Valid = $false; Reason = $m; Path = $Path } }
    if ([string]::IsNullOrWhiteSpace($Path)) { return (& $fail 'No path specified.') }
    if ($Path.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or $Path -match '[\*\?<>|"]') { return (& $fail 'The path contains invalid characters.') }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return (& $fail 'The path is not valid.') }
    if (-not [IO.Path]::IsPathRooted($Path)) { return (& $fail 'Use a full path.') }
    $name = [IO.Path]::GetFileName($full)
    if ([string]::IsNullOrEmpty($name)) { return (& $fail 'No file name specified.') }
    $win = $env:SystemRoot
    if ($win -and $full.StartsWith($win + '\', [StringComparison]::OrdinalIgnoreCase)) { return (& $fail 'Exporting to the Windows folder is not allowed.') }
    if ($AllowedExtensions.Count -gt 0) {
        $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
        if ($AllowedExtensions -notcontains $ext) { return (& $fail ("Extension '$ext' is not allowed (allowed: " + ($AllowedExtensions -join ', ') + ').')) }
    }
    $dir = [IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return (& $fail "The folder '$dir' does not exist.") }
    [pscustomobject]@{ Valid = $true; Reason = ''; Path = $full }
}

function ConvertTo-FslPlainRows {
    # Flattens rows to string-valued PSCustomObjects for CSV/HTML output.
    param($Rows, [string[]]$Properties)
    foreach ($r in @($Rows)) {
        $o = [ordered]@{}
        $props = if ($Properties) { $Properties } else { $r.PSObject.Properties.Name }
        foreach ($p in $props) { $o[$p] = Format-FslValue $r.$p }
        [pscustomobject]$o
    }
}
