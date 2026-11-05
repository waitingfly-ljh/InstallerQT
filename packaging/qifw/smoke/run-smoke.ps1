#Requires -Version 5.1
<#
.SYNOPSIS
  QIFW smoke loop: package -> silent install -> hash verification -> silent uninstall -> cleanup verification.

.DESCRIPTION
  Runs the full binarycreator / installerbase / maintenancetool chain with the
  minimal package under smoke/, decoupling QIFW's own issues from those of the
  real 528 MB product tree.

  Each step's elapsed time, archive format, compression level, and effective
  values are written to out/smoke/<timestamp>/run-smoke.log and result.json.

  Install target and artifacts are all under out/smoke/<timestamp>/ inside this repo;
  after uninstall, maintenancetool --purge is used. If the directory still has residue
  (on Windows, a process holding its own maintenancetool.exe prevents deletion),
  the residue list written to disk is logged as WARN, not a failure.

.PARAMETER Compression
  Compression level passed to binarycreator --ac. QIFW accepts only 0/1/3/5/7/9, default 5.

.PARAMETER ArchiveFormat
  Archive format passed to binarycreator --af, default 7z.

.PARAMETER SkipUninstall
  Only package and install, skip uninstall (for inspecting install results manually).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1
  # Non-default compression level
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1 -Compression 9
#>
[CmdletBinding()]
param(
    [ValidateSet(0, 1, 3, 5, 7, 9)][int]$Compression = 5,
    [ValidateSet('7z', 'zip', 'tar', 'tar.gz', 'tar.bz2', 'tar.xz', 'qbsp')][string]$ArchiveFormat = '7z',
    [switch]$SkipUninstall
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'toolchain\_common.ps1')

# Unify child-process output and logs to UTF-8 (no BOM) so other tools don't read CJK as garbage
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = Get-RepoRoot -StartDir $PSScriptRoot
$Manifest = Get-ToolchainManifest -RepoRoot $RepoRoot
$ToolchainRoot = Get-ToolchainRoot -Manifest $Manifest -RepoRoot $RepoRoot
$IfwBin = Resolve-RepoPath -RelativePath $Manifest.ifw.installDir -RepoRoot $RepoRoot | ForEach-Object { Join-Path $_ 'bin' }

$SmokeDir = Resolve-RepoPath 'packaging/qifw/smoke' -RepoRoot $RepoRoot
$ConfigXml = Join-Path $SmokeDir 'config\config.xml'
$PackagesDir = Join-Path $SmokeDir 'packages'
$DataDir = Join-Path $PackagesDir 'com.orbbec.smoke\data'

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Resolve-RepoPath "packaging/qifw/out/smoke/$Stamp" -RepoRoot $RepoRoot
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LogPath = Join-Path $OutDir 'run-smoke.log'
$InstallerPath = Join-Path $OutDir 'SmokeInstaller.exe'
$InstallDir = Join-Path $OutDir 'install'
# IFW by default writes metadata cache to %LOCALAPPDATA%\cache\qt-installer-framework\<guid>,
# which is outside the repo. All install/uninstall calls use --cp pointing at this run's output dir.
$CacheDir = Join-Path $OutDir 'cache'
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

$steps = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[string]

function Add-Step {
    param([string]$Name, [bool]$Ok, [string]$Detail, [double]$Seconds = 0)
    $steps.Add([pscustomobject]@{ Step = $Name; Ok = $Ok; Detail = $Detail; Seconds = [math]::Round($Seconds, 2) })
    if ($Ok) { Write-Both ("{0} completed ({1}s)" -f $Name, [math]::Round($Seconds, 2)) 'OK' }
    else {
        Write-Both ("{0} failed: {1}" -f $Name, $Detail) 'ERROR'
        $failures.Add("${Name}: $Detail")
    }
}

function Write-Both {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Log $Message $Level
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

Write-Both "Repo root: $RepoRoot" 'INFO'
Write-Both "Toolchain root: $ToolchainRoot" 'INFO'
Write-Both "Output dir: $OutDir" 'INFO'

# --- 0. Preflight ---------------------------------------------------------
$binarycreator = Join-Path $IfwBin 'binarycreator.exe'
$installerbase = Join-Path $IfwBin 'installerbase.exe'
foreach ($exe in @($binarycreator, $installerbase)) {
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Both "Missing $exe, run toolchain\install-toolchain.ps1 first" 'ERROR'
        exit 1
    }
}
if (-not (Test-Path -LiteralPath $ConfigXml)) { Write-Both "Missing $ConfigXml" 'ERROR'; exit 1 }

# Expected file list: prefer the manifest committed with the package (a fixed baseline
# that reports which file is missing); fall back to "current state of data/" only when
# no manifest exists.
$payloadManifest = Join-Path $SmokeDir 'expected-payload.json'
if (Test-Path -LiteralPath $payloadManifest) {
    $manifestDoc = Get-Content -LiteralPath $payloadManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $expected = @(foreach ($f in $manifestDoc.files) {
            [pscustomobject]@{ Rel = $f.path; Hash = $f.sha256.ToLower(); Size = $f.size }
        })
    Write-Both "Expected files: $($expected.Count) (from expected-payload.json)" 'INFO'
}
else {
    $expected = @(Get-ChildItem -LiteralPath $DataDir -Recurse -File | ForEach-Object {
            [pscustomobject]@{
                Rel  = $_.FullName.Substring($DataDir.Length).TrimStart('\')
                Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
                Size = $_.Length
            }
        })
    Write-Both "Expected files: $($expected.Count) (from current data/, expected-payload.json not found)" 'WARN'
}
if ($expected.Count -lt 3) { Write-Both 'Expected list has fewer than 3 files; smoke package is insufficient for verification' 'ERROR'; exit 1 }

# --- 1. Package -----------------------------------------------------------
Write-Both '== 1. binarycreator package ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# -c must point at the config.xml file itself (pointing at a directory prints usage and exits 1)
# -t must explicitly specify installerbase.exe
$r = Invoke-Native -FilePath $binarycreator -ArgumentList @(
    '--offline-only', '-c', $ConfigXml, '-p', $PackagesDir, '-t', $installerbase,
    '--af', $ArchiveFormat, '--ac', "$Compression", '-v', $InstallerPath
) -LogPath $LogPath
$sw.Stop()
$built = (Test-Path -LiteralPath $InstallerPath)
$size = if ($built) { (Get-Item -LiteralPath $InstallerPath).Length } else { 0 }
Add-Step 'Package' ($r.ExitCode -eq 0 -and $built) "exit=$($r.ExitCode), artifact=$(if ($built) { "$size B" } else { 'missing' })" $sw.Elapsed.TotalSeconds
if (-not ($r.ExitCode -eq 0 -and $built)) {
    Write-Both 'Package failed, skipping remaining steps. See run-smoke.log for full output' 'ERROR'
    exit 1
}

# binarycreator -v does not echo the actual compression level, only the archive path and size;
# the compression level is recorded together with "passed argument + artifact byte count + SHA-256"
# so the caller can compare across runs.
$archiveEcho = ($r.Combined -split "`r?`n" | Where-Object { $_ -match 'Appending|Creating the binary' } | Select-Object -First 3) -join ' | '
Write-Both "Arguments: --offline-only --af $ArchiveFormat --ac $Compression" 'INFO'
Write-Both "binarycreator echo: $(if ($archiveEcho) { $archiveEcho } else { '(no archive info echoed)' })" 'INFO'
Write-Both ("Artifact: {0} = {1:N0} B" -f (Split-Path -Leaf $InstallerPath), $size) 'INFO'

# --- 2. Silent install ----------------------------------------------------
Write-Both '== 2. Silent install ==' 'STEP'
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# --platform minimal + -c --confirm-command --accept-licenses --accept-messages is the headless convention
$r = Invoke-Native -FilePath $InstallerPath -ArgumentList @(
    '--platform', 'minimal', 'in', '-c', '--confirm-command', '--accept-licenses', '--accept-messages',
    '--cp', $CacheDir, '-t', $InstallDir
) -LogPath $LogPath
$sw.Stop()
Add-Step 'Install' ($r.ExitCode -eq 0) "exit=$($r.ExitCode)" $sw.Elapsed.TotalSeconds
if ($r.ExitCode -ne 0) {
    Write-Both 'Install failed, skipping remaining steps.' 'ERROR'
    exit 1
}

# --- 3. Verify install result ---------------------------------------------
Write-Both '== 3. Verify install result ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$missing = New-Object System.Collections.Generic.List[string]
$mismatch = New-Object System.Collections.Generic.List[string]
foreach ($e in $expected) {
    $target = Join-Path $InstallDir ($e.Rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $target)) { $missing.Add($e.Rel); continue }
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $e.Hash) { $mismatch.Add("$($e.Rel) expected $($e.Hash) / actual $actual") }
}
$sw.Stop()
$problems = @()
if ($missing.Count) { $problems += ("missing " + $missing.Count + ": " + ($missing -join ', ')) }
if ($mismatch.Count) { $problems += ("hash mismatch " + $mismatch.Count + ": " + ($mismatch -join '; ')) }
# Shortcut: installscript.qs creates a .lnk under @StartMenuDir@; it must exist after install and
# disappear after uninstall. Note QIFW uninstall only removes shortcuts it registered itself and
# does not clear the whole StartMenuDir directory.
$shortcutDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\OrbbecSlicerQifwSmoke'
$shortcutPath = Join-Path $shortcutDir 'OrbbecSlicer QIFW Smoke.lnk'
$shortcutExistedBefore = Test-Path -LiteralPath $shortcutPath

Add-Step 'Verify install result' ($problems.Count -eq 0) ($(if ($problems.Count -eq 0) { "all $($expected.Count) files match" } else { $problems -join ' / ' })) $sw.Elapsed.TotalSeconds
$shortcutMade = Test-Path -LiteralPath $shortcutPath
Add-Step 'Verify shortcut' $shortcutMade ($(if ($shortcutMade) { $shortcutPath } else { "not created: $shortcutPath" }))
if ($problems.Count -gt 0) {
    if ($missing.Count) { Write-Both ("Missing relative paths: " + ($missing -join ', ')) 'ERROR' }
    if ($mismatch.Count) { $mismatch | ForEach-Object { Write-Both "hash mismatch: $_" 'ERROR' } }
    Write-Both 'Install result does not match data/, skipping uninstall to preserve state.' 'ERROR'
    Write-Both "On-site dir: $InstallDir" 'ERROR'
    Write-JsonFile -Path (Join-Path $OutDir 'result.json') -InputObject $steps -Depth 4
    exit 1
}

# --- 4. Silent uninstall --------------------------------------------------
$uninstallSeconds = 0
$residue = @()
if ($SkipUninstall) {
    Write-Both 'Skipping uninstall as requested (-SkipUninstall), install dir preserved' 'WARN'
    Add-Step 'Uninstall' $true 'skipped (-SkipUninstall)'
}
else {
    Write-Both '== 4. Silent uninstall ==' 'STEP'
    $mt = Join-Path $InstallDir 'maintenancetool.exe'
    if (-not (Test-Path -LiteralPath $mt)) {
        Add-Step 'Uninstall' $false "cannot find $mt"
    }
    else {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Native -FilePath $mt -ArgumentList @(
            '--platform', 'minimal', 'pr', '-c', '--confirm-command', '--accept-licenses', '--accept-messages',
            '--cp', $CacheDir
        ) -LogPath $LogPath
        $sw.Stop()
        $uninstallSeconds = $sw.Elapsed.TotalSeconds

        # After purge, maintenancetool may remain for a short while because it holds itself open
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            $left = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue)
            if ($left.Count -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
        $left = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($InstallDir.Length).TrimStart('\') })
        $payloadLeft = @($left | Where-Object { $_ -like 'payload*' })
        Add-Step 'Uninstall' ($r.ExitCode -eq 0 -and $payloadLeft.Count -eq 0) "exit=$($r.ExitCode), residue $($left.Count) items" $uninstallSeconds
        if ($left.Count -gt 0) {
            $residue = $left
            Write-Both ("Residue (mostly a process holding its own exe): " + ($left -join ', ')) 'WARN'
        }

        Write-Both '== 5. Verify cleanup ==' 'STEP'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $badLeft = @($expected | Where-Object { Test-Path -LiteralPath (Join-Path $InstallDir ($_.Rel -replace '/', '\')) })
        Add-Step 'Verify cleanup' ($badLeft.Count -eq 0) ($(if ($badLeft.Count) { "still present: " + (($badLeft | ForEach-Object Rel) -join ', ') } else { 'all expected files removed' })) $sw.Elapsed.TotalSeconds
        $shortcutLeft = Test-Path -LiteralPath $shortcutPath
        Add-Step 'Verify shortcut removal' (-not $shortcutLeft) ($(if ($shortcutLeft) { "still present: $shortcutPath" } else { 'shortcut deleted' }))
    }
}

# --- 6. Summary -----------------------------------------------------------
$result = [ordered]@{
    timestamp        = (Get-Date).ToString('o')
    repoRoot         = $RepoRoot
    qifwVersion      = $Manifest.ifw.version
    binarycreator    = $binarycreator
    archiveFormat    = $ArchiveFormat
    compression      = $Compression
    installerPath    = $InstallerPath
    installerBytes   = $size
    installerSha256  = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLower()
    installDir       = $InstallDir
    shortcutPath     = $shortcutPath
    shortcutExistedBefore = $shortcutExistedBefore
    expectedFiles    = $expected.Count
    uninstallSeconds = [math]::Round($uninstallSeconds, 2)
    residue          = $residue
    steps            = $steps
    failures         = $failures
    log              = $LogPath
}
$resultPath = Join-Path $OutDir 'result.json'
Write-JsonFile -Path $resultPath -InputObject ([pscustomobject]$result)

Write-Both "Result: $resultPath" 'INFO'
if ($failures.Count -gt 0) {
    Write-Both "Smoke loop failed at $($failures.Count) step(s)" 'ERROR'
    exit 1
}
Write-Both 'Smoke loop passed' 'OK'
exit 0
