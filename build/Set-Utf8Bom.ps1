# Ensures all PowerShell/XAML sources are UTF-8 with BOM (required so Windows PowerShell 5.1 reads non-ASCII text correctly).
param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
Get-ChildItem -Path $Root -Recurse -File -Include *.ps1, *.psm1, *.xaml |
    Where-Object { $_.FullName -notmatch '\\(dist|\.git)\\' } | ForEach-Object {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $hasBom) {
            [IO.File]::WriteAllText($_.FullName, [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8), $utf8Bom)
            "BOM toegevoegd: $($_.FullName)"
        }
    }
