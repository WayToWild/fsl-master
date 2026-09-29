# Generates assets\fsl-master.ico (classic BMP-based icon entries, compatible with csc /win32icon) from code.
param([string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\fsl-master.ico'))
Add-Type -AssemblyName System.Drawing

function New-FslIconBitmap {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $r = [int]($Size * 0.18)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rect = New-Object System.Drawing.Rectangle(0, 0, ($Size - 1), ($Size - 1))
    $d = $r * 2
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90); $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90); $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90); $path.CloseFigure()
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(255, 47, 111, 196), [System.Drawing.Color]::FromArgb(255, 22, 40, 82), 65)
    $g.FillPath($brush, $path)
    $fontSize = [single]($Size * 0.36)
    $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString('FSL', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, [single]($Size * 0.02), $Size, $Size)), $sf)
    # small "pulse" line under the text = monitoring
    if ($Size -ge 32) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 102, 214, 137), [single][math]::Max(1.5, $Size * 0.035))
        $y = $Size * 0.78; $x0 = $Size * 0.16; $w = $Size * 0.68
        $pts = @([System.Drawing.PointF]::new($x0, $y), [System.Drawing.PointF]::new($x0 + $w * 0.3, $y), [System.Drawing.PointF]::new($x0 + $w * 0.4, $y - $Size * 0.09), [System.Drawing.PointF]::new($x0 + $w * 0.52, $y + $Size * 0.08), [System.Drawing.PointF]::new($x0 + $w * 0.62, $y), [System.Drawing.PointF]::new($x0 + $w, $y))
        $g.DrawLines($pen, $pts)
    }
    $g.Dispose()
    $bmp
}

$sizes = 16, 32, 48, 64, 256
$images = @()
foreach ($s in $sizes) {
    $bmp = New-FslIconBitmap -Size $s
    $rect = New-Object System.Drawing.Rectangle(0, 0, $s, $s)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($data.Stride * $s)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    $bmp.UnlockBits($data)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int]($s * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]0); $bw.Write([int]($s * $s * 4)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    for ($y = $s - 1; $y -ge 0; $y--) { $bw.Write($raw, $y * $data.Stride, $s * 4) }   # bottom-up rows
    $maskRow = [int]([math]::Ceiling($s / 32.0) * 4)
    $bw.Write((New-Object byte[] ($maskRow * $s)))
    $bw.Flush()
    $images += , @{ Size = $s; Bytes = $ms.ToArray() }
    $bmp.Dispose()
}
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($i in $images) {
    $dim = if ($i.Size -ge 256) { 0 } else { $i.Size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0); $w.Write([int16]1); $w.Write([int16]32)
    $w.Write([int]$i.Bytes.Length); $w.Write([int]$offset); $offset += $i.Bytes.Length
}
foreach ($i in $images) { $w.Write($i.Bytes) }
$w.Flush()
$dir = Split-Path -Parent $Path
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllBytes($Path, $out.ToArray())
"Icon geschreven: $Path ($($out.Length) bytes)"
