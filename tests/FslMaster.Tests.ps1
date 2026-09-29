# Pester tests for the FSL Master data layer (Pester 3.4+ compatible syntax; also runs under Pester 4).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path (Split-Path -Parent $here) 'src'
foreach ($f in 'Core\Core.ps1', 'Collectors\SystemInfo.ps1', 'Collectors\FSLogix.ps1', 'Collectors\Sessions.ps1', 'Collectors\Containers.ps1', 'Collectors\Events.ps1', 'Collectors\Health.ps1', 'Collectors\Collect.ps1', 'Export\Report.ps1') {
    . (Join-Path $src $f)
}

Describe 'Administrator detection' {
    Context 'ctx' {
        It 'returns true when the principal is in the Administrator role' {
            $fake = New-Object psobject
            $fake | Add-Member -MemberType ScriptMethod -Name IsInRole -Value { param($r) $true }
            Mock Get-FslCurrentPrincipal { $fake }
            Test-FslIsAdministrator | Should Be $true
        }
    }
    Context 'ctx' {
        It 'returns false when the principal is not an administrator' {
            $fake = New-Object psobject
            $fake | Add-Member -MemberType ScriptMethod -Name IsInRole -Value { param($r) $false }
            Mock Get-FslCurrentPrincipal { $fake }
            Test-FslIsAdministrator | Should Be $false
        }
    }
    Context 'ctx' {
        It 'returns false (no crash) when the check throws' {
            Mock Get-FslCurrentPrincipal { throw 'boom' }
            Test-FslIsAdministrator | Should Be $false
        }
    }
}

Describe 'FSLogix installation and frx.exe detection' {
    Context 'ctx' {
        It 'finds frx.exe through an explicit candidate' {
            $p = Join-Path $TestDrive 'frx.exe'
            Set-Content -LiteralPath $p -Value 'x'
            Mock Get-FslRegistryValue { $null }
            Get-FslFrxPath -ExtraCandidates @($p) | Should Be $p
        }
    }
    Context 'ctx' {
        It 'returns null when frx.exe does not exist anywhere' {
            Mock Get-FslRegistryValue { $null }
            Mock Get-Command { $null }
            $old = $env:ProgramFiles; $old86 = ${env:ProgramFiles(x86)}
            try {
                $env:ProgramFiles = Join-Path $TestDrive 'nope'; ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'nope86'
                Get-FslFrxPath | Should BeNullOrEmpty
            } finally { $env:ProgramFiles = $old; ${env:ProgramFiles(x86)} = $old86 }
        }
    }
    Context 'ctx' {
        It 'reports Installed = false without crashing when FSLogix is missing' {
            Mock Get-FslRegistryValue { $null }
            Mock Get-FslFrxPath { $null }
            Mock Get-FslInstalledProduct { $null }
            Mock Get-Service { $null }
            Mock Test-Path { $false }
            $i = Get-FslInstallInfo
            $i.Installed | Should Be $false
        }
    }
    Context 'ctx' {
        It 'reports Installed = true when the install folder exists' {
            $dir = Join-Path $TestDrive 'FSLogix\Apps'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'frx.exe') -Value 'x'
            Mock Get-FslRegistryValue { if ($Name -eq 'InstallPath') { [pscustomobject]@{ Value = $dir; Kind = 'String' } } else { $null } }
            Mock Get-FslInstalledProduct { $null }
            Mock Get-Service { $null }
            $i = Get-FslInstallInfo
            $i.Installed | Should Be $true
            $i.FrxPath | Should Be (Join-Path $dir 'frx.exe')
        }
    }
    Context 'ctx' {
        It 'service info does not crash and marks services N/A when FSLogix is absent' {
            # isolate from the real host (this machine may have FSLogix installed)
            Mock Get-CimInstance { @() }
            Mock Get-Process { @() }
            $rows = Get-FslServiceInfo -Install ([pscustomobject]@{ Installed = $false; InstallDir = $null }) -ConfigLookup @{}
            @($rows | Where-Object { $_.Kind -eq 'Installation' }).Count | Should Be 1
            (@($rows | Where-Object { $_.Name -eq 'frxsvc' })[0]).Status | Should Be 'NA'
        }
    }
}

Describe 'Registry reading and policy priority' {
    $key = 'HKCU:\Software\FslMasterTest'
    Context 'ctx' {
        It 'reads existing and missing values' {
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name 'Enabled' -Value 1 -PropertyType DWord -Force | Out-Null
            try {
                (Get-FslRegistryValue -Path $key -Name 'Enabled').Value | Should Be 1
                Get-FslRegistryValue -Path $key -Name 'Missing' | Should BeNullOrEmpty
                Get-FslRegistryValue -Path 'HKCU:\Software\FslMasterDoesNotExist' -Name 'x' | Should BeNullOrEmpty
            } finally { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    Context 'ctx' {
        It 'policy value wins over the local value and flags a conflict' {
            Mock Get-FslRegistryValue {
                if ($Path -like '*Policies*') { [pscustomobject]@{ Value = 1; Kind = 'DWord' } } else { [pscustomobject]@{ Value = 0; Kind = 'DWord' } }
            }
            $e = Get-FslEffectiveSetting -Scope 'Profiles' -Name 'Enabled'
            $e.Source | Should Be 'Policy'
            $e.Value | Should Be 1
            $e.Conflict | Should Be $true
            $e.Path | Should Be 'HKLM:\SOFTWARE\Policies\FSLogix\Profiles'
        }
    }
    Context 'ctx' {
        It 'falls back to the local value without policy' {
            Mock Get-FslRegistryValue { if ($Path -notlike '*Policies*') { [pscustomobject]@{ Value = 'x'; Kind = 'String' } } else { $null } }
            $e = Get-FslEffectiveSetting -Scope 'Profiles' -Name 'VHDLocations'
            $e.Source | Should Be 'Local'
            $e.Conflict | Should Be $false
        }
    }
    Context 'ctx' {
        It 'reports NotConfigured when nothing is set' {
            Mock Get-FslRegistryValue { $null }
            (Get-FslEffectiveSetting -Scope 'ODFC' -Name 'Enabled').Source | Should Be 'NotConfigured'
        }
    }
    Context 'ctx' {
        It 'builds a full configuration without any FSLogix registry keys' {
            Mock Get-FslRegistryValue { $null }
            Mock Get-FslRegistryValues { @() }
            Mock Get-FslLocalGroupMembers { @() }
            $c = Get-FslConfiguration
            $c.Rows.Count | Should BeGreaterThan 10
            (@($c.Rows | Where-Object { $_.Name -eq 'Enabled' -and $_.Scope -eq 'Profiles' })[0]).Status | Should Be 'Warning'
            (@($c.Rows | Where-Object { $_.Name -eq 'VolumeType' })[0]).Default | Should Be 'Unknown'
        }
    }
}

Describe 'frx.exe list-redirects parsing' {
    $sample = @"
FSLogix Apps frx.exe
Redirect list:

Session 3  Profile
User SID: S-1-5-21-111111111-222222222-333333333-1105
VHD: \\fs01.contoso.local\profiles\jdoe_S-1-5-21-111111111-222222222-333333333-1105\Profile_jdoe.vhdx
\Device\HarddiskVolume12\ -> C:\Users\jdoe

Session 5  ODFC
User SID: S-1-5-21-111111111-222222222-333333333-1110
VHD: \\fs01.contoso.local\odfc\asmith_S-1-5-21-111111111-222222222-333333333-1110\ODFC_asmith.vhdx
"@
    Context 'ctx' {
        It 'extracts records with SID, session, type and VHD path' {
            $r = @(ConvertFrom-FslFrxRedirects -Text $sample)
            $r.Count | Should Be 2
            $r[0].Sid | Should Be 'S-1-5-21-111111111-222222222-333333333-1105'
            $r[0].SessionId | Should Be 3
            $r[0].RedirectType | Should Be 'Profile'
            $r[0].VhdPath | Should Match 'Profile_jdoe\.vhdx$'
            $r[1].RedirectType | Should Be 'ODFC'
        }
    }
    Context 'ctx' {
        It 'returns nothing for empty output' {
            @(ConvertFrom-FslFrxRedirects -Text '').Count | Should Be 0
        }
    }
    Context 'ctx' {
        It 'returns a clear failure when frx.exe is missing' {
            $r = Invoke-FslFrx -FrxPath (Join-Path $TestDrive 'nofrx.exe') -Arguments @('list-redirects')
            $r.Ok | Should Be $false
        }
    }
}

Describe 'quser output parsing' {
    Context 'ctx' {
        It 'parses English output including a disconnected session' {
            $lines = @(
                ' USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME',
                '>jdoe                  rdp-sxs2309       2  Active          .  9/29/2026 8:01 AM',
                ' asmith                                  4  Disc      1+03:14  9/28/2026 4:12 PM')
            $r = @(ConvertFrom-FslQuserOutput -Lines $lines)
            $r.Count | Should Be 2
            $r[0].User | Should Be 'jdoe'
            $r[0].SessionId | Should Be 2
            $r[0].IsCurrent | Should Be $true
            $r[1].User | Should Be 'asmith'
            $r[1].SessionId | Should Be 4
            $r[1].State | Should Be 'Disc'
            $r[1].Idle.TotalHours | Should BeGreaterThan 26
        }
    }
    Context 'ctx' {
        It 'parses localized (Dutch) headers and states' {
            $lines = @(
                ' GEBRUIKERSNAAM       SESSIENAAM         ID  STATUS  ONBEZET    AANMELDTIJD',
                ' rick                 console             1  Actief   niets  29-9-2026 08:00')
            $r = @(ConvertFrom-FslQuserOutput -Lines $lines)
            $r.Count | Should Be 1
            $r[0].User | Should Be 'rick'
            $r[0].State | Should Be 'Actief'   # localized state text is passed through unchanged
        }
    }
    Context 'ctx' {
        It 'ignores empty input' {
            @(ConvertFrom-FslQuserOutput -Lines @('', $null)).Count | Should Be 0
        }
    }
    Context 'ctx' {
        It 'merges container information into sessions' {
            $s = @([pscustomobject]@{ User = 'jdoe'; Sid = 'S-1-5-21-1-2-3-4'; Status = 'OK'; StatusText = ''; Glyph = ''; ContainerMounted = ''; ContainerType = ''; ContainerPath = ''; VhdFile = ''; ContainerStatus = '' })
            $c = @([pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-4'; User = 'CONTOSO\jdoe'; RedirectType = 'Profile'; ContainerPath = '\\fs\p\a.vhdx'; VhdFile = 'a.vhdx'; Status = 'OK' })
            $r = Merge-FslSessionContainers -Sessions $s -Containers $c -FslogixInstalled $true -ProfilesEnabled $true -ContainerDataAvailable $true
            $r[0].ContainerMounted | Should Be 'Yes'
            $r[0].VhdFile | Should Be 'a.vhdx'
        }
    }
    Context 'ctx' {
        It 'marks containers unknown when FSLogix is not installed' {
            $s = @([pscustomobject]@{ User = 'jdoe'; Sid = 'S-1-5-21-1-2-3-4'; Status = 'OK'; StatusText = ''; Glyph = ''; ContainerMounted = ''; ContainerType = ''; ContainerPath = ''; VhdFile = ''; ContainerStatus = '' })
            $r = Merge-FslSessionContainers -Sessions $s -Containers @() -FslogixInstalled $false -ProfilesEnabled $false -ContainerDataAvailable $false
            $r[0].ContainerMounted | Should Be 'Unknown'
        }
    }
}

Describe 'Event log handling' {
    Context 'ctx' {
        It 'lists missing logs and does not throw when no event log exists' {
            Mock Test-FslEventLogExists { $false }
            $r = Get-FslEvents -StartTime (Get-Date).AddHours(-1)
            $r.Rows.Count | Should Be 0
            $r.MissingLogs.Count | Should Be 4
            $r.PresentLogs.Count | Should Be 0
        }
    }
    Context 'ctx' {
        It 'treats "no events found" as empty, not as an error' {
            Mock Test-FslEventLogExists { $true }
            Mock Get-WinEvent { throw (New-Object Exception 'No events were found that match the specified selection criteria.') }
            $r = Get-FslEvents -StartTime (Get-Date).AddHours(-1)
            $r.Errors.Count | Should Be 0
        }
    }
    Context 'ctx' {
        It 'reports a real read failure as an error without throwing' {
            Mock Test-FslEventLogExists { $true }
            Mock Get-WinEvent { throw (New-Object Exception 'Access denied') }
            $r = Get-FslEvents -StartTime (Get-Date).AddHours(-1)
            $r.Errors.Count | Should BeGreaterThan 0
        }
    }
    Context 'ctx' {
        It 'marks configured event IDs' {
            $ev = [pscustomobject]@{ Message = 'x'; LevelDisplayName = 'Error'; Level = 2; ActivityId = $null; TimeCreated = Get-Date; LogName = 'L'; ProviderName = 'Microsoft-FSLogix-Apps'; Id = 26; UserId = $null; Properties = @() }
            (ConvertTo-FslEventRow -Event $ev -MarkedIds @(26) -UserCache @{}).Marked | Should Be $true
            (ConvertTo-FslEventRow -Event $ev -MarkedIds @(99) -UserCache @{}).Marked | Should Be $false
        }
    }
}

Describe 'Pending reboot detection' {
    Context 'ctx' {
        It 'is false when nothing is pending' {
            Mock Test-FslRegistryKey { $false }
            Mock Get-FslRegistryValue { $null }
            (Get-FslPendingReboot).Pending | Should Be $false
        }
    }
    Context 'ctx' {
        It 'detects CBS RebootPending' {
            Mock Test-FslRegistryKey { $Path -like '*RebootPending' }
            Mock Get-FslRegistryValue { $null }
            $r = Get-FslPendingReboot
            $r.Pending | Should Be $true
            $r.Reasons[0] | Should Match 'RebootPending'
        }
    }
    Context 'ctx' {
        It 'detects PendingFileRenameOperations' {
            Mock Test-FslRegistryKey { $false }
            Mock Get-FslRegistryValue { if ($Name -eq 'PendingFileRenameOperations') { [pscustomobject]@{ Value = @('a', 'b'); Kind = 'MultiString' } } else { $null } }
            (Get-FslPendingReboot).Pending | Should Be $true
        }
    }
    Context 'ctx' {
        It 'detects a pending computer rename' {
            Mock Test-FslRegistryKey { $false }
            Mock Get-FslRegistryValue { if ($Path -like '*ActiveComputerName') { [pscustomobject]@{ Value = 'A'; Kind = 'String' } } elseif ($Path -like '*\ComputerName\ComputerName') { [pscustomobject]@{ Value = 'B'; Kind = 'String' } } else { $null } }
            (Get-FslPendingReboot).Pending | Should Be $true
        }
    }
}

Describe 'HTML escaping' {
    Context 'ctx' {
        It 'escapes markup characters' {
            ConvertTo-FslHtmlEncoded '<script>alert("x")&</script>' | Should Be '&lt;script&gt;alert(&quot;x&quot;)&amp;&lt;/script&gt;'
        }
    }
    Context 'ctx' {
        It 'handles null' { ConvertTo-FslHtmlEncoded $null | Should Be '' }
    }
    Context 'ctx' {
        It 'escapes values inside generated tables' {
            $html = ConvertTo-FslHtmlTable -Rows @([pscustomobject]@{ Name = '<b>x</b>' }) -Columns 'Name'
            $html | Should Match '&lt;b&gt;x&lt;/b&gt;'
            $html | Should Not Match '<b>x</b>'
        }
    }
}

Describe 'Health score' {
    function MkR($s, $w = 1) { [pscustomobject]@{ Status = $s; Weight = $w } }
    Context 'ctx' {
        It 'gives 100 when everything is OK' {
            (Get-FslHealthScore -Results @((MkR 'OK'), (MkR 'OK'))).Score | Should Be 100
        }
    }
    Context 'ctx' {
        It 'scores warnings as half and errors as zero' {
            (Get-FslHealthScore -Results @((MkR 'OK'), (MkR 'Warning'))).Score | Should Be 75
            (Get-FslHealthScore -Results @((MkR 'OK'), (MkR 'Error'))).Score | Should Be 50
        }
    }
    Context 'ctx' {
        It 'does not count Unknown or NA as errors' {
            $s = Get-FslHealthScore -Results @((MkR 'OK'), (MkR 'OK'), (MkR 'Unknown'), (MkR 'NA'))
            $s.Score | Should Be 100
            $s.Unknown | Should Be 1
            $s.Total | Should Be 3
        }
    }
    Context 'ctx' {
        It 'returns no score when nothing could be scored' {
            $s = Get-FslHealthScore -Results @((MkR 'Unknown'), (MkR 'NA'))
            $s.Score | Should BeNullOrEmpty
            $s.Status | Should Be 'Unknown'
        }
    }
    Context 'ctx' {
        It 'weights critical checks double' {
            (Get-FslHealthScore -Results @((MkR 'Error' 2), (MkR 'OK' 1))).Score | Should Be 33
        }
    }
    Context 'ctx' {
        It 'flags Error status for a critical failure even with a high score' {
            $r = @(1..9 | ForEach-Object { MkR 'OK' }) + @((MkR 'Error' 2))
            (Get-FslHealthScore -Results $r).Status | Should Be 'Error'
        }
    }
    Context 'ctx' {
        It 'reports Unknown status when coverage is below 50 percent' {
            $s = Get-FslHealthScore -Results @((MkR 'OK'), (MkR 'Unknown'), (MkR 'Unknown'))
            $s.Status | Should Be 'Unknown'
        }
    }
}

Describe 'Sanitizing' {
    $snap = @{
        System = [pscustomobject]@{ ComputerName = 'AVDHOST-01'; Domain = 'contoso.local' }
        Sessions = @([pscustomobject]@{ User = 'jdoe'; Domain = 'CONTOSO'; Sid = 'S-1-5-21-111-222-333-1105' })
        Containers = [pscustomobject]@{ Rows = @([pscustomobject]@{ User = 'CONTOSO\jdoe'; Sid = 'S-1-5-21-111-222-333-1105'; FileServer = 'fs01.contoso.local' }); LocalProfiles = @(); Smb = @() }
        Config = $null; Events = $null
    }
    $ctx = New-FslSanitizeContext -Snapshot $snap
    Context 'ctx' {
        It 'masks user names, SIDs, servers, domains and UNC paths' {
            $text = 'jdoe on AVDHOST-01 at \\fs01.contoso.local\profiles\jdoe_S-1-5-21-111-222-333-1105\p.vhdx CONTOSO\jdoe'
            $out = Protect-FslText -Text $text -Context $ctx
            $out | Should Not Match 'jdoe'
            $out | Should Not Match 'S-1-5-21'
            $out | Should Not Match 'AVDHOST'
            $out | Should Not Match 'contoso'
            $out | Should Match '\\\\SERVER\d+\\SHARE\d+'
        }
    }
    Context 'ctx' {
        It 'is consistent: the same value gets the same placeholder' {
            (Protect-FslText -Text 'jdoe' -Context $ctx) | Should Be (Protect-FslText -Text 'jdoe' -Context $ctx)
        }
    }
    Context 'ctx' {
        It 'sanitizes nested objects' {
            $o = ConvertTo-FslSanitizedObject -Object ([pscustomobject]@{ A = 'jdoe'; B = @('x jdoe'); N = 5 }) -Context $ctx
            $o.A | Should Not Match 'jdoe'
            $o.B[0] | Should Not Match 'jdoe'
            $o.N | Should Be 5
        }
    }
}

Describe 'Export' {
    $rows = @(
        [pscustomobject]@{ User = 'jdoe'; Note = '<b>hi</b>'; Status = 'OK'; StatusText = 'Healthy' },
        [pscustomobject]@{ User = 'asmith'; Note = 'a,b'; Status = 'Error'; StatusText = 'Error' })
    Context 'ctx' {
        It 'exports CSV' {
            $p = Join-Path $TestDrive 'a.csv'
            Export-FslRows -Rows $rows -Properties 'User', 'Note' -Format csv -Path $p | Out-Null
            (Import-Csv -LiteralPath $p).Count | Should Be 2
        }
    }
    Context 'ctx' {
        It 'exports JSON' {
            $p = Join-Path $TestDrive 'a.json'
            Export-FslRows -Rows $rows -Properties 'User', 'Note' -Format json -Path $p | Out-Null
            (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).Count | Should Be 2
        }
    }
    Context 'ctx' {
        It 'exports HTML with escaped content' {
            $p = Join-Path $TestDrive 'a.html'
            Export-FslRows -Rows $rows -Properties 'User', 'Note', 'StatusText' -Format html -Path $p | Out-Null
            $t = Get-Content -LiteralPath $p -Raw
            $t | Should Match '&lt;b&gt;hi&lt;/b&gt;'
            $t | Should Not Match '<b>hi</b>'
        }
    }
    Context 'ctx' {
        It 'rejects invalid export paths and wrong extensions' {
            (Test-FslExportPath -Path 'relative.csv').Valid | Should Be $false
            (Test-FslExportPath -Path (Join-Path $TestDrive 'x?.csv')).Valid | Should Be $false
            (Test-FslExportPath -Path (Join-Path $TestDrive 'x.exe') -AllowedExtensions @('.csv')).Valid | Should Be $false
            (Test-FslExportPath -Path (Join-Path $TestDrive 'nofolder\x.csv')).Valid | Should Be $false
            (Test-FslExportPath -Path (Join-Path $TestDrive 'ok.csv') -AllowedExtensions @('.csv')).Valid | Should Be $true
        }
    }
    Context 'ctx' {
        It 'writes a full report in every format (also sanitized) from a minimal snapshot' {
            $snap = @{
                LookbackHours = 24; Errors = @()
                System = [pscustomobject]@{ ComputerName = 'HOST1'; Domain = 'd'; UptimeText = '1u 2m'; LastBoot = (Get-Date); PendingReboot = $false; ProductName = 'Windows'; DisplayVersion = '24H2'; BuildFull = '26100.1'; LastUpdateTitle = 'KB1'; LastUpdateDate = (Get-Date); Avd = [pscustomobject]@{ AgentVersion = '1'; BootLoaderVersion = '2' } }
                Install = [pscustomobject]@{ Installed = $false; Version = $null; InstallDir = $null; FrxPath = $null }
                Services = @(); Sessions = @(); Containers = $null; Config = $null; Events = $null
                Health = @((New-FslResult -Category 'X' -Check 'c' -Status 'Warning' -Result 'r' -Evidence 'e' -Recommendation 'Doe iets <nu>'))
            }
            $snap.Score = Get-FslHealthScore -Results $snap.Health
            foreach ($fmt in 'html', 'json', 'txt', 'csv') {
                $p = Join-Path $TestDrive "rep.$fmt"
                $w = @(Export-FslReport -Snapshot $snap -Format $fmt -Path $p -Sanitized)
                $w.Count | Should BeGreaterThan 0
                (Test-Path -LiteralPath $w[0]) | Should Be $true
            }
            $html = Get-Content -LiteralPath (Join-Path $TestDrive 'rep.html') -Raw
            $html | Should Match 'Doe iets &lt;nu&gt;'
            $html | Should Not Match 'HOST1'
        }
    }
}

Describe 'Helpers' {
    Context 'ctx' {
        It 'parses UNC paths' {
            $p = Get-FslUncParts '\\fs01\profiles\user\a.vhdx'
            $p.Server | Should Be 'fs01'
            $p.Share | Should Be 'profiles'
            Get-FslUncParts 'C:\x' | Should BeNullOrEmpty
        }
    }
    Context 'ctx' {
        It 'reports Timeout for an unreachable path without hanging' {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Test-FslPathReachable -Path '\\10.255.255.1\share' -TimeoutMs 1500
            $sw.Stop()
            ($r -in 'Timeout', 'Error', 'NotFound') | Should Be $true
            $sw.Elapsed.TotalSeconds | Should BeLessThan 8
        }
    }
    Context 'ctx' {
        It 'extracts UNC locations from VHDLocations and Cloud Cache strings' {
            $l = @(Get-FslLocationsFromValue 'type=smb,connectionString=\\fs1\p1;type=smb,connectionString=\\fs2\p2\sub')
            $l.Count | Should Be 2
            $l[0] | Should Be '\\fs1\p1'
        }
    }
    Context 'ctx' {
        It 'reads a log tail without loading the whole file and detects levels' {
            $p = Join-Path $TestDrive 'Profile_test.log'
            $lines = 1..2000 | ForEach-Object { "[10:00:00.000][tid:0001][INFO:00000000] line $_" }
            $lines += '[10:00:01.000][tid:0001][ERROR:00000005] attach failed for user jdoe'
            Set-Content -LiteralPath $p -Value $lines -Encoding UTF8
            $t = Read-FslLogTail -Path $p -MaxBytes 4096
            $t.Truncated | Should Be $true
            $t.Lines.Count | Should BeLessThan 200
            $sel = @(Select-FslLogLines -Lines $t.Lines -Levels @('ERROR'))
            $sel.Count | Should Be 1
            $sel[0].Text | Should Match 'attach failed'
            @(Select-FslLogLines -Lines $t.Lines -Search 'jdoe' -User 'jdoe').Count | Should Be 1
        }
    }
    Context 'ctx' {
        It 'handles a missing log file gracefully' {
            (Read-FslLogTail -Path (Join-Path $TestDrive 'missing.log')).Error | Should Not BeNullOrEmpty
        }
    }
    Context 'ctx' {
        It 'falls back to defaults for a broken config file' {
            $p = Join-Path $TestDrive 'bad.json'
            Set-Content -LiteralPath $p -Value '{ not json'
            $c = Get-FslConfig -Paths @($p)
            $c.MarkedEventIds -contains 57 | Should Be $true
        }
    }
    Context 'ctx' {
        It 'reads marked event IDs from a config file' {
            $p = Join-Path $TestDrive 'good.json'
            Set-Content -LiteralPath $p -Value '{ "MarkedEventIds": [1, 2, 3], "LookbackHours": 48 }'
            $c = Get-FslConfig -Paths @($p)
            ($c.MarkedEventIds -join ',') | Should Be '1,2,3'
            $c.LookbackHours | Should Be 48
        }
    }
}

Describe 'Health checks and collection with FSLogix absent' {
    Context 'ctx' {
        It 'produces results and a score on a host without FSLogix, without throwing' {
            $data = @{
                Install = [pscustomobject]@{ Installed = $false }
                Config = [pscustomobject]@{ Rows = @(); Lookup = @{}; Groups = @() }
                Services = @(); Sessions = @(); Containers = $null; Events = $null; Volumes = @()
                System = $null
            }
            $r = @(Get-FslHealthChecks -Data $data -Config (Get-FslDefaultConfig))
            $r.Count | Should BeGreaterThan 0
            (Get-FslHealthScore -Results $r) | Should Not BeNullOrEmpty
        }
    }
    Context 'ctx' {
        It 'flags an unreachable configured container location without crashing' {
            $lookup = @{ 'Profiles.VHDLocations' = [pscustomobject]@{ Source = 'Local'; Value = '\\10.255.255.1\profiles' }; 'Profiles.Enabled' = [pscustomobject]@{ Source = 'Local'; Value = 1 } }
            $data = @{
                Install = [pscustomobject]@{ Installed = $true; Version = '2.9'; InstallDir = 'C:\x' }
                Config = [pscustomobject]@{ Rows = @(); Lookup = $lookup; Groups = @() }
                Services = @(); Sessions = @(); Containers = $null; Events = $null; Volumes = @(); System = $null
            }
            $cfg = Get-FslDefaultConfig; $cfg.NetworkTimeoutMs = 1000
            $r = @(Get-FslHealthChecks -Data $data -Config $cfg)
            (@($r | Where-Object { $_.Category -eq 'Network' -and $_.Status -in 'Warning', 'Error' }).Count) | Should BeGreaterThan 0
        }
    }
}

Describe 'Containers with FSLogix present (mocked)' {
    Context 'ctx' {
        It 'builds container rows from frx output, volumes and registry' {
            $sample = "Session 3 Profile`r`nUser SID: S-1-5-21-1-2-3-1105`r`nVHD: \\fs01\profiles\jdoe_S-1-5-21-1-2-3-1105\Profile_jdoe.vhdx"
            Mock Invoke-FslFrx { [pscustomobject]@{ Ok = $true; TimedOut = $false; ExitCode = 0; Output = $sample; Error = $null } }
            Mock Get-FslMountedVhdVolumes { @([pscustomobject]@{ DiskNumber = 1; Label = 'Profile-jdoe'; DriveLetter = 'P'; Path = '\\?\Volume{1}\'; Size = 30GB; Free = 20GB; Health = 'Healthy'; Operational = 'OK'; FileSystem = 'NTFS'; Type = 'Profile'; User = 'jdoe'; Access = '' }) }
            Mock Get-FslSmbConnections { @() }
            Mock Get-FslUserProfiles { @{} }
            Mock Get-FslRegistrySubKeyNames { @() }
            Mock Get-FslAccountForSid { 'CONTOSO\jdoe' }
            Mock Test-FslTcpPort { 'Open' }
            Mock Invoke-FslWithTimeout { [pscustomobject]@{ TimedOut = $false; Result = @([pscustomobject]@{ Length = 5GB; Modified = (Get-Date) }); Error = $null } }
            $r = Get-FslContainers -Install ([pscustomobject]@{ FrxPath = 'C:\frx.exe' })
            $r.Rows.Count | Should Be 1
            $r.Rows[0].User | Should Be 'CONTOSO\jdoe'
            $r.Rows[0].FileServer | Should Be 'fs01'
            $r.Rows[0].Status | Should Be 'OK'
            $r.Rows[0].Volume | Should Match 'P:'
            $r.DataAvailable | Should Be $true
        }
        It 'flags an unreachable file server as warning (time-out) without hanging' {
            Mock Invoke-FslFrx { [pscustomobject]@{ Ok = $true; TimedOut = $false; ExitCode = 0; Output = "SID S-1-5-21-1-2-3-1105 \\fs01\p\a.vhdx"; Error = $null } }
            Mock Get-FslMountedVhdVolumes { @() }
            Mock Get-FslSmbConnections { @() }
            Mock Get-FslUserProfiles { @{} }
            Mock Get-FslRegistrySubKeyNames { @() }
            Mock Get-FslAccountForSid { 'CONTOSO\jdoe' }
            Mock Test-FslTcpPort { 'Timeout' }
            $r = Get-FslContainers -Install ([pscustomobject]@{ FrxPath = 'C:\frx.exe' })
            $r.Rows[0].Network | Should Be 'Timeout'
            $r.Rows[0].Status | Should Be 'Warning'
        }
    }
}

Describe 'Events with FSLogix log present (mocked)' {
    Context 'ctx' {
        It 'returns rows, counts FSLogix errors and marks configured IDs' {
            Mock Test-FslEventLogExists { $Log = $LogName; $LogName -eq 'Microsoft-FSLogix-Apps/Operational' }
            $mk = { param($id, $lvl, $name) [pscustomobject]@{ Message = "msg $id"; LevelDisplayName = $name; Level = $lvl; ActivityId = [guid]::NewGuid(); TimeCreated = Get-Date; LogName = 'Microsoft-FSLogix-Apps/Operational'; ProviderName = 'Microsoft-FSLogix-Apps'; Id = $id; UserId = $null; Properties = @() } }
            $list = @((& $mk 26 2 'Error'), (& $mk 57 3 'Warning'), (& $mk 25 4 'Information'))
            Mock Get-WinEvent { $list }
            $r = Get-FslEvents -StartTime (Get-Date).AddHours(-1) -MarkedIds @(26, 57)
            $r.PresentLogs -contains 'Microsoft-FSLogix-Apps/Operational' | Should Be $true
            $r.Rows.Count | Should Be 3
            $r.ErrorCount | Should Be 1
            $r.WarningCount | Should Be 1
            @($r.Rows | Where-Object { $_.Marked }).Count | Should Be 2
            $r.MissingLogs.Count | Should Be 3
        }
    }
}

Describe 'Health checks with FSLogix present' {
    Context 'ctx' {
        It 'reports OK for a healthy configuration and Error for a stopped frxsvc' {
            $lookup = @{ 'Profiles.Enabled' = [pscustomobject]@{ Source = 'Local'; Value = 1 }; 'Profiles.VHDLocations' = [pscustomobject]@{ Source = 'Local'; Value = 'D:\local' } }
            $mkSvc = { param($state, $st) @([pscustomobject]@{ Kind = 'Service'; Name = 'frxsvc'; State = $state; StartMode = 'Auto'; Status = $st }, [pscustomobject]@{ Kind = 'Driver'; Name = 'frxdrv'; State = 'Running'; StartMode = 'System'; Status = 'OK' }) }
            $base = @{ Install = [pscustomobject]@{ Installed = $true; Version = '2.9'; InstallDir = 'C:\x' }; Config = [pscustomobject]@{ Rows = @(); Lookup = $lookup; Groups = @() }; Sessions = @(); Containers = $null; Events = $null; Volumes = @(); System = $null }
            $ok = @(Get-FslHealthChecks -Data ($base + @{ Services = (& $mkSvc 'Running' 'OK') }) -Config (Get-FslDefaultConfig))
            ($ok | Where-Object { $_.Check -eq 'Service frxsvc running' }).Status | Should Be 'OK'
            ($ok | Where-Object { $_.Check -eq 'Profile Containers enabled' }).Status | Should Be 'OK'
            $bad = @(Get-FslHealthChecks -Data ($base + @{ Services = (& $mkSvc 'Stopped' 'Error') }) -Config (Get-FslDefaultConfig))
            $svc = $bad | Where-Object { $_.Check -eq 'Service frxsvc running' }
            $svc.Status | Should Be 'Error'
            $svc.Weight | Should Be 2
            (Get-FslHealthScore -Results $bad).Status | Should Be 'Error'
        }
    }
}

Describe 'Service actions' {
    Context 'ctx' {
        It 'refuses services other than frxsvc and frxccds' {
            { Invoke-FslServiceAction -Name 'Spooler' -Action 'Stop' } | Should Throw
        }
        It 'reports failure without throwing when the service does not exist' {
            Mock Get-Service { throw 'not found' }
            $r = Invoke-FslServiceAction -Name 'frxsvc' -Action 'Start'
            $r.Success | Should Be $false
        }
    }
}
