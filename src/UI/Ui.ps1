# FSL Master - WPF user interface helpers. All functions here contain "FslUi" so they are NOT injected into background runspaces.
# Runs on the STA UI thread only. Long-running work is done in background runspaces (Start-FslUiJob); results are picked
# up by a DispatcherTimer, so the window never blocks and needs no cross-thread dispatching.

$script:Ui = @{}
$script:Snap = $null
$script:Config = $null
$script:Jobs = New-Object System.Collections.ArrayList
$script:Iss = $null
$script:Sync = $null
$script:Refreshing = $false
$script:RefreshStart = $null
$script:CurrentRows = @{}
$script:GridTables = @{}
$script:LogRaw = @()
$script:LogShown = @()
$script:LogPath = $null
$script:FilterDirty = @{}
$script:PageMap = @{}

function Get-FslUiStatusColor {
    param([string]$Status)
    switch ($Status) { 'OK' { '#2E7D32' } 'Warning' { '#E65100' } 'Error' { '#C62828' } default { '#616161' } }
}

function Get-FslUiBrush {
    param([string]$Hex)
    (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex)
}

# ------------------------------------------------------------------ background jobs
function New-FslUiIss {
    $iss = [initialsessionstate]::CreateDefault()
    try { $iss.ExecutionPolicy = (Get-ExecutionPolicy) } catch { }
    Get-ChildItem -Path Function:\ | Where-Object { $_.Name -match '-Fsl' -and $_.Name -notmatch 'FslUi' } | ForEach-Object {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($_.Name, $_.Definition)))
    }
    $iss
}

function Start-FslUiJob {
    param([scriptblock]$Script, [object[]]$ArgumentList = @(), [scriptblock]$OnDone, [string]$Name = 'job')
    if (-not $script:Iss) { $script:Iss = New-FslUiIss }
    $rs = [runspacefactory]::CreateRunspace($script:Iss.Clone())
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($Script.ToString())
    foreach ($a in $ArgumentList) { $null = $ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    [void]$script:Jobs.Add(@{ PS = $ps; RS = $rs; Handle = $handle; OnDone = $OnDone; Name = $Name })
    Write-FslLog -Level INFO -Message "Background job started: $Name"
}

function Invoke-FslUiJobPoll {
    if ($script:Refreshing -and $script:Sync) {
        $script:Ui.TxtStatus.Text = "Checking: $($script:Sync.Step)"
        $script:Ui.PbRefresh.Value = [double]$script:Sync.Progress
    }
    foreach ($job in @($script:Jobs.ToArray())) {
        if (-not $job.Handle.IsCompleted) { continue }
        [void]$script:Jobs.Remove($job)
        Write-FslLog -Level INFO -Message "Background job finished: $($job.Name)"
        $results = @(); $errs = @()
        try { $results = @($job.PS.EndInvoke($job.Handle)) } catch { $errs += $_.Exception.Message }
        foreach ($e in $job.PS.Streams.Error) { $errs += "$e" }
        try { $job.PS.Dispose(); $job.RS.Dispose() } catch { }
        if ($job.OnDone) {
            try { & $job.OnDone $results $errs } catch {
                Write-FslLog -Level ERROR -Message "Error handling job '$($job.Name)'" -Exception $_
                Show-FslUiError -Short 'An error occurred while processing the results.' -Detail ($_ | Out-String)
            }
        }
    }
}

# ------------------------------------------------------------------ messages and dialogs
function Show-FslUiMessage {
    param([string]$Text, [string]$Title = 'FSL Master', [string]$Icon = 'Information')
    [void][Windows.MessageBox]::Show($Text, $Title, 'OK', $Icon)
}

function Confirm-FslUiAction {
    param([string]$Text, [string]$Title = 'Confirm management action')
    ([Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Warning', 'No') -eq 'Yes')
}

function Copy-FslUiText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    try { [Windows.Clipboard]::SetText($Text) } catch { Start-Sleep -Milliseconds 100; try { [Windows.Clipboard]::SetText($Text) } catch { Show-FslUiMessage 'Copying to the clipboard failed.' 'FSL Master' 'Warning' } }
}

function Show-FslUiTextWindow {
    param([string]$Title, [string]$Text, [string]$Intro = '')
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="820" Height="560" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="Intro" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <TextBox x:Name="Body" Grid.Row="1" IsReadOnly="True" FontFamily="Consolas" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AcceptsReturn="True"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="Copy" Content="Copy" Padding="14,4" Margin="0,0,8,0"/>
      <Button x:Name="Close" Content="Close" Padding="14,4" IsDefault="True"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $w.Title = $Title
    try { $w.Owner = $script:Ui.MainWin } catch { }
    $w.FindName('Intro').Text = $Intro
    $w.FindName('Intro').Visibility = $(if ($Intro) { 'Visible' } else { 'Collapsed' })
    $body = $w.FindName('Body'); $body.Text = $Text
    $w.FindName('Copy').Add_Click({ Copy-FslUiText -Text $body.Text }.GetNewClosure())
    $w.FindName('Close').Add_Click({ $w.Close() }.GetNewClosure())
    [void]$w.ShowDialog()
}

function Show-FslUiError {
    param([string]$Short, [string]$Detail)
    Write-FslLog -Level ERROR -Message $Short -Exception $Detail
    try { Show-FslUiTextWindow -Title 'Error' -Text $Detail -Intro $Short } catch { [void][Windows.MessageBox]::Show($Short, 'FSL Master', 'OK', 'Error') }
}

function Show-FslUiEditWindow {
    param([string]$Title, [string]$Intro, [string]$Initial)
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="520" Height="300" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="Intro" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <TextBox x:Name="Body" Grid.Row="1" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="Ok" Content="Save" Padding="14,4" Margin="0,0,8,0" IsDefault="True"/>
      <Button x:Name="Cancel" Content="Cancel" Padding="14,4" IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $w.Title = $Title
    try { $w.Owner = $script:Ui.MainWin } catch { }
    $w.FindName('Intro').Text = $Intro
    $body = $w.FindName('Body'); $body.Text = $Initial
    $state = @{ Result = $null }
    $w.FindName('Ok').Add_Click({ $state.Result = $body.Text; $w.Close() }.GetNewClosure())
    [void]$w.ShowDialog()
    $state.Result
}

function Get-FslUiSaveFile {
    param([string]$Filter, [string]$DefaultName)
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = $Filter
    $dlg.FileName = $DefaultName
    $dlg.OverwritePrompt = $true
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog($script:Ui.MainWin)) { return $dlg.FileName }
    $null
}

# ------------------------------------------------------------------ data grids
function ConvertTo-FslUiDataTable {
    param($Rows, [string[]]$Properties)
    $dt = New-Object System.Data.DataTable
    $arr = @($Rows | Where-Object { $null -ne $_ })
    foreach ($p in $Properties) {
        $type = [string]
        foreach ($r in $arr) {
            $v = $r.$p
            if ($null -ne $v -and "$v" -ne '') {
                if ($v -is [datetime]) { $type = [datetime] } elseif ($v -is [bool]) { $type = [bool] }
                elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [int64]) { $type = [double] }
                break
            }
        }
        [void]$dt.Columns.Add($p, $type)
    }
    $dt.BeginLoadData()
    foreach ($r in $arr) {
        $row = $dt.NewRow()
        foreach ($p in $Properties) {
            $v = $r.$p
            $col = $dt.Columns[$p]
            if ($null -eq $v -or ($col.DataType -ne [string] -and "$v" -eq '')) { $row[$p] = [DBNull]::Value; continue }
            try {
                if ($col.DataType -eq [string]) { $row[$p] = (Format-FslValue $v) } else { $row[$p] = $v }
            } catch { $row[$p] = [DBNull]::Value }
        }
        [void]$dt.Rows.Add($row)
    }
    $dt.EndLoadData()
    , $dt
}

function New-FslUiStatusColumn {
    param([string]$Header = 'Status', [int]$Width = 135)
    $xaml = @"
<DataGridTemplateColumn xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Header="$Header" Width="$Width" SortMemberPath="StatusText">
  <DataGridTemplateColumn.CellTemplate>
    <DataTemplate>
      <Border CornerRadius="3" Padding="7,1" Margin="0,1" HorizontalAlignment="Left">
        <Border.Style>
          <Style TargetType="Border">
            <Setter Property="Background" Value="#616161"/>
            <Style.Triggers>
              <DataTrigger Binding="{Binding Status}" Value="OK"><Setter Property="Background" Value="#2E7D32"/></DataTrigger>
              <DataTrigger Binding="{Binding Status}" Value="Warning"><Setter Property="Background" Value="#E65100"/></DataTrigger>
              <DataTrigger Binding="{Binding Status}" Value="Error"><Setter Property="Background" Value="#C62828"/></DataTrigger>
            </Style.Triggers>
          </Style>
        </Border.Style>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="{Binding Glyph}" FontFamily="Segoe UI Symbol" Foreground="White" Margin="0,0,5,0"/>
          <TextBlock Text="{Binding StatusText}" Foreground="White" FontWeight="SemiBold"/>
        </StackPanel>
      </Border>
    </DataTemplate>
  </DataGridTemplateColumn.CellTemplate>
</DataGridTemplateColumn>
"@
    [Windows.Markup.XamlReader]::Parse($xaml)
}

function Get-FslUiGridSpecs {
    @{
        GridConfig     = @(
            @{ H = 'Scope'; P = 'Scope'; W = 80 }, @{ H = 'Setting'; P = 'Name'; W = 230 }, @{ H = 'Effective value'; P = 'Value'; W = 260 },
            @{ H = 'Data source'; P = 'Source'; W = 120 }, @{ S = $true; H = 'Assessment'; W = 135 }, @{ H = 'Notes'; P = 'Assessment'; W = 340 },
            @{ H = 'Default'; P = 'Default'; W = 80 }, @{ H = 'Registry path'; P = 'RegistryPath'; W = 320 }, @{ H = 'Description'; P = 'Description'; W = 420 })
        GridServices   = @(
            @{ S = $true; H = 'Status'; W = 135 }, @{ H = 'Type'; P = 'Kind'; W = 80 }, @{ H = 'Name'; P = 'Name'; W = 120 }, @{ H = 'Display name'; P = 'DisplayName'; W = 200 },
            @{ H = 'Status (service)'; P = 'State'; W = 110 }, @{ H = 'Start type'; P = 'StartMode'; W = 90 }, @{ H = 'Version'; P = 'Version'; W = 130 },
            @{ H = 'Process'; P = 'Process'; W = 80 }, @{ H = 'Notes'; P = 'Note'; W = 300 }, @{ H = 'Path'; P = 'Path'; W = 380 })
        GridSessions   = @(
            @{ S = $true; H = 'Status'; W = 135 }, @{ H = 'User'; P = 'User'; W = 130 }, @{ H = 'Domain'; P = 'Domain'; W = 110 }, @{ H = 'SID'; P = 'Sid'; W = 250 },
            @{ H = 'Session ID'; P = 'SessionId'; W = 70 }, @{ H = 'Session state'; P = 'State'; W = 100 }, @{ H = 'Logon time'; P = 'LogonTime'; W = 150; F = 'yyyy-MM-dd HH:mm:ss' },
            @{ H = 'Idle'; P = 'IdleText'; W = 90 }, @{ H = 'Profile path'; P = 'ProfilePath'; W = 260 }, @{ H = 'Profile note'; P = 'ProfileNote'; W = 160 },
            @{ H = 'Container mounted'; P = 'ContainerMounted'; W = 130 }, @{ H = 'Type'; P = 'ContainerType'; W = 90 }, @{ H = 'Container path'; P = 'ContainerPath'; W = 340 },
            @{ H = 'VHD(X) file'; P = 'VhdFile'; W = 200 }, @{ H = 'Container status'; P = 'ContainerStatus'; W = 170 })
        GridContainers = @(
            @{ S = $true; H = 'Status'; W = 135 }, @{ H = 'User'; P = 'User'; W = 150 }, @{ H = 'SID'; P = 'Sid'; W = 240 }, @{ H = 'Session ID'; P = 'SessionId'; W = 70 },
            @{ H = 'Type'; P = 'RedirectType'; W = 80 }, @{ H = 'Container path'; P = 'ContainerPath'; W = 360 }, @{ H = 'VHD(X) file'; P = 'VhdFile'; W = 200 },
            @{ H = 'File server'; P = 'FileServer'; W = 140 }, @{ H = 'Share'; P = 'Share'; W = 110 }, @{ H = 'Size'; P = 'SizeText'; W = 90; M = 'SizeBytes' },
            @{ H = 'Last modified'; P = 'LastWrite'; W = 150; F = 'yyyy-MM-dd HH:mm:ss' }, @{ H = 'Mounted volume'; P = 'Volume'; W = 200 },
            @{ H = 'Volume health'; P = 'VolumeHealth'; W = 100 }, @{ H = 'Network'; P = 'Network'; W = 90 }, @{ H = 'Warnings'; P = 'Warnings'; W = 380 }, @{ H = 'Source'; P = 'Source'; W = 160 })
        GridVolumes    = @(
            @{ H = 'Disk'; P = 'DiskNumber'; W = 50 }, @{ H = 'Label'; P = 'Label'; W = 180 }, @{ H = 'Drive'; P = 'DriveLetter'; W = 60 }, @{ H = 'Type'; P = 'Type'; W = 80 },
            @{ H = 'User'; P = 'User'; W = 140 }, @{ H = 'Size'; P = 'SizeText'; W = 90; M = 'Size' }, @{ H = 'Free'; P = 'FreeText'; W = 90; M = 'Free' },
            @{ H = 'Health'; P = 'Health'; W = 90 }, @{ H = 'Operational'; P = 'Operational'; W = 100 }, @{ H = 'File system'; P = 'FileSystem'; W = 110 }, @{ H = 'Volume path'; P = 'Path'; W = 380 })
        GridSmb        = @(
            @{ H = 'Server'; P = 'Server'; W = 200 }, @{ H = 'Share'; P = 'Share'; W = 160 }, @{ H = 'User'; P = 'UserName'; W = 200 }, @{ H = 'Dialect'; P = 'Dialect'; W = 80 },
            @{ H = 'Open handles'; P = 'NumOpens'; W = 100 }, @{ H = 'Encrypted'; P = 'Encrypted'; W = 90 })
        GridProfiles   = @(
            @{ H = 'User'; P = 'User'; W = 200 }, @{ H = 'SID'; P = 'Sid'; W = 260 }, @{ H = 'Local path'; P = 'LocalPath'; W = 320 }, @{ H = 'Loaded'; P = 'Loaded'; W = 80 },
            @{ H = 'Profile status'; P = 'ProfileStatus'; W = 100 }, @{ H = 'Last used'; P = 'LastUse'; W = 150; F = 'yyyy-MM-dd HH:mm:ss' })
        GridEvents     = @(
            @{ H = 'Time'; P = 'Time'; W = 150; F = 'yyyy-MM-dd HH:mm:ss' }, @{ H = 'Level'; P = 'LevelDisplay'; W = 110; M = 'LevelNumber' }, @{ H = 'ID'; P = 'EventId'; W = 60 },
            @{ H = 'Marked'; P = 'MarkedText'; W = 90 }, @{ H = 'Log'; P = 'LogName'; W = 210 }, @{ H = 'Provider'; P = 'Provider'; W = 190 }, @{ H = 'User/SID'; P = 'User'; W = 160 },
            @{ H = 'Message'; P = 'Summary'; W = 520 }, @{ H = 'Correlation ID'; P = 'Correlation'; W = 250 })
        GridLogFiles   = @(
            @{ H = 'Folder'; P = 'Folder'; W = 90 }, @{ H = 'File'; P = 'Name'; W = 300 }, @{ H = 'Size'; P = 'SizeText'; W = 90; M = 'SizeBytes' }, @{ H = 'Last modified'; P = 'Modified'; W = 160; F = 'yyyy-MM-dd HH:mm:ss' })
        GridLogLines   = @(
            @{ H = '#'; P = 'Number'; W = 60 }, @{ H = 'Level'; P = 'Level'; W = 70 }, @{ H = 'Line'; P = 'Text'; W = 1400 })
        GridHealth     = @(
            @{ H = 'Category'; P = 'Category'; W = 90 }, @{ H = 'Check'; P = 'Check'; W = 260 }, @{ S = $true; H = 'Status'; W = 135 }, @{ H = 'Result'; P = 'Result'; W = 320 },
            @{ H = 'Evidence / data source'; P = 'Evidence'; W = 260 }, @{ H = 'Recommendation'; P = 'Recommendation'; W = 340 }, @{ H = 'Time'; P = 'Time'; W = 140 })
        GridDashIssues = @(
            @{ S = $true; H = 'Status'; W = 135 }, @{ H = 'Category'; P = 'Category'; W = 90 }, @{ H = 'Check'; P = 'Check'; W = 240 }, @{ H = 'Result'; P = 'Result'; W = 340 }, @{ H = 'Recommendation'; P = 'Recommendation'; W = 400 })
    }
}

function Initialize-FslUiGrids {
    $specs = Get-FslUiGridSpecs
    foreach ($name in $specs.Keys) {
        $grid = $script:Ui[$name]
        $grid.Columns.Clear()
        foreach ($c in $specs[$name]) {
            if ($c.S) { [void]$grid.Columns.Add((New-FslUiStatusColumn -Header $c.H -Width $c.W)); continue }
            $col = New-Object Windows.Controls.DataGridTextColumn
            $col.Header = $c.H
            $b = New-Object Windows.Data.Binding($c.P)
            if ($c.F) { $b.StringFormat = $c.F }
            $col.Binding = $b
            if ($c.M) { $col.SortMemberPath = $c.M }
            $col.Width = New-Object Windows.Controls.DataGridLength([double]$c.W)
            [void]$grid.Columns.Add($col)
        }
    }
}

function Set-FslUiGridData {
    param([string]$GridName, $Rows)
    $specs = Get-FslUiGridSpecs
    $props = New-Object System.Collections.Generic.List[string]
    foreach ($c in $specs[$GridName]) {
        if ($c.S) { foreach ($p in 'Status', 'StatusText', 'Glyph') { if (-not $props.Contains($p)) { $props.Add($p) } } }
        else { if (-not $props.Contains($c.P)) { $props.Add($c.P) }; if ($c.M -and -not $props.Contains($c.M)) { $props.Add($c.M) } }
    }
    if ($GridName -in 'GridEvents', 'GridLogLines') { foreach ($p in 'Status', 'Marked', 'Level', 'Message') { if (-not $props.Contains($p) -and $Rows -and @($Rows)[0].PSObject.Properties[$p]) { $props.Add($p) } } }
    if ($GridName -eq 'GridEvents' -and -not $props.Contains('Message')) { $props.Add('Message') }
    $arr = @($Rows | Where-Object { $null -ne $_ })
    $dt = ConvertTo-FslUiDataTable -Rows $arr -Properties $props.ToArray()
    $script:CurrentRows[$GridName] = $arr
    $script:Ui[$GridName].ItemsSource = $dt.DefaultView
}

function Get-FslUiSelectedRows {
    param([string]$GridName)
    $out = @()
    foreach ($i in $script:Ui[$GridName].SelectedItems) { if ($i -is [System.Data.DataRowView]) { $out += $i } }
    $out
}

function Get-FslUiGridText {
    # Selected rows (or all when none selected) as tab separated text with header.
    param([string]$GridName)
    $grid = $script:Ui[$GridName]
    $rows = @(Get-FslUiSelectedRows $GridName)
    if ($rows.Count -eq 0) { $rows = @($grid.Items | Where-Object { $_ -is [System.Data.DataRowView] }) }
    $cols = @($grid.Columns | Where-Object { $_ -is [Windows.Controls.DataGridTextColumn] -or $_ -is [Windows.Controls.DataGridTemplateColumn] })
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((($cols | ForEach-Object { "$($_.Header)" }) -join "`t"))
    foreach ($r in $rows) {
        $vals = foreach ($c in $cols) {
            $p = if ($c -is [Windows.Controls.DataGridTextColumn]) { $c.Binding.Path.Path } else { 'StatusText' }
            $v = $r.Row[$p]; if ($v -is [DBNull]) { '' } else { "$v" }
        }
        $lines.Add(($vals -join "`t"))
    }
    $lines -join "`r`n"
}

function Test-FslUiRowMatch {
    param($Row, [string[]]$Props, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    foreach ($p in $Props) { $v = Format-FslValue $Row.$p; if ($v.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    $false
}

# ------------------------------------------------------------------ dashboard
function New-FslUiCard {
    param([string]$Title, [string]$Value, [string]$Status = 'NA', [string]$Sub = '')
    $color = Get-FslUiStatusColor $Status
    $b = New-Object Windows.Controls.Border
    $b.Width = 262; $b.Margin = New-Object Windows.Thickness(0, 0, 10, 10); $b.Padding = New-Object Windows.Thickness(12, 8, 12, 8)
    $b.CornerRadius = New-Object Windows.CornerRadius(4); $b.BorderThickness = New-Object Windows.Thickness(5, 0, 0, 0)
    $b.BorderBrush = Get-FslUiBrush $color
    $b.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'PanelBrush')
    $sp = New-Object Windows.Controls.StackPanel
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $Title; $t.FontSize = 11
    $t.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MutedBrush')
    $v = New-Object Windows.Controls.TextBlock; $v.Text = $Value; $v.FontSize = 15; $v.FontWeight = 'SemiBold'; $v.TextWrapping = 'Wrap'; $v.Margin = New-Object Windows.Thickness(0, 2, 0, 2)
    $s = New-Object Windows.Controls.TextBlock; $s.FontSize = 11; $s.Foreground = Get-FslUiBrush $color; $s.FontWeight = 'SemiBold'
    if ($Status -eq 'NA') {
        # purely informational card: no verdict to show (colour is grey, extra note as text only)
        $s.Text = $Sub; $s.FontWeight = 'Normal'
        $s.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MutedBrush')
    } else {
        $s.Text = ('{0} {1}' -f (Get-FslStatusGlyph $Status), (Get-FslStatusText $Status))
        if ($Sub) { $s.Text += " - $Sub" }
    }
    [void]$sp.Children.Add($t); [void]$sp.Children.Add($v)
    if ($s.Text) { [void]$sp.Children.Add($s) }
    $b.Child = $sp
    $b.ToolTip = "$Title`: $Value"
    $b
}

function Update-FslUiDashboard {
    $snap = $script:Snap
    $cards = $script:Ui.WpCards
    $cards.Children.Clear()
    if (-not $snap) { return }
    $sys = $snap.System; $inst = $snap.Install
    $installed = [bool]($inst -and $inst.Installed)
    $na = 'Not available'
    $add = { param($t, $v, $s, $sub) [void]$cards.Children.Add((New-FslUiCard -Title $t -Value $v -Status $s -Sub $sub)) }
    & $add 'Computer name' $(if ($sys) { $sys.ComputerName } else { $na }) 'NA' ''
    & $add 'Windows product' $(if ($sys) { $sys.ProductName } else { $na }) $(if ($sys) { 'NA' } else { 'Unknown' }) ''
    & $add 'Windows version' $(if ($sys) { "$($sys.DisplayVersion) ($($sys.Version))" } else { $na }) $(if ($sys) { 'NA' } else { 'Unknown' }) ''
    & $add 'Windows build and UBR' $(if ($sys) { $sys.BuildFull } else { $na }) $(if ($sys) { 'NA' } else { 'Unknown' }) ''
    & $add 'Last cumulative update' $(if ($sys -and $sys.LastUpdateDate) { "$($sys.LastUpdateTitle) ($($sys.LastUpdateDate.ToString('yyyy-MM-dd')))" } else { 'Unknown' }) $(if ($sys -and $sys.LastUpdateDate) { $(if (((Get-Date) - $sys.LastUpdateDate).TotalDays -gt 90) { 'Warning' } else { 'OK' }) } else { 'Unknown' }) ''
    & $add 'Uptime' $(if ($sys) { $sys.UptimeText } else { $na }) $(if ($sys) { $(if ($sys.Uptime.TotalDays -gt 60) { 'Warning' } else { 'OK' }) } else { 'Unknown' }) ''
    & $add 'FSLogix installed' $(if ($installed) { 'Yes' } else { 'No' }) $(if ($installed) { 'OK' } else { 'NA' }) $(if ($installed) { '' } else { 'Not installed' })
    & $add 'FSLogix version' $(if ($installed -and $inst.Version) { $inst.Version } elseif ($installed) { $na } else { 'Not installed' }) $(if ($installed -and $inst.Version) { 'OK' } elseif ($installed) { 'Unknown' } else { 'NA' }) ''
    $svc = @($snap.Services | Where-Object { $_.Name -eq 'frxsvc' }) | Select-Object -First 1
    & $add 'FSLogix service (frxsvc)' $(if ($svc) { $svc.State } else { $na }) $(if ($svc) { $svc.Status } else { 'Unknown' }) ''
    $a = if ($sys) { $sys.Avd } else { $null }
    & $add 'AVD Agent version' $(if ($a -and $a.AgentInstalled) { $a.AgentVersion } else { 'Not installed' }) $(if ($a -and $a.AgentInstalled) { 'OK' } else { 'Unknown' }) ''
    & $add 'AVD Boot Loader version' $(if ($a -and $a.BootLoaderInstalled) { $a.BootLoaderVersion } else { 'Not installed' }) $(if ($a -and $a.BootLoaderInstalled) { 'OK' } else { 'Unknown' }) ''
    $sess = @($snap.Sessions)
    $active = @($sess | Where-Object { $_.State -in 'Active', 'Active' }).Count
    & $add 'Active user sessions' $(if ($null -ne $snap.Sessions) { "$active active ($($sess.Count) total)" } else { $na }) $(if ($null -ne $snap.Sessions) { 'NA' } else { 'Unknown' }) ''
    $cn = if ($snap.Containers) { @($snap.Containers.Rows).Count } else { $null }
    & $add 'Mounted FSLogix containers' $(if ($null -ne $cn -and ($installed -or $cn -gt 0)) { "$cn" } elseif ($installed) { $na } else { 'Not installed' }) $(if ($null -ne $cn -and $installed) { 'NA' } else { 'Unknown' }) ''
    $ev = $snap.Events
    $hoursText = if ($snap.LookbackHours -ge 24) { "$([math]::Round($snap.LookbackHours / 24)) day(s)" } else { "$($snap.LookbackHours) hours" }
    if ($ev -and $ev.PresentLogs.Count -gt 0) {
        $es = if ($ev.ErrorCount -ge 10) { 'Error' } elseif ($ev.ErrorCount -gt 0) { 'Warning' } else { 'OK' }
        & $add "FSLogix errors (last $hoursText)" "$($ev.ErrorCount) error(s), $($ev.WarningCount) warning(s)" $es ''
    } else { & $add "FSLogix errors (last $hoursText)" $(if ($installed) { 'Event log not available' } else { 'Not installed' }) $(if ($installed) { 'Unknown' } else { 'NA' }) '' }
    & $add 'Last refresh' $(if ($snap.Finished) { $snap.Finished.ToString('yyyy-MM-dd HH:mm:ss') } else { $na }) 'NA' ''
    $sc = $snap.Score
    & $add 'Overall health' $(if ($sc -and $null -ne $sc.Score) { "$($sc.Score) / 100" } else { 'Unknown' }) $(if ($sc) { $sc.Status } else { 'Unknown' }) $(if ($sc -and -not $installed) { 'FSLogix not installed' } elseif ($sc) { "coverage $($sc.Coverage)%" } else { '' })

    if (-not $installed) {
        $script:Ui.TxtBanner.Text = 'FSLogix is not installed on this host. Components that require FSLogix are shown as "Not installed" or "Not available"; other Windows, AVD and storage data remain available.'
        $script:Ui.BdrBanner.Visibility = 'Visible'
    } else { $script:Ui.BdrBanner.Visibility = 'Collapsed' }

    $issues = @($snap.Health | Where-Object { $_.Status -in 'Error', 'Warning', 'Unknown' } | Sort-Object @{ e = { switch ($_.Status) { 'Error' { 0 } 'Warning' { 1 } default { 2 } } } })
    Set-FslUiGridData -GridName 'GridDashIssues' -Rows $issues
}

function Update-FslUiHealth {
    $snap = $script:Snap
    if (-not $snap) { return }
    $sc = $snap.Score
    if ($sc -and $null -ne $sc.Score) { $script:Ui.TxtScore.Text = "$($sc.Score)" } else { $script:Ui.TxtScore.Text = '?' }
    $status = if ($sc) { $sc.Status } else { 'Unknown' }
    $script:Ui.TxtScore.Foreground = Get-FslUiBrush (Get-FslUiStatusColor $status)
    $script:Ui.TxtScoreStatus.Text = ('{0} {1}' -f (Get-FslStatusGlyph $status), (Get-FslStatusText $status))
    $script:Ui.TxtScoreStatus.Foreground = Get-FslUiBrush (Get-FslUiStatusColor $status)
    if ($sc) { $script:Ui.TxtScoreDetail.Text = "$($sc.Scored) scored checks, $($sc.Errors) error, $($sc.Warnings) warning, $($sc.Unknown) unknown (not counted as errors). Coverage: $($sc.Coverage)%." }
    $filter = "$($script:Ui.CmbHealthFilter.SelectedItem.Tag)"
    $rows = @($snap.Health)
    switch ($filter) {
        'problems' { $rows = @($rows | Where-Object { $_.Status -in 'Error', 'Warning' }) }
        '' { }
        default { $rows = @($rows | Where-Object { $_.Status -eq $filter }) }
    }
    Set-FslUiGridData -GridName 'GridHealth' -Rows $rows
}

function Update-FslUiConfig {
    $snap = $script:Snap
    if (-not $snap -or -not $snap.Config) { Set-FslUiGridData -GridName 'GridConfig' -Rows @(); return }
    $rows = @($snap.Config.Rows)
    if ($script:Ui.ChkCfgOnlySet.IsChecked) { $rows = @($rows | Where-Object { $_.SourceKey -ne 'NotConfigured' }) }
    $t = $script:Ui.TxtCfgSearch.Text
    if ($t) { $rows = @($rows | Where-Object { Test-FslUiRowMatch $_ @('Scope', 'Name', 'Value', 'Source', 'Assessment', 'Description', 'RegistryPath') $t }) }
    Set-FslUiGridData -GridName 'GridConfig' -Rows $rows
}

function Update-FslUiServices {
    $snap = $script:Snap
    Set-FslUiGridData -GridName 'GridServices' -Rows $(if ($snap) { @($snap.Services) } else { @() })
}

function Update-FslUiSessions {
    $snap = $script:Snap
    $rows = if ($snap) { @($snap.Sessions) } else { @() }
    $t = $script:Ui.TxtSesSearch.Text
    if ($t) { $rows = @($rows | Where-Object { Test-FslUiRowMatch $_ @('User', 'Domain', 'Sid', 'State', 'ProfilePath', 'ContainerPath', 'VhdFile') $t }) }
    Set-FslUiGridData -GridName 'GridSessions' -Rows $rows
    $script:Ui.TxtSesCount.Text = "$($rows.Count) session(s)"
}

function Update-FslUiContainers {
    $snap = $script:Snap
    $c = if ($snap) { $snap.Containers } else { $null }
    $rows = if ($c) { @($c.Rows) } else { @() }
    $t = $script:Ui.TxtCtSearch.Text
    if ($t) { $rows = @($rows | Where-Object { Test-FslUiRowMatch $_ @('User', 'Sid', 'ContainerPath', 'VhdFile', 'FileServer', 'Share', 'Volume', 'Warnings') $t }) }
    Set-FslUiGridData -GridName 'GridContainers' -Rows $rows
    $vols = if ($c) { @($c.Volumes | ForEach-Object { $_ | Select-Object *, @{ n = 'SizeText'; e = { Format-FslBytes $_.Size } }, @{ n = 'FreeText'; e = { Format-FslBytes $_.Free } } }) } else { @() }
    Set-FslUiGridData -GridName 'GridVolumes' -Rows $vols
    Set-FslUiGridData -GridName 'GridSmb' -Rows $(if ($c) { @($c.Smb) } else { @() })
    $profs = if ($c) { @($c.LocalProfiles | ForEach-Object { $_ | Select-Object Sid, User, LocalPath, Loaded, @{ n = 'ProfileStatus'; e = { $_.Status } }, LastUse }) } else { @() }
    Set-FslUiGridData -GridName 'GridProfiles' -Rows $profs
    $script:Ui.TxtFrxRaw.Text = if ($c -and $c.FrxOutput) { $c.FrxOutput } elseif ($c) { "(no output)`r`n$($c.FrxNote)" } else { '' }
    $script:Ui.TxtCtNote.Text = if ($c -and $c.FrxNote) { $c.FrxNote + ' The frx output is parsed by SID/VHD path (best effort); check the raw output when in doubt.' } else { 'The frx output is parsed by SID/VHD path (best effort); check the raw output when in doubt.' }
}

# ------------------------------------------------------------------ events
function Update-FslUiEventLogList {
    $cmb = $script:Ui.CmbEvLog
    $sel = if ($cmb.SelectedItem) { "$($cmb.SelectedItem)" } else { 'All logs' }
    $cmb.Items.Clear()
    [void]$cmb.Items.Add('All logs')
    if ($script:Snap -and $script:Snap.Events) { foreach ($l in $script:Snap.Events.PresentLogs) { [void]$cmb.Items.Add($l) } }
    $idx = $cmb.Items.IndexOf($sel); if ($idx -lt 0) { $idx = 0 }
    $cmb.SelectedIndex = $idx
}

function Update-FslUiEvents {
    $snap = $script:Snap
    $ev = if ($snap) { $snap.Events } else { $null }
    if (-not $ev) { Set-FslUiGridData -GridName 'GridEvents' -Rows @(); $script:Ui.TxtEvCount.Text = ''; $script:Ui.TxtEvNote.Text = 'No event data available.'; return }
    $rows = @($ev.Rows)
    $log = "$($script:Ui.CmbEvLog.SelectedItem)"
    if ($log -and $log -ne 'All logs') { $rows = @($rows | Where-Object { $_.LogName -eq $log }) }
    $ids = @()
    foreach ($p in ($script:Ui.TxtEvId.Text -split '[,; ]+')) { $n = 0; if ([int]::TryParse($p, [ref]$n)) { $ids += $n } }
    if ($ids.Count -gt 0) { $rows = @($rows | Where-Object { $ids -contains $_.EventId }) }
    $e = [bool]$script:Ui.ChkEvError.IsChecked; $w = [bool]$script:Ui.ChkEvWarn.IsChecked; $i = [bool]$script:Ui.ChkEvInfo.IsChecked
    $rows = @($rows | Where-Object { ($e -and $_.LevelNumber -in 1, 2) -or ($w -and $_.LevelNumber -eq 3) -or ($i -and ($_.LevelNumber -ge 4 -or $_.LevelNumber -eq 0)) })
    if ($script:Ui.ChkEvMarked.IsChecked) { $rows = @($rows | Where-Object { $_.Marked }) }
    $u = $script:Ui.TxtEvUser.Text
    if ($u) { $rows = @($rows | Where-Object { Test-FslUiRowMatch $_ @('User') $u }) }
    $s = $script:Ui.TxtEvSearch.Text
    if ($s) { $rows = @($rows | Where-Object { Test-FslUiRowMatch $_ @('Message', 'Provider', 'LogName', 'Correlation', 'EventId') $s }) }
    $shown = @($rows | Select-Object -First 5000 | ForEach-Object {
            $_ | Select-Object *, @{ n = 'LevelDisplay'; e = { '{0} {1}' -f (Get-FslStatusGlyph $(if ($_.LevelNumber -le 2 -and $_.LevelNumber -ge 1) { 'Error' } elseif ($_.LevelNumber -eq 3) { 'Warning' } else { 'OK' })), $_.Level } }
        })
    Set-FslUiGridData -GridName 'GridEvents' -Rows $shown
    $script:Ui.TxtEvCount.Text = "$($rows.Count) event(s)" + $(if ($rows.Count -gt 5000) { ' (first 5000 shown)' } else { '' }) + " since $($ev.Start.ToString('yyyy-MM-dd HH:mm'))"
    $note = ''
    if ($ev.MissingLogs.Count -gt 0) { $note += 'Not present on this host: ' + ($ev.MissingLogs -join ', ') + '. ' }
    $note += 'Marked Event IDs (configurable): ' + ($script:Config.MarkedEventIds -join ', ') + '. The meaning of an ID depends on the provider, log and message text.'
    $script:Ui.TxtEvNote.Text = $note
}

function Show-FslUiEventDetail {
    $rows = @(Get-FslUiSelectedRows 'GridEvents')
    if ($rows.Count -eq 0) { Show-FslUiMessage 'Select an event first.'; return }
    $r = $rows[0].Row
    $text = "Time: $($r['Time'])`r`nLog: $($r['LogName'])`r`nProvider: $($r['Provider'])`r`nEvent ID: $($r['EventId'])`r`nLevel: $($r['Level'])`r`nUser/SID: $($r['User'])`r`nCorrelation ID: $($r['Correlation'])`r`n`r`n$($r['Message'])"
    Show-FslUiTextWindow -Title "Event $($r['EventId'])" -Text $text
}

# ------------------------------------------------------------------ logs
function Update-FslUiLogFileList {
    Start-FslUiJob -Name 'logfiles' -Script { Get-FslLogFiles } -OnDone {
        param($res, $errs)
        $files = @($res | Where-Object { $_.Path })
        $d = $script:Ui.DpLogDate.SelectedDate
        if ($d) { $files = @($files | Where-Object { $_.Modified.Date -eq $d.Date }) }
        Set-FslUiGridData -GridName 'GridLogFiles' -Rows $files
        if (@($res).Count -eq 0) { $script:Ui.TxtLogInfo.Text = 'No FSLogix log files found under C:\ProgramData\FSLogix\Logs (Profile, ODFC, CloudCache).' }
        elseif ($files.Count -gt 0 -and -not $script:LogPath) { $script:Ui.GridLogFiles.SelectedIndex = 0 }
    }
}

function Open-FslUiLogFile {
    $rows = @(Get-FslUiSelectedRows 'GridLogFiles')
    if ($rows.Count -eq 0) { Show-FslUiMessage 'Select a log file first.'; return }
    $path = "$($rows[0].Row['Name'])"
    $folder = "$($rows[0].Row['Folder'])"
    $match = @($script:CurrentRows['GridLogFiles'] | Where-Object { $_.Name -eq $path -and $_.Folder -eq $folder }) | Select-Object -First 1
    if (-not $match) { return }
    $bytes = [int64]("$($script:Ui.CmbLogTail.SelectedItem.Tag)")
    if ($bytes -le 0) { $bytes = 1048576 }
    $script:Ui.TxtLogInfo.Text = "Reading $($match.Name)..."
    $script:LogPath = $match.Path
    Start-FslUiJob -Name 'logread' -ArgumentList @($match.Path, $bytes) -Script { param($p, $b) Read-FslLogTail -Path $p -MaxBytes $b } -OnDone {
        param($res, $errs)
        $r = @($res) | Select-Object -Last 1
        if (-not $r -or $r.Error) { $script:Ui.TxtLogInfo.Text = "Read failed: $(if ($r) { $r.Error } else { $errs -join '; ' })"; $script:LogRaw = @(); Set-FslUiGridData -GridName 'GridLogLines' -Rows @(); return }
        $script:LogRaw = @($r.Lines)
        $script:LogTruncated = $r.Truncated
        $script:LogInfoBase = ('{0}: {1} of {2} read{3}' -f [IO.Path]::GetFileName($script:LogPath), (Format-FslBytes $r.ReadBytes), (Format-FslBytes $r.FileBytes), $(if ($r.Truncated) { ' (end of file only)' } else { '' }))
        Update-FslUiLogView
    }
}

function Update-FslUiLogView {
    if (-not $script:LogRaw -or $script:LogRaw.Count -eq 0) { Set-FslUiGridData -GridName 'GridLogLines' -Rows @(); return }
    $levels = @()
    if ($script:Ui.ChkLogErr.IsChecked) { $levels += 'ERROR' }
    if ($script:Ui.ChkLogWarn.IsChecked) { $levels += 'WARN' }
    if ($script:Ui.ChkLogInfo.IsChecked) { $levels += 'INFO' }
    $args2 = @(, $script:LogRaw) + @($script:Ui.TxtLogSearch.Text, $script:Ui.TxtLogUser.Text, (, $levels))
    Start-FslUiJob -Name 'logfilter' -ArgumentList $args2 -Script { param($lines, $s, $u, $lv) Select-FslLogLines -Lines $lines -Search $s -User $u -Levels $lv -MaxLines 20000 } -OnDone {
        param($res, $errs)
        $rows = @($res)
        $script:LogShown = $rows
        Set-FslUiGridData -GridName 'GridLogLines' -Rows $rows
        $script:Ui.TxtLogInfo.Text = "$($script:LogInfoBase) - $($rows.Count) line(s) shown"
        if ($rows.Count -gt 0) { $script:Ui.GridLogLines.ScrollIntoView($script:Ui.GridLogLines.Items[$script:Ui.GridLogLines.Items.Count - 1]) }
    }
}

# ------------------------------------------------------------------ refresh
function Start-FslUiRefresh {
    if ($script:Refreshing) { return }
    $script:Refreshing = $true
    $script:RefreshStart = Get-Date
    $script:Sync = [hashtable]::Synchronized(@{ Step = 'Starting'; Progress = 0 })
    $script:Ui.BtnRefresh.IsEnabled = $false
    $script:Ui.PbRefresh.Value = 0
    $script:Ui.TxtStatus.Text = 'Checking: starting'
    $hours = 24
    try { $hours = [int]("$($script:Ui.CmbPeriod.SelectedItem.Tag)") } catch { }
    $script:Config.LookbackHours = $hours
    $opts = @{ Config = $script:Config; LookbackHours = $hours }
    Write-FslLog -Level INFO -Message 'Refresh started by user or timer'
    Start-FslUiJob -Name 'refresh' -ArgumentList @($opts, $script:Sync) -Script { param($o, $s) Invoke-FslCollectAll -Options $o -Sync $s } -OnDone {
        param($res, $errs)
        $script:Refreshing = $false
        $script:Ui.BtnRefresh.IsEnabled = $true
        $snap = @($res | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Started') }) | Select-Object -Last 1
        if (-not $snap) {
            $script:Ui.TxtStatus.Text = 'Refresh failed'
            Show-FslUiError -Short 'Collecting data failed.' -Detail ($errs -join "`r`n")
            return
        }
        $script:Snap = $snap
        Update-FslUiAll
        $sec = ((Get-Date) - $script:RefreshStart).TotalSeconds
        $script:Ui.PbRefresh.Value = 100
        $script:Ui.TxtStatus.Text = ('Ready - refresh took {0:N1} s' -f $sec)
        $script:Ui.TxtLast.Text = ('Last refresh: {0} (start {1}, end {2})' -f $snap.Finished.ToString('HH:mm:ss'), $snap.Started.ToString('HH:mm:ss'), $snap.Finished.ToString('HH:mm:ss'))
        $n = @($snap.Errors).Count
        $script:Ui.BtnErrors.Content = "Data source errors ($n)"
        if ($script:AfterFirstRefresh) {
            # developer screenshot hook: must not run inside the timer tick (nested pumping would stall job polling)
            $cb = $script:AfterFirstRefresh; $script:AfterFirstRefresh = $null
            [void]$script:Ui.MainWin.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action]$cb)
        }
    }
}

function Update-FslUiAll {
    Update-FslUiDashboard
    Update-FslUiConfig
    Update-FslUiServices
    Update-FslUiSessions
    Update-FslUiContainers
    Update-FslUiEventLogList
    Update-FslUiEvents
    Update-FslUiHealth
}

function Set-FslUiTheme {
    param([ValidateSet('Dark', 'Light')][string]$Name)
    $p = if ($Name -eq 'Dark') { @{ BgBrush = '#16181D'; PanelBrush = '#1E2128'; Panel2Brush = '#272B34'; TextBrush = '#E8EAED'; MutedBrush = '#9AA0A6'; AccentBrush = '#3B7DD8'; LineBrush = '#3A3F4A' } }
    else { @{ BgBrush = '#F3F4F6'; PanelBrush = '#FFFFFF'; Panel2Brush = '#ECEEF1'; TextBrush = '#1B1D21'; MutedBrush = '#5F6672'; AccentBrush = '#2F6FC4'; LineBrush = '#CFD3DA' } }
    # brushes may be frozen by WPF, so replace the resource objects (DynamicResource references pick up the new brush)
    foreach ($k in $p.Keys) {
        $color = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($p[$k])
        $script:Ui.MainWin.Resources[$k] = [Windows.Media.SolidColorBrush]::new($color)
    }
    $script:Config.Theme = $Name
    if ($script:Snap) { Update-FslUiDashboard; Update-FslUiHealth }
}

function Show-FslUiPage {
    param([string]$Page)
    foreach ($k in $script:PageMap.Keys) { $script:Ui[$script:PageMap[$k]].Visibility = 'Collapsed' }
    $script:Ui[$script:PageMap[$Page]].Visibility = 'Visible'
    if ($Page -eq 'NavLogs' -and $script:Ui.GridLogFiles.Items.Count -eq 0) { Update-FslUiLogFileList }
}

function Invoke-FslUiExport {
    # Generic single-grid export used by several pages.
    param([string]$GridName, [ValidateSet('csv', 'json', 'html')][string]$Format, [string]$Title, [string]$BaseName)
    try {
        $rows = $script:CurrentRows[$GridName]
        if (-not $rows -or @($rows).Count -eq 0) { Show-FslUiMessage 'There is no data to export.'; return }
        $filter = switch ($Format) { 'csv' { 'CSV (*.csv)|*.csv' } 'json' { 'JSON (*.json)|*.json' } default { 'HTML (*.html)|*.html' } }
        $file = Get-FslUiSaveFile -Filter $filter -DefaultName ("$BaseName-$((Get-Date).ToString('yyyyMMdd-HHmm')).$Format")
        if (-not $file) { return }
        $props = @(@($rows)[0].PSObject.Properties.Name | Where-Object { $_ -notin 'Glyph', 'Status', 'Raw', 'Details', 'LevelNumber', 'Marked', 'LevelDisplay' })
        $written = Export-FslRows -Rows $rows -Properties $props -Format $Format -Path $file -Title $Title
        $script:Ui.TxtStatus.Text = "Export written: $written"
    } catch { Show-FslUiError -Short "Export failed: $($_.Exception.Message)" -Detail ($_ | Out-String) }
}

function Invoke-FslUiServiceAction {
    param([ValidateSet('Start', 'Stop', 'Restart')][string]$Action)
    $rows = @(Get-FslUiSelectedRows 'GridServices')
    if ($rows.Count -eq 0) { Show-FslUiMessage 'Select a service first (frxsvc or frxccds).'; return }
    $r = $rows[0].Row
    $name = "$($r['Name'])"
    if ($r['Kind'] -ne 'Service' -or $name -notin 'frxsvc', 'frxccds') { Show-FslUiMessage 'Service actions are only allowed for the services frxsvc and frxccds.' 'FSL Master' 'Warning'; return }
    $impact = if ($Action -ne 'Start') { "`n`nWARNING: stopping or restarting $name can disrupt active user sessions and profile containers." } else { '' }
    if (-not (Confirm-FslUiAction -Text "Are you sure you want to run this service action on '$name': $Action?$impact")) { return }
    $script:Ui.TxtStatus.Text = "Running: $Action $name"
    Start-FslUiJob -Name 'svcaction' -ArgumentList @($name, $Action) -Script { param($n, $a) Invoke-FslServiceAction -Name $n -Action $a } -OnDone {
        param($res, $errs)
        $r = @($res) | Select-Object -Last 1
        if ($r -and $r.Success) { Show-FslUiMessage $r.Message } else { Show-FslUiError -Short 'Service action failed.' -Detail $(if ($r) { $r.Message } else { $errs -join "`r`n" }) }
        Start-FslUiRefresh
    }
}

function Invoke-FslUiReport {
    param([ValidateSet('html', 'json', 'csv', 'txt')][string]$Format)
    if (-not $script:Snap) { Show-FslUiMessage 'Wait until the first refresh has finished.'; return }
    try {
        $sanitize = [bool]$script:Ui.ChkSanitize.IsChecked
        $filter = switch ($Format) { 'html' { 'HTML (*.html)|*.html' } 'json' { 'JSON (*.json)|*.json' } 'csv' { 'CSV (*.csv)|*.csv' } default { 'Text (*.txt)|*.txt' } }
        $file = Get-FslUiSaveFile -Filter $filter -DefaultName ("fsl-master-report$(if ($sanitize) { '-sanitized' })-$((Get-Date).ToString('yyyyMMdd-HHmm')).$Format")
        if (-not $file) { return }
        $written = @(Export-FslReport -Snapshot $script:Snap -Format $Format -Path $file -Sanitized:$sanitize)
        $script:Ui.TxtRepResult.Text = 'Written:' + [Environment]::NewLine + ($written -join [Environment]::NewLine)
    } catch { Show-FslUiError -Short "Report export failed: $($_.Exception.Message)" -Detail ($_ | Out-String) }
}
