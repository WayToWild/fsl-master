# FSL Master - orchestrator. Every step is isolated: a failing data source is recorded and never stops the others.

function Invoke-FslStep {
    param([string]$Name, [scriptblock]$Script, [hashtable]$Snapshot, [hashtable]$Sync, [double]$Progress)
    if ($Sync) { $Sync.Step = $Name; $Sync.Progress = $Progress }
    $t0 = Get-Date
    try {
        $r = & $Script
        Write-FslLog -Level INFO -Message ("Databron '{0}' voltooid in {1:N1}s" -f $Name, ((Get-Date) - $t0).TotalSeconds)
        return $r
    } catch {
        $msg = $_.Exception.Message
        Write-FslLog -Level ERROR -Message "Databron '$Name' mislukt: $msg" -Exception $_
        $Snapshot.Errors.Add([pscustomobject]@{ Source = $Name; Message = $msg; Detail = ($_ | Out-String).Trim() })
        return $null
    }
}

function Invoke-FslCollectAll {
    param([hashtable]$Options, [hashtable]$Sync)
    $cfg = if ($Options.Config) { $Options.Config } else { Get-FslDefaultConfig }
    $hours = if ($Options.LookbackHours) { [int]$Options.LookbackHours } else { [int]$cfg.LookbackHours }
    $snap = @{ Started = Get-Date; Errors = (New-Object System.Collections.Generic.List[object]); LookbackHours = $hours }
    Write-FslLog -Level INFO -Message "Refresh gestart (periode: $hours uur)"

    $snap.System = Invoke-FslStep -Name 'Windows en AVD-informatie' -Snapshot $snap -Sync $Sync -Progress 5 -Script { Get-FslSystemInfo }
    $snap.Volumes = Invoke-FslStep -Name 'Lokale volumes' -Snapshot $snap -Sync $Sync -Progress 15 -Script { @(Get-FslLocalVolumes) }
    $snap.Install = Invoke-FslStep -Name 'FSLogix-installatie' -Snapshot $snap -Sync $Sync -Progress 22 -Script { Get-FslInstallInfo }
    $snap.Config = Invoke-FslStep -Name 'FSLogix-configuratie' -Snapshot $snap -Sync $Sync -Progress 30 -Script { Get-FslConfiguration }
    $lookup = if ($snap.Config) { $snap.Config.Lookup } else { @{} }
    $snap.Services = Invoke-FslStep -Name 'Services en componenten' -Snapshot $snap -Sync $Sync -Progress 40 -Script { @(Get-FslServiceInfo -Install $snap.Install -ConfigLookup $lookup) }
    $snap.Containers = Invoke-FslStep -Name 'Containers en redirects' -Snapshot $snap -Sync $Sync -Progress 55 -Script { Get-FslContainers -Install $snap.Install -TimeoutMs ([int]$cfg.NetworkTimeoutMs) }
    $snap.Sessions = Invoke-FslStep -Name 'Gebruikers en sessies' -Snapshot $snap -Sync $Sync -Progress 68 -Script { @(Get-FslSessions) }
    if ($snap.Sessions) {
        $installed = [bool]($snap.Install -and $snap.Install.Installed)
        $pe = $false
        if ($lookup.ContainsKey('Profiles.Enabled') -and $lookup['Profiles.Enabled'].Source -ne 'NotConfigured') { $pe = ("$($lookup['Profiles.Enabled'].Value)" -eq '1') }
        $cRows = if ($snap.Containers) { $snap.Containers.Rows } else { @() }
        $avail = [bool]($snap.Containers -and $snap.Containers.DataAvailable)
        $null = Merge-FslSessionContainers -Sessions $snap.Sessions -Containers $cRows -FslogixInstalled $installed -ProfilesEnabled $pe -ContainerDataAvailable $avail
    }
    $start = (Get-Date).AddHours(-$hours)
    $snap.Events = Invoke-FslStep -Name 'Eventlogs' -Snapshot $snap -Sync $Sync -Progress 80 -Script { Get-FslEvents -StartTime $start -MaxEvents ([int]$cfg.MaxEvents) -MarkedIds @($cfg.MarkedEventIds) }
    if ($snap.Events) { foreach ($e in $snap.Events.Errors) { $snap.Errors.Add([pscustomobject]@{ Source = 'Eventlogs'; Message = $e; Detail = $e }) } }
    $snap.Health = Invoke-FslStep -Name 'Health check (netwerk en overige controles)' -Snapshot $snap -Sync $Sync -Progress 90 -Script { @(Get-FslHealthChecks -Data $snap -Config $cfg) }
    $fslOn = [bool]($snap.Install -and $snap.Install.Installed)
    if ($snap.Health) { $snap.Score = Get-FslHealthScore -Results $snap.Health -FslogixInstalled $fslOn } else { $snap.Score = Get-FslHealthScore -Results @() -FslogixInstalled $fslOn }
    $snap.Finished = Get-Date
    if ($Sync) { $Sync.Step = 'Gereed'; $Sync.Progress = 100 }
    Write-FslLog -Level INFO -Message ("Refresh voltooid in {0:N1}s met {1} databronfout(en)" -f ($snap.Finished - $snap.Started).TotalSeconds, $snap.Errors.Count)
    $snap.Errors = $snap.Errors.ToArray()
    $snap
}
