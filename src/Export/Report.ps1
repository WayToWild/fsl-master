# FSL Master - sanitizing, report data model and exports (JSON, CSV, HTML, TXT).

# ------------------------------------------------------------------ sanitizing
function New-FslSanitizeContext {
    # Collects sensitive tokens from a snapshot and assigns stable placeholders.
    param($Snapshot)
    $ctx = @{ Users = @{}; Domains = @{}; Servers = @{}; Sids = @{}; Hosts = @{}; Shares = @{}; Counters = @{ User = 0; Domain = 0; Server = 0; Sid = 0; Host = 0; Share = 0 } }
    $addUser = { param($n) if ($n -and $n.Length -ge 2 -and -not $ctx.Users.ContainsKey($n.ToLowerInvariant())) { $ctx.Counters.User++; $ctx.Users[$n.ToLowerInvariant()] = ('User{0:D2}' -f $ctx.Counters.User) } }
    $addDomain = { param($n) if ($n -and $n.Length -ge 2 -and -not $ctx.Domains.ContainsKey($n.ToLowerInvariant())) { $ctx.Counters.Domain++; $ctx.Domains[$n.ToLowerInvariant()] = ('DOMAIN{0:D2}' -f $ctx.Counters.Domain) } }
    $addServer = { param($n) if ($n -and -not $ctx.Servers.ContainsKey($n.ToLowerInvariant())) { $ctx.Counters.Server++; $ctx.Servers[$n.ToLowerInvariant()] = ('SERVER{0:D2}' -f $ctx.Counters.Server) } }
    $addHost = { param($n) if ($n -and $n.Length -ge 2 -and -not $ctx.Hosts.ContainsKey($n.ToLowerInvariant())) { $ctx.Counters.Host++; $ctx.Hosts[$n.ToLowerInvariant()] = ('HOST{0:D2}' -f $ctx.Counters.Host) } }
    $addAccount = { param($acct) if ($acct) { $parts = "$acct" -split '\\'; if ($parts.Count -gt 1) { & $addDomain $parts[0]; & $addUser $parts[-1] } else { & $addUser $parts[0] } } }
    if ($Snapshot.System) { & $addHost $Snapshot.System.ComputerName; & $addDomain $Snapshot.System.Domain }
    foreach ($s in @($Snapshot.Sessions)) { & $addUser $s.User; & $addDomain $s.Domain; if ($s.Sid) { if (-not $ctx.Sids.ContainsKey($s.Sid)) { $ctx.Counters.Sid++; $ctx.Sids[$s.Sid] = ('SID-{0:D2}' -f $ctx.Counters.Sid) } } }
    if ($Snapshot.Containers) {
        foreach ($c in @($Snapshot.Containers.Rows)) {
            & $addAccount $c.User
            if ($c.FileServer) { & $addServer $c.FileServer }
            if ($c.Sid -and -not $ctx.Sids.ContainsKey($c.Sid)) { $ctx.Counters.Sid++; $ctx.Sids[$c.Sid] = ('SID-{0:D2}' -f $ctx.Counters.Sid) }
        }
        foreach ($p in @($Snapshot.Containers.LocalProfiles)) { & $addAccount $p.User; if ($p.Sid -and -not $ctx.Sids.ContainsKey($p.Sid)) { $ctx.Counters.Sid++; $ctx.Sids[$p.Sid] = ('SID-{0:D2}' -f $ctx.Counters.Sid) } }
        foreach ($m in @($Snapshot.Containers.Smb)) { & $addServer $m.Server; & $addAccount $m.UserName }
    }
    if ($Snapshot.Config) {
        foreach ($r in @($Snapshot.Config.Rows)) { foreach ($u in [regex]::Matches((Format-FslValue $r.Value), '\\\\([^\\;,\s"]+)\\')) { & $addServer $u.Groups[1].Value } }
        foreach ($g in @($Snapshot.Config.Groups)) { foreach ($m in @($g.Members)) { & $addAccount $m } }
    }
    if ($Snapshot.Events) { foreach ($e in @($Snapshot.Events.Rows | Select-Object -First 500)) { if ($e.User -and $e.User -notmatch '^S-1-' ) { & $addAccount $e.User } } }
    $ctx
}

function Protect-FslText {
    param([string]$Text, $Context)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    # UNC paths: \\server\share -> \\SERVERnn\SHAREnn
    $t = [regex]::Replace($t, '\\\\([^\\;,\s"|]+)\\([^\\;,\s"|]+)', {
            param($m)
            $srv = $m.Groups[1].Value.ToLowerInvariant(); $shr = $m.Groups[2].Value.ToLowerInvariant()
            if (-not $Context.Servers.ContainsKey($srv)) { $Context.Counters.Server++; $Context.Servers[$srv] = ('SERVER{0:D2}' -f $Context.Counters.Server) }
            if (-not $Context.Shares.ContainsKey($shr)) { $Context.Counters.Share++; $Context.Shares[$shr] = ('SHARE{0:D2}' -f $Context.Counters.Share) }
            '\\' + $Context.Servers[$srv] + '\' + $Context.Shares[$shr]
        })
    $t = [regex]::Replace($t, 'S-1-\d+(?:-\d+){2,}', {
            param($m)
            if (-not $Context.Sids.ContainsKey($m.Value)) { $Context.Counters.Sid++; $Context.Sids[$m.Value] = ('SID-{0:D2}' -f $Context.Counters.Sid) }
            $Context.Sids[$m.Value]
        })
    foreach ($map in $Context.Servers, $Context.Hosts, $Context.Domains, $Context.Users) {
        foreach ($k in ($map.Keys | Sort-Object { $_.Length } -Descending)) {
            $t = [regex]::Replace($t, '(?<![A-Za-z0-9])' + [regex]::Escape($k) + '(?![A-Za-z0-9])', $map[$k], 'IgnoreCase')
        }
    }
    $t
}

function ConvertTo-FslSanitizedObject {
    param($Object, $Context)
    if ($null -eq $Object) { return $null }
    if ($Object -is [string]) { return (Protect-FslText -Text $Object -Context $Context) }
    if ($Object -is [datetime] -or $Object -is [ValueType]) { return $Object }
    if ($Object -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $Object.Keys) { $h[$k] = ConvertTo-FslSanitizedObject -Object $Object[$k] -Context $Context }
        return $h
    }
    if ($Object -is [System.Collections.IEnumerable]) { return @(foreach ($i in $Object) { ConvertTo-FslSanitizedObject -Object $i -Context $Context }) }
    $o = [ordered]@{}
    foreach ($p in $Object.PSObject.Properties) { $o[$p.Name] = ConvertTo-FslSanitizedObject -Object $p.Value -Context $Context }
    [pscustomobject]$o
}

# ------------------------------------------------------------------ report model
function Get-FslRecommendations {
    param($Health)
    @($Health | Where-Object { $_.Status -in 'Error', 'Warning' -and $_.Recommendation } | Sort-Object @{ e = { if ($_.Status -eq 'Error') { 0 } else { 1 } } } |
            ForEach-Object { $_.Recommendation } | Select-Object -Unique)
}

function Get-FslReportData {
    param($Snapshot, [switch]$Sanitized)
    $app = Get-FslAppInfo
    $sys = $Snapshot.System
    $data = [ordered]@{
        Meta = [pscustomobject]@{ Application = $app.Name; Version = $app.Version; Generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Sanitized = [bool]$Sanitized; PeriodHours = $Snapshot.LookbackHours }
        Host = if ($sys) { [pscustomobject]@{ ComputerName = $sys.ComputerName; Domain = $sys.Domain; Uptime = $sys.UptimeText; LastBoot = $sys.LastBoot.ToString('yyyy-MM-dd HH:mm:ss'); PendingReboot = $sys.PendingReboot } } else { $null }
        Windows = if ($sys) { [pscustomobject]@{ Product = $sys.ProductName; Version = $sys.DisplayVersion; Build = $sys.BuildFull; LastUpdate = $sys.LastUpdateTitle; LastUpdateDate = $(if ($sys.LastUpdateDate) { $sys.LastUpdateDate.ToString('yyyy-MM-dd') } else { '' }); AvdAgent = $sys.Avd.AgentVersion; AvdBootLoader = $sys.Avd.BootLoaderVersion } } else { $null }
        FSLogix = if ($Snapshot.Install) { [pscustomobject]@{ Installed = $Snapshot.Install.Installed; Version = $Snapshot.Install.Version; InstallDir = $Snapshot.Install.InstallDir; Frx = $Snapshot.Install.FrxPath } } else { $null }
        Services = @(ConvertTo-FslPlainRows -Rows $Snapshot.Services -Properties 'Kind', 'Name', 'State', 'StartMode', 'Version', 'StatusText', 'Note')
        Configuration = @(ConvertTo-FslPlainRows -Rows $(if ($Snapshot.Config) { $Snapshot.Config.Rows } else { @() }) -Properties 'Scope', 'Name', 'Value', 'Source', 'Default', 'StatusText', 'Assessment', 'RegistryPath')
        Sessions = @(ConvertTo-FslPlainRows -Rows $Snapshot.Sessions -Properties 'User', 'Domain', 'Sid', 'SessionId', 'State', 'LogonTime', 'IdleText', 'ProfilePath', 'ContainerMounted', 'ContainerPath', 'VhdFile', 'ContainerStatus')
        Containers = @(ConvertTo-FslPlainRows -Rows $(if ($Snapshot.Containers) { $Snapshot.Containers.Rows } else { @() }) -Properties 'User', 'Sid', 'SessionId', 'RedirectType', 'ContainerPath', 'VhdFile', 'FileServer', 'Share', 'SizeText', 'LastWrite', 'Volume', 'StatusText', 'Warnings')
        Events = @(ConvertTo-FslPlainRows -Rows @($(if ($Snapshot.Events) { $Snapshot.Events.Rows | Where-Object { $_.LevelNumber -le 3 -or $_.Marked } | Select-Object -First 200 })) -Properties 'Time', 'LogName', 'Provider', 'EventId', 'Level', 'User', 'Summary')
        Health = @(ConvertTo-FslPlainRows -Rows $Snapshot.Health -Properties 'Category', 'Check', 'StatusText', 'Result', 'Evidence', 'Recommendation', 'Time')
        Score = if ($Snapshot.Score) { [pscustomobject]@{ Score = $(if ($null -ne $Snapshot.Score.Score) { $Snapshot.Score.Score } else { 'Unknown' }); Status = (Get-FslStatusText $Snapshot.Score.Status); Scored = $Snapshot.Score.Scored; Unknown = $Snapshot.Score.Unknown; Errors = $Snapshot.Score.Errors; Warnings = $Snapshot.Score.Warnings; CoveragePercent = $Snapshot.Score.Coverage } } else { $null }
        Recommendations = @(Get-FslRecommendations -Health $Snapshot.Health)
    }
    if ($Sanitized) {
        $ctx = New-FslSanitizeContext -Snapshot $Snapshot
        $data = ConvertTo-FslSanitizedObject -Object $data -Context $ctx
    }
    $data
}

# ------------------------------------------------------------------ writers
function Write-FslFileUtf8 {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($true)))
}

function ConvertTo-FslHtmlTable {
    param($Rows, [string[]]$Columns)
    $rowsArr = @($Rows | Where-Object { $null -ne $_ })
    if ($rowsArr.Count -eq 0) { return '<p class="muted">No data.</p>' }
    if (-not $Columns) { $Columns = $rowsArr[0].PSObject.Properties.Name }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $Columns) { [void]$sb.Append('<th>' + (ConvertTo-FslHtmlEncoded $c) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $rowsArr) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columns) {
            $v = Format-FslValue $r.$c
            $cls = ''
            if ($c -in 'StatusText', 'Status', 'ContainerStatus') {
                $cls = switch -Wildcard ($v) { 'Healthy' { ' class="ok"' } 'Warning' { ' class="warn"' } 'Error' { ' class="err"' } default { ' class="unk"' } }
                $glyph = switch ($v) { 'Healthy' { [string][char]0x2714 } 'Warning' { [string][char]0x26A0 } 'Error' { [string][char]0x2716 } default { '?' } }
                [void]$sb.Append("<td$cls>" + $glyph + ' ' + (ConvertTo-FslHtmlEncoded $v) + '</td>')
            } else { [void]$sb.Append('<td>' + (ConvertTo-FslHtmlEncoded $v) + '</td>') }
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    $sb.ToString()
}

function ConvertTo-FslHtmlDocument {
    param([string]$Title, [string]$Body)
    @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>$(ConvertTo-FslHtmlEncoded $Title)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b;background:#fff}
h1{font-size:22px;margin-bottom:2px}h2{font-size:16px;margin-top:28px;border-bottom:1px solid #ccc;padding-bottom:4px}
table{border-collapse:collapse;width:100%;font-size:12px;margin-top:8px}th{background:#f0f0f0;text-align:left}
th,td{border:1px solid #ddd;padding:4px 6px;vertical-align:top;word-break:break-word}
.muted{color:#666}.ok{background:#e3f4e4;color:#1b5e20}.warn{background:#fff0dc;color:#8a4500}.err{background:#fde3e3;color:#b71c1c}.unk{background:#eee;color:#444}
.score{font-size:32px;font-weight:600}
</style></head><body>
$Body
</body></html>
"@
}

function ConvertTo-FslReportHtml {
    param($Data)
    $sb = New-Object Text.StringBuilder
    $m = $Data.Meta
    [void]$sb.Append("<h1>FSL Master - report</h1><p class=`"muted`">Local FSLogix diagnostics and monitoring for Azure Virtual Desktop &middot; version $(ConvertTo-FslHtmlEncoded $m.Version) &middot; generated on $(ConvertTo-FslHtmlEncoded $m.Generated)$(if ($m.Sanitized) { ' &middot; <strong>SANITIZED REPORT</strong>' })</p>")
    if ($Data.Score) {
        $s = $Data.Score
        [void]$sb.Append("<h2>Health score</h2><p><span class=`"score`">$(ConvertTo-FslHtmlEncoded $s.Score)</span> / 100 &mdash; $(ConvertTo-FslHtmlEncoded $s.Status) ($(ConvertTo-FslHtmlEncoded $s.Errors) error(s), $(ConvertTo-FslHtmlEncoded $s.Warnings) warning(s), $(ConvertTo-FslHtmlEncoded $s.Unknown) unknown; coverage $(ConvertTo-FslHtmlEncoded $s.CoveragePercent)%)</p>")
    }
    [void]$sb.Append('<h2>Host information</h2>' + (ConvertTo-FslHtmlTable -Rows @($Data.Host)))
    [void]$sb.Append('<h2>Windows and AVD</h2>' + (ConvertTo-FslHtmlTable -Rows @($Data.Windows)))
    [void]$sb.Append('<h2>FSLogix</h2>' + (ConvertTo-FslHtmlTable -Rows @($Data.FSLogix)))
    [void]$sb.Append('<h2>Services and components</h2>' + (ConvertTo-FslHtmlTable -Rows $Data.Services))
    [void]$sb.Append('<h2>Effective configuration</h2>' + (ConvertTo-FslHtmlTable -Rows $Data.Configuration))
    [void]$sb.Append('<h2>Users and sessions</h2>' + (ConvertTo-FslHtmlTable -Rows $Data.Sessions))
    [void]$sb.Append('<h2>Containers</h2>' + (ConvertTo-FslHtmlTable -Rows $Data.Containers))
    [void]$sb.Append("<h2>Recent relevant events (period: $(ConvertTo-FslHtmlEncoded $m.PeriodHours) hours)</h2>" + (ConvertTo-FslHtmlTable -Rows $Data.Events))
    [void]$sb.Append('<h2>Health check results</h2>' + (ConvertTo-FslHtmlTable -Rows $Data.Health))
    [void]$sb.Append('<h2>Technical recommendations</h2>')
    if (@($Data.Recommendations).Count -gt 0) { [void]$sb.Append('<ul>' + (($Data.Recommendations | ForEach-Object { '<li>' + (ConvertTo-FslHtmlEncoded $_) + '</li>' }) -join '') + '</ul>') }
    else { [void]$sb.Append('<p class="muted">No recommendations.</p>') }
    ConvertTo-FslHtmlDocument -Title 'FSL Master report' -Body $sb.ToString()
}

function ConvertTo-FslReportText {
    param($Data)
    $sb = New-Object Text.StringBuilder
    $line = '=' * 78
    $m = $Data.Meta
    [void]$sb.AppendLine("FSL Master - report (version $($m.Version))")
    [void]$sb.AppendLine("Generated on: $($m.Generated)$(if ($m.Sanitized) { '  [SANITIZED]' })")
    [void]$sb.AppendLine($line)
    if ($Data.Score) { [void]$sb.AppendLine("Health score: $($Data.Score.Score) / 100 - $($Data.Score.Status) (coverage $($Data.Score.CoveragePercent)%)") }
    $section = {
        param($title, $rows)
        [void]$sb.AppendLine(''); [void]$sb.AppendLine($title); [void]$sb.AppendLine('-' * $title.Length)
        $arr = @($rows)
        if ($arr.Count -eq 0 -or $null -eq $arr[0]) { [void]$sb.AppendLine('  (no data)') }
        foreach ($r in $arr) { if ($null -eq $r) { continue }; [void]$sb.AppendLine(('  ' + (($r.PSObject.Properties | ForEach-Object { "$($_.Name)=$(Format-FslValue $_.Value)" }) -join ' | '))) }
    }
    & $section 'Host' @($Data.Host)
    & $section 'Windows en AVD' @($Data.Windows)
    & $section 'FSLogix' @($Data.FSLogix)
    & $section 'Services' $Data.Services
    & $section 'Configuration' $Data.Configuration
    & $section 'Sessions' $Data.Sessions
    & $section 'Containers' $Data.Containers
    & $section 'Events' $Data.Events
    & $section 'Health checks' $Data.Health
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('Recommendations'); [void]$sb.AppendLine('-------------')
    foreach ($r in @($Data.Recommendations)) { [void]$sb.AppendLine("  * $r") }
    $sb.ToString()
}

function Export-FslRows {
    # Generic single-table export for page-level exports.
    param($Rows, [string[]]$Properties, [ValidateSet('csv', 'json', 'html')][string]$Format, [string]$Path, [string]$Title = 'FSL Master export')
    $v = Test-FslExportPath -Path $Path -AllowedExtensions @(".$Format")
    if (-not $v.Valid) { throw $v.Reason }
    $plain = @(ConvertTo-FslPlainRows -Rows $Rows -Properties $Properties)
    switch ($Format) {
        'csv' { $plain | Export-Csv -LiteralPath $v.Path -NoTypeInformation -Encoding UTF8 }
        'json' { Write-FslFileUtf8 -Path $v.Path -Content (ConvertTo-Json -InputObject $plain -Depth 4) }
        'html' { Write-FslFileUtf8 -Path $v.Path -Content (ConvertTo-FslHtmlDocument -Title $Title -Body ("<h1>$(ConvertTo-FslHtmlEncoded $Title)</h1><p class=`"muted`">Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>" + (ConvertTo-FslHtmlTable -Rows $plain))) }
    }
    Write-FslLog -Level ACTION -Message "Export ($Format) written: $($v.Path)"
    $v.Path
}

function Export-FslReport {
    param($Snapshot, [ValidateSet('html', 'json', 'csv', 'txt')][string]$Format, [string]$Path, [switch]$Sanitized)
    $v = Test-FslExportPath -Path $Path -AllowedExtensions @(".$Format")
    if (-not $v.Valid) { throw $v.Reason }
    $data = Get-FslReportData -Snapshot $Snapshot -Sanitized:$Sanitized
    $written = @()
    switch ($Format) {
        'html' { Write-FslFileUtf8 -Path $v.Path -Content (ConvertTo-FslReportHtml -Data $data); $written += $v.Path }
        'json' { Write-FslFileUtf8 -Path $v.Path -Content (ConvertTo-Json -InputObject $data -Depth 6); $written += $v.Path }
        'txt' { Write-FslFileUtf8 -Path $v.Path -Content (ConvertTo-FslReportText -Data $data); $written += $v.Path }
        'csv' {
            $base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($v.Path), [IO.Path]::GetFileNameWithoutExtension($v.Path))
            foreach ($sec in 'Services', 'Configuration', 'Sessions', 'Containers', 'Events', 'Health') {
                $rows = @($data[$sec])
                if ($rows.Count -eq 0 -or $null -eq $rows[0]) { continue }
                $f = "${base}_$sec.csv"
                $rows | Export-Csv -LiteralPath $f -NoTypeInformation -Encoding UTF8
                $written += $f
            }
        }
    }
    Write-FslLog -Level ACTION -Message "Report ($Format, sanitized=$([bool]$Sanitized)) written: $($written -join ', ')"
    $written
}
