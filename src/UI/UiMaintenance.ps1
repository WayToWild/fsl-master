# FSL Master - UI for "Host maintenance" and "Windows updates". Function names contain "FslUi": UI thread only.

$script:MaintDt = $null
$script:MaintRunning = $false
$script:MaintSync = $null
$script:MaintRun = $null
$script:MaintStart = $null
$script:UpdStatus = $null
$script:UpdRunning = $false
$script:UpdSync = $null

# ------------------------------------------------------------------ Host maintenance
function Get-FslUiMaintColumnsXaml {
    $ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
    $check = @"
<DataGridTemplateColumn $ns Header="Run" Width="50" SortMemberPath="Selected">
  <DataGridTemplateColumn.CellTemplate><DataTemplate>
    <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0"/>
  </DataTemplate></DataGridTemplateColumn.CellTemplate>
</DataGridTemplateColumn>
"@
    $risk = @"
<DataGridTemplateColumn $ns Header="Risk" Width="95" SortMemberPath="Risk">
  <DataGridTemplateColumn.CellTemplate><DataTemplate>
    <Border CornerRadius="3" Padding="7,1" Margin="0,1" HorizontalAlignment="Left">
      <Border.Style><Style TargetType="Border">
        <Setter Property="Background" Value="#616161"/>
        <Style.Triggers>
          <DataTrigger Binding="{Binding Risk}" Value="None"><Setter Property="Background" Value="#2E7D32"/></DataTrigger>
          <DataTrigger Binding="{Binding Risk}" Value="Low"><Setter Property="Background" Value="#8D6E00"/></DataTrigger>
          <DataTrigger Binding="{Binding Risk}" Value="Medium"><Setter Property="Background" Value="#C62828"/></DataTrigger>
        </Style.Triggers></Style></Border.Style>
      <TextBlock Text="{Binding Risk}" Foreground="White" FontWeight="SemiBold"/>
    </Border>
  </DataTemplate></DataGridTemplateColumn.CellTemplate>
</DataGridTemplateColumn>
"@
    @($check, $risk)
}

function Initialize-FslUiMaintenance {
    $grid = $script:Ui.GridMaintTasks
    $grid.Columns.Clear()
    $cols = Get-FslUiMaintColumnsXaml
    [void]$grid.Columns.Add([Windows.Markup.XamlReader]::Parse($cols[0]))
    [void]$grid.Columns.Add([Windows.Markup.XamlReader]::Parse($cols[1]))
    foreach ($c in @(@{ H = 'Task'; P = 'Name'; W = 260 }, @{ H = 'Category'; P = 'Category'; W = 85 }, @{ H = 'Est. time'; P = 'EstText'; W = 80; M = 'EstMinutes' }, @{ H = 'What it does'; P = 'Description'; W = 900 })) {
        $col = New-Object Windows.Controls.DataGridTextColumn
        $col.Header = $c.H; $col.Binding = New-Object Windows.Data.Binding($c.P); $col.IsReadOnly = $true
        if ($c.M) { $col.SortMemberPath = $c.M }
        $col.Width = New-Object Windows.Controls.DataGridLength([double]$c.W)
        [void]$grid.Columns.Add($col)
    }
    $rows = @(Get-FslMaintenanceCatalog | ForEach-Object { $_ | Select-Object *, @{ n = 'Selected'; e = { $false } }, @{ n = 'EstText'; e = { "~$($_.EstMinutes) min" } } })
    $script:MaintDt = ConvertTo-FslUiDataTable -Rows $rows -Properties @('Selected', 'Id', 'Risk', 'Name', 'Category', 'EstText', 'EstMinutes', 'Description')
    $grid.ItemsSource = $script:MaintDt.DefaultView
    $script:Ui.ChkMaintDry.IsChecked = [bool]$script:Config.MaintDefaultDryRun
    Update-FslUiMaintHistory
}

function Set-FslUiMaintPreset {
    param([string]$Preset)
    $ids = if ($Preset) { @(Get-FslMaintenancePresetIds -Preset $Preset) } else { @() }
    foreach ($r in $script:MaintDt.Rows) { $r['Selected'] = [bool]($ids -contains $r['Id']) }
    $n = @($ids).Count
    $script:Ui.TxtMaintStatus.Text = if ($Preset) { "Preset '$Preset': $n task(s) selected." } else { 'Selection cleared.' }
}

function Get-FslUiMaintSelectedIds {
    @($script:MaintDt.Rows | Where-Object { $_['Selected'] -eq $true } | ForEach-Object { "$($_['Id'])" })
}

function Format-FslUiPreflightText {
    param($Pre)
    $t = New-Object System.Collections.Generic.List[string]
    if ($Pre.Blockers.Count -gt 0) { $t.Add('BLOCKERS (must be fixed first):'); foreach ($b in $Pre.Blockers) { $t.Add("  x $b") }; $t.Add('') }
    if ($Pre.Warnings.Count -gt 0) { $t.Add('Warnings:'); foreach ($w in $Pre.Warnings) { $t.Add("  ! $w") }; $t.Add('') }
    if ($Pre.Info.Count -gt 0) { $t.Add('Info:'); foreach ($i in $Pre.Info) { $t.Add("  - $i") } }
    if ($t.Count -eq 0) { $t.Add('No findings.') }
    $t -join "`r`n"
}

function Start-FslUiMaintPreflight {
    $ids = Get-FslUiMaintSelectedIds
    if ($ids.Count -eq 0) { Show-FslUiMessage 'Select one or more tasks first (or pick a preset).'; return }
    $script:Ui.TxtMaintStatus.Text = 'Running preflight checks...'
    Start-FslUiJob -Name 'maintpreflight' -ArgumentList @(, $ids) -Script { param($ids) Get-FslMaintenancePreflight -TaskIds $ids -Options @{} } -OnDone {
        param($res, $errs)
        $pre = @($res) | Select-Object -Last 1
        $script:Ui.TxtMaintStatus.Text = 'Preflight finished.'
        if (-not $pre) { Show-FslUiError -Short 'Preflight failed.' -Detail ($errs -join "`r`n"); return }
        Show-FslUiTextWindow -Title 'Maintenance preflight' -Intro $(if ($pre.Ok) { 'No blockers. The run may start.' } else { 'The run cannot start until the blockers are fixed.' }) -Text (Format-FslUiPreflightText $pre)
    }
}

function Start-FslUiMaintRun {
    if ($script:MaintRunning) { return }
    $ids = Get-FslUiMaintSelectedIds
    if ($ids.Count -eq 0) { Show-FslUiMessage 'Select one or more tasks first (or pick a preset).'; return }
    $script:Ui.TxtMaintStatus.Text = 'Running preflight checks...'
    $script:Ui.BtnMaintRun.IsEnabled = $false
    Start-FslUiJob -Name 'maintpreflight' -ArgumentList @(, $ids) -Script { param($ids) Get-FslMaintenancePreflight -TaskIds $ids -Options @{} } -OnDone {
        param($res, $errs)
        $script:Ui.BtnMaintRun.IsEnabled = $true
        $pre = @($res) | Select-Object -Last 1
        if (-not $pre) { Show-FslUiError -Short 'Preflight failed.' -Detail ($errs -join "`r`n"); return }
        if (-not $pre.Ok) {
            $script:Ui.TxtMaintStatus.Text = 'Blocked by preflight.'
            Show-FslUiTextWindow -Title 'Maintenance blocked' -Intro 'The run cannot start until the blockers are fixed.' -Text (Format-FslUiPreflightText $pre)
            return
        }
        $ids2 = Get-FslUiMaintSelectedIds
        $dry = [bool]$script:Ui.ChkMaintDry.IsChecked
        $tasks = @(Get-FslMaintenanceCatalog | Where-Object { $ids2 -contains $_.Id })
        $hasRepair = @($tasks | Where-Object { $_.Category -eq 'Repair' }).Count -gt 0
        $lines = ($tasks | ForEach-Object { "  [{0}] {1}  (~{2} min)" -f $_.Risk, $_.Name, $_.EstMinutes }) -join "`n"
        $msg = "Run $($tasks.Count) task(s)?`n`n$lines`n`n"
        $msg += if ($dry) { 'DRY RUN: cleanup and repair tasks only preview; read-only diagnostics still run.' } else { 'LIVE RUN: cleanup tasks will delete old files and repair tasks will modify system files.' }
        if ($pre.Warnings.Count -gt 0) { $msg += "`n`nWarnings:`n" + (($pre.Warnings | ForEach-Object { "  ! $_" }) -join "`n") }
        if ($hasRepair -and -not $dry) { $msg += "`n`nRepair tasks are only recommended in a maintenance window with a recent snapshot/backup." }
        $msg += "`n`nThe host is never rebooted automatically."
        if (-not (Confirm-FslUiAction -Text $msg -Title 'Confirm maintenance run')) { $script:Ui.TxtMaintStatus.Text = 'Cancelled before start.'; return }
        $script:MaintSync = [hashtable]::Synchronized(@{ Cancel = $false; Index = 0; Total = $tasks.Count; TaskName = ''; TaskStart = $null })
        $script:MaintRunning = $true; $script:MaintStart = Get-Date; $script:MaintRun = $null
        $script:Ui.BtnMaintRun.IsEnabled = $false; $script:Ui.BtnMaintCancel.IsEnabled = $true; $script:Ui.PbMaint.Value = 0
        Set-FslUiGridData -GridName 'GridMaintResults' -Rows @()
        $script:Ui.TxtMaintOutput.Text = ''
        $opts = @{ DryRun = $dry; StopOnError = [bool]$script:Ui.ChkMaintStop.IsChecked; Config = $script:Config }
        Write-FslLog -Level ACTION -Message "Maintenance run started from the GUI: $($ids2 -join ', ') (dry run: $dry)"
        Start-FslUiJob -Name 'maintrun' -ArgumentList @($ids2, $opts, $script:MaintSync) -Script { param($ids, $o, $s) Invoke-FslMaintenanceRun -TaskIds $ids -Options $o -Sync $s } -OnDone {
            param($res, $errs)
            $script:MaintRunning = $false
            $script:Ui.BtnMaintRun.IsEnabled = $true; $script:Ui.BtnMaintCancel.IsEnabled = $false; $script:Ui.PbMaint.Value = 100
            $run = @($res | Where-Object { $_.PSObject.Properties['RunId'] }) | Select-Object -Last 1
            if (-not $run) { $script:Ui.TxtMaintStatus.Text = 'Run failed.'; Show-FslUiError -Short 'The maintenance run failed.' -Detail ($errs -join "`r`n"); return }
            $script:MaintRun = $run
            Update-FslUiMaintResults
            Update-FslUiMaintHistory
            $s = if ($run.Aborted) { $run.Aborted } else { "Finished: $($run.Ok) OK, $($run.Warnings) warning(s), $($run.Errors) error(s)$(if ($run.DryRun) { ' (dry run)' })$(if ($run.Cancelled) { ' - cancelled' })" }
            if ($run.RebootRecommended) { $s += ' - REBOOT RECOMMENDED' }
            $script:Ui.TxtMaintStatus.Text = $s
        }
    }
}

function Stop-FslUiMaintRun {
    if (-not $script:MaintRunning -or -not $script:MaintSync) { return }
    if (-not (Confirm-FslUiAction -Title 'Cancel maintenance run' -Text "Cancel the run?`n`nThe running tool is stopped and remaining tasks are skipped. Stopping DISM/SFC mid-way is normally safe, but a reboot is recommended before running them again.")) { return }
    $script:MaintSync.Cancel = $true
    Write-FslLog -Level ACTION -Message 'Maintenance run cancellation requested by the user'
    $script:Ui.TxtMaintStatus.Text = 'Cancelling...'
}

function Update-FslUiMaintProgress {
    # called by the job timer while a run is active
    $s = $script:MaintSync
    if (-not $s -or -not $script:MaintRunning) { return }
    $idx = [int]$s.Index; $tot = [math]::Max(1, [int]$s.Total)
    if ($idx -gt 0) {
        $el = if ($s.TaskStart) { ((Get-Date) - $s.TaskStart).ToString('mm\:ss') } else { '00:00' }
        $script:Ui.TxtMaintStatus.Text = "Running $idx/$tot`: $($s.TaskName) ($el)"
        $script:Ui.PbMaint.Value = [double](100 * ($idx - 1) / $tot)
    }
}

function Update-FslUiMaintResults {
    $run = $script:MaintRun
    $rows = if ($run) { @($run.Results) } else { @() }
    Set-FslUiGridData -GridName 'GridMaintResults' -Rows $rows
    if ($run -and $run.Aborted) { $script:Ui.TxtMaintOutput.Text = $run.Aborted + "`r`n`r`n" + (Format-FslUiPreflightText $run.Preflight) }
}

function Show-FslUiMaintOutput {
    $rows = @(Get-FslUiSelectedRows 'GridMaintResults')
    if ($rows.Count -eq 0 -or -not $script:MaintRun) { return }
    $id = "$($rows[0].Row['Id'])"
    $r = @($script:MaintRun.Results | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    if (-not $r) { return }
    $t = "$($r.Name)  [$($r.StatusText)]  $($r.Duration)`r`n$($r.Summary)"
    if ($r.Recommendation) { $t += "`r`n`r`nRecommendation: $($r.Recommendation)" }
    if ($r.Output) { $t += "`r`n`r`n---- output ----`r`n$($r.Output)" }
    $script:Ui.TxtMaintOutput.Text = $t
}

function Update-FslUiMaintHistory {
    Set-FslUiGridData -GridName 'GridMaintHistory' -Rows @(Get-FslMaintenanceHistory -Max 15 | ForEach-Object { $_ | Select-Object *, @{ n = 'ModeText'; e = { if ($_.DryRun) { 'Dry run' } else { 'Live' } } } })
}

# ------------------------------------------------------------------ Windows updates
function Start-FslUiUpdateCheck {
    param([bool]$Search = $true)
    if ($script:UpdRunning) { return }
    $script:UpdRunning = $true
    $script:UpdSync = [hashtable]::Synchronized(@{ Step = 'Starting' })
    $script:Ui.BtnUpdCheck.IsEnabled = $false
    $script:Ui.TxtUpdInfo.Text = if ($Search) { 'Checking (this can take a minute)...' } else { 'Reading local update information...' }
    Start-FslUiJob -Name 'updatestatus' -ArgumentList @($script:Config, $Search, $script:UpdSync) -Script {
        param($cfg, $doSearch, $sync)
        if ($doSearch) { Get-FslWindowsUpdateStatus -Config $cfg -Search -Sync $sync } else { Get-FslWindowsUpdateStatus -Config $cfg -Sync $sync }
    } -OnDone {
        param($res, $errs)
        $script:UpdRunning = $false
        $script:Ui.BtnUpdCheck.IsEnabled = $true
        $st = @($res | Where-Object { $_.PSObject.Properties['Findings'] }) | Select-Object -Last 1
        if (-not $st) { $script:Ui.TxtUpdInfo.Text = 'Update status failed.'; Show-FslUiError -Short 'Reading the update status failed.' -Detail ($errs -join "`r`n"); return }
        $script:UpdStatus = $st
        Update-FslUiUpdates
    }
}

function Update-FslUiUpdates {
    $st = $script:UpdStatus
    $cards = $script:Ui.WpUpdCards
    $cards.Children.Clear()
    if (-not $st) { return }
    $add = { param($t, $v, $s, $sub) [void]$cards.Children.Add((New-FslUiCard -Title $t -Value $v -Status $s -Sub $sub)) }
    $f = @{}; foreach ($x in $st.Findings) { $f[$x.Check] = $x }
    $stat = { param($name, $default) if ($f.ContainsKey($name)) { $f[$name].Status } else { $default } }
    & $add 'Windows build' "$($st.ProductName) $($st.DisplayVersion) (build $($st.BuildFull))" 'NA' ''
    $lc = $st.Lifecycle
    & $add 'Servicing status of this build' $(if ($lc.Known) { if ($lc.DaysLeft -lt 0) { "$($lc.Name): ended $($lc.EndOfServicing.ToString('yyyy-MM-dd'))" } else { "$($lc.Name): until $($lc.EndOfServicing.ToString('yyyy-MM-dd'))" } } else { 'Not in the reference table' }) (& $stat 'Windows build servicing status' 'Unknown') $(if ($lc.Known -and $lc.DaysLeft -ge 0) { "$($lc.DaysLeft) days left" } else { '' })
    & $add 'Last cumulative update' $(if ($st.LastCu) { "$($st.LastCu.Title) ($($st.LastCu.Date.ToString('yyyy-MM-dd')))" } else { 'Unknown' }) (& $stat 'Last cumulative update' 'Unknown') $(if ($st.LastCu) { "$([int]((Get-Date) - $st.LastCu.Date).TotalDays) days ago" } else { '' })
    if ($st.Search -and $st.Search.Ok) {
        $p = @($st.Search.Updates)
        & $add 'Pending updates' "$($p.Count) pending ($(@($p | Where-Object { $_.Class -in 'Critical', 'Security' }).Count) security/critical)" (& $stat 'Pending quality/security updates' 'Unknown') ''
    } else { & $add 'Pending updates' $(if ($st.Search) { 'Search failed' } else { 'Not checked yet - click Check for updates' }) 'Unknown' '' }
    & $add 'Failed installs (30 days)' $(if ($f.ContainsKey('Failed update installs (30 days)')) { $f['Failed update installs (30 days)'].Result } else { 'Unknown' }) (& $stat 'Failed update installs (30 days)' 'Unknown') ''
    & $add 'Last update check' $(if ($f.ContainsKey('Last successful update check')) { $f['Last successful update check'].Result } else { 'Unknown' }) (& $stat 'Last successful update check' 'Unknown') ''
    & $add 'Update source' $st.Policy.Source 'NA' $(if ($st.Policy.TargetRelease) { "target release $($st.Policy.TargetRelease)" } else { '' })
    $sc = $st.Score
    & $add 'Update health' $(if ($sc -and $null -ne $sc.Score) { "$($sc.Score) / 100" } else { 'Unknown' }) $(if ($sc) { $sc.Status } else { 'Unknown' }) $(if ($sc) { "coverage $($sc.Coverage)%" } else { '' })
    Set-FslUiGridData -GridName 'GridUpdFindings' -Rows @($st.Findings)
    $pend = if ($st.Search -and $st.Search.Ok) { @($st.Search.Updates | Sort-Object @{ e = { switch ($_.Class) { 'Critical' { 0 } 'Security' { 1 } 'Other' { 2 } 'Feature' { 3 } 'Driver' { 4 } default { 5 } } } }) } else { @() }
    Set-FslUiGridData -GridName 'GridUpdPending' -Rows $pend
    Set-FslUiGridData -GridName 'GridUpdHistory' -Rows @($st.History)
    $script:Ui.TxtUpdInfo.Text = if ($st.Search) { if ($st.Search.Ok) { ('Update search completed in {0:N0} s.' -f $st.Search.Seconds) } else { "Update search failed: $($st.Search.Error)" } } else { 'Local information only. Click "Check for updates" to search the update source (read-only).' }
}
