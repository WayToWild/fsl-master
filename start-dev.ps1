<#
.SYNOPSIS
    Starts FSL Master from source (no build needed).
.DESCRIPTION
    Runs src\App.ps1 in an STA PowerShell process. Normally run from an elevated prompt.
    -AllowNonElevated   run without administrator rights (limited data; developer/testing only)
    -CaptureScreenshots write PNG screenshots of all pages to the given folder and exit
    -SelfTest           collect data without GUI and write a JSON summary to the given file
#>
param(
    [switch]$AllowNonElevated,
    [string]$CaptureScreenshots,
    [string]$SelfTest
)
$app = Join-Path $PSScriptRoot 'src\App.ps1'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psArgs = @('-STA', '-NoProfile', '-File', ('"' + $PSCommandPath + '"'))
    if ($AllowNonElevated) { $psArgs += '-AllowNonElevated' }
    if ($CaptureScreenshots) { $psArgs += @('-CaptureScreenshots', ('"' + $CaptureScreenshots + '"')) }
    if ($SelfTest) { $psArgs += @('-SelfTest', ('"' + $SelfTest + '"')) }
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $psArgs -Wait -PassThru
    exit $p.ExitCode
}
& $app @PSBoundParameters
