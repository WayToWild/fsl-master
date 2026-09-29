# FSL Master - Windows build health and update status. Strictly read-only: it searches for updates and reads history,
# it never downloads or installs anything.

function Get-FslDefaultBuildLifecycle {
    # Reference data (end of servicing for Enterprise/Education editions, which AVD session hosts use). Verify against
    # https://learn.microsoft.com/lifecycle - builds that are not listed are reported as "not in the reference table".
    # Users can add or override entries through "BuildLifecycle" in fsl-master.config.json.
    @(
        [pscustomobject]@{ Build = 14393; Name = 'Windows Server 2016 (1607)'; EndOfServicing = [datetime]'2027-01-12' }
        [pscustomobject]@{ Build = 17763; Name = 'Windows Server 2019 (1809)'; EndOfServicing = [datetime]'2029-01-09' }
        [pscustomobject]@{ Build = 19045; Name = 'Windows 10 22H2'; EndOfServicing = [datetime]'2025-10-14' }
        [pscustomobject]@{ Build = 20348; Name = 'Windows Server 2022 (21H2)'; EndOfServicing = [datetime]'2031-10-14' }
        [pscustomobject]@{ Build = 22000; Name = 'Windows 11 21H2'; EndOfServicing = [datetime]'2024-10-08' }
        [pscustomobject]@{ Build = 22621; Name = 'Windows 11 22H2'; EndOfServicing = [datetime]'2024-10-08' }
        [pscustomobject]@{ Build = 22631; Name = 'Windows 11 23H2'; EndOfServicing = [datetime]'2025-11-11' }
        [pscustomobject]@{ Build = 26100; Name = 'Windows 11 24H2 / Windows Server 2025'; EndOfServicing = [datetime]'2027-10-12' }
        [pscustomobject]@{ Build = 26200; Name = 'Windows 11 25H2'; EndOfServicing = [datetime]'2028-10-10' }
    )
}

function Get-FslBuildLifecycle {
    # Returns @{ Known; Name; EndOfServicing; DaysLeft; Status } for a build number.
    param([int]$Build, [hashtable]$Config, [datetime]$Now = (Get-Date))
    $table = @(Get-FslDefaultBuildLifecycle)
    if ($Config -and $Config.BuildLifecycle) {
        foreach ($e in @($Config.BuildLifecycle)) {
            try {
                $eb = [int]$e.Build; $ed = [datetime]$e.EndOfServicing
                $table = @($table | Where-Object { $_.Build -ne $eb }) + [pscustomobject]@{ Build = $eb; Name = "$($e.Name)"; EndOfServicing = $ed }
            } catch { }
        }
    }
    $hit = $table | Where-Object { $_.Build -eq $Build } | Select-Object -First 1
    if (-not $hit) { return [pscustomobject]@{ Known = $false; Name = $null; EndOfServicing = $null; DaysLeft = $null; Status = 'Unknown' } }
    $days = [int][math]::Floor(($hit.EndOfServicing - $Now).TotalDays)
    $st = if ($days -lt 0) { 'Error' } elseif ($days -lt 180) { 'Warning' } else { 'OK' }
    [pscustomobject]@{ Known = $true; Name = $hit.Name; EndOfServicing = $hit.EndOfServicing; DaysLeft = $days; Status = $st }
}

function Get-FslUpdateClass {
    param([string]$Categories, [string]$Severity)
    if ($Categories -match '(?i)definition') { return 'Definition' }
    if ($Categories -match '(?i)upgrade|feature pack') { return 'Feature' }
    if ($Categories -match '(?i)driver') { return 'Driver' }
    if ($Severity -match '(?i)critical' -or $Categories -match '(?i)critical') { return 'Critical' }
    if ($Categories -match '(?i)security' -or $Severity -match '(?i)important|moderate|low') { return 'Security' }
    'Other'
}

function Get-FslUpdateResultText {
    param([int]$Code)
    switch ($Code) { 1 { 'In progress' } 2 { 'Succeeded' } 3 { 'Succeeded with errors' } 4 { 'Failed' } 5 { 'Aborted' } default { 'Not started' } }
}

function Get-FslUpdatePolicy {
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $au = "$wu\AU"
    $server = Get-FslRegistryValue -Path $wu -Name 'WUServer'
    $use = Get-FslRegistryValue -Path $au -Name 'UseWUServer'
    $noAuto = Get-FslRegistryValue -Path $au -Name 'NoAutoUpdate'
    $target = Get-FslRegistryValue -Path $wu -Name 'TargetReleaseVersionInfo'
    $deferQ = Get-FslRegistryValue -Path $wu -Name 'DeferQualityUpdatesPeriodInDays'
    $deferF = Get-FslRegistryValue -Path $wu -Name 'DeferFeatureUpdatesPeriodInDays'
    $source = if ($server -and $use -and [int]$use.Value -eq 1) { "WSUS: $($server.Value)" } else { 'Windows Update / Microsoft Update (default or Windows Update for Business)' }
    [pscustomobject]@{
        Source = $source; AutoUpdateDisabled = [bool]($noAuto -and [int]$noAuto.Value -eq 1)
        TargetRelease = $(if ($target) { "$($target.Value)" } else { $null })
        DeferQualityDays = $(if ($deferQ) { [int]$deferQ.Value } else { $null }); DeferFeatureDays = $(if ($deferF) { [int]$deferF.Value } else { $null })
    }
}

function Search-FslWindowsUpdates {
    # Searches the configured update source (read-only). Runs with a hard timeout because WSUS/WU can be slow or unreachable.
    param([int]$TimeoutSec = 240)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-FslWithTimeout -TimeoutMs ($TimeoutSec * 1000) -ScriptBlock {
        $s = New-Object -ComObject Microsoft.Update.Session
        $s.ClientApplicationID = 'FSL Master (read-only)'
        $searcher = $s.CreateUpdateSearcher()
        $res = $searcher.Search('IsInstalled=0 and IsHidden=0')
        foreach ($u in $res.Updates) {
            [pscustomobject]@{
                Title = $u.Title; Kb = (@($u.KBArticleIDs) -join ', '); Categories = (@($u.Categories | ForEach-Object { $_.Name }) -join ', ')
                Severity = "$($u.MsrcSeverity)"; SizeBytes = [int64]$u.MaxDownloadSize; Downloaded = [bool]$u.IsDownloaded; Mandatory = [bool]$u.IsMandatory
                RebootRequired = ([int]$u.InstallationBehavior.RebootBehavior -gt 0)
            }
        }
    }
    if ($r.TimedOut) { return [pscustomobject]@{ Ok = $false; Updates = @(); Error = "Timed out after $TimeoutSec s (update source unreachable or slow)."; Seconds = $sw.Elapsed.TotalSeconds } }
    if ($r.Error -and @($r.Result).Count -eq 0) { return [pscustomobject]@{ Ok = $false; Updates = @(); Error = $r.Error; Seconds = $sw.Elapsed.TotalSeconds } }
    $rows = @($r.Result | ForEach-Object {
            $cls = Get-FslUpdateClass -Categories $_.Categories -Severity $_.Severity
            $_ | Select-Object *, @{ n = 'Class'; e = { $cls } }, @{ n = 'SizeText'; e = { Format-FslBytes $_.SizeBytes } }
        })
    [pscustomobject]@{ Ok = $true; Updates = $rows; Error = $null; Seconds = $sw.Elapsed.TotalSeconds }
}

function Get-FslUpdateHistory {
    param([int]$Max = 60)
    $r = Invoke-FslWithTimeout -TimeoutMs 60000 -ArgumentList @($Max) -ScriptBlock {
        param($max)
        $s = New-Object -ComObject Microsoft.Update.Session
        $searcher = $s.CreateUpdateSearcher()
        $n = $searcher.GetTotalHistoryCount()
        if ($n -gt 0) {
            foreach ($h in $searcher.QueryHistory(0, [math]::Min($n, $max))) {
                [pscustomobject]@{ Date = [datetime]$h.Date; Title = $h.Title; ResultCode = [int]$h.ResultCode; Operation = [int]$h.Operation; HResult = ('0x{0:X8}' -f [int]$h.HResult) }
            }
        }
    }
    @($r.Result | ForEach-Object { $_ | Select-Object *, @{ n = 'Result'; e = { Get-FslUpdateResultText $_.ResultCode } }, @{ n = 'Kind'; e = { if ($_.Operation -eq 2) { 'Uninstall' } else { 'Install' } } } })
}

function Get-FslAutoUpdateInfo {
    try {
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $res = $au.Results
        [pscustomobject]@{ LastSearch = $(try { [datetime]$res.LastSearchSuccessDate } catch { $null }); LastInstall = $(try { [datetime]$res.LastInstallationSuccessDate } catch { $null }); ServiceEnabled = [bool]$au.ServiceEnabled }
    } catch { $null }
}

function Get-FslUpdateFindings {
    # Turns the collected data into checks (same model/score as the health check).
    param($Data, [hashtable]$Config)
    $res = New-Object System.Collections.Generic.List[object]
    $cat = 'Windows Updates'
    $add = { param($chk, $st, $r, $ev, $rec, $w) $res.Add((New-FslResult -Category $cat -Check $chk -Status $st -Result $r -Evidence $ev -Recommendation $rec -Weight $w)) }
    $lc = $Data.Lifecycle
    if ($lc -and $lc.Known) {
        $txt = if ($lc.DaysLeft -lt 0) { "$($lc.Name): end of servicing was $([math]::Abs($lc.DaysLeft)) days ago ($($lc.EndOfServicing.ToString('yyyy-MM-dd')))" } else { "$($lc.Name): supported until $($lc.EndOfServicing.ToString('yyyy-MM-dd')) ($($lc.DaysLeft) days left)" }
        & $add 'Windows build servicing status' $lc.Status $txt 'Built-in reference table (verify with Microsoft lifecycle)' $(if ($lc.Status -eq 'Error') { 'This build no longer receives security updates. Upgrade the image/host to a supported release.' } elseif ($lc.Status -eq 'Warning') { 'Plan the upgrade to a newer release before servicing ends.' } else { '' }) 2
    } else { & $add 'Windows build servicing status' 'Unknown' "Build $($Data.Build) is not in the reference table" 'Add it through BuildLifecycle in the configuration file' 'Check https://learn.microsoft.com/lifecycle for this build.' 1 }
    if ($Data.LastCu) {
        $age = ((Get-Date) - $Data.LastCu.Date).TotalDays
        $s = if ($age -gt 90) { 'Error' } elseif ($age -gt 45) { 'Warning' } else { 'OK' }
        & $add 'Last cumulative update' $s ("{0} ({1:N0} days ago)" -f $Data.LastCu.Title, $age) $Data.LastCu.Source $(if ($s -ne 'OK') { 'Install the latest cumulative update.' } else { '' }) 2
    } else { & $add 'Last cumulative update' 'Unknown' 'Could not be determined' 'Windows Update history / Get-HotFix' '' 1 }
    if ($Data.Search -and $Data.Search.Ok) {
        $p = @($Data.Search.Updates)
        $crit = @($p | Where-Object { $_.Class -eq 'Critical' }); $sec = @($p | Where-Object { $_.Class -eq 'Security' }); $other = @($p | Where-Object { $_.Class -eq 'Other' })
        $s = if ($crit.Count -gt 0) { 'Error' } elseif ($sec.Count -gt 0 -or $other.Count -gt 0) { 'Warning' } else { 'OK' }
        & $add 'Pending quality/security updates' $s "$($crit.Count) critical, $($sec.Count) security, $($other.Count) other" ("Update source: " + $Data.Policy.Source) $(if ($s -ne 'OK') { 'Install the pending updates during a maintenance window (build a new image or use your update tooling).' } else { '' }) 2
        $feat = @($p | Where-Object { $_.Class -eq 'Feature' }).Count
        if ($feat -gt 0) { & $add 'Feature update offered' 'NA' "$feat feature update(s) offered" 'Windows Update search' 'Informational. Feature updates on session hosts are normally delivered through a new image.' 1 }
        $reboot = @($p | Where-Object { $_.RebootRequired }).Count
        if ($reboot -gt 0) { & $add 'Pending updates need a reboot' 'NA' "$reboot update(s) require a restart when installed" 'Windows Update search' '' 1 }
    } else {
        & $add 'Pending quality/security updates' 'Unknown' $(if ($Data.Search) { "Update search failed: $($Data.Search.Error)" } else { 'Not searched' }) ("Update source: " + $Data.Policy.Source) 'Check that this host can reach its update source (WSUS / Windows Update).' 1
    }
    if ($Data.History) {
        $recent = @($Data.History | Where-Object { $_.Kind -eq 'Install' -and $_.Date -gt (Get-Date).AddDays(-30) })
        $failed = @($recent | Where-Object { $_.ResultCode -in 4, 5 })
        $s = if ($failed.Count -ge 3) { 'Error' } elseif ($failed.Count -ge 1) { 'Warning' } else { 'OK' }
        & $add 'Failed update installs (30 days)' $s "$($failed.Count) failed of $($recent.Count) install attempts" 'Windows Update history' $(if ($s -ne 'OK') { 'Review the failed updates below and the CBS/WindowsUpdate logs; consider DISM RestoreHealth (Maintenance page).' } else { '' }) 1
    }
    if ($Data.AutoUpdate -and $Data.AutoUpdate.LastSearch -and $Data.AutoUpdate.LastSearch.Year -gt 2000) {
        $age = ((Get-Date) - $Data.AutoUpdate.LastSearch).TotalDays
        $s = if ($age -gt 14) { 'Warning' } else { 'OK' }
        & $add 'Last successful update check' $s ("{0:yyyy-MM-dd HH:mm} ({1:N0} days ago)" -f $Data.AutoUpdate.LastSearch, $age) 'Microsoft.Update.AutoUpdate' $(if ($s -ne 'OK') { 'The host has not contacted its update source recently.' } else { '' }) 1
    }
    if ($Data.PendingReboot) { & $add 'Pending reboot' 'Warning' ($Data.PendingRebootReasons -join '; ') 'Registry' 'Restart the host to complete servicing.' 1 } else { & $add 'Pending reboot' 'OK' 'None' 'Registry' '' 1 }
    foreach ($svcName in 'wuauserv', 'BITS', 'cryptsvc') {
        $sv = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($sv) { $dis = ("$($sv.StartType)" -eq 'Disabled'); & $add "Service $svcName" $(if ($dis) { 'Warning' } else { 'OK' }) "$($sv.Status) (start: $($sv.StartType))" 'Get-Service' $(if ($dis) { "Service $svcName is disabled; updates cannot be installed." } else { '' }) 1 }
    }
    if ($Data.Policy.AutoUpdateDisabled) { & $add 'Automatic updates policy' 'NA' 'Automatic updates are disabled by policy' 'Registry policy' 'Expected when updates are managed through images or another tool.' 1 }
    $res.ToArray()
}

function Get-FslWindowsUpdateStatus {
    # Full status. Local information is always returned; the (slow) online search is optional.
    param([hashtable]$Config, [switch]$Search, [int]$SearchTimeoutSec = 240, [hashtable]$Sync)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ubr = Get-FslRegistryValue -Path $cv -Name 'UBR'
    $dv = Get-FslRegistryValue -Path $cv -Name 'DisplayVersion'
    $build = [int]$os.BuildNumber
    $pr = Get-FslPendingReboot
    if ($Sync) { $Sync.Step = 'Reading update history' }
    $hist = @(Get-FslUpdateHistory)
    $data = @{
        Build = $build; BuildFull = $(if ($ubr) { "$build.$($ubr.Value)" } else { "$build" }); ProductName = $os.Caption; DisplayVersion = $(if ($dv) { "$($dv.Value)" } else { '' })
        Lifecycle = (Get-FslBuildLifecycle -Build $build -Config $Config); LastCu = (Get-FslLastCumulativeUpdate); Policy = (Get-FslUpdatePolicy)
        History = $hist; AutoUpdate = (Get-FslAutoUpdateInfo); PendingReboot = $pr.Pending; PendingRebootReasons = $pr.Reasons; Search = $null; Collected = (Get-Date)
    }
    if ($Search) {
        if ($Sync) { $Sync.Step = 'Searching the update source (this can take a minute)' }
        $data.Search = Search-FslWindowsUpdates -TimeoutSec $SearchTimeoutSec
    }
    $data.Findings = @(Get-FslUpdateFindings -Data $data -Config $Config)
    $data.Score = Get-FslHealthScore -Results $data.Findings
    [pscustomobject]$data
}
