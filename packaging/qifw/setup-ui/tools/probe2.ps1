# probe2.ps1 - hex run dump for one column or row, or an ink bounding box (window coordinates at scale 1).
# Examples:
#   probe2.ps1 -View license -Col 700 -From 100 -To 480
#   probe2.ps1 -View snapshot -Row 330 -From 490 -To 945
#   probe2.ps1 -View uninstall-done-zh -Ink -InkTop 355 -InkBottom 390 -From 500 -To 940
param(
    [Parameter(Mandatory = $true)][string]$View,
    [double]$Col = -1,
    [double]$Row = -1,
    [double]$From = 0,
    [double]$To = 540,
    [string]$ShotDir = '',
    [switch]$Ink,
    [double]$InkTop = 0,
    [double]$InkBottom = 540
)
Add-Type -AssemblyName System.Drawing
if (-not $ShotDir) { $ShotDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'out\ui-shots' }
$p = Join-Path $ShotDir "$View.png"
if (-not (Test-Path -LiteralPath $p)) { Write-Output "MISSING $p"; exit 1 }
$bmp = [System.Drawing.Bitmap]::new($p)
$s = $bmp.Width / 960.0
$lastX = $bmp.Width - 1
$lastY = $bmp.Height - 1

function HexOf([System.Drawing.Color]$c) { '#{0:x2}{1:x2}{2:x2}' -f $c.R, $c.G, $c.B }
function Px([double]$v, [int]$limit) { return [Math]::Min($limit, [Math]::Max(0, [int][Math]::Round($v, [System.MidpointRounding]::AwayFromZero))) }

if ($Ink) {
    $px0 = Px $From $lastX; $px1 = Px $To $lastX
    $py0 = Px $InkTop $lastY; $py1 = Px $InkBottom $lastY
    $loX = 99999; $loY = 99999; $hiX = -1; $hiY = -1
    for ($y = $py0; $y -le $py1; $y++) {
        for ($x = $px0; $x -le $px1; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if ($c.A -gt 8 -and (255 - $c.R -gt 18 -or 255 - $c.G -gt 18 -or 255 - $c.B -gt 18)) {
                if ($x -lt $loX) { $loX = $x }
                if ($x -gt $hiX) { $hiX = $x }
                if ($y -lt $loY) { $loY = $y }
                if ($y -gt $hiY) { $hiY = $y }
            }
        }
    }
    if ($hiX -lt 0) {
        Write-Output 'INK (empty)'
    } else {
        Write-Output ('INK x {0:0.0}..{1:0.0} y {2:0.0}..{3:0.0}  (w {4:0.0} h {5:0.0})' -f ($loX / $s), (($hiX + 1) / $s), ($loY / $s), (($hiY + 1) / $s), (($hiX - $loX + 1) / $s), (($hiY - $loY + 1) / $s))
    }
} elseif ($Col -ge 0) {
    $px = Px $Col $lastX
    $y0 = Px $From $lastY; $y1 = Px $To $lastY
    $runs = @(); $start = $y0; $prev = HexOf $bmp.GetPixel($px, $y0)
    for ($y = $y0 + 1; $y -le $y1; $y++) {
        $h = HexOf $bmp.GetPixel($px, $y)
        if ($h -ne $prev) {
            $runs += ("{0}@{1:0.0}..{2:0.0}" -f $prev, ($start / $s), ($y / $s))
            $start = $y; $prev = $h
        }
    }
    $runs += ("{0}@{1:0.0}..{2:0.0}" -f $prev, ($start / $s), (($y1 + 1) / $s))
    Write-Output ("COL x={0}: {1}" -f $Col, ($runs -join ' | '))
} else {
    $py = Px $Row $lastY
    $x0 = Px $From $lastX; $x1 = Px $To $lastX
    $runs = @(); $start = $x0; $prev = HexOf $bmp.GetPixel($x0, $py)
    for ($x = $x0 + 1; $x -le $x1; $x++) {
        $h = HexOf $bmp.GetPixel($x, $py)
        if ($h -ne $prev) {
            $runs += ("{0}@{1:0.0}..{2:0.0}" -f $prev, ($start / $s), ($x / $s))
            $start = $x; $prev = $h
        }
    }
    $runs += ("{0}@{1:0.0}..{2:0.0}" -f $prev, ($start / $s), (($x1 + 1) / $s))
    Write-Output ("ROW y={0}: {1}" -f $Row, ($runs -join ' | '))
}
$bmp.Dispose()
