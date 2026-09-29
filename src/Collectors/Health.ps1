# FSL Master - read-only health checks and score. Nothing in this file changes system state.

function Get-FslLocationsFromValue {
    # Extracts UNC paths from VHDLocations (multi-string / ';' separated) and CCDLocations (type=smb,connectionString=...).
    param($Value)
    $text = Format-FslValue $Value
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $found = [regex]::Matches($text, '\\\\[^\\;,\s"]+\\[^;,\s"]+(?:\\[^;,\s"]*)*')
    @($found | ForEach-Object { $_.Value.TrimEnd('\') } | Select-Object -Unique)
}

function Get-FslHealthScore {
    # Weighted score: OK = 1, Warning = 0.5, Error = 0. Unknown and NA are NOT scored (they are not counted as failures).
    param($Results, [bool]$FslogixInstalled = $true)
    $scored = @($Results | Where-Object { $_.Status -in 'OK', 'Warning', 'Error' })
    $total = @($Results | Where-Object { $_.Status -ne 'NA' }).Count
    $unknown = @($Results | Where-Object { $_.Status -eq 'Unknown' }).Count
    $errors = @($Results | Where-Object { $_.Status -eq 'Error' })
    $warns = @($Results | Where-Object { $_.Status -eq 'Warning' })
    if ($scored.Count -eq 0) {
        return [pscustomobject]@{ Score = $null; Status = 'Unknown'; Scored = 0; Total = $total; Unknown = $unknown; Errors = 0; Warnings = 0; Coverage = 0 }
    }
    $wSum = 0.0; $pSum = 0.0
    foreach ($r in $scored) {
        $w = if ($null -ne $r.Weight) { [double]$r.Weight } else { 1.0 }
        $p = switch ($r.Status) { 'OK' { 1.0 } 'Warning' { 0.5 } default { 0.0 } }
        $wSum += $w; $pSum += $w * $p
    }
    $score = [int][math]::Round(100 * $pSum / $wSum, 0, [MidpointRounding]::AwayFromZero)
    $coverage = if ($total -gt 0) { [math]::Round(100 * $scored.Count / $total) } else { 0 }
    $criticalError = @($errors | Where-Object { $_.Weight -ge 2 }).Count -gt 0
    $status = 'OK'
    if ($score -lt 60 -or $criticalError) { $status = 'Error' }
    elseif ($score -lt 90 -or $errors.Count -gt 0 -or $warns.Count -gt 0) { $status = 'Warning' }
    if ($coverage -lt 50 -or -not $FslogixInstalled) { $status = 'Unknown' }   # without FSLogix there is nothing FSLogix-specific to be healthy about
    [pscustomobject]@{ Score = $score; Status = $status; Scored = $scored.Count; Total = $total; Unknown = $unknown; Errors = $errors.Count; Warnings = $warns.Count; Coverage = $coverage }
}

function Get-FslHealthChecks {
    param($Data, [hashtable]$Config)
    $res = New-Object System.Collections.Generic.List[object]
    $add = { param($cat, $chk, $st, $r, $ev, $rec, $w) $res.Add((New-FslResult -Category $cat -Check $chk -Status $st -Result $r -Evidence $ev -Recommendation $rec -Weight $w)) }
    $timeout = if ($Config -and $Config.NetworkTimeoutMs) { [int]$Config.NetworkTimeoutMs } else { 3000 }
    $warnPct = if ($Config -and $Config.LowDiskWarnPercent) { [double]$Config.LowDiskWarnPercent } else { 10 }
    $errPct = if ($Config -and $Config.LowDiskErrorPercent) { [double]$Config.LowDiskErrorPercent } else { 5 }
    $inst = $Data.Install
    $cfg = $Data.Config
    $lookup = if ($cfg) { $cfg.Lookup } else { @{} }
    $installed = [bool]($inst -and $inst.Installed)
    $fsl = 'FSLogix'
    $val = { param($k) if ($lookup.ContainsKey($k) -and $lookup[$k].Source -ne 'NotConfigured') { $lookup[$k].Value } else { $null } }

    # ---- FSLogix
    if ($installed) { & $add $fsl 'FSLogix geïnstalleerd' 'OK' 'Ja' "Installatiemap: $($inst.InstallDir)" '' 2 }
    else { & $add $fsl 'FSLogix geïnstalleerd' 'NA' 'Niet geïnstalleerd' 'Geen FSLogix-map, service of product gevonden.' 'Installeer FSLogix Apps als deze host profielcontainers moet gebruiken.' 1 }
    if ($installed) {
        if ($inst.Version) { & $add $fsl 'FSLogix-versie beschikbaar' 'OK' "$($inst.Version)" 'Bestandsversie van frxsvc.exe / registry' '' 1 }
        else { & $add $fsl 'FSLogix-versie beschikbaar' 'Unknown' 'Versie niet vast te stellen' 'Geen bestandsversie of registrywaarde' 'Controleer de installatie handmatig.' 1 }
        $svc = @($Data.Services | Where-Object { $_.Kind -eq 'Service' -and $_.Name -eq 'frxsvc' }) | Select-Object -First 1
        if ($svc) { & $add $fsl 'Service frxsvc actief' $svc.Status "$($svc.State) (start: $($svc.StartMode))" 'Win32_Service' $(if ($svc.Status -ne 'OK') { 'Start de service frxsvc en controleer de startmodus (Automatic).' } else { '' }) 2 }
        else { & $add $fsl 'Service frxsvc actief' 'Unknown' 'Serviceinformatie niet beschikbaar' 'Win32_Service' '' 2 }
        $drv = @($Data.Services | Where-Object { $_.Kind -eq 'Driver' -and $_.Name -eq 'frxdrv' }) | Select-Object -First 1
        if ($drv) { & $add $fsl 'Driver frxdrv geladen' $drv.Status "$($drv.State)" 'Win32_SystemDriver' $(if ($drv.Status -ne 'OK') { 'Herstart de host of herstel de FSLogix-installatie.' } else { '' }) 1 }
    }
    $pe = & $val 'Profiles.Enabled'
    $peOn = ($null -ne $pe -and "$pe" -eq '1')
    if ($installed) {
        if ($peOn) { & $add $fsl 'Profile Containers ingeschakeld' 'OK' 'Enabled = 1' 'Registry (policy of lokaal)' '' 2 }
        elseif ($cfg) { & $add $fsl 'Profile Containers ingeschakeld' 'Warning' 'Niet ingeschakeld' 'Registry Profiles\Enabled' 'Zet Enabled op 1 (bij voorkeur via GPO) als profielcontainers gewenst zijn.' 2 }
        else { & $add $fsl 'Profile Containers ingeschakeld' 'Unknown' 'Configuratie niet gelezen' '' '' 2 }
    }
    $vhd = & $val 'Profiles.VHDLocations'; $ccd = & $val 'Profiles.CCDLocations'
    $hasLoc = (-not [string]::IsNullOrWhiteSpace((Format-FslValue $vhd))) -or (-not [string]::IsNullOrWhiteSpace((Format-FslValue $ccd)))
    if ($installed -and $peOn) {
        if ($hasLoc) { & $add $fsl 'Profielcontainerlocatie geconfigureerd' 'OK' $(if ($ccd) { 'Cloud Cache (CCDLocations)' } else { Format-FslValue $vhd }) 'Registry Profiles\VHDLocations / CCDLocations' '' 2 }
        else { & $add $fsl 'Profielcontainerlocatie geconfigureerd' 'Error' 'Geen VHDLocations of CCDLocations' 'Registry' 'Configureer VHDLocations of CCDLocations.' 2 }
    }
    $oe = & $val 'ODFC.Enabled'
    if ($installed) {
        if ($oe -and "$oe" -eq '1') {
            $ol = (& $val 'ODFC.VHDLocations'); $oc = (& $val 'ODFC.CCDLocations')
            if ($ol -or $oc) { & $add $fsl 'ODFC-configuratie' 'OK' 'Ingeschakeld met locatie' 'Registry ODFC' '' 1 } else { & $add $fsl 'ODFC-configuratie' 'Error' 'Ingeschakeld zonder locatie' 'Registry ODFC' 'Configureer ODFC VHDLocations of CCDLocations.' 1 }
        } else { & $add $fsl 'ODFC-configuratie' 'NA' 'ODFC niet ingeschakeld' 'Registry ODFC' '' 1 }
        if ($ccd) {
            $ccs = @($Data.Services | Where-Object { $_.Name -eq 'frxccds' }) | Select-Object -First 1
            & $add $fsl 'Cloud Cache-configuratie' $(if ($ccs -and $ccs.State -eq 'Running') { 'OK' } else { 'Error' }) "CCDLocations ingesteld; frxccds: $(if ($ccs) { $ccs.State } else { 'onbekend' })" 'Registry + Win32_Service' 'Start frxccds of controleer de Cloud Cache-configuratie.' 1
        } else { & $add $fsl 'Cloud Cache-configuratie' 'NA' 'Niet in gebruik' 'Registry' '' 1 }
    }
    # container mounts vs sessions
    if ($installed -and $peOn) {
        $sess = @($Data.Sessions | Where-Object { $_.User })
        if ($Data.Containers -and $Data.Containers.DataAvailable) {
            $missingMounts = @($sess | Where-Object { $_.ContainerMounted -eq 'Nee' })
            if ($sess.Count -eq 0) { & $add $fsl 'Containerkoppelingen' 'NA' 'Geen gebruikerssessies' 'WTS API' '' 1 }
            elseif ($missingMounts.Count -eq 0) { & $add $fsl 'Containerkoppelingen' 'OK' "Alle $($sess.Count) sessie(s) hebben een container" 'frx list-redirects / registry / volumes' '' 1 }
            else { & $add $fsl 'Containerkoppelingen' 'Warning' "$($missingMounts.Count) van $($sess.Count) sessie(s) zonder container: $((($missingMounts | ForEach-Object { $_.User }) -join ', '))" 'frx list-redirects / registry / volumes' 'Controleer de FSLogix-events en logs voor deze gebruikers.' 1 }
        } else { & $add $fsl 'Containerkoppelingen' 'Unknown' 'Geen containergegevens beschikbaar' 'frx list-redirects' 'Controleer of frx.exe werkt (admin).' 1 }
    }
    # events
    if ($installed) {
        if ($Data.Events -and $Data.Events.PresentLogs.Count -gt 0) {
            $e = $Data.Events.ErrorCount; $w = $Data.Events.WarningCount
            $st = if ($e -ge 10) { 'Error' } elseif ($e -gt 0 -or $w -gt 0) { 'Warning' } else { 'OK' }
            & $add $fsl 'Recente errors en warnings' $st "$e error(s), $w warning(s) sinds $($Data.Events.Start.ToString('yyyy-MM-dd HH:mm'))" ('Logs: ' + ($Data.Events.PresentLogs -join ', ')) $(if ($st -ne 'OK') { 'Bekijk de pagina Events voor details.' } else { '' }) 1
        } else { & $add $fsl 'Recente errors en warnings' 'Unknown' 'FSLogix-eventlog niet beschikbaar' 'Get-WinEvent' 'Controleer of Microsoft-FSLogix-Apps/Operational bestaat en leesbaar is.' 1 }
    }

    # ---- Storage
    $st = 'Opslag'
    foreach ($v in @($Data.Volumes)) {
        if ($null -eq $v.FreePercent) { continue }
        $s = if ($v.FreePercent -lt $errPct) { 'Error' } elseif ($v.FreePercent -lt $warnPct) { 'Warning' } else { 'OK' }
        & $add $st "Vrije ruimte $($v.Drive)" $s ("{0:N1}% vrij ({1} van {2})" -f $v.FreePercent, (Format-FslBytes $v.Free), (Format-FslBytes $v.Size)) 'Win32_LogicalDisk' $(if ($s -ne 'OK') { 'Maak schijfruimte vrij.' } else { '' }) 1
    }
    if ($Data.Containers) {
        $vols = @($Data.Containers.Volumes)
        if ($vols.Count -gt 0) {
            $bad = @($vols | Where-Object { $_.Health -and $_.Health -ne 'Healthy' })
            $low = @($vols | Where-Object { $_.Size -gt 0 -and (($_.Free / $_.Size) * 100) -lt $warnPct })
            $s = if ($bad.Count -gt 0) { 'Error' } elseif ($low.Count -gt 0) { 'Warning' } else { 'OK' }
            & $add $st 'Gekoppelde VHD(X)-volumes' $s "$($vols.Count) volume(s); $($bad.Count) niet gezond; $($low.Count) bijna vol" 'Get-Disk / Get-Volume' $(if ($s -ne 'OK') { 'Controleer de betreffende containers (grootte/health).' } else { '' }) 1
        } elseif ($installed -and $peOn) { & $add $st 'Gekoppelde VHD(X)-volumes' 'NA' 'Geen gekoppelde volumes (geen actieve gebruikers?)' 'Get-Disk' '' 1 }
    }

    # ---- Network (UNC locations)
    $net = 'Netwerk'
    $locations = @()
    foreach ($k in 'Profiles.VHDLocations', 'Profiles.CCDLocations', 'ODFC.VHDLocations', 'ODFC.CCDLocations') { $locations += (Get-FslLocationsFromValue (& $val $k)) }
    $locations = @($locations | Select-Object -Unique)
    if ($locations.Count -eq 0) {
        & $add $net 'Bereikbaarheid containerlocaties' 'NA' 'Geen UNC-locaties geconfigureerd' 'Registry' '' 1
    } else {
        $servers = @{}
        foreach ($loc in $locations) { $p = Get-FslUncParts $loc; if ($p) { $servers[$p.Server] = $true } }
        foreach ($srv in $servers.Keys) {
            $dns = Resolve-FslDnsName -Name $srv -TimeoutMs $timeout
            $ds = switch ($dns.Status) { 'Resolved' { 'OK' } 'Timeout' { 'Warning' } default { 'Error' } }
            & $add $net "DNS-resolutie $srv" $ds $(if ($dns.Status -eq 'Resolved') { ($dns.Addresses -join ', ') } elseif ($dns.Status -eq 'Timeout') { 'Time-out' } else { 'Niet te resolven' }) 'DNS' $(if ($ds -ne 'OK') { 'Controleer DNS-instellingen en de servernaam.' } else { '' }) 1
            if ($dns.Status -eq 'Resolved') {
                $tcp = Test-FslTcpPort -ComputerName $srv -Port 445 -TimeoutMs $timeout
                $ts = switch ($tcp) { 'Open' { 'OK' } 'Timeout' { 'Warning' } default { 'Error' } }
                & $add $net "SMB-poort 445 $srv" $ts $(switch ($tcp) { 'Open' { 'Open' } 'Timeout' { 'Time-out' } default { 'Gesloten/onbereikbaar' } }) 'TCP-verbinding' $(if ($ts -ne 'OK') { 'Controleer firewall, NSG en de fileserver.' } else { '' }) 2
            }
        }
        foreach ($loc in $locations) {
            $p = Get-FslUncParts $loc
            if (-not $p) { continue }
            if ($servers.ContainsKey($p.Server)) {
                $r = Test-FslPathReachable -Path $loc -TimeoutMs ($timeout + 2000)
                $rs = switch ($r) { 'Reachable' { 'OK' } 'Timeout' { 'Warning' } default { 'Error' } }
                & $add $net "Toegang tot $loc" $rs $(switch ($r) { 'Reachable' { 'Toegankelijk' } 'Timeout' { 'Time-out' } 'NotFound' { 'Niet gevonden of geen toegang' } default { 'Fout bij toegang' } }) 'Test-Path (met time-out)' $(if ($rs -ne 'OK') { 'Controleer share- en NTFS-rechten voor het computeraccount/gebruikers.' } else { '' }) 2
            }
        }
    }
    if ($Data.Containers) {
        $c = @($Data.Containers.Smb).Count
        & $add $net 'Bestaande SMB-connecties' $(if ($c -gt 0) { 'OK' } else { 'NA' }) "$c connectie(s)" 'Get-SmbConnection' '' 1
    }

    # ---- Windows
    $win = 'Windows'
    $sys = $Data.System
    if ($sys) {
        & $add $win 'Pending reboot' $(if ($sys.PendingReboot) { 'Warning' } else { 'OK' }) $(if ($sys.PendingReboot) { ($sys.PendingRebootReasons -join '; ') } else { 'Geen herstart in afwachting' }) 'Registry (CBS, WU, Session Manager)' $(if ($sys.PendingReboot) { 'Plan een herstart van de host.' } else { '' }) 1
        if ($sys.LastUpdateDate) {
            $age = ((Get-Date) - $sys.LastUpdateDate).TotalDays
            $s = if ($age -gt 90) { 'Error' } elseif ($age -gt 45) { 'Warning' } else { 'OK' }
            & $add $win 'Laatst geïnstalleerde update' $s ("{0} ({1:N0} dagen geleden)" -f $sys.LastUpdateTitle, $age) 'Windows Update history / Get-HotFix' $(if ($s -ne 'OK') { 'Installeer recente cumulatieve updates.' } else { '' }) 1
        } else { & $add $win 'Laatst geïnstalleerde update' 'Unknown' 'Niet vast te stellen' 'Windows Update history / Get-HotFix' '' 1 }
        & $add $win 'Windows-build' 'NA' "$($sys.ProductName) $($sys.DisplayVersion) (build $($sys.BuildFull))" 'Registry / Win32_OperatingSystem' '' 1
        $days = $sys.Uptime.TotalDays
        $us = if ($days -gt 60) { 'Warning' } else { 'OK' }
        & $add $win 'Uptime' $us $sys.UptimeText 'Win32_OperatingSystem' $(if ($us -ne 'OK') { 'Overweeg een geplande herstart (langlopende host).' } else { '' }) 1
        # AVD
        $avd = 'AVD'
        $a = $sys.Avd
        if ($a.AgentInstalled) { & $add $avd 'AVD Agent geïnstalleerd' 'OK' "Versie $($a.AgentVersion)" 'Uninstall-registry' '' 1 } else { & $add $avd 'AVD Agent geïnstalleerd' 'Unknown' 'Niet gevonden (geen AVD-host?)' 'Uninstall-registry' 'Installeer de AVD Agent als dit een session host is.' 1 }
        if ($a.BootLoaderInstalled) { & $add $avd 'AVD Boot Loader' 'OK' "Versie $($a.BootLoaderVersion)" 'Uninstall-registry' '' 1 } else { & $add $avd 'AVD Boot Loader' 'Unknown' 'Niet gevonden' 'Uninstall-registry' '' 1 }
        foreach ($s in @($a.Services)) {
            if ($s.Name -in 'RDAgentBootLoader', 'RdAgent') { & $add $avd "Service $($s.Name)" $(if ($s.Status -eq 'Running') { 'OK' } else { 'Error' }) "$($s.Status) (start: $($s.StartType))" 'Get-Service' $(if ($s.Status -ne 'Running') { "Start de service $($s.Name)." } else { '' }) 1 }
        }
    } else { & $add $win 'Hostinformatie' 'Unknown' 'Systeeminformatie niet beschikbaar' '' '' 1 }
    $res.ToArray()
}
