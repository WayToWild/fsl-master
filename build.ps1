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
$version = '0.1.0'
$steps = New-Object System.Collections.Generic.List[string]
function Step($m) { $steps.Add($m); Write-Output ("[build] " + $m) }
function Fail($m) { throw "BUILD MISLUKT: $m" }

# ---------------------------------------------------------------- 1+2. dependencies
Step '1/9 Builddependencies controleren'
if ($PSVersionTable.PSVersion.Major -ne 5) { Fail "Windows PowerShell 5.1 vereist (gevonden: $($PSVersionTable.PSVersion))." }
$ps2 = Get-Module -ListAvailable -Name ps2exe | Where-Object { $_.Version -eq [version]$ps2exeVersion } | Select-Object -First 1
if (-not $ps2) {
    Fail "Module ps2exe $ps2exeVersion ontbreekt. Installeer met: Install-Module ps2exe -RequiredVersion $ps2exeVersion -Scope CurrentUser"
}
Import-Module $ps2.Path -Force
$pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -and -not $SkipTests) { Fail 'Pester ontbreekt (Install-Module Pester of gebruik -SkipTests).' }
Add-Type -AssemblyName PresentationFramework
Step "  ps2exe $($ps2.Version), Pester $(if ($pester) { $pester.Version } else { 'n.v.t.' })"

# ---------------------------------------------------------------- 3. validate sources
Step '2/9 Broncode valideren (syntax + XAML)'
& (Join-Path $buildDir 'Set-Utf8Bom.ps1') -Root $root | Out-Null
$bad = 0
Get-ChildItem -Path $root -Recurse -Include *.ps1 -File | Where-Object { $_.FullName -notmatch '\\(dist|\.git)\\' } | ForEach-Object {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count -gt 0) { $bad++; $errs | ForEach-Object { Write-Output "  SYNTAXFOUT $($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" } }
}
if ($bad -gt 0) { Fail "$bad bestand(en) met syntaxfouten." }
$xamlText = [IO.File]::ReadAllText((Join-Path $src 'UI\MainWindow.xaml'), [Text.Encoding]::UTF8)
try { $null = [Windows.Markup.XamlReader]::Parse($xamlText) } catch { Fail "XAML ongeldig: $($_.Exception.Message)" }
if ($xamlText -match "(?m)^'@") { Fail "XAML bevat een regel die met '@ begint (breekt de bundel)." }
# no forbidden runtime behaviour in the sources (spec: no ExecutionPolicy bypass, no downloads at runtime)
$hits = Get-ChildItem -Path $src -Recurse -Include *.ps1 -File | Select-String -Pattern '(?i)-ExecutionPolicy\s+Bypass|Invoke-WebRequest|Invoke-RestMethod|DownloadString|DownloadFile|Start-BitsTransfer|Invoke-Command\s+-ComputerName|Enter-PSSession' -ErrorAction SilentlyContinue
if ($hits) { $hits | ForEach-Object { Write-Output "  VERBODEN: $($_.Path):$($_.LineNumber): $($_.Line.Trim())" }; Fail 'Verboden constructies gevonden in de broncode.' }

# ---------------------------------------------------------------- 4. tests
if (-not $SkipTests) {
    Step '3/9 Pester-tests uitvoeren'
    $res = Invoke-Pester -Script (Join-Path $root 'tests\FslMaster.Tests.ps1') -PassThru -Quiet
    Step "  Geslaagd: $($res.PassedCount), mislukt: $($res.FailedCount)"
    if ($res.FailedCount -gt 0) { $res.TestResult | Where-Object { -not $_.Passed } | ForEach-Object { Write-Output "  FAIL: $($_.Describe) / $($_.Name): $($_.FailureMessage)" }; Fail 'Tests mislukt.' }
} else { Step '3/9 Pester-tests overgeslagen (-SkipTests)' }

# ---------------------------------------------------------------- 5. bundle
Step '4/9 Bundel maken'
$commit = ''
try { $commit = (& git -C $root rev-parse --short HEAD 2>$null) } catch { }
if ($LASTEXITCODE -ne 0) { $commit = '' }
$buildDate = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$modules = 'Core\Core.ps1', 'Collectors\SystemInfo.ps1', 'Collectors\FSLogix.ps1', 'Collectors\Sessions.ps1', 'Collectors\Containers.ps1',
'Collectors\Events.ps1', 'Collectors\Health.ps1', 'Collectors\Collect.ps1', 'Export\Report.ps1', 'UI\Ui.ps1'
$app = [IO.File]::ReadAllText((Join-Path $src 'App.ps1'), [Text.Encoding]::UTF8)
$rx = [regex]'(?s)#region MODULES.*?#endregion MODULES'
if (-not $rx.IsMatch($app)) { Fail 'MODULES-regio niet gevonden in App.ps1.' }
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
if ($errs.Count -gt 0) { Fail "Bundel bevat syntaxfouten: $($errs[0].Message)" }
Step "  Bundel: $([math]::Round((Get-Item $bundlePath).Length / 1KB)) KB"

# ---------------------------------------------------------------- 6. icon
$icon = Join-Path $root 'assets\fsl-master.ico'
if (-not (Test-Path $icon)) { & (Join-Path $buildDir 'New-Icon.ps1') -Path $icon | Out-Null }

# ---------------------------------------------------------------- 7. compile
Step '5/9 dist-map opnieuw opbouwen en executable compileren (PS2EXE)'
Get-ChildItem -Path $dist -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
$exe = Join-Path $dist 'fsl-master.exe'
$common = @{
    inputFile = $bundlePath; noConsole = $true; STA = $true; x64 = $true; iconFile = $icon; DPIAware = $true
    title = 'FSL Master'; description = 'Local FSLogix diagnostics and monitoring for Azure Virtual Desktop'
    company = 'WayToWild'; product = 'FSL Master'; copyright = 'Copyright (c) 2026 WayToWild - MIT License'; version = "$version.0"
}
Invoke-ps2exe @common -outputFile $exe -requireAdmin | Out-Null
if (-not (Test-Path $exe)) { Fail 'PS2EXE heeft geen executable geproduceerd.' }

# ---------------------------------------------------------------- 8. verify exe
Step '6/9 Executable controleren'
$bytes = [IO.File]::ReadAllBytes($exe)
if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { Fail 'Geen geldig Windows-executable (MZ-header ontbreekt).' }
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
if ([Text.Encoding]::ASCII.GetString($bytes, $peOffset, 2) -ne 'PE') { Fail 'PE-header ontbreekt.' }
$latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
if ($latin -notmatch 'requestedExecutionLevel level="requireAdministrator"' -and $latin -notmatch "requestedExecutionLevel level='requireAdministrator'") { Fail 'Administrator-manifest (requireAdministrator) niet gevonden in de executable.' }
$fv = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
Step "  PE geldig, requireAdministrator-manifest aanwezig, bestandsversie $($fv.FileVersion), $([math]::Round($bytes.Length / 1KB)) KB"

# ---------------------------------------------------------------- 7. smoke tests
if (-not $SkipSmoke) {
    Step '7/9 Smoke-test: exact dezelfde bundel als script uitvoeren (zelftest + alle pagina''s renderen)'
    $json = Join-Path $work 'selftest.json'
    $psExe = (Get-Process -Id $PID).Path
    $p = Start-Process -FilePath $psExe -ArgumentList @('-STA', '-NoProfile', '-File', "`"$bundlePath`"", '-SelfTest', "`"$json`"", '-AllowNonElevated') -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(240000)) { try { $p.Kill() } catch { }; Fail 'Smoke-test: time-out.' }
    if (-not (Test-Path $json)) { Fail 'Smoke-test: geen resultaatbestand.' }
    $r = Get-Content $json -Raw | ConvertFrom-Json
    if (-not $r.ComputerName -or -not $r.Compiled) { Fail 'Smoke-test: basisgegevens van de host konden niet worden opgehaald uit de bundel.' }
    Step "  Selftest OK: host $($r.ComputerName), $($r.Windows), FSLogix geinstalleerd: $($r.FslogixInstalled), health-checks: $($r.HealthChecks), bronfouten: $(@($r.SourceErrors).Count)"
    $shots = Join-Path $work 'shots'
    $errFile = Join-Path $work 'gui-stderr.txt'; $outFile = Join-Path $work 'gui-stdout.txt'
    $p2 = Start-Process -FilePath $psExe -ArgumentList @('-STA', '-NoProfile', '-File', "`"$bundlePath`"", '-AllowNonElevated', '-CaptureScreenshots', "`"$shots`"") -PassThru -WindowStyle Hidden -RedirectStandardError $errFile -RedirectStandardOutput $outFile
    if (-not $p2.WaitForExit(240000)) { try { $p2.Kill() } catch { }; Fail 'Smoke-test GUI: time-out.' }
    $png = @(Get-ChildItem $shots -Filter *.png -ErrorAction SilentlyContinue)
    if ($png.Count -lt 12) { Fail "Smoke-test GUI: verwacht 12 schermafbeeldingen, gevonden $($png.Count)." }
    $stray = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue)
    $strayErr = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
    if ($stray -or $strayErr) { Fail "Smoke-test GUI: onverwachte uitvoer/fouten (zou in de noConsole-exe als berichtvensters verschijnen):`n$stray`n$strayErr" }
    Step "  GUI-smoke OK: $($png.Count) schermafbeeldingen gerenderd, geen onverwachte uitvoer of fouten"

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
        if (-not $pe.WaitForExit(240000)) { try { $pe.Kill() } catch { }; Fail 'Smoke-test exe: time-out.' }
        if (-not (Test-Path $json2)) { Fail 'Smoke-test exe: geen resultaatbestand.' }
        $r2 = Get-Content $json2 -Raw | ConvertFrom-Json
        if (-not $r2.ComputerName) { Fail 'Smoke-test exe: geen hostgegevens.' }
        Step "  Gecompileerde exe (niet-verhoogde tweeling) OK: host $($r2.ComputerName)"
    } catch [System.InvalidOperationException] {
        Step "  WAARSCHUWING: de gecompileerde exe kon niet worden gestart op deze buildmachine ($($_.Exception.Message)). Uitvoeren van niet-ondertekende executables is hier waarschijnlijk geblokkeerd (AppLocker/antivirus). De exe is NIET runtime-getest; test deze op de doelhost."
    }
} else { Step '7/9 Smoke-test overgeslagen (-SkipSmoke)' }

# ---------------------------------------------------------------- hash, info, zip
Step '8/9 Hash, buildinfo en ZIP'
$hash = (Get-FileHash -Path $exe -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$exe.sha256", "$hash *fsl-master.exe`r`n", (New-Object Text.UTF8Encoding($false)))
$info = [ordered]@{ Name = 'FSL Master'; Version = $version; BuildDate = $buildDate; GitCommit = $commit; Sha256 = $hash; Packaging = "PS2EXE $ps2exeVersion (single exe, x64, STA, noConsole, requireAdministrator)"; BuiltOn = $env:COMPUTERNAME }
($info | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $dist 'build-info.json') -Encoding UTF8
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $dist 'LICENSE') -ErrorAction SilentlyContinue
Copy-Item (Join-Path $root 'README.md') (Join-Path $dist 'README.md') -ErrorAction SilentlyContinue
$zip = Join-Path $dist 'fsl-master.zip'
Compress-Archive -Path $exe, "$exe.sha256", (Join-Path $dist 'build-info.json'), (Join-Path $dist 'LICENSE'), (Join-Path $dist 'README.md') -DestinationPath $zip -Force
Step '9/9 Klaar'
Write-Output ''
Write-Output "  Executable : $exe"
Write-Output "  SHA256     : $hash"
Write-Output "  ZIP        : $zip"
Write-Output "  Versie     : $version (build $buildDate, commit $(if ($commit) { $commit } else { 'n.v.t.' }))"

exit 0
