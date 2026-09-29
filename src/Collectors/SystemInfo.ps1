# FSL Master - registry helpers, Windows/host information, AVD agent, pending reboot.

function Get-FslRegistryValue {
    param([string]$Path, [string]$Name)
    try { $key = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $null }
    try {
        if (@($key.GetValueNames()) -contains $Name) {
            return [pscustomobject]@{ Value = $key.GetValue($Name); Kind = [string]$key.GetValueKind($Name) }
        }
    } catch { }
    $null
}

function Get-FslRegistryValues {
    param([string]$Path)
    try { $key = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return @() }
    foreach ($n in $key.GetValueNames()) {
        if ($n -eq '') { continue }
        [pscustomobject]@{ Name = $n; Value = $key.GetValue($n); Kind = [string]$key.GetValueKind($n) }
    }
}

function Get-FslRegistrySubKeyNames {
    param([string]$Path)
    try { return @((Get-Item -LiteralPath $Path -ErrorAction Stop).GetSubKeyNames()) } catch { return @() }
}

function Test-FslRegistryKey {
    param([string]$Path)
    [bool](Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
}

function Get-FslInstalledProduct {
    # Reads Uninstall registry (64 and 32 bit) for products whose DisplayName matches a wildcard.
    param([string]$NameLike)
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($root in $roots) {
        foreach ($sub in (Get-FslRegistrySubKeyNames $root)) {
            $dn = Get-FslRegistryValue -Path "$root\$sub" -Name 'DisplayName'
            if ($dn -and "$($dn.Value)" -like $NameLike) {
                $ver = Get-FslRegistryValue -Path "$root\$sub" -Name 'DisplayVersion'
                [pscustomobject]@{ Name = "$($dn.Value)"; Version = $(if ($ver) { "$($ver.Value)" } else { '' }); Key = "$root\$sub" }
            }
        }
    }
}

function Get-FslFileVersion {
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileVersion }
    } catch { }
    $null
}

function Get-FslPendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]
    if (Test-FslRegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons.Add('Component Based Servicing: RebootPending') }
    if (Test-FslRegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons.Add('Windows Update: RebootRequired') }
    if (Test-FslRegistryKey 'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile') {
        $v = Get-FslRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Updates' -Name 'UpdateExeVolatile'
        if ($v -and [int]$v.Value -ne 0) { $reasons.Add('UpdateExeVolatile') }
    }
    $pfr = Get-FslRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
    if ($pfr -and @($pfr.Value | Where-Object { $_ }).Count -gt 0) { $reasons.Add('PendingFileRenameOperations') }
    $a = Get-FslRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name 'ComputerName'
    $p = Get-FslRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name 'ComputerName'
    if ($a -and $p -and "$($a.Value)" -ne "$($p.Value)") { $reasons.Add('Computer rename pending') }
    [pscustomobject]@{ Pending = ($reasons.Count -gt 0); Reasons = @($reasons) }
}

function Get-FslLastCumulativeUpdate {
    # Newest installed update. Prefers Windows Update history (cumulative titles), falls back to Get-HotFix.
    $best = $null
    try {
        $r = Invoke-FslWithTimeout -TimeoutMs 15000 -ScriptBlock {
            $s = New-Object -ComObject Microsoft.Update.Session
            $searcher = $s.CreateUpdateSearcher()
            $count = $searcher.GetTotalHistoryCount()
            if ($count -gt 0) {
                $searcher.QueryHistory(0, [math]::Min($count, 100)) | Where-Object { $_.ResultCode -eq 2 -and $_.Title -match 'Cumulative|Cumulatieve' } |
                    Sort-Object Date -Descending | Select-Object -First 1 | ForEach-Object { [pscustomobject]@{ Title = $_.Title; Date = $_.Date } }
            }
        }
        $item = $r.Result | Select-Object -First 1
        if ($item) { $best = [pscustomobject]@{ Title = $item.Title; Date = [datetime]$item.Date; Source = 'Windows Update history' } }
    } catch { }
    try {
        $hf = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf -and (-not $best -or [datetime]$hf.InstalledOn -gt $best.Date)) {
            if (-not $best) { $best = [pscustomobject]@{ Title = "$($hf.HotFixID) ($($hf.Description))"; Date = [datetime]$hf.InstalledOn; Source = 'Get-HotFix' } }
        }
    } catch { }
    $best
}

function Get-FslAvdInfo {
    $agent = Get-FslInstalledProduct -NameLike 'Remote Desktop Services Infrastructure Agent*' | Select-Object -First 1
    $boot = Get-FslInstalledProduct -NameLike 'Remote Desktop Agent Boot Loader*' | Select-Object -First 1
    $svcs = @()
    foreach ($n in 'RDAgentBootLoader', 'RdAgent', 'WindowsAzureGuestAgent') {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { $svcs += [pscustomobject]@{ Name = $n; Status = "$($s.Status)"; StartType = "$($s.StartType)" } }
    }
    [pscustomobject]@{
        AgentInstalled      = [bool]$agent
        AgentVersion        = $(if ($agent) { $agent.Version } else { $null })
        BootLoaderInstalled = [bool]$boot
        BootLoaderVersion   = $(if ($boot) { $boot.Version } else { $null })
        Services            = $svcs
    }
}

function Get-FslSystemInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ubr = Get-FslRegistryValue -Path $cv -Name 'UBR'
    $dv = Get-FslRegistryValue -Path $cv -Name 'DisplayVersion'
    if (-not $dv) { $dv = Get-FslRegistryValue -Path $cv -Name 'ReleaseId' }
    $boot = $os.LastBootUpTime
    $uptime = (Get-Date) - $boot
    $cu = Get-FslLastCumulativeUpdate
    $reboot = Get-FslPendingReboot
    $sessionsActive = 0
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    [pscustomobject]@{
        ComputerName     = $env:COMPUTERNAME
        Domain           = $(if ($cs) { $cs.Domain } else { '' })
        ProductName      = $os.Caption
        Version          = $os.Version
        DisplayVersion   = $(if ($dv) { "$($dv.Value)" } else { '' })
        Build            = $os.BuildNumber
        Ubr              = $(if ($ubr) { [int]$ubr.Value } else { $null })
        BuildFull        = $(if ($ubr) { "$($os.BuildNumber).$($ubr.Value)" } else { "$($os.BuildNumber)" })
        LastBoot         = $boot
        Uptime           = $uptime
        UptimeText       = (Format-FslTimeSpan $uptime)
        LastUpdateTitle  = $(if ($cu) { $cu.Title } else { $null })
        LastUpdateDate   = $(if ($cu) { $cu.Date } else { $null })
        PendingReboot    = $reboot.Pending
        PendingRebootReasons = $reboot.Reasons
        Avd              = (Get-FslAvdInfo)
        Collected        = Get-Date
    }
}

function Get-FslLocalVolumes {
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {
            $pct = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { $null }
            [pscustomobject]@{ Drive = $_.DeviceID; Label = $_.VolumeName; FileSystem = $_.FileSystem; Size = [int64]$_.Size; Free = [int64]$_.FreeSpace; FreePercent = $pct }
        }
    } catch { @() }
}
