# Pester tests for the maintenance engine and the Windows update status (Pester 3.4+ syntax).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path (Split-Path -Parent $here) 'src'
foreach ($f in 'Core\Core.ps1', 'Collectors\SystemInfo.ps1', 'Collectors\FSLogix.ps1', 'Collectors\Sessions.ps1', 'Collectors\Health.ps1', 'Collectors\Maintenance.ps1', 'Collectors\Updates.ps1') { . (Join-Path $src $f) }

Describe 'Maintenance catalog' {
    Context 'ctx' {
        It 'has unique ids and valid risk/category values' {
            $c = @(Get-FslMaintenanceCatalog)
            ($c.Id | Select-Object -Unique).Count | Should Be $c.Count
            @($c | Where-Object { $_.Risk -notin 'None', 'Low', 'Medium' }).Count | Should Be 0
            @($c | Where-Object { $_.Category -notin 'Diagnose', 'Cleanup', 'Repair', 'Optimize' }).Count | Should Be 0
        }
        It 'keeps the Diagnostics preset strictly read-only' {
            $ids = Get-FslMaintenancePresetIds -Preset Diagnostics
            $ids.Count | Should BeGreaterThan 3
            @(Get-FslMaintenanceCatalog | Where-Object { $ids -contains $_.Id -and $_.Risk -ne 'None' }).Count | Should Be 0
        }
        It 'keeps repair tasks out of Diagnostics and Routine, and only in Full' {
            foreach ($p in 'Diagnostics', 'Routine') {
                $ids = Get-FslMaintenancePresetIds -Preset $p
                @(Get-FslMaintenanceCatalog | Where-Object { $ids -contains $_.Id -and $_.Category -eq 'Repair' }).Count | Should Be 0
            }
            (Get-FslMaintenancePresetIds -Preset Full) -contains 'repair.dism.restore' | Should Be $true
        }
        It 'never offers dangerous operations' {
            $c = @(Get-FslMaintenanceCatalog | ForEach-Object { "$($_.Id) $($_.Name) $($_.Description)" }) -join ' '
            $c | Should Not Match '(?i)/f\b.*chkdsk|chkdsk /f\b(?! or)|ResetBase\b(?!\))|Clear-EventLog|Remove-Item|Restart-Computer'
        }
        It 'orders DISM repair before SFC repair and diagnostics before repair' {
            $c = @(Get-FslMaintenanceCatalog)
            ($c | Where-Object { $_.Id -eq 'repair.dism.restore' }).Order | Should BeLessThan ($c | Where-Object { $_.Id -eq 'repair.sfc.scannow' }).Order
            ($c | Where-Object { $_.Id -eq 'diag.sfc.verify' }).Order | Should BeLessThan ($c | Where-Object { $_.Id -eq 'repair.dism.restore' }).Order
        }
    }
}

Describe 'Cleanup path whitelist and engine' {
    Context 'ctx' {
        It 'accepts folders inside an allowed root and rejects everything else' {
            $roots = @('C:\Windows\Temp', 'C:\ProgramData\FSLogix\Logs')
            Test-FslCleanupPathAllowed -Path 'C:\Windows\Temp' -AllowedRoots $roots | Should Be $true
            Test-FslCleanupPathAllowed -Path 'C:\Windows\Temp\sub\x' -AllowedRoots $roots | Should Be $true
            Test-FslCleanupPathAllowed -Path 'C:\Windows' -AllowedRoots $roots | Should Be $false
            Test-FslCleanupPathAllowed -Path 'C:\' -AllowedRoots $roots | Should Be $false
            Test-FslCleanupPathAllowed -Path 'C:\Windows\Temp\..\System32' -AllowedRoots $roots | Should Be $false
            Test-FslCleanupPathAllowed -Path 'Temp' -AllowedRoots $roots | Should Be $false
            Test-FslCleanupPathAllowed -Path 'C:\Windows\TempEvil' -AllowedRoots $roots | Should Be $false
            Test-FslCleanupPathAllowed -Path '' -AllowedRoots $roots | Should Be $false
        }
        It 'refuses to touch a path outside the whitelist' {
            $r = Remove-FslOldFiles -Root $TestDrive -AgeDays 1 -AllowedRoots @('C:\Windows\Temp')
            $r.Blocked | Should Be $true
            $r.Files | Should Be 0
        }
        It 'dry run counts old files but deletes nothing' {
            $d = Join-Path $TestDrive 'dry'; New-Item -ItemType Directory -Path $d | Out-Null
            $old = Join-Path $d 'old.tmp'; Set-Content $old 'x'; (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-40)
            $new = Join-Path $d 'new.tmp'; Set-Content $new 'x'
            $r = Remove-FslOldFiles -Root $d -AgeDays 7 -DryRun -AllowedRoots @($TestDrive)
            $r.Files | Should Be 1
            Test-Path $old | Should Be $true
            Test-Path $new | Should Be $true
        }
        It 'deletes only files older than the age and keeps recent ones' {
            $d = Join-Path $TestDrive 'real'; New-Item -ItemType Directory -Path "$d\sub" | Out-Null
            $old = Join-Path $d 'sub\old.tmp'; Set-Content $old 'x'; (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-40)
            $new = Join-Path $d 'new.tmp'; Set-Content $new 'x'
            $r = Remove-FslOldFiles -Root $d -AgeDays 7 -AllowedRoots @($TestDrive)
            $r.Files | Should Be 1
            Test-Path $old | Should Be $false
            Test-Path $new | Should Be $true
            Test-Path $d | Should Be $true
        }
        It 'honours the file filter' {
            $d = Join-Path $TestDrive 'filter'; New-Item -ItemType Directory -Path $d | Out-Null
            $a = Join-Path $d 'a.log'; $b = Join-Path $d 'b.txt'
            Set-Content $a 'x'; Set-Content $b 'x'; (Get-Item $a).LastWriteTime = (Get-Date).AddDays(-40); (Get-Item $b).LastWriteTime = (Get-Date).AddDays(-40)
            $null = Remove-FslOldFiles -Root $d -AgeDays 7 -Filter '*.log' -AllowedRoots @($TestDrive)
            Test-Path $a | Should Be $false
            Test-Path $b | Should Be $true
        }
        It 'does not follow junctions (reparse points)' {
            $target = Join-Path $TestDrive 'target'; New-Item -ItemType Directory -Path $target | Out-Null
            $precious = Join-Path $target 'precious.dat'; Set-Content $precious 'x'; (Get-Item $precious).LastWriteTime = (Get-Date).AddDays(-400)
            $root = Join-Path $TestDrive 'withlink'; New-Item -ItemType Directory -Path $root | Out-Null
            & cmd.exe /c mklink /J "$root\link" "$target" | Out-Null
            $r = Remove-FslOldFiles -Root $root -AgeDays 7 -AllowedRoots @($TestDrive)
            Test-Path $precious | Should Be $true
            $r.Skipped | Should BeGreaterThan 0
            & cmd.exe /c rmdir "$root\link" | Out-Null
        }
        It 'stops when cancelled' {
            $d = Join-Path $TestDrive 'cancel'; New-Item -ItemType Directory -Path $d | Out-Null
            $f = Join-Path $d 'o.tmp'; Set-Content $f 'x'; (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-40)
            $r = Remove-FslOldFiles -Root $d -AgeDays 7 -AllowedRoots @($TestDrive) -Sync @{ Cancel = $true }
            $r.Cancelled | Should Be $true
            Test-Path $f | Should Be $true
        }
    }
}

Describe 'Output interpreters' {
    Context 'ctx' {
        It 'reads DISM CheckHealth results' {
            (ConvertFrom-FslDismOutput -Mode check -Text 'No component store corruption detected.' -ExitCode 0).Status | Should Be 'OK'
            (ConvertFrom-FslDismOutput -Mode check -Text 'The component store is repairable.' -ExitCode 0).Status | Should Be 'Warning'
            (ConvertFrom-FslDismOutput -Mode check -Text 'The component store cannot be repaired.' -ExitCode 0).Status | Should Be 'Error'
            (ConvertFrom-FslDismOutput -Mode check -Text 'iets onbekends' -ExitCode 0).Status | Should Be 'Unknown'
        }
        It 'treats a DISM failure exit code as an error and explains missing source files' {
            $r = ConvertFrom-FslDismOutput -Mode restore -Text 'Error: 0x800f081f The source files could not be found.' -ExitCode 1
            $r.Status | Should Be 'Error'
            $r.Recommendation | Should Match 'source'
        }
        It 'recommends a reboot on exit code 3010' {
            (ConvertFrom-FslDismOutput -Mode cleanup -Text 'The operation completed successfully.' -ExitCode 3010).Reboot | Should Be $true
        }
        It 'reads AnalyzeComponentStore' {
            (ConvertFrom-FslDismOutput -Mode analyze -Text "Actual Size of Component Store : 6.31 GB`r`nComponent Store Cleanup Recommended : Yes" -ExitCode 0).Status | Should Be 'Warning'
            (ConvertFrom-FslDismOutput -Mode analyze -Text 'Component Store Cleanup Recommended : No' -ExitCode 0).Status | Should Be 'OK'
        }
        It 'reads RestoreHealth' {
            $r = ConvertFrom-FslDismOutput -Mode restore -Text 'The restore operation completed successfully. The component store corruption was repaired.' -ExitCode 0
            $r.Status | Should Be 'OK'
            $r.Reboot | Should Be $true
        }
        It 'reads SFC results' {
            (ConvertFrom-FslSfcOutput -Mode verify -Text 'Windows Resource Protection did not find any integrity violations.' -ExitCode 0).Status | Should Be 'OK'
            (ConvertFrom-FslSfcOutput -Mode verify -Text 'Windows Resource Protection found integrity violations.' -ExitCode 0).Status | Should Be 'Warning'
            $rep = ConvertFrom-FslSfcOutput -Mode scan -Text 'Windows Resource Protection found corrupt files and successfully repaired them.' -ExitCode 0
            $rep.Status | Should Be 'OK'; $rep.Reboot | Should Be $true
            (ConvertFrom-FslSfcOutput -Mode scan -Text 'Windows Resource Protection found corrupt files but was unable to fix some of them.' -ExitCode 0).Status | Should Be 'Error'
            (ConvertFrom-FslSfcOutput -Mode scan -Text 'There is a system repair pending which requires reboot to complete.' -ExitCode 0).Status | Should Be 'Warning'
            (ConvertFrom-FslSfcOutput -Mode scan -Text 'xyz' -ExitCode 0).Status | Should Be 'Unknown'
        }
        It 'maps chkdsk exit codes without relying on text' {
            (ConvertFrom-FslChkdskOutput -Text '' -ExitCode 0).Status | Should Be 'OK'
            (ConvertFrom-FslChkdskOutput -Text '' -ExitCode 2).Status | Should Be 'Warning'
            (ConvertFrom-FslChkdskOutput -Text '' -ExitCode 3).Status | Should Be 'Error'
            (ConvertFrom-FslChkdskOutput -Text '' -ExitCode 3).Recommendation | Should Match 'not automated'
        }
        It 'collapses progress bars, carriage returns and NULs' {
            $t = "Deployment Image Servicing`r`n[==   5.0%   ]`r[=====  20.0%  ]`r[========100.0%========]`r`nDone.`0"
            $c = ConvertTo-FslCleanProcessOutput $t
            $c | Should Match '100.0%'
            $c | Should Not Match '5.0%'
            $c | Should Not Match "`0"
            $c | Should Match 'Done\.'
        }
    }
}

Describe 'Process runner' {
    Context 'ctx' {
        $cmd = Join-Path $env:windir 'System32\cmd.exe'
        It 'runs a command and captures output and exit code' {
            $r = Invoke-FslProcess -FilePath $cmd -Arguments '/c echo hello & exit 3' -TimeoutSec 30
            $r.Started | Should Be $true
            $r.ExitCode | Should Be 3
            $r.Output | Should Match 'hello'
        }
        It 'stops a process that exceeds the timeout' {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-FslProcess -FilePath $cmd -Arguments '/c ping -n 30 127.0.0.1 > nul' -TimeoutSec 1
            $r.TimedOut | Should Be $true
            $sw.Elapsed.TotalSeconds | Should BeLessThan 15
        }
        It 'stops a process when cancelled' {
            $r = Invoke-FslProcess -FilePath $cmd -Arguments '/c ping -n 30 127.0.0.1 > nul' -TimeoutSec 60 -Sync @{ Cancel = $true }
            $r.Cancelled | Should Be $true
        }
        It 'reports a start failure without throwing' {
            $r = Invoke-FslProcess -FilePath (Join-Path $TestDrive 'nothing.exe') -Arguments ''
            $r.Started | Should Be $false
        }
    }
}

Describe 'Preflight' {
    Context 'ctx' {
        It 'blocks when nothing is selected' {
            (Get-FslMaintenancePreflight -TaskIds @() -Options @{ AllowNonElevated = $true }).Ok | Should Be $false
        }
        It 'blocks when not running as administrator' {
            Mock Test-FslIsAdministrator { $false }
            $p = Get-FslMaintenancePreflight -TaskIds @('diag.dism.check')
            $p.Ok | Should Be $false
            ($p.Blockers -join ' ') | Should Match 'Administrator'
        }
        It 'warns about user sessions, pending reboot and repair risk, and blocks on almost no disk space' {
            Mock Test-FslIsAdministrator { $true }
            Mock Get-FslRawSessions { @([pscustomobject]@{ User = 'jdoe'; State = 'Active' }) }
            Mock Get-FslPendingReboot { [pscustomobject]@{ Pending = $true; Reasons = @('CBS') } }
            Mock Get-CimInstance { [pscustomobject]@{ FreeSpace = 500MB; LoadPercentage = 5 } }
            $p = Get-FslMaintenancePreflight -TaskIds @('repair.dism.restore')
            $p.Ok | Should Be $false
            ($p.Blockers -join ' ') | Should Match 'free'
            ($p.Warnings -join ' ') | Should Match 'user session'
            ($p.Warnings -join ' ') | Should Match 'reboot is pending'
            ($p.Warnings -join ' ') | Should Match 'Repair tasks'
        }
        It 'passes for read-only tasks on a healthy host' {
            Mock Test-FslIsAdministrator { $true }
            Mock Get-FslRawSessions { @() }
            Mock Get-FslPendingReboot { [pscustomobject]@{ Pending = $false; Reasons = @() } }
            Mock Get-CimInstance { [pscustomobject]@{ FreeSpace = 50GB; LoadPercentage = 5 } }
            (Get-FslMaintenancePreflight -TaskIds @('diag.dism.check', 'diag.sfc.verify')).Ok | Should Be $true
        }
    }
}

Describe 'Maintenance tasks and runs' {
    Context 'ctx' {
        It 'does not start repair tools in a dry run' {
            Mock Invoke-FslProcess { throw 'must not be called in a dry run' }
            $t = Get-FslMaintenanceCatalog | Where-Object { $_.Id -eq 'repair.dism.restore' }
            $r = Invoke-FslMaintenanceTask -Task $t -Options @{ DryRun = $true }
            $r.Skipped | Should Be $true
            $r.Summary | Should Match 'Dry run'
        }
        It 'does not delete anything in a cleanup dry run' {
            Mock Remove-FslOldFiles { [pscustomobject]@{ Root = 'x'; Files = 3; Bytes = 3000; Skipped = 0; Errors = 0; DryRun = $DryRun.IsPresent; Blocked = $false; Cancelled = $false } }
            $t = Get-FslMaintenanceCatalog | Where-Object { $_.Id -eq 'clean.temp' }
            $r = Invoke-FslMaintenanceTask -Task $t -Options @{ DryRun = $true; Config = (Get-FslDefaultConfig) }
            $r.Summary | Should Match 'Dry run'
            Assert-MockCalled Remove-FslOldFiles -ParameterFilter { $DryRun } -Times 1
        }
        It 'turns a tool failure into an Error result instead of throwing' {
            Mock Invoke-FslProcess { [pscustomobject]@{ Started = $true; ExitCode = 1; TimedOut = $false; Cancelled = $false; Output = 'Error: 0x800f0922'; Seconds = 1; Error = $null } }
            $t = Get-FslMaintenanceCatalog | Where-Object { $_.Id -eq 'diag.dism.check' }
            (Invoke-FslMaintenanceTask -Task $t -Options @{}).Status | Should Be 'Error'
        }
        It 'runs tasks in catalog order, honours StopOnError and writes a report' {
            $env:FSLM_LOGDIR = $TestDrive
            Mock Get-FslMaintenancePreflight { [pscustomobject]@{ Blockers = @(); Warnings = @(); Info = @(); Ok = $true } }
            $script:order = @()
            Mock Invoke-FslMaintenanceTask { $script:order += $Task.Id; New-FslMaintResult -Task $Task -Status $(if ($Task.Id -eq 'diag.dism.check') { 'Error' } else { 'OK' }) -Summary 's' }
            $run = Invoke-FslMaintenanceRun -TaskIds @('diag.sfc.verify', 'diag.dism.check', 'diag.disk.health') -Options @{ StopOnError = $true }
            ($script:order -join ',') | Should Be 'diag.disk.health,diag.dism.check'
            $run.Errors | Should Be 1
            @($run.Results | Where-Object { $_.Skipped }).Count | Should Be 1
            Test-Path $run.ReportPath | Should Be $true
            (Get-Content $run.ReportPath -Raw | ConvertFrom-Json).RunId | Should Be $run.RunId
            @(Get-FslMaintenanceHistory).Count | Should BeGreaterThan 0
            Remove-Item Env:\FSLM_LOGDIR
        }
        It 'skips the remaining tasks after cancellation' {
            $env:FSLM_LOGDIR = $TestDrive
            Mock Get-FslMaintenancePreflight { [pscustomobject]@{ Blockers = @(); Warnings = @(); Info = @(); Ok = $true } }
            Mock Invoke-FslMaintenanceTask { New-FslMaintResult -Task $Task -Status 'OK' -Summary 's' }
            $run = Invoke-FslMaintenanceRun -TaskIds @('diag.disk.health', 'diag.dism.check') -Options @{} -Sync ([hashtable]::Synchronized(@{ Cancel = $true }))
            @($run.Results | Where-Object { $_.Skipped }).Count | Should Be 2
            $run.Cancelled | Should Be $true
            Remove-Item Env:\FSLM_LOGDIR
        }
        It 'aborts the run when preflight blocks' {
            $env:FSLM_LOGDIR = $TestDrive
            Mock Get-FslMaintenancePreflight { [pscustomobject]@{ Blockers = @('nope'); Warnings = @(); Info = @(); Ok = $false } }
            Mock Invoke-FslMaintenanceTask { throw 'must not run' }
            $run = Invoke-FslMaintenanceRun -TaskIds @('diag.dism.check') -Options @{}
            $run.Aborted | Should Match 'Preflight'
            $run.Results.Count | Should Be 0
            Remove-Item Env:\FSLM_LOGDIR
        }
    }
}

Describe 'Windows build and update status' {
    Context 'ctx' {
        It 'evaluates the servicing lifecycle of a build' {
            $now = [datetime]'2026-09-29'
            $l = Get-FslBuildLifecycle -Build 26100 -Now $now
            $l.Known | Should Be $true
            $l.Status | Should Be 'OK'
            (Get-FslBuildLifecycle -Build 19045 -Now $now).Status | Should Be 'Error'
            (Get-FslBuildLifecycle -Build 22631 -Now ([datetime]'2025-07-01')).Status | Should Be 'Warning'
            (Get-FslBuildLifecycle -Build 99999 -Now $now).Known | Should Be $false
        }
        It 'lets the configuration add and override lifecycle entries' {
            $cfg = @{ BuildLifecycle = @([pscustomobject]@{ Build = 26200; Name = 'Windows 11 25H2'; EndOfServicing = '2028-10-10' }, [pscustomobject]@{ Build = 26100; Name = 'X'; EndOfServicing = '2026-01-01' }) }
            $now = [datetime]'2026-09-29'
            (Get-FslBuildLifecycle -Build 26200 -Config $cfg -Now $now).Known | Should Be $true
            (Get-FslBuildLifecycle -Build 26100 -Config $cfg -Now $now).Status | Should Be 'Error'
        }
        It 'classifies updates' {
            Get-FslUpdateClass -Categories 'Definition Updates' -Severity '' | Should Be 'Definition'
            Get-FslUpdateClass -Categories 'Security Updates' -Severity 'Critical' | Should Be 'Critical'
            Get-FslUpdateClass -Categories 'Security Updates' -Severity 'Important' | Should Be 'Security'
            Get-FslUpdateClass -Categories 'Upgrades' -Severity '' | Should Be 'Feature'
            Get-FslUpdateClass -Categories 'Updates' -Severity '' | Should Be 'Other'
        }
        It 'turns a failed search into Unknown, not into a failure of the whole status' {
            Mock Invoke-FslWithTimeout { [pscustomobject]@{ TimedOut = $false; Result = @(); Error = '0x80072EE2' } }
            $s = Search-FslWindowsUpdates -TimeoutSec 5
            $s.Ok | Should Be $false
            $data = @{ Build = 26100; Lifecycle = (Get-FslBuildLifecycle -Build 26100); LastCu = $null; Policy = [pscustomobject]@{ Source = 'WSUS'; AutoUpdateDisabled = $false }; History = @(); AutoUpdate = $null; PendingReboot = $false; PendingRebootReasons = @(); Search = $s }
            $f = @(Get-FslUpdateFindings -Data $data)
            ($f | Where-Object { $_.Check -eq 'Pending quality/security updates' }).Status | Should Be 'Unknown'
        }
        It 'flags critical pending updates and failed installs' {
            $pending = @([pscustomobject]@{ Class = 'Critical'; RebootRequired = $true }, [pscustomobject]@{ Class = 'Security'; RebootRequired = $false })
            $hist = 1..3 | ForEach-Object { [pscustomobject]@{ Kind = 'Install'; Date = (Get-Date).AddDays(-2); ResultCode = 4 } }
            $data = @{ Build = 26100; Lifecycle = (Get-FslBuildLifecycle -Build 26100); LastCu = [pscustomobject]@{ Title = 'KB1'; Date = (Get-Date).AddDays(-100); Source = 't' }
                Policy = [pscustomobject]@{ Source = 'WSUS'; AutoUpdateDisabled = $false }; History = $hist; AutoUpdate = $null; PendingReboot = $true; PendingRebootReasons = @('CBS')
                Search = [pscustomobject]@{ Ok = $true; Updates = $pending; Error = $null } }
            $f = @(Get-FslUpdateFindings -Data $data)
            ($f | Where-Object { $_.Check -eq 'Pending quality/security updates' }).Status | Should Be 'Error'
            ($f | Where-Object { $_.Check -eq 'Failed update installs (30 days)' }).Status | Should Be 'Error'
            ($f | Where-Object { $_.Check -eq 'Last cumulative update' }).Status | Should Be 'Error'
            ($f | Where-Object { $_.Check -eq 'Pending reboot' }).Status | Should Be 'Warning'
            (Get-FslHealthScore -Results $f).Status | Should Be 'Error'
        }
        It 'keeps maintenance config values safe' {
            $p = Join-Path $TestDrive 'c.json'
            Set-Content $p '{ "MaintTempAgeDays": 0, "MaintLogAgeDays": -5, "MaintDefaultDryRun": false }'
            $c = Get-FslConfig -Paths @($p)
            $c.MaintTempAgeDays | Should Be 7
            $c.MaintLogAgeDays | Should Be 30
            $c.MaintDefaultDryRun | Should Be $false
        }
    }
}
