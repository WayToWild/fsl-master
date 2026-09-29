<#
.SYNOPSIS
    Builds FSL Master: validates the source, runs the tests, bundles the sources into one script and compiles
    the portable executable (dist\fsl-master.exe) with PS2EXE, then writes hash, build info and ZIP.
.PARAMETER SkipTests   Do not run the Pester tests.
.PARAMETER SkipSmoke   Do not run the post-build smoke test of the compiled application.
.NOTES
    Build machine dependencies: Windows PowerShell 5.1, module ps2exe (pinned to 1.0.18), Pester (3.4+, optional but recommended).
    The resulting exe needs no modules or installation on the target host.
#>
[CmdletBinding()]
param([switch]$SkipTests, [switch]$SkipSmoke)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$src = Join-Path $root 'src'
$dist = Join-Path $root 'dist'
$buildDir = Join-Path $root 'build'
$ps2exeVersion = '1.0.18'
$version = '0.1.1'
$steps = New-Object System.Collections.Generic.List[string]
function Step($m) { $steps.Add($m); Write-Output ("[build] " + $m) }
function Fail($m) { throw "BUILD FAILED: $m" }

# ---------------------------------------------------------------- 1+2. dependencies
Step '1/9 Checking build dependencies'
if ($PSVersionTable.PSVersion.Major -ne 5) { Fail "Windows PowerShell 5.1 required (found: $($PSVersionTable.PSVersion))." }
$ps2 = Get-Module -ListAvailable -Name ps2exe | Where-Object { $_.Version -eq [version]$ps2exeVersion } | Select-Object -First 1
if (-not $ps2) {
    Fail "Module ps2exe $ps2exeVersion is missing. Install with: Install-Module ps2exe -RequiredVersion $ps2exeVersion -Scope CurrentUser"
}
Import-Module $ps2.Path -Force
$pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -and -not $SkipTests) { Fail 'Pester is missing (Install-Module Pester or use -SkipTests).' }
Add-Type -AssemblyName PresentationFramework
Step "  ps2exe $($ps2.Version), Pester $(if ($pester) { $pester.Version } else { 'n/a' })"

# ---------------------------------------------------------------- 3. validate sources
Step '2/9 Validating source (syntax + XAML)'
& (Join-Path $buildDir 'Set-Utf8Bom.ps1') -Root $root | Out-Null
$bad = 0
Get-ChildItem -Path $root -Recurse -Include *.ps1 -File | Where-Object { $_.FullName -notmatch '\\(dist|\.git)\\' } | ForEach-Object {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count -gt 0) { $bad++; $errs | ForEach-Object { Write-Output "  SYNTAX ERROR $($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" } }
}
if ($bad -gt 0) { Fail "$bad file(s) with syntax errors." }
$xamlText = [IO.File]::ReadAllText((Join-Path $src 'UI\MainWindow.xaml'), [Text.Encoding]::UTF8)
try { $null = [Windows.Markup.XamlReader]::Parse($xamlText) } catch { Fail "XAML invalid: $($_.Exception.Message)" }
if ($xamlText -match "(?m)^'@") { Fail "XAML contains a line starting with '@ (would break the bundle)." }
# no forbidden runtime behaviour in the sources (spec: no ExecutionPolicy bypass, no downloads at runtime)
$hits = Get-ChildItem -Path $src -Recurse -Include *.ps1 -File | Select-String -Pattern '(?i)-ExecutionPolicy\s+Bypass|Invoke-WebRequest|Invoke-RestMethod|DownloadString|DownloadFile|Start-BitsTransfer|Invoke-Command\s+-ComputerName|Enter-PSSession' -ErrorAction SilentlyContinue
if ($hits) { $hits | ForEach-Object { Write-Output "  FORBIDDEN: $($_.Path):$($_.LineNumber): $($_.Line.Trim())" }; Fail 'Forbidden constructs found in the source.' }

# ---------------------------------------------------------------- 4. tests
if (-not $SkipTests) {
    Step '3/9 Running Pester tests'
    $res = Invoke-Pester -Script (Join-Path $root 'tests\FslMaster.Tests.ps1') -PassThru -Quiet
    Step "  Passed: $($res.PassedCount), failed: $($res.FailedCount)"
    if ($res.FailedCount -gt 0) { $res.TestResult | Where-Object { -not $_.Passed } | ForEach-Object { Write-Output "  FAIL: $($_.Describe) / $($_.Name): $($_.FailureMessage)" }; Fail 'Tests failed.' }
} else { Step '3/9 Pester tests skipped (-SkipTests)' }

# ---------------------------------------------------------------- 5. bundle
Step '4/9 Creating bundle'
$commit = ''
try { $commit = (& git -C $root rev-parse --short HEAD 2>$null) } catch { }
if ($LASTEXITCODE -ne 0) { $commit = '' }
$buildDate = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$modules = 'Core\Core.ps1', 'Collectors\SystemInfo.ps1', 'Collectors\FSLogix.ps1', 'Collectors\Sessions.ps1', 'Collectors\Containers.ps1',
'Collectors\Events.ps1', 'Collectors\Health.ps1', 'Collectors\Collect.ps1', 'Export\Report.ps1', 'UI\Ui.ps1'
$app = [IO.File]::ReadAllText((Join-Path $src 'App.ps1'), [Text.Encoding]::UTF8)
$rx = [regex]'(?s)#region MODULES.*?#endregion MODULES'
if (-not $rx.IsMatch($app)) { Fail 'MODULES region not found in App.ps1.' }
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('#region MODULES (bundled by build.ps1)')
[void]$sb.AppendLine('$script:FslBundled = $true')
[void]$sb.AppendLine("`$script:FslBuildInfo = @{ BuildDate = '$buildDate'; Commit = '$commit' }")
[void]$sb.AppendLine("`$script:FslMainXaml = @'")
[void]$sb.AppendLine($xamlText.TrimEnd())
[void]$sb.AppendLine("'@")
foreach ($m in $modules) { [void]$sb.AppendLine("# ---- $m"); [void]$sb.AppendLine([IO.File]::ReadAllText((Join-Path $src $m), [Text.Encoding]::UTF8)) }
[void]$sb.AppendLine('#endregion MODULES')
$bundle = $rx.Replace($app, { param($m) $sb.ToString() })
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
$work = Join-Path $buildDir 'work'
if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $work -Force | Out-Null
$bundlePath = Join-Path $work 'fsl-master.bundle.ps1'
[IO.File]::WriteAllText($bundlePath, $bundle, (New-Object Text.UTF8Encoding($true)))
$tokens = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($bundlePath, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) { Fail "Bundle contains syntax errors: $($errs[0].Message)" }
Step "  Bundle: $([math]::Round((Get-Item $bundlePath).Length / 1KB)) KB"

# ---------------------------------------------------------------- 6. icon
$icon = Join-Path $root 'assets\fsl-master.ico'
if (-not (Test-Path $icon)) { & (Join-Path $buildDir 'New-Icon.ps1') -Path $icon | Out-Null }

# ---------------------------------------------------------------- 7. compile
Step '5/9 Rebuilding dist folder and compiling executable (PS2EXE)'
Get-ChildItem -Path $dist -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
$exe = Join-Path $dist 'fsl-master.exe'
$common = @{
    inputFile = $bundlePath; noConsole = $true; STA = $true; x64 = $true; iconFile = $icon; DPIAware = $true
    title = 'FSL Master'; description = 'Local FSLogix diagnostics and monitoring for Azure Virtual Desktop'
    company = 'WayToWild'; product = 'FSL Master'; copyright = 'Copyright (c) 2026 WayToWild - MIT License'; version = "$version.0"
}
Invoke-ps2exe @common -outputFile $exe -requireAdmin | Out-Null
if (-not (Test-Path $exe)) { Fail 'PS2EXE did not produce an executable.' }

# ---------------------------------------------------------------- 8. verify exe
Step '6/9 Verifying executable'
$bytes = [IO.File]::ReadAllBytes($exe)
if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { Fail 'Not a valid Windows executable (MZ header missing).' }
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
if ([Text.Encoding]::ASCII.GetString($bytes, $peOffset, 2) -ne 'PE') { Fail 'PE header missing.' }
$latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
if ($latin -notmatch 'requestedExecutionLevel level="requireAdministrator"' -and $latin -notmatch "requestedExecutionLevel level='requireAdministrator'") { Fail 'Administrator manifest (requireAdministrator) not found in the executable.' }
$fv = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
Step "  PE valid, requireAdministrator manifest present, file version $($fv.FileVersion), $([math]::Round($bytes.Length / 1KB)) KB"

# ---------------------------------------------------------------- 7. smoke tests
if (-not $SkipSmoke) {
    Step '7/9 Smoke test: running the exact same bundle as a script (self-test + render all pages)'
    $json = Join-Path $work 'selftest.json'
    $psExe = (Get-Process -Id $PID).Path
    $p = Start-Process -FilePath $psExe -ArgumentList @('-STA', '-NoProfile', '-File', "`"$bundlePath`"", '-SelfTest', "`"$json`"", '-AllowNonElevated') -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(240000)) { try { $p.Kill() } catch { }; Fail 'Smoke test: timeout.' }
    if (-not (Test-Path $json)) { Fail 'Smoke test: no result file.' }
    $r = Get-Content $json -Raw | ConvertFrom-Json
    if (-not $r.ComputerName -or -not $r.Compiled) { Fail 'Smoke test: basic host data could not be retrieved from the bundle.' }
    Step "  Selftest OK: host $($r.ComputerName), $($r.Windows), FSLogix installed: $($r.FslogixInstalled), health-checks: $($r.HealthChecks), source errors: $(@($r.SourceErrors).Count)"
    $shots = Join-Path $work 'shots'
    $errFile = Join-Path $work 'gui-stderr.txt'; $outFile = Join-Path $work 'gui-stdout.txt'
    $p2 = Start-Process -FilePath $psExe -ArgumentList @('-STA', '-NoProfile', '-File', "`"$bundlePath`"", '-AllowNonElevated', '-CaptureScreenshots', "`"$shots`"") -PassThru -WindowStyle Hidden -RedirectStandardError $errFile -RedirectStandardOutput $outFile
    if (-not $p2.WaitForExit(240000)) { try { $p2.Kill() } catch { }; Fail 'Smoke test GUI: timeout.' }
    $png = @(Get-ChildItem $shots -Filter *.png -ErrorAction SilentlyContinue)
    if ($png.Count -lt 12) { Fail "Smoke test GUI: expected 12 screenshots, found $($png.Count)." }
    $stray = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue)
    $strayErr = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
    if ($stray -or $strayErr) { Fail "Smoke test GUI: unexpected output/errors (would appear as message boxes in the noConsole exe):`n$stray`n$strayErr" }
    Step "  GUI smoke OK: $($png.Count) screenshots rendered, no unexpected output or errors"

    # The compiled exe itself: needs permission to run unsigned executables (AppLocker/AV may block this on managed machines).
    $smoke = Join-Path $work 'fsl-master-smoke.exe'
    try {
        Invoke-ps2exe @common -outputFile $smoke | Out-Null
        $json2 = Join-Path $work 'selftest-exe.json'
        $pe = $null
        for ($attempt = 1; $attempt -le 4 -and -not $pe; $attempt++) {   # security software may deny the first launches of a new unsigned exe
            try { $pe = Start-Process -FilePath $smoke -ArgumentList @('-SelfTest', "`"$json2`"", '-AllowNonElevated') -PassThru -WindowStyle Hidden -ErrorAction Stop }
            catch { if ($attempt -eq 4) { throw }; Start-Sleep -Seconds 4 }
        }
        if (-not $pe.WaitForExit(240000)) { try { $pe.Kill() } catch { }; Fail 'Smoke test exe: timeout.' }
        if (-not (Test-Path $json2)) { Fail 'Smoke test exe: no result file.' }
        $r2 = Get-Content $json2 -Raw | ConvertFrom-Json
        if (-not $r2.ComputerName) { Fail 'Smoke test exe: no host data.' }
        Step "  Compiled exe (non-elevated twin) OK: host $($r2.ComputerName)"
    } catch [System.InvalidOperationException] {
        Step "  WARNING: the compiled exe could not be started on this build machine ($($_.Exception.Message)). Running unsigned executables is probably blocked here (AppLocker/antivirus). The exe was NOT runtime-tested; test it on the target host."
    }
} else { Step '7/9 Smoke test skipped (-SkipSmoke)' }

# ---------------------------------------------------------------- hash, info, zip
Step '8/9 Hash, build info and ZIP'
$hash = (Get-FileHash -Path $exe -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$exe.sha256", "$hash *fsl-master.exe`r`n", (New-Object Text.UTF8Encoding($false)))
$info = [ordered]@{ Name = 'FSL Master'; Version = $version; BuildDate = $buildDate; GitCommit = $commit; Sha256 = $hash; Packaging = "PS2EXE $ps2exeVersion (single exe, x64, STA, noConsole, requireAdministrator)"; BuiltOn = $env:COMPUTERNAME }
($info | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $dist 'build-info.json') -Encoding UTF8
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $dist 'LICENSE') -ErrorAction SilentlyContinue
Copy-Item (Join-Path $root 'README.md') (Join-Path $dist 'README.md') -ErrorAction SilentlyContinue
$zip = Join-Path $dist 'fsl-master.zip'
Compress-Archive -Path $exe, "$exe.sha256", (Join-Path $dist 'build-info.json'), (Join-Path $dist 'LICENSE'), (Join-Path $dist 'README.md') -DestinationPath $zip -Force
Step '9/9 Done'
Write-Output ''
Write-Output "  Executable : $exe"
Write-Output "  SHA256     : $hash"
Write-Output "  ZIP        : $zip"
Write-Output "  Version    : $version (build $buildDate, commit $(if ($commit) { $commit } else { 'n/a' }))"

exit 0
