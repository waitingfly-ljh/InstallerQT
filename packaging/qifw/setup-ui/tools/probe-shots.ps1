# probe-shots.ps1 - reads out/ui-shots/*.png and prints the geometry used in review.md.
# Window coordinates (960x540 at -Scale 1). Scale folders are divided back to DIPs.
param(
    [string]$ShotDir = '',
    [double]$Scale = 0,
    [string]$ViewList = ''
)
Add-Type -AssemblyName System.Drawing

$Here = Split-Path -Parent $PSScriptRoot
if (-not $ShotDir) { $ShotDir = Join-Path $Here 'out\ui-shots' }

function Open([string]$name) {
    $p = Join-Path $ShotDir "$name.png"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return [System.Drawing.Bitmap]::new($p)
}

function IsInk([System.Drawing.Color]$c, [int]$tol = 18) {
    return ($c.A -gt 8 -and (255 - $c.R -gt $tol -or 255 - $c.G -gt $tol -or 255 - $c.B -gt $tol))
}

# Bounding box of non-white pixels inside a DIP rectangle. Returns "" when the region is empty.
function InkBox([System.Drawing.Bitmap]$bmp, [double]$s, [double]$x0, [double]$y0, [double]$x1, [double]$y1) {
    $px0 = [int][Math]::Floor($x0 * $s); $px1 = [int][Math]::Ceiling($x1 * $s) - 1
    $py0 = [int][Math]::Floor($y0 * $s); $py1 = [int][Math]::Ceiling($y1 * $s) - 1
    $minX = 99999; $minY = 99999; $maxX = -1; $maxY = -1
    for ($y = $py0; $y -le $py1; $y++) {
        for ($x = $px0; $x -le $px1; $x++) {
            if (IsInk $bmp.GetPixel($x, $y)) {
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -lt 0) { return '(empty)' }
    $d = [System.Globalization.CultureInfo]::InvariantCulture
    return ('{0:0.0},{1:0.0}..{2:0.0},{3:0.0} (w {4:0.0} h {5:0.0})' -f ($minX / $s), ($minY / $s), (($maxX + 1) / $s), (($maxY + 1) / $s), (($maxX - $minX + 1) / $s), (($maxY - $minY + 1) / $s))
}

# Horizontal runs of a given row (DIP row), merged by colour class: ink / bg / brand.
function RowRuns([System.Drawing.Bitmap]$bmp, [double]$s, [double]$y, [double]$x0, [double]$x1, [int]$minLen = 6) {
    $py = [int][Math]::Round($y * $s)
    $px0 = [int][Math]::Round($x0 * $s); $px1 = [int][Math]::Round($x1 * $s)
    $runs = @(); $start = -1; $prev = $null
    for ($x = $px0; $x -le $px1; $x++) {
        $c = $bmp.GetPixel($x, $py)
        $cls = if (-not (IsInk $c)) { 'bg' } else { "ink#$('{0:x2}{1:x2}{2:x2}' -f $c.R,$c.G,$c.B)" }
        if ($cls -ne $prev) {
            if ($prev -ne $null -and ($x - $start) -ge [int]($minLen * $s)) { $runs += ("{0}@{1:0.0}" -f $prev, ($start / $s)) }
            $start = $x; $prev = $cls
        }
    }
    if ($prev -ne $null -and ($px1 - $start + 1) -ge [int]($minLen * $s)) { $runs += ("{0}@{1:0.0}" -f $prev, ($start / $s)) }
    return ($runs -join ' | ')
}

# Vertical runs of one column (DIP column).
function ColRuns([System.Drawing.Bitmap]$bmp, [double]$s, [double]$x, [double]$y0, [double]$y1, [int]$minLen = 3) {
    $px = [int][Math]::Round($x * $s)
    $py0 = [int][Math]::Round($y0 * $s); $py1 = [int][Math]::Round($y1 * $s)
    $runs = @(); $start = -1; $prev = $null
    for ($y = $py0; $y -le $py1; $y++) {
        $c = $bmp.GetPixel($px, $y)
        $cls = if (-not (IsInk $c)) { 'bg' } else { "ink#$('{0:x2}{1:x2}{2:x2}' -f $c.R,$c.G,$c.B)" }
        if ($cls -ne $prev) {
            if ($prev -ne $null -and ($y - $start) -ge [int]($minLen * $s)) { $runs += ("{0}@{1:0.0}" -f $prev, ($start / $s)) }
            $start = $y; $prev = $cls
        }
    }
    if ($prev -ne $null -and ($py1 - $start + 1) -ge [int]($minLen * $s)) { $runs += ("{0}@{1:0.0}" -f $prev, ($start / $s)) }
    return ($runs -join ' | ')
}

function Pixel([System.Drawing.Bitmap]$bmp, [double]$s, [double]$x, [double]$y) {
    $c = $bmp.GetPixel([int][Math]::Round($x * $s), [int][Math]::Round($y * $s))
    return ('#{0:x2}{1:x2}{2:x2}' -f $c.R, $c.G, $c.B)
}

# Per-view probes. Each entry: view, scale detection from image width, and the probe lines.
$views = if ($ViewList) { $ViewList -split '\|' } else { @('welcome', 'license', 'options', 'maintenance', 'snapshot', 'progress', 'complete', 'failure-code', 'uninstall-scope', 'uninstall-confirm', 'uninstall-done', 'rollback', 'failure') }
foreach ($v in $views) {
    $bmp = Open $v
    if ($bmp -eq $null) { Write-Output "== $v : MISSING"; continue }
    $s = if ($Scale -gt 0) { $Scale } else { $bmp.Width / 960.0 }
    Write-Output ("== {0}  ({1}x{2}, scale {3:0.##})" -f $v, $bmp.Width, $bmp.Height, $s)
    Write-Output ("   title ink   : " + (InkBox $bmp $s 495 36 700 68))
    Write-Output ("   lead ink    : " + (InkBox $bmp $s 495 70 945 100))
    Write-Output ("   buttons@497 : " + (RowRuns $bmp $s 497 600 945 10))
    Write-Output ("   col x=520   : " + (ColRuns $bmp $s 520 100 460 2))
    Write-Output ("   bg@(700,110): " + (Pixel $bmp $s 700 110))
    $bmp.Dispose()
}
