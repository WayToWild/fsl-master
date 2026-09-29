# FSL Master - FSLogix installation, services/components, effective configuration.

# ------------------------------------------------------------------ installation
function Get-FslFrxPath {
    param([string[]]$ExtraCandidates = @())
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($c in $ExtraCandidates) { $cands.Add($c) }
    $ip = Get-FslRegistryValue -Path 'HKLM:\SOFTWARE\FSLogix\Apps' -Name 'InstallPath'
    if ($ip -and $ip.Value) { $cands.Add((Join-Path "$($ip.Value)" 'frx.exe')) }
    if ($env:ProgramFiles) { $cands.Add((Join-Path $env:ProgramFiles 'FSLogix\Apps\frx.exe')) }
    if (${env:ProgramFiles(x86)}) { $cands.Add((Join-Path ${env:ProgramFiles(x86)} 'FSLogix\Apps\frx.exe')) }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c } }
    $cmd = Get-Command -Name 'frx.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $null
}

function Get-FslInstallInfo {
    param([string[]]$ExtraCandidates = @())
    $ip = Get-FslRegistryValue -Path 'HKLM:\SOFTWARE\FSLogix\Apps' -Name 'InstallPath'
    $installDir = $null
    if ($ip -and $ip.Value -and (Test-Path -LiteralPath "$($ip.Value)")) { $installDir = "$($ip.Value)" }
    elseif ($env:ProgramFiles -and (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'FSLogix\Apps'))) { $installDir = Join-Path $env:ProgramFiles 'FSLogix\Apps' }
    $frx = Get-FslFrxPath -ExtraCandidates $ExtraCandidates
    $product = Get-FslInstalledProduct -NameLike '*FSLogix*' | Select-Object -First 1
    $version = $null
    if ($installDir) { $version = Get-FslFileVersion (Join-Path $installDir 'frxsvc.exe') }
    if (-not $version -and $frx) { $version = Get-FslFileVersion $frx }
    if (-not $version -and $product) { $version = $product.Version }
    $iv = Get-FslRegistryValue -Path 'HKLM:\SOFTWARE\FSLogix\Apps' -Name 'InstallVersion'
    if (-not $version -and $iv) { $version = "$($iv.Value)" }
    $svc = Get-Service -Name 'frxsvc' -ErrorAction SilentlyContinue
    $installed = [bool]($installDir -or $frx -or $product -or $svc)
    [pscustomobject]@{
        Installed  = $installed
        Version    = $version
        InstallDir = $installDir
        FrxPath    = $frx
        ProductName = $(if ($product) { $product.Name } else { $null })
    }
}

# ------------------------------------------------------------------ services and components
function Get-FslServiceInfo {
    param($Install, $ConfigLookup)
    $rows = New-Object System.Collections.Generic.List[object]
    $cloudCache = $false
    if ($ConfigLookup) {
        foreach ($k in 'Profiles.CCDLocations', 'ODFC.CCDLocations') {
            if ($ConfigLookup.ContainsKey($k) -and $ConfigLookup[$k].Source -ne 'NotConfigured' -and $ConfigLookup[$k].Value) { $cloudCache = $true }
        }
    }
    $profilesEnabled = $false
    if ($ConfigLookup -and $ConfigLookup.ContainsKey('Profiles.Enabled') -and $ConfigLookup['Profiles.Enabled'].Source -ne 'NotConfigured') { $profilesEnabled = ([int]$ConfigLookup['Profiles.Enabled'].Value -eq 1) }
    $installed = ($Install -and $Install.Installed)

    $svcInfo = @{}
    try { Get-CimInstance -ClassName Win32_Service -Filter "Name='frxsvc' OR Name='frxccds'" -ErrorAction Stop | ForEach-Object { $svcInfo[$_.Name] = $_ } } catch { }
    $drvInfo = @{}
    try { Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction Stop | Where-Object { $_.Name -like 'frx*' } | ForEach-Object { $drvInfo[$_.Name] = $_ } } catch { }
    $procs = @{}
    Get-Process -Name 'frxsvc', 'frxccds' -ErrorAction SilentlyContinue | ForEach-Object { $procs[$_.ProcessName.ToLowerInvariant()] = $_ }

    foreach ($name in 'frxsvc', 'frxccds') {
        $s = $svcInfo[$name]
        $status = 'Unknown'; $note = ''
        if (-not $s) {
            if ($installed) { $status = 'Error'; $note = 'Service not found although FSLogix appears to be installed.' } else { $status = 'NA'; $note = 'FSLogix not installed.' }
        } elseif ($s.StartMode -eq 'Disabled') { $status = 'Warning'; $note = 'Service is disabled.' }
        elseif ($s.State -eq 'Running') { $status = 'OK'; $note = 'Running.' }
        elseif ($name -eq 'frxccds') {
            if ($cloudCache) { $status = 'Error'; $note = 'Cloud Cache is configured but the service is not running.' } else { $status = 'NA'; $note = 'Only needed with Cloud Cache.' }
        } else { $status = 'Error'; $note = 'Service is not running.' }
        $path = $null; $ver = $null
        if ($s -and $s.PathName) {
            $path = ($s.PathName -replace '^"([^"]+)".*$', '$1')
            $ver = Get-FslFileVersion $path
        }
        $rows.Add([pscustomobject]@{
            Kind = 'Service'; Name = $name; DisplayName = $(if ($s) { $s.DisplayName } else { '' }); State = $(if ($s) { $s.State } else { 'Not present' })
            StartMode = $(if ($s) { $s.StartMode } else { '' }); Version = $ver; Path = $path
            Process = $(if ($procs.ContainsKey($name)) { "PID $($procs[$name].Id)" } else { '' })
            Status = $status; StatusText = (Get-FslStatusText $status); Glyph = (Get-FslStatusGlyph $status); Note = $note
        })
    }
    foreach ($name in 'frxdrv', 'frxdrvvt', 'frxdrvlt') {
        $d = $drvInfo[$name]
        $status = 'Unknown'; $note = ''
        if (-not $d) {
            if ($installed -and $name -ne 'frxdrvlt') { $status = 'Warning'; $note = 'Driver not found.' } else { $status = 'NA'; $note = 'Not present (not always required).' }
        } elseif ($d.State -eq 'Running') { $status = 'OK'; $note = 'Loaded.' }
        else { $status = 'Warning'; $note = "Driver status: $($d.State)." }
        $path = $null; $ver = $null
        if ($d -and $d.PathName) { $path = ($d.PathName -replace '^\\\?\?\\', '' -replace '^\\SystemRoot', $env:SystemRoot); $ver = Get-FslFileVersion $path }
        $rows.Add([pscustomobject]@{
            Kind = 'Driver'; Name = $name; DisplayName = $(if ($d) { $d.DisplayName } else { '' }); State = $(if ($d) { $d.State } else { 'Not present' })
            StartMode = $(if ($d) { $d.StartMode } else { '' }); Version = $ver; Path = $path; Process = ''
            Status = $status; StatusText = (Get-FslStatusText $status); Glyph = (Get-FslStatusGlyph $status); Note = $note
        })
    }
    if ($Install -and $Install.InstallDir) {
        foreach ($bin in 'frx.exe', 'frxsvc.exe', 'frxccds.exe', 'frxccd.exe', 'frxtray.exe', 'frxshell.exe') {
            $p = Join-Path $Install.InstallDir $bin
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $rows.Add([pscustomobject]@{
                    Kind = 'Binary'; Name = $bin; DisplayName = ''; State = 'Present'; StartMode = ''; Version = (Get-FslFileVersion $p); Path = $p; Process = ''
                    Status = 'OK'; StatusText = (Get-FslStatusText 'OK'); Glyph = (Get-FslStatusGlyph 'OK'); Note = ''
                })
            }
        }
    }
    if (-not $installed) {
        $rows.Add([pscustomobject]@{
            Kind = 'Installation'; Name = 'FSLogix'; DisplayName = ''; State = 'Not installed'; StartMode = ''; Version = ''; Path = ''; Process = ''
            Status = 'NA'; StatusText = (Get-FslStatusText 'NA'); Glyph = (Get-FslStatusGlyph 'NA'); Note = 'FSLogix Apps was not found on this host.'
        })
    }
    $rows.ToArray()
}

function Invoke-FslServiceAction {
    # Local management action. Only the two FSLogix services are allowed. Caller must already have asked for confirmation.
    param([ValidateSet('frxsvc', 'frxccds')][string]$Name, [ValidateSet('Start', 'Stop', 'Restart')][string]$Action)
    Write-FslLog -Level ACTION -Message "Service action started: $Action $Name"
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        switch ($Action) {
            'Start' { if ($svc.Status -ne 'Running') { Start-Service -Name $Name -ErrorAction Stop } }
            'Stop' { if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction Stop } }
            'Restart' { Restart-Service -Name $Name -Force -ErrorAction Stop }
        }
        $svc.Refresh()
        Write-FslLog -Level ACTION -Message "Service action completed: $Action $Name -> $($svc.Status)"
        return [pscustomobject]@{ Success = $true; Message = "$Action $Name completed (status: $($svc.Status))." }
    } catch {
        Write-FslLog -Level ERROR -Message "Service action failed: $Action $Name" -Exception $_
        return [pscustomobject]@{ Success = $false; Message = $_.Exception.Message }
    }
}

# ------------------------------------------------------------------ configuration
function Get-FslSettingDefinitions {
    # Default = documented Microsoft default; $null means "unknown / not reliably documented" and is shown as such.
    $d = New-Object System.Collections.Generic.List[hashtable]
    $add = { param($scope, $name, $desc, $default) $d.Add(@{ Scope = $scope; Name = $name; Description = $desc; Default = $default }) }
    & $add 'Profiles' 'Enabled' 'Enables (1) or disables (0) FSLogix Profile Containers.' 0
    & $add 'Profiles' 'VHDLocations' 'SMB location(s) where the profile VHD(X) is stored.' $null
    & $add 'Profiles' 'CCDLocations' 'Cloud Cache providers (type=smb/azure,connectionString=...).' $null
    & $add 'Profiles' 'ProfileType' '0 = normal, 1 = RW/RO, 2 = RO/RW, 3 = read-only.' 0
    & $add 'Profiles' 'VolumeType' 'Container format: VHD or VHDX.' $null
    & $add 'Profiles' 'SizeInMBs' 'Maximum size of the container in MB.' 30000
    & $add 'Profiles' 'IsDynamic' '1 = dynamically expanding file, 0 = fixed size.' 1
    & $add 'Profiles' 'DeleteLocalProfileWhenVHDShouldApply' 'Deletes an existing local profile when a container should apply.' 0
    & $add 'Profiles' 'FlipFlopProfileDirectoryName' 'Folder name <username>_<SID> instead of <SID>_<username>.' 0
    & $add 'Profiles' 'PreventLoginWithFailure' 'Blocks sign-in when attaching the container fails.' 0
    & $add 'Profiles' 'PreventLoginWithTempProfile' 'Blocks sign-in when Windows would create a temporary profile.' 0
    & $add 'Profiles' 'LockedRetryCount' 'Number of retries when the container is locked.' 12
    & $add 'Profiles' 'LockedRetryInterval' 'Seconds between retries for a locked container.' 5
    & $add 'Profiles' 'ReAttachIntervalSeconds' 'Seconds between attempts to re-attach a disconnected container.' 10
    & $add 'Profiles' 'ReAttachRetryCount' 'Number of attempts to re-attach a disconnected container.' 60
    & $add 'Profiles' 'RoamIdentity' 'Roams Windows credentials (Credential Manager) in the container.' 0
    & $add 'Profiles' 'IncludeOfficeActivation' 'Includes Office activation data in the container.' 0
    & $add 'Profiles' 'AccessNetworkAsComputerObject' 'Accesses the share as the computer account instead of as the user.' $null
    & $add 'Profiles' 'ConcurrentUserSessions' 'Allows multiple concurrent sessions per user.' $null
    & $add 'Profiles' 'RedirXMLSourceFolder' 'Folder containing redirections.xml.' $null
    & $add 'Profiles' 'ClearCacheOnLogoff' 'Cloud Cache: clears the local cache at sign-out.' $null
    & $add 'Profiles' 'HealthyProvidersRequiredForRegister' 'Cloud Cache: number of healthy providers required to register.' $null
    & $add 'Profiles' 'HealthyProvidersRequiredForUnregister' 'Cloud Cache: number of healthy providers required to unregister.' $null
    & $add 'ODFC' 'Enabled' 'Enables (1) or disables (0) Office Data File Containers (ODFC).' 0
    & $add 'ODFC' 'VHDLocations' 'SMB location(s) for the Office container.' $null
    & $add 'ODFC' 'CCDLocations' 'Cloud Cache providers for the Office container.' $null
    & $add 'ODFC' 'VolumeType' 'Container format: VHD or VHDX.' $null
    & $add 'ODFC' 'SizeInMBs' 'Maximum size of the Office container in MB.' $null
    & $add 'ODFC' 'IsDynamic' '1 = dynamically expanding file.' $null
    & $add 'ODFC' 'FlipFlopProfileDirectoryName' 'Folder name <username>_<SID>.' $null
    & $add 'ODFC' 'IncludeOfficeActivation' 'Includes Office activation data.' $null
    & $add 'ODFC' 'IncludeOneDrive' 'Includes the OneDrive cache.' $null
    & $add 'ODFC' 'IncludeOneNote' 'Includes OneNote data.' $null
    & $add 'ODFC' 'IncludeOutlook' 'Includes Outlook data (OST).' $null
    & $add 'ODFC' 'IncludeOutlookPersonalization' 'Includes Outlook personalization.' $null
    & $add 'ODFC' 'IncludeSharepoint' 'Includes the SharePoint cache.' $null
    & $add 'ODFC' 'IncludeSkype' 'Includes Skype for Business data.' $null
    & $add 'ODFC' 'IncludeTeams' 'Includes Teams data.' $null
    , $d.ToArray()
}

function Get-FslEffectiveSetting {
    # Policy (GPO) wins over the local value; otherwise local; otherwise not configured.
    param([string]$Scope, [string]$Name)
    $polPath = if ($Scope -eq 'Root') { 'HKLM:\SOFTWARE\Policies\FSLogix' } else { "HKLM:\SOFTWARE\Policies\FSLogix\$Scope" }
    $locPath = if ($Scope -eq 'Root') { 'HKLM:\SOFTWARE\FSLogix' } else { "HKLM:\SOFTWARE\FSLogix\$Scope" }
    $pol = Get-FslRegistryValue -Path $polPath -Name $Name
    $loc = Get-FslRegistryValue -Path $locPath -Name $Name
    $source = 'NotConfigured'; $val = $null; $path = $locPath
    if ($pol) { $source = 'Policy'; $val = $pol.Value; $path = $polPath }
    elseif ($loc) { $source = 'Local'; $val = $loc.Value; $path = $locPath }
    $srcText = switch ($source) { 'Policy' { 'Via policy' } 'Local' { 'Local' } default { 'Not configured' } }
    [pscustomobject]@{
        Scope = $Scope; Name = $Name; Source = $source; SourceText = $srcText; Value = $val; Path = $path
        PolicyValue = $(if ($pol) { $pol.Value } else { $null }); LocalValue = $(if ($loc) { $loc.Value } else { $null })
        Conflict = [bool]($pol -and $loc -and ((Format-FslValue $pol.Value) -ne (Format-FslValue $loc.Value)))
    }
}

function Get-FslSettingAssessment {
    param($Def, $Eff, [hashtable]$Lookup)
    $isSet = ($Eff.Source -ne 'NotConfigured')
    $hasValue = $isSet -and -not [string]::IsNullOrWhiteSpace((Format-FslValue $Eff.Value))
    $status = 'NA'; $note = 'Informational (no assessment).'
    $intVal = 0; $isInt = $isSet -and [int]::TryParse((Format-FslValue $Eff.Value), [ref]$intVal)
    $profilesOn = $false
    if ($Lookup.ContainsKey('Profiles.Enabled')) { $e = $Lookup['Profiles.Enabled']; if ($e.Source -ne 'NotConfigured' -and [int]::TryParse((Format-FslValue $e.Value), [ref]$null)) { $profilesOn = ([int](Format-FslValue $e.Value) -eq 1) } }
    $odfcOn = $false
    if ($Lookup.ContainsKey('ODFC.Enabled')) { $e = $Lookup['ODFC.Enabled']; if ($e.Source -ne 'NotConfigured' -and [int]::TryParse((Format-FslValue $e.Value), [ref]$null)) { $odfcOn = ([int](Format-FslValue $e.Value) -eq 1) } }
    switch ("$($Def.Scope).$($Def.Name)") {
        'Profiles.Enabled' {
            if ($isInt -and $intVal -eq 1) { $status = 'OK'; $note = 'Profile Containers are enabled.' }
            else { $status = 'Warning'; $note = 'Profile Containers are not enabled; users will not get an FSLogix profile.' }
        }
        'ODFC.Enabled' {
            if ($isInt -and $intVal -eq 1) { $status = 'OK'; $note = 'ODFC is enabled.' } else { $status = 'NA'; $note = 'ODFC is not enabled (optional).' }
        }
        { $_ -in 'Profiles.VHDLocations', 'ODFC.VHDLocations' } {
            $scopeOn = if ($Def.Scope -eq 'Profiles') { $profilesOn } else { $odfcOn }
            $ccd = $Lookup["$($Def.Scope).CCDLocations"]
            $ccdSet = $ccd -and $ccd.Source -ne 'NotConfigured' -and -not [string]::IsNullOrWhiteSpace((Format-FslValue $ccd.Value))
            if ($hasValue) { $status = 'OK'; $note = 'Container location is configured.' }
            elseif ($scopeOn -and -not $ccdSet) { $status = 'Error'; $note = 'Enabled but neither VHDLocations nor CCDLocations is set.' }
            elseif ($scopeOn -and $ccdSet) { $status = 'NA'; $note = 'Cloud Cache (CCDLocations) is used.' }
            else { $status = 'NA'; $note = 'Not applicable (not enabled).' }
        }
        { $_ -in 'Profiles.CCDLocations', 'ODFC.CCDLocations' } {
            $vhd = $Lookup["$($Def.Scope).VHDLocations"]
            $vhdSet = $vhd -and $vhd.Source -ne 'NotConfigured' -and -not [string]::IsNullOrWhiteSpace((Format-FslValue $vhd.Value))
            if ($hasValue -and $vhdSet) { $status = 'Warning'; $note = 'Both VHDLocations and CCDLocations are set; check which one should be active (Cloud Cache normally takes precedence).' }
            elseif ($hasValue) { $status = 'OK'; $note = 'Cloud Cache is configured.' }
            else { $status = 'NA'; $note = 'Cloud Cache not in use.' }
        }
        'Profiles.PreventLoginWithFailure' { $note = 'Consider 1 so a failed attach does not silently produce temporary profiles (depends on policy).' }
        'Profiles.PreventLoginWithTempProfile' { $note = 'Consider 1 so users cannot work with a temporary profile (depends on policy).' }
    }
    if ($Eff.Conflict -and $status -ne 'Error') {
        $status = 'Warning'
        $note = "Local value ($(Format-FslValue $Eff.LocalValue)) is overridden by policy ($(Format-FslValue $Eff.PolicyValue)). " + $note
    }
    [pscustomobject]@{ Status = $status; Note = $note }
}

function Get-FslLocalGroupMembers {
    param([string]$GroupName)
    try {
        $g = [ADSI]"WinNT://./$GroupName,group"
        $members = @($g.Invoke('Members'))
        foreach ($m in $members) {
            $adsPath = $m.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $m, $null)
            ($adsPath -replace '^WinNT://', '' -replace '/', '\')
        }
    } catch { }
}

function Get-FslConfiguration {
    $lookup = @{}
    $rows = New-Object System.Collections.Generic.List[object]
    $defs = Get-FslSettingDefinitions
    $known = @{}
    foreach ($def in $defs) {
        $eff = Get-FslEffectiveSetting -Scope $def.Scope -Name $def.Name
        $lookup["$($def.Scope).$($def.Name)"] = $eff
        $known["$($def.Scope).$($def.Name)".ToLowerInvariant()] = $true
    }
    foreach ($def in $defs) {
        $eff = $lookup["$($def.Scope).$($def.Name)"]
        $a = Get-FslSettingAssessment -Def $def -Eff $eff -Lookup $lookup
        $valText = if ($eff.Source -eq 'NotConfigured') { '(not configured)' } else { Format-FslValue $eff.Value }
        $defText = if ($null -ne $def.Default) { "$($def.Default)" } else { 'Unknown' }
        $rows.Add([pscustomobject]@{
            Scope = $def.Scope; Name = $def.Name; Value = $valText; Source = $eff.SourceText; SourceKey = $eff.Source
            RegistryPath = $eff.Path; Description = $def.Description; Default = $defText
            LocalValue = (Format-FslValue $eff.LocalValue); PolicyValue = (Format-FslValue $eff.PolicyValue)
            Status = $a.Status; StatusText = (Get-FslStatusText $a.Status); Glyph = (Get-FslStatusGlyph $a.Status); Assessment = $a.Note
        })
    }
    # Any other values below the FSLogix keys (also FSLogix\Apps and the Policies root) are listed so nothing is hidden.
    foreach ($scope in 'Root', 'Profiles', 'ODFC') {
        foreach ($src in @(@{ K = 'Policy'; P = $(if ($scope -eq 'Root') { 'HKLM:\SOFTWARE\Policies\FSLogix' } else { "HKLM:\SOFTWARE\Policies\FSLogix\$scope" }) },
                @{ K = 'Local'; P = $(if ($scope -eq 'Root') { 'HKLM:\SOFTWARE\FSLogix' } else { "HKLM:\SOFTWARE\FSLogix\$scope" }) })) {
            foreach ($v in (Get-FslRegistryValues -Path $src.P)) {
                $key = "$scope.$($v.Name)".ToLowerInvariant()
                if ($known.ContainsKey($key)) { continue }
                $known[$key + '|' + $src.K] = $true
                $rows.Add([pscustomobject]@{
                    Scope = $scope; Name = $v.Name; Value = (Format-FslValue $v.Value); Source = $(if ($src.K -eq 'Policy') { 'Via policy' } else { 'Local' }); SourceKey = $src.K
                    RegistryPath = $src.P; Description = 'Other value (no built-in description).'; Default = 'Unknown'
                    LocalValue = ''; PolicyValue = ''
                    Status = 'NA'; StatusText = (Get-FslStatusText 'NA'); Glyph = (Get-FslStatusGlyph 'NA'); Assessment = 'Informational (no assessment).'
                })
            }
        }
    }
    $groups = @()
    foreach ($g in 'FSLogix Profile Include List', 'FSLogix Profile Exclude List', 'FSLogix ODFC Include List', 'FSLogix ODFC Exclude List') {
        $m = @(Get-FslLocalGroupMembers -GroupName $g)
        $groups += [pscustomobject]@{ Group = $g; Members = $m; MemberText = ($m -join '; '); Count = $m.Count }
        $rows.Add([pscustomobject]@{
            Scope = 'Groups'; Name = $g; Value = $(if ($m.Count -gt 0) { $m -join '; ' } else { '(empty or not present)' }); Source = 'Local group'; SourceKey = 'Group'
            RegistryPath = "Local group '$g'"; Description = 'Inclusion/exclusion of users for FSLogix.'; Default = 'Unknown'
            LocalValue = ''; PolicyValue = ''
            Status = 'NA'; StatusText = (Get-FslStatusText 'NA'); Glyph = (Get-FslStatusGlyph 'NA'); Assessment = "$($m.Count) member(s)."
        })
    }
    [pscustomobject]@{ Rows = $rows.ToArray(); Lookup = $lookup; Groups = $groups }
}
