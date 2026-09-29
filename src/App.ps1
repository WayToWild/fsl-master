param(
    [switch]$AllowNonElevated,       # developer/testing switch: run without administrator rights (limited data)
    [string]$CaptureScreenshots,     # developer/testing: folder to write PNG screenshots of every page, then exit
    [string]$SelfTest                # smoke test: collect data without GUI, write a JSON summary to this file, exit
)
$ErrorActionPreference = 'Continue'

#region MODULES
if (-not $script:FslBundled) {
    $script:SrcRoot = $PSScriptRoot
    foreach ($m in 'Core\Core.ps1', 'Collectors\SystemInfo.ps1', 'Collectors\FSLogix.ps1', 'Collectors\Sessions.ps1', 'Collectors\Containers.ps1',
        'Collectors\Events.ps1', 'Collectors\Health.ps1', 'Collectors\Collect.ps1', 'Export\Report.ps1', 'UI\Ui.ps1') {
        . (Join-Path $script:SrcRoot $m)
    }
    $script:FslBuildInfo = @{ BuildDate = 'ontwikkelversie (broncode)'; Commit = '' }
    try { $script:FslBuildInfo.Commit = (& git -C (Split-Path -Parent $script:SrcRoot) rev-parse --short HEAD 2>$null) } catch { }
    $env:FSLM_APPDIR = Split-Path -Parent $script:SrcRoot
}
#endregion MODULES

$app = Get-FslAppInfo
$null = Initialize-FslLog
$isAdmin = Test-FslIsAdministrator
Write-FslLog -Level INFO -Message "Applicatiestart: $($app.Name) $($app.Version); beheerder=$isAdmin; PID=$PID; PowerShell=$($PSVersionTable.PSVersion)"

# ---------------------------------------------------------------- self test (no GUI)
if ($SelfTest) {
    try {
        $cfg = Get-FslConfig
        $snap = Invoke-FslCollectAll -Options @{ Config = $cfg; LookbackHours = 24 } -Sync $null
        $summary = [ordered]@{
            Application = $app.Name; Version = $app.Version; IsAdministrator = $isAdmin; Compiled = [bool]$script:FslBundled
            ComputerName = $(if ($snap.System) { $snap.System.ComputerName } else { $null })
            Windows = $(if ($snap.System) { "$($snap.System.ProductName) $($snap.System.BuildFull)" } else { $null })
            FslogixInstalled = [bool]($snap.Install -and $snap.Install.Installed)
            ConfigRows = $(if ($snap.Config) { @($snap.Config.Rows).Count } else { 0 })
            ServiceRows = @($snap.Services).Count
            Sessions = @($snap.Sessions).Count
            Containers = $(if ($snap.Containers) { @($snap.Containers.Rows).Count } else { 0 })
            MissingEventLogs = $(if ($snap.Events) { @($snap.Events.MissingLogs) } else { @() })
            HealthChecks = @($snap.Health).Count
            HealthScore = $(if ($snap.Score) { $snap.Score.Score } else { $null })
            SourceErrors = @($snap.Errors | ForEach-Object { "$($_.Source): $($_.Message)" })
            Seconds = [math]::Round(($snap.Finished - $snap.Started).TotalSeconds, 1)
        }
        ($summary | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $SelfTest -Encoding UTF8
        exit 0
    } catch {
        Write-FslLog -Level ERROR -Message 'Selftest mislukt' -Exception $_
        ($_ | Out-String) | Set-Content -LiteralPath $SelfTest -Encoding UTF8
        exit 1
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Data

# ---------------------------------------------------------------- elevation check
if (-not $isAdmin -and -not $AllowNonElevated) {
    $choice = [Windows.MessageBox]::Show("FSL Master vereist administratorrechten om FSLogix, services, eventlogs en volumes te kunnen lezen.`n`nWilt u de applicatie opnieuw starten met verhoogde rechten?", 'FSL Master - administratorrechten vereist', 'YesNo', 'Warning')
    if ($choice -eq 'Yes') {
        try {
            $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ($exe -match '(?i)\\(powershell|pwsh)\.exe$') {
                Start-Process -FilePath $exe -Verb RunAs -ArgumentList @('-STA', '-NoProfile', '-File', ('"' + $PSCommandPath + '"'))
            } else { Start-Process -FilePath $exe -Verb RunAs }
            Write-FslLog -Level INFO -Message 'Verhoogde herstart aangevraagd; niet-verhoogde instantie sluit af.'
        } catch { Write-FslLog -Level WARN -Message 'Verhoogd herstarten geannuleerd of mislukt.' -Exception $_ }
    } else { Write-FslLog -Level INFO -Message 'Gebruiker koos niet voor verhoogde herstart; applicatie sluit af.' }
    exit 0
}

# ---------------------------------------------------------------- build the window
$script:Config = Get-FslConfig
$xaml = if ($script:FslMainXaml) { $script:FslMainXaml } else { [IO.File]::ReadAllText((Join-Path $script:SrcRoot 'UI\MainWindow.xaml'), [Text.Encoding]::UTF8) }
try {
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
} catch {
    Write-FslLog -Level ERROR -Message 'XAML kon niet worden geladen' -Exception $_
    [void][Windows.MessageBox]::Show("De gebruikersinterface kon niet worden geladen:`n$($_.Exception.Message)", 'FSL Master', 'OK', 'Error')
    exit 1
}
foreach ($m in [regex]::Matches($xaml, 'x:Name="(\w+)"')) { $n = $m.Groups[1].Value; $script:Ui[$n] = $win.FindName($n) }

$script:PageMap = @{
    NavDashboard = 'PageDashboard'; NavConfig = 'PageConfig'; NavServices = 'PageServices'; NavSessions = 'PageSessions'; NavContainers = 'PageContainers'
    NavEvents = 'PageEvents'; NavLogs = 'PageLogs'; NavHealth = 'PageHealth'; NavReport = 'PageReport'; NavAbout = 'PageAbout'
}
$script:UiReady = $false
Initialize-FslUiGrids
Set-FslUiTheme -Name $script:Config.Theme

# header info
$script:Ui.TxtAdmin.Text = if ($isAdmin) { ([string][char]0x2714) + ' Beheerder' } else { ([string][char]0x26A0) + ' Geen beheerder (beperkte modus)' }
$script:Ui.TxtAdmin.Foreground = Get-FslUiBrush $(if ($isAdmin) { '#2E7D32' } else { '#E65100' })
$bi = if ($script:FslBuildInfo) { $script:FslBuildInfo } else { @{ BuildDate = 'onbekend'; Commit = '' } }
$script:Ui.TxtAboutName.Text = "$($app.Name) $($app.Version)"
$script:Ui.TxtAboutDesc.Text = $app.Description
$script:Ui.TxtAboutInfo.Text = "Versie: $($app.Version)`nBuilddatum: $($bi.BuildDate)`nGit commit: $(if ($bi.Commit) { $bi.Commit } else { 'niet beschikbaar' })`nLicentie: $($app.License)`nLogmap: $($env:FSLM_LOGDIR)`nConfiguratie: $((Get-FslConfigCandidates) -join '  |  ')"
$script:Ui.MainWin.Title = "$($app.Name) $($app.Version)"
$script:Ui.LnkRepo.Add_RequestNavigate({ try { Start-Process -FilePath $args[1].Uri.AbsoluteUri } catch { }; $args[1].Handled = $true })

# quick log filters
foreach ($q in 'ERROR', 'WARN', 'attach', 'detach', 'failed', 'timeout', 'locked', 'LoadProfile', 'VHD', 'VHDX', 'Cloud Cache') {
    $btn = New-Object Windows.Controls.Button
    $btn.Content = $q; $btn.Padding = New-Object Windows.Thickness(7, 2, 7, 2); $btn.Tag = $q
    $btn.Add_Click({ $script:Ui.TxtLogSearch.Text = "$($args[0].Tag)" })
    [void]$script:Ui.SpLogQuick.Children.Add($btn)
}
$clr = New-Object Windows.Controls.Button; $clr.Content = 'Wis filter'; $clr.Padding = New-Object Windows.Thickness(7, 2, 7, 2)
$clr.Add_Click({ $script:Ui.TxtLogSearch.Text = ''; $script:Ui.TxtLogUser.Text = '' })
[void]$script:Ui.SpLogQuick.Children.Add($clr)

# ---------------------------------------------------------------- timers
$script:JobTimer = New-Object Windows.Threading.DispatcherTimer
$script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:JobTimer.Add_Tick({ Invoke-FslUiJobPoll })
$script:JobTimer.Start()

$script:FilterTimer = New-Object Windows.Threading.DispatcherTimer
$script:FilterTimer.Interval = [TimeSpan]::FromMilliseconds(280)
$script:FilterTimer.Add_Tick({
        $script:FilterTimer.Stop()
        $d = @($script:FilterDirty.Keys); $script:FilterDirty.Clear()
        foreach ($k in $d) {
            switch ($k) {
                'config' { Update-FslUiConfig } 'sessions' { Update-FslUiSessions } 'containers' { Update-FslUiContainers }
                'events' { Update-FslUiEvents } 'logview' { Update-FslUiLogView } 'health' { Update-FslUiHealth }
            }
        }
    })
function Request-FslUiFilter { param([string]$Key) if (-not $script:UiReady) { return }; $script:FilterDirty[$Key] = $true; $script:FilterTimer.Stop(); $script:FilterTimer.Start() }

$script:AutoTimer = New-Object Windows.Threading.DispatcherTimer
$script:AutoTimer.Add_Tick({ Start-FslUiRefresh })   # Start-FslUiRefresh ignores the tick while a refresh is running

# ---------------------------------------------------------------- event wiring
foreach ($nav in $script:PageMap.Keys) { $script:Ui[$nav].Add_Checked({ Show-FslUiPage -Page $args[0].Name }) }
$script:Ui.BtnRefresh.Add_Click({ Start-FslUiRefresh })
$script:Ui.BtnHealthRun.Add_Click({ Start-FslUiRefresh })
$script:Ui.CmbPeriod.Add_SelectionChanged({ if ($script:UiReady) { Start-FslUiRefresh } })
$script:Ui.CmbAuto.Add_SelectionChanged({
        if (-not $script:UiReady) { return }
        $s = 0; [void][int]::TryParse("$($script:Ui.CmbAuto.SelectedItem.Tag)", [ref]$s)
        $script:AutoTimer.Stop()
        if ($s -gt 0) { $script:AutoTimer.Interval = [TimeSpan]::FromSeconds($s); $script:AutoTimer.Start() }
        Write-FslLog -Level INFO -Message "Auto-refresh ingesteld op $s seconden"
    })
$script:Ui.BtnTheme.Add_Click({ Set-FslUiTheme -Name $(if ($script:Config.Theme -eq 'Dark') { 'Light' } else { 'Dark' }) })
$script:Ui.BtnErrors.Add_Click({
        $e = if ($script:Snap) { @($script:Snap.Errors) } else { @() }
        if ($e.Count -eq 0) { Show-FslUiMessage 'Geen databronfouten tijdens de laatste refresh.'; return }
        Show-FslUiTextWindow -Title 'Databronfouten' -Intro 'Een fout in een databron blokkeert de overige onderdelen niet.' -Text (($e | ForEach-Object { "[$($_.Source)] $($_.Message)`r`n$($_.Detail)`r`n" }) -join "`r`n")
    })

# filters -> debounced updates
foreach ($p in @(@('TxtCfgSearch', 'config'), @('TxtSesSearch', 'sessions'), @('TxtCtSearch', 'containers'), @('TxtEvId', 'events'), @('TxtEvUser', 'events'), @('TxtEvSearch', 'events'),
        @('TxtLogSearch', 'logview'), @('TxtLogUser', 'logview'))) {
    $key = $p[1]; $script:Ui[$p[0]].Add_TextChanged({ Request-FslUiFilter -Key $args[0].Tag }.GetNewClosure()); $script:Ui[$p[0]].Tag = $key
}
foreach ($p in @(@('ChkCfgOnlySet', 'config'), @('ChkEvError', 'events'), @('ChkEvWarn', 'events'), @('ChkEvInfo', 'events'), @('ChkEvMarked', 'events'), @('ChkLogErr', 'logview'), @('ChkLogWarn', 'logview'), @('ChkLogInfo', 'logview'))) {
    $script:Ui[$p[0]].Tag = $p[1]
    $script:Ui[$p[0]].Add_Click({ Request-FslUiFilter -Key $args[0].Tag })
}
$script:Ui.CmbEvLog.Add_SelectionChanged({ Request-FslUiFilter -Key 'events' })
$script:Ui.CmbHealthFilter.Add_SelectionChanged({ Request-FslUiFilter -Key 'health' })

# config page
$script:Ui.BtnCfgJson.Add_Click({ Invoke-FslUiExport -GridName 'GridConfig' -Format json -Title 'FSLogix-configuratie' -BaseName 'fslogix-config' })
$script:Ui.BtnCfgCsv.Add_Click({ Invoke-FslUiExport -GridName 'GridConfig' -Format csv -Title 'FSLogix-configuratie' -BaseName 'fslogix-config' })
$script:Ui.BtnCfgCopy.Add_Click({ Copy-FslUiText -Text (Get-FslUiGridText 'GridConfig') })
# services
$script:Ui.BtnSvcStart.Add_Click({ Invoke-FslUiServiceAction -Action Start })
$script:Ui.BtnSvcStop.Add_Click({ Invoke-FslUiServiceAction -Action Stop })
$script:Ui.BtnSvcRestart.Add_Click({ Invoke-FslUiServiceAction -Action Restart })
$script:Ui.BtnSvcCopy.Add_Click({ Copy-FslUiText -Text (Get-FslUiGridText 'GridServices') })
# sessions
$script:Ui.BtnSesCsv.Add_Click({ Invoke-FslUiExport -GridName 'GridSessions' -Format csv -Title 'Gebruikers en sessies' -BaseName 'fslogix-sessies' })
$script:Ui.BtnSesCopy.Add_Click({ Copy-FslUiText -Text (Get-FslUiGridText 'GridSessions') })
# containers
$ctViews = @{ RbCtMain = 'GridContainers'; RbCtVol = 'GridVolumes'; RbCtSmb = 'GridSmb'; RbCtProf = 'GridProfiles'; RbCtRaw = 'TxtFrxRaw' }
$script:CtViews = $ctViews
foreach ($rb in $ctViews.Keys) {
    $script:Ui[$rb].Add_Checked({ foreach ($k in $script:CtViews.Keys) { $script:Ui[$script:CtViews[$k]].Visibility = 'Collapsed' }; $script:Ui[$script:CtViews[$args[0].Name]].Visibility = 'Visible' })
}
function Get-FslUiActiveContainerGrid { foreach ($k in $script:CtViews.Keys) { if ($script:Ui[$k].IsChecked) { return $script:CtViews[$k] } } 'GridContainers' }
$script:Ui.BtnCtCsv.Add_Click({ $g = Get-FslUiActiveContainerGrid; if ($g -eq 'TxtFrxRaw') { $g = 'GridContainers' }; Invoke-FslUiExport -GridName $g -Format csv -Title 'FSLogix-containers' -BaseName 'fslogix-containers' })
$script:Ui.BtnCtJson.Add_Click({ $g = Get-FslUiActiveContainerGrid; if ($g -eq 'TxtFrxRaw') { $g = 'GridContainers' }; Invoke-FslUiExport -GridName $g -Format json -Title 'FSLogix-containers' -BaseName 'fslogix-containers' })
$script:Ui.BtnCtHtml.Add_Click({ $g = Get-FslUiActiveContainerGrid; if ($g -eq 'TxtFrxRaw') { $g = 'GridContainers' }; Invoke-FslUiExport -GridName $g -Format html -Title 'FSLogix-containers' -BaseName 'fslogix-containers' })
$script:Ui.BtnCtCopy.Add_Click({ $g = Get-FslUiActiveContainerGrid; if ($g -eq 'TxtFrxRaw') { Copy-FslUiText -Text $script:Ui.TxtFrxRaw.Text } else { Copy-FslUiText -Text (Get-FslUiGridText $g) } })
# events
$script:Ui.BtnEvDetail.Add_Click({ Show-FslUiEventDetail })
$script:Ui.GridEvents.Add_MouseDoubleClick({ Show-FslUiEventDetail })
$script:Ui.BtnEvCopy.Add_Click({
        $r = @(Get-FslUiSelectedRows 'GridEvents')
        if ($r.Count -eq 0) { Show-FslUiMessage 'Selecteer eerst een event.'; return }
        Copy-FslUiText -Text (($r | ForEach-Object { "$($_.Row['Time']) [$($_.Row['LogName'])] $($_.Row['Provider']) ID $($_.Row['EventId']) $($_.Row['Level'])`r`n$($_.Row['Message'])" }) -join "`r`n`r`n")
    })
$script:Ui.BtnEvCsv.Add_Click({ Invoke-FslUiExport -GridName 'GridEvents' -Format csv -Title 'Events' -BaseName 'fslogix-events' })
$script:Ui.BtnEvMarks.Add_Click({
        $res = Show-FslUiEditWindow -Title 'Gemarkeerde Event ID''s' -Intro 'Kommagescheiden lijst met Event ID''s die in de eventlijst worden gemarkeerd. Wordt opgeslagen in het lokale JSON-configuratiebestand.' -Initial ($script:Config.MarkedEventIds -join ', ')
        if ($null -eq $res) { return }
        $ids = @(); foreach ($p in ($res -split '[,;\s]+')) { if ($p) { $n = 0; if ([int]::TryParse($p, [ref]$n) -and $n -gt 0 -and $n -lt 65536) { $ids += $n } else { Show-FslUiMessage "'$p' is geen geldig Event ID." 'FSL Master' 'Warning'; return } } }
        $script:Config.MarkedEventIds = $ids
        $saved = Save-FslConfig -Config $script:Config
        Write-FslLog -Level ACTION -Message "Gemarkeerde Event ID's bijgewerkt: $($ids -join ',') (opgeslagen: $saved)"
        if ($script:Snap -and $script:Snap.Events) { foreach ($r in $script:Snap.Events.Rows) { $r.Marked = [bool]($ids -contains $r.EventId); $r.MarkedText = $(if ($r.Marked) { 'Ja' } else { '' }) } }
        Update-FslUiEvents
        if (-not $saved) { Show-FslUiMessage 'De lijst is bijgewerkt voor deze sessie maar kon niet naar het configuratiebestand worden geschreven.' 'FSL Master' 'Warning' }
    })
# logs
$script:Ui.BtnLogRefresh.Add_Click({ Update-FslUiLogFileList })
$script:Ui.BtnLogLoad.Add_Click({ Open-FslUiLogFile })
$script:Ui.GridLogFiles.Add_MouseDoubleClick({ Open-FslUiLogFile })
$script:Ui.DpLogDate.Add_SelectedDateChanged({ if ($script:UiReady) { Update-FslUiLogFileList } })
$script:Ui.BtnLogDateClear.Add_Click({ $script:Ui.DpLogDate.SelectedDate = $null })
$script:Ui.BtnLogCopy.Add_Click({ $r = @(Get-FslUiSelectedRows 'GridLogLines'); if ($r.Count -eq 0) { Show-FslUiMessage 'Selecteer eerst een of meer regels.'; return }; Copy-FslUiText -Text (($r | ForEach-Object { "$($_.Row['Text'])" }) -join "`r`n") })
$script:Ui.BtnLogExport.Add_Click({
        try {
            $r = @(Get-FslUiSelectedRows 'GridLogLines')
            $lines = if ($r.Count -gt 0) { @($r | ForEach-Object { "$($_.Row['Text'])" }) } else { @($script:LogShown | ForEach-Object { $_.Text }) }
            if ($lines.Count -eq 0) { Show-FslUiMessage 'Er zijn geen regels om te exporteren.'; return }
            $f = Get-FslUiSaveFile -Filter 'Tekst (*.txt)|*.txt|Log (*.log)|*.log' -DefaultName ("logfragment-$((Get-Date).ToString('yyyyMMdd-HHmm')).txt")
            if (-not $f) { return }
            $v = Test-FslExportPath -Path $f -AllowedExtensions @('.txt', '.log')
            if (-not $v.Valid) { Show-FslUiMessage $v.Reason 'FSL Master' 'Warning'; return }
            Write-FslFileUtf8 -Path $v.Path -Content ($lines -join "`r`n")
            Write-FslLog -Level ACTION -Message "Logfragment geëxporteerd: $($v.Path) ($($lines.Count) regels)"
            $script:Ui.TxtStatus.Text = "Logfragment geschreven: $($v.Path)"
        } catch { Show-FslUiError -Short "Exporteren mislukt: $($_.Exception.Message)" -Detail ($_ | Out-String) }
    })
# health + report
$script:Ui.BtnHealthCsv.Add_Click({ Invoke-FslUiExport -GridName 'GridHealth' -Format csv -Title 'Health check' -BaseName 'fslogix-health' })
$script:Ui.BtnHealthCopy.Add_Click({ Copy-FslUiText -Text (Get-FslUiGridText 'GridHealth') })
$script:Ui.BtnRepHtml.Add_Click({ Invoke-FslUiReport -Format html })
$script:Ui.BtnRepJson.Add_Click({ Invoke-FslUiReport -Format json })
$script:Ui.BtnRepCsv.Add_Click({ Invoke-FslUiReport -Format csv })
$script:Ui.BtnRepTxt.Add_Click({ Invoke-FslUiReport -Format txt })

# unexpected exceptions on the UI thread: log, show short message + copyable details, keep running
$win.Dispatcher.Add_UnhandledException({
        $ex = $args[1].Exception
        $args[1].Handled = $true
        Write-FslLog -Level ERROR -Message 'Onverwachte exceptie in de UI' -Exception $ex
        try { Show-FslUiError -Short 'Er is een onverwachte fout opgetreden. De applicatie blijft draaien.' -Detail ($ex | Out-String) } catch { }
    })
$win.Add_Closing({ try { $script:AutoTimer.Stop(); $script:JobTimer.Stop(); Write-FslLog -Level INFO -Message 'Applicatie afgesloten' } catch { } })

# ---------------------------------------------------------------- developer screenshot mode
function Invoke-FslUiDoEvents { $win.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Background, [Action]{ }) }
function Wait-FslUiIdle { param([int]$Ms = 600) $t = [Diagnostics.Stopwatch]::StartNew(); while ($t.ElapsedMilliseconds -lt $Ms -or $script:Jobs.Count -gt 0) { Invoke-FslUiDoEvents; Start-Sleep -Milliseconds 40; if ($t.Elapsed.TotalSeconds -gt 20) { break } } }
function Save-FslUiScreenshot {
    param([string]$Path)
    $w = $script:Ui.MainWin
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$w.ActualWidth, [int]$w.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($w)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    [void]$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($Path); $enc.Save($fs); $fs.Close()
}
if ($CaptureScreenshots) {
    New-Item -ItemType Directory -Force -Path $CaptureScreenshots | Out-Null
    $script:AfterFirstRefresh = {
        $i = 0
        foreach ($nav in 'NavDashboard', 'NavConfig', 'NavServices', 'NavSessions', 'NavContainers', 'NavEvents', 'NavLogs', 'NavHealth', 'NavReport', 'NavAbout') {
            $i++
            $script:Ui[$nav].IsChecked = $true
            Wait-FslUiIdle -Ms 700
            Save-FslUiScreenshot -Path (Join-Path $CaptureScreenshots ('{0:D2}-{1}.png' -f $i, $nav.Substring(3).ToLower()))
        }
        Set-FslUiTheme -Name Light; $script:Ui.NavDashboard.IsChecked = $true; Wait-FslUiIdle -Ms 700
        Save-FslUiScreenshot -Path (Join-Path $CaptureScreenshots '11-dashboard-light.png')
        $script:Ui.NavHealth.IsChecked = $true; Wait-FslUiIdle -Ms 700
        Save-FslUiScreenshot -Path (Join-Path $CaptureScreenshots '12-health-light.png')
        Write-FslLog -Level INFO -Message "Screenshots geschreven naar $CaptureScreenshots"
        $win.Close()
    }
}

# ---------------------------------------------------------------- go
$win.Add_ContentRendered({
        if ($script:UiStarted) { return }
        $script:UiStarted = $true
        # defaults from the local config file (period first, before the change handlers are armed)
        foreach ($it in $script:Ui.CmbPeriod.Items) { if ("$($it.Tag)" -eq "$($script:Config.LookbackHours)") { $script:Ui.CmbPeriod.SelectedItem = $it } }
        $script:UiReady = $true
        foreach ($it in $script:Ui.CmbAuto.Items) { if ("$($it.Tag)" -eq "$($script:Config.AutoRefreshSeconds)") { $script:Ui.CmbAuto.SelectedItem = $it } }
        Start-FslUiRefresh
    })
[void]$win.ShowDialog()
exit 0
