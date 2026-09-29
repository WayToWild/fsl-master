# FSL Master - containers and redirects (frx list-redirects + registry + mounted VHD volumes + SMB connections).

function Invoke-FslFrx {
    # Runs frx.exe with a timeout. Returns @{ Ok; TimedOut; ExitCode; Output }
    param([string]$FrxPath, [string[]]$Arguments, [int]$TimeoutMs = 20000)
    if (-not $FrxPath -or -not (Test-Path -LiteralPath $FrxPath -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; TimedOut = $false; ExitCode = $null; Output = ''; Error = 'frx.exe niet gevonden.' }
    }
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $FrxPath
        $psi.Arguments = ($Arguments -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ Ok = $false; TimedOut = $true; ExitCode = $null; Output = ''; Error = 'Time-out' }
        }
        $null = $outTask.Wait(2000)
        $text = $outTask.Result
        if ([string]::IsNullOrWhiteSpace($text) -and $errTask.Wait(1000)) { $text = $errTask.Result }
        return [pscustomobject]@{ Ok = ($p.ExitCode -eq 0); TimedOut = $false; ExitCode = $p.ExitCode; Output = $text; Error = $null }
    } catch {
        return [pscustomobject]@{ Ok = $false; TimedOut = $false; ExitCode = $null; Output = ''; Error = $_.Exception.Message }
    }
}

function ConvertFrom-FslFrxRedirects {
    # Best-effort parser: records are recognised by SIDs, VHD(X) paths and redirect targets, so it does not depend
    # on one exact output layout. The raw output is always available in the UI for verification.
    param([string]$Text)
    $records = New-Object System.Collections.Generic.List[object]
    $cur = $null
    $flush = {
        if ($cur -and ($cur.Sid -or $cur.VhdPath -or $cur.Target)) { $records.Add([pscustomobject]$cur) }
    }
    $sidRx = 'S-1-\d+(?:-\d+){2,}'
    $vhdRx = '(?i)(\\\\[^\s"''<>|]+?\.vhdx?|[A-Za-z]:\\[^"''<>|\r\n]+?\.vhdx?)'
    foreach ($line in ($Text -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            & $flush; $cur = $null; continue
        }
        $sid = if ($line -match $sidRx) { $Matches[0] } else { $null }
        $vhd = if ($line -match $vhdRx) { $Matches[1] } else { $null }
        $target = $null
        if ($line -match '(?i)(?:->|=>)\s*(\S.*)$') { $target = $Matches[1].Trim() }
        elseif ($line -match '(?i)redirect(?:ed)?(?:\s+to)?\s*[:=]\s*(\S.*)$') { $target = $Matches[1].Trim() }
        $sess = if ($line -match '(?i)session(?:\s*id)?\s*[:=]?\s*(\d+)') { [int]$Matches[1] } else { $null }
        $type = if ($line -match '(?i)odfc|office') { 'ODFC' } elseif ($line -match '(?i)profile') { 'Profile' } else { $null }
        $vol = if ($line -match '(\\Device\\HarddiskVolume\d+\S*|\\\\\?\\Volume\{[0-9a-fA-F-]+\}\\?)') { $Matches[1] } else { $null }
        $hasData = $sid -or $vhd -or $target -or $vol -or $null -ne $sess
        if (-not $hasData -and -not $type) { continue }
        # a second SID or a second VHD path means a new record
        if ($cur -and (($sid -and $cur.Sid -and $sid -ne $cur.Sid) -or ($vhd -and $cur.VhdPath -and $vhd -ne $cur.VhdPath))) { & $flush; $cur = $null }
        if (-not $cur) { $cur = @{ Sid = $null; SessionId = $null; RedirectType = $null; VhdPath = $null; Target = $null; Volume = $null; Raw = (New-Object System.Collections.Generic.List[string]) } }
        if ($sid -and -not $cur.Sid) { $cur.Sid = $sid }
        if ($vhd -and -not $cur.VhdPath) { $cur.VhdPath = $vhd }
        if ($target -and -not $cur.Target) { $cur.Target = $target }
        if ($null -ne $sess -and $null -eq $cur.SessionId) { $cur.SessionId = $sess }
        if ($type -and -not $cur.RedirectType) { $cur.RedirectType = $type }
        if ($vol -and -not $cur.Volume) { $cur.Volume = $vol }
        $cur.Raw.Add($line.Trim())
    }
    & $flush
    foreach ($r in $records) { $r.Raw = ($r.Raw -join ' | ') }
    @($records | ForEach-Object { [pscustomobject]@{ Sid = $_.Sid; SessionId = $_.SessionId; RedirectType = $_.RedirectType; VhdPath = $_.VhdPath; Target = $_.Target; Volume = $_.Volume; Raw = $_.Raw } })
}

function Get-FslMountedVhdVolumes {
    # Volumes on file-backed virtual disks (this is how FSLogix mounts VHD/VHDX). Label is typically Profile-<user> / O365-<user>.
    $out = @()
    try {
        $disks = @(Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -eq 'File Backed Virtual' })
        foreach ($d in $disks) {
            $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)
            foreach ($p in $parts) {
                $v = $null
                try { $v = $p | Get-Volume -ErrorAction Stop } catch { }
                if (-not $v) { continue }
                $label = "$($v.FileSystemLabel)"
                $type = ''; $user = ''
                if ($label -match '^(?i)(Profile|O365|ODFC)[-_](.+)$') {
                    $type = if ($Matches[1] -match '(?i)profile') { 'Profile' } else { 'ODFC' }
                    $user = $Matches[2]
                }
                $out += [pscustomobject]@{
                    DiskNumber = $d.Number; Label = $label; DriveLetter = "$($v.DriveLetter)"; Path = "$($v.Path)"
                    Size = [int64]$v.Size; Free = [int64]$v.SizeRemaining; Health = "$($v.HealthStatus)"; Operational = "$($v.OperationalStatus)"
                    FileSystem = "$($v.FileSystem)"; DiskHealth = "$($d.HealthStatus)"; Type = $type; User = $user
                    Access = (@($p.AccessPaths) -join '; ')
                }
            }
        }
    } catch { }
    $out
}

function Get-FslSmbConnections {
    try {
        @(Get-SmbConnection -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Server = $_.ServerName; Share = $_.ShareName; UserName = $_.UserName; Dialect = "$($_.Dialect)"; NumOpens = $_.NumOpens; Encrypted = "$($_.Encrypted)" }
        })
    } catch { @() }
}

function Get-FslLocalProfileList {
    param($Profiles)
    foreach ($k in @($Profiles.Keys)) {
        $p = $Profiles[$k]
        $acct = Get-FslAccountForSid $p.Sid
        [pscustomobject]@{ Sid = $p.Sid; User = $acct; LocalPath = $p.LocalPath; Loaded = $(if ($null -ne $p.Loaded) { $(if ($p.Loaded) { 'Ja' } else { 'Nee' }) } else { '' }); Status = $p.Status; LastUse = $p.LastUse }
    }
}

function Get-FslContainers {
    param($Install, [int]$TimeoutMs = 3000, [hashtable]$Sync)
    $raw = ''
    $frxOk = $false
    $frxNote = ''
    $records = @()
    if ($Install -and $Install.FrxPath) {
        $res = Invoke-FslFrx -FrxPath $Install.FrxPath -Arguments @('list-redirects') -TimeoutMs 20000
        $raw = $res.Output
        if ($res.TimedOut) { $frxNote = 'frx.exe list-redirects: time-out.' }
        elseif ($res.Error) { $frxNote = "frx.exe: $($res.Error)" }
        else { $frxOk = $true; $records = @(ConvertFrom-FslFrxRedirects -Text $raw) }
    } else { $frxNote = 'frx.exe niet gevonden.' }

    $volumes = @(Get-FslMountedVhdVolumes)
    $smb = @(Get-FslSmbConnections)
    $profiles = Get-FslUserProfiles
    $localProfiles = @(Get-FslLocalProfileList -Profiles $profiles)

    # candidate containers: frx records, registry session keys, labelled volumes
    $cands = New-Object System.Collections.Generic.List[object]
    foreach ($r in $records) {
        $cands.Add([pscustomobject]@{ Sid = $r.Sid; SessionId = $r.SessionId; Type = $r.RedirectType; Vhd = $r.VhdPath; Target = $r.Target; Volume = $r.Volume; Source = 'frx list-redirects'; Details = $r.Raw })
    }
    foreach ($sid in (Get-FslRegistrySubKeyNames 'HKLM:\SOFTWARE\FSLogix\Profiles\Sessions')) {
        if ($sid -notmatch '^S-1-') { continue }
        $vals = @(Get-FslRegistryValues -Path "HKLM:\SOFTWARE\FSLogix\Profiles\Sessions\$sid")
        $vhd = $null
        foreach ($v in $vals) { if ("$($v.Value)" -match '(?i)\.vhdx?$') { $vhd = "$($v.Value)"; break } }
        $existing = $cands | Where-Object { $_.Sid -eq $sid -and (-not $vhd -or -not $_.Vhd -or $_.Vhd -eq $vhd) } | Select-Object -First 1
        $detail = (($vals | ForEach-Object { "$($_.Name)=$(Format-FslValue $_.Value)" }) -join '; ')
        if ($existing) { if (-not $existing.Vhd -and $vhd) { $existing.Vhd = $vhd }; continue }
        $cands.Add([pscustomobject]@{ Sid = $sid; SessionId = $null; Type = 'Profile'; Vhd = $vhd; Target = $null; Volume = $null; Source = 'Registry (Profiles\Sessions)'; Details = $detail })
    }

    $sidNames = @{}
    $usedVolumes = @{}
    $netCache = @{}
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cands) {
        $user = ''
        if ($c.Sid) {
            if (-not $sidNames.ContainsKey($c.Sid)) { $sidNames[$c.Sid] = Get-FslAccountForSid $c.Sid }
            $user = "$($sidNames[$c.Sid])"
        }
        $short = ($user -split '\\')[-1]
        $type = $c.Type
        # attach a mounted volume: label match on user (+ type when known)
        $vol = $null
        foreach ($v in $volumes) {
            if ($usedVolumes.ContainsKey($v.Path)) { continue }
            if ($v.User -and $short -and $v.User -ieq $short -and (-not $type -or -not $v.Type -or $v.Type -eq $type)) { $vol = $v; break }
        }
        if ($vol) { $usedVolumes[$vol.Path] = $true; if (-not $type) { $type = $vol.Type } }
        $rows.Add((New-FslContainerRow -Cand $c -User $user -Type $type -Volume $vol -Smb $smb -NetCache ([ref]$netCache) -TimeoutMs $TimeoutMs -SessionsUnknown $false))
    }
    foreach ($v in $volumes) {
        if ($usedVolumes.ContainsKey($v.Path) -or -not $v.User) { continue }
        $cand = [pscustomobject]@{ Sid = $null; SessionId = $null; Type = $v.Type; Vhd = $null; Target = $null; Volume = $v.Path; Source = 'Gekoppeld volume'; Details = "Label: $($v.Label)" }
        $rows.Add((New-FslContainerRow -Cand $cand -User $v.User -Type $v.Type -Volume $v -Smb $smb -NetCache ([ref]$netCache) -TimeoutMs $TimeoutMs -SessionsUnknown $false))
    }
    [pscustomobject]@{
        Rows = $rows.ToArray(); Volumes = $volumes; Smb = $smb; LocalProfiles = $localProfiles
        FrxOutput = $raw; FrxOk = $frxOk; FrxNote = $frxNote; DataAvailable = ($frxOk -or $rows.Count -gt 0 -or $volumes.Count -gt 0)
    }
}

function New-FslContainerRow {
    param($Cand, [string]$User, [string]$Type, $Volume, $Smb, [ref]$NetCache, [int]$TimeoutMs, [bool]$SessionsUnknown)
    $warnings = New-Object System.Collections.Generic.List[string]
    $status = 'OK'
    $path = if ($Cand.Vhd) { $Cand.Vhd } else { $Cand.Target }
    $vhdFile = $null; $dirPath = $null
    if ($Cand.Vhd) { $vhdFile = [IO.Path]::GetFileName($Cand.Vhd); $dirPath = [IO.Path]::GetDirectoryName($Cand.Vhd) }
    $unc = if ($Cand.Vhd) { Get-FslUncParts $Cand.Vhd } else { $null }
    $server = if ($unc) { $unc.Server } else { '' }
    $share = if ($unc) { $unc.Share } else { '' }
    $size = $null; $mod = $null; $net = 'n.v.t.'
    if ($unc) {
        $cache = $NetCache.Value
        if (-not $cache.ContainsKey($server)) { $cache[$server] = Test-FslTcpPort -ComputerName $server -Port 445 -TimeoutMs $TimeoutMs }
        $net = $cache[$server]
        if ($net -eq 'Timeout') { $warnings.Add("Time-out bij bereiken van $server (poort 445)."); $status = 'Warning'; $net = 'Time-out' }
        elseif ($net -ne 'Open') { $warnings.Add("$server niet bereikbaar op poort 445."); $status = 'Warning' }
        else {
            $r = Invoke-FslWithTimeout -TimeoutMs ($TimeoutMs + 2000) -ArgumentList @($Cand.Vhd) -ScriptBlock {
                param($p)
                if (Test-Path -LiteralPath $p -PathType Leaf) { $i = Get-Item -LiteralPath $p -Force; [pscustomobject]@{ Length = $i.Length; Modified = $i.LastWriteTime } } else { 'MISSING' }
            }
            if ($r.TimedOut) { $warnings.Add('Time-out bij lezen van containerbestand.'); $status = 'Warning'; $net = 'Time-out' }
            else {
                $v = $r.Result | Select-Object -First 1
                if ($v -is [string] -and $v -eq 'MISSING') { $warnings.Add('Containerbestand niet gevonden of geen toegang.') }
                elseif ($v) { $size = [int64]$v.Length; $mod = $v.Modified }
            }
        }
    } elseif ($Cand.Vhd) {
        if (Test-Path -LiteralPath $Cand.Vhd -PathType Leaf) { $i = Get-Item -LiteralPath $Cand.Vhd -Force; $size = $i.Length; $mod = $i.LastWriteTime }
    }
    $volText = ''; $health = ''
    if ($Volume) {
        $volText = if ($Volume.DriveLetter) { "$($Volume.DriveLetter): ($($Volume.Label))" } else { "$($Volume.Label) [$($Volume.Path)]" }
        $health = $Volume.Health
        if ($Volume.Health -and $Volume.Health -ne 'Healthy') { $warnings.Add("Volume health: $($Volume.Health)."); $status = 'Error' }
        if ($Volume.Size -gt 0) {
            $freePct = ($Volume.Free / $Volume.Size) * 100
            if ($freePct -lt 5) { $warnings.Add(('Container bijna vol ({0:N1}% vrij).' -f $freePct)); $status = 'Error' }
            elseif ($freePct -lt 10) { $warnings.Add(('Container raakt vol ({0:N1}% vrij).' -f $freePct)); if ($status -eq 'OK') { $status = 'Warning' } }
        }
    } else {
        if ($status -eq 'OK') { $status = 'Unknown' }
        $warnings.Add('Geen gekoppeld volume gevonden.')
    }
    if ($warnings.Count -gt 1 -or ($warnings.Count -eq 1 -and $warnings[0] -ne 'Geen gekoppeld volume gevonden.')) {
        if ($status -eq 'Unknown') { $status = 'Warning' }
    }
    [pscustomobject]@{
        User = $User; Sid = $Cand.Sid; SessionId = $Cand.SessionId; RedirectType = $Type; ContainerPath = $path; VhdFile = $vhdFile
        FileServer = $server; Share = $share; SizeBytes = $size; SizeText = $(if ($null -ne $size) { Format-FslBytes $size } else { '' })
        LastWrite = $mod; Volume = $volText; VolumeHealth = $health; Network = $net
        VolumeSizeText = $(if ($Volume) { (Format-FslBytes $Volume.Size) } else { '' }); VolumeFreeText = $(if ($Volume) { (Format-FslBytes $Volume.Free) } else { '' })
        Warnings = ($warnings -join ' '); Source = $Cand.Source; Details = $Cand.Details
        Status = $status; StatusText = (Get-FslStatusText $status); Glyph = (Get-FslStatusGlyph $status)
    }
}
