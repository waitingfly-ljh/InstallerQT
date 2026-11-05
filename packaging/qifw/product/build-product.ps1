#Requires -Version 5.1
<#
.SYNOPSIS
  Package OrbbecSlicer's staging tree into a QIFW offline installer and generate a SHA-256 checksum.

.DESCRIPTION
  Read-only references to two locations in the original project:
    - <StageRoot>           product staging tree (default <UpstreamRepo>\build\presets\windows-release\OrbbecSlicer)
    - set(SLICER_APP_VERSION "...") in <UpstreamRepo>\version.inc

  This repo only writes out/product/<timestamp>/ and out/staging-work/<timestamp>/:
    staging-work is a copy of the staging tree (QIFW requires packages/<id>/data/ as the data directory,
    and building directly on the original tree would require creating directories in the original project, so copy first and then package).

  Steps:
    1. Resolve the version (missing version source => failure, no artifact produced)
    2. Snapshot the staging tree before and after (file count + content digest); abort on any mismatch
    3. Generate config.xml / package.xml (including icon, StartMenuDir, TargetDir)
    4. Package with binarycreator --offline-only
    5. Generate <artifact>.sha256, recompute and compare
    6. Silent install into a temp directory and compare each installed file against staging (the diff list must be empty)

.PARAMETER StageRoot
  Staging tree path. Must be absolute and exist; read-only.
  Empty (default) resolves to <UpstreamRepo>\build\presets\windows-release\OrbbecSlicer,
  i.e. the CMake preset install output of the original project.

.PARAMETER UpstreamRepo
  Original project root (used to read version.inc). Read-only.

.PARAMETER Compression
  binarycreator --ac level; only 0/1/3/5/7/9 accepted, default 5.

.PARAMETER SkipInstallVerify
  Skip step 6 (per-file comparison after install). This step takes a long time for 528 MB / 13k files.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\product\build-product.ps1
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\product\build-product.ps1 -Compression 9 -SkipInstallVerify
#>
[CmdletBinding()]
param(
    # 留空 ⇒ <UpstreamRepo>\build\presets\windows-release\OrbbecSlicer（在下方解析）
    [string]$StageRoot = '',
    [string]$UpstreamRepo = 'D:\Orbbec\orbbecslicer',
    [ValidateSet(0, 1, 3, 5, 7, 9)][int]$Compression = 5,
    [string]$ArchiveFormat = '7z',
    [switch]$SkipInstallVerify,
    # 8.4: do not build the shell; deliver the QIFW native package directly (deliverable = "qifw-native").
    [switch]$WithoutSetupUi
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'toolchain\_common.ps1')

# Unify child processes and logs to UTF-8 so other tools don't misread Chinese as mojibake
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = Get-RepoRoot -StartDir $PSScriptRoot
$Manifest = Get-ToolchainManifest -RepoRoot $RepoRoot
$IfwBin = Join-Path (Resolve-RepoPath -RelativePath $Manifest.ifw.installDir -RepoRoot $RepoRoot) 'bin'
$binarycreator = Join-Path $IfwBin 'binarycreator.exe'
$installerbase = Join-Path $IfwBin 'installerbase.exe'

# 默认 staging = 原项目 CMake preset 的安装产物（原项目已删除 packaging\windows\dist）
if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    $StageRoot = Join-Path $UpstreamRepo 'build\presets\windows-release\OrbbecSlicer'
}

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Resolve-RepoPath "packaging/qifw/out/product/$Stamp" -RepoRoot $RepoRoot
$WorkRoot = Resolve-RepoPath "packaging/qifw/out/staging-work/$Stamp" -RepoRoot $RepoRoot
New-Item -ItemType Directory -Force -Path $OutDir, $WorkRoot | Out-Null
$LogPath = Join-Path $OutDir 'build-product.log'

$steps = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[string]

function Write-Both {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Log $Message $Level
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("[{0}] [{1}] {2}" -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message)
}

function Add-Step {
    param([string]$Name, [bool]$Ok, [string]$Detail, [double]$Seconds = 0)
    $steps.Add([pscustomobject]@{ Step = $Name; Ok = $Ok; Detail = $Detail; Seconds = [math]::Round($Seconds, 2) })
    if ($Ok) { Write-Both ("{0} done ({1}s)" -f $Name, [math]::Round($Seconds, 2)) 'OK' }
    else { Write-Both ("{0} failed: {1}" -f $Name, $Detail) 'ERROR'; $failures.Add("${Name}: $Detail") }
}

function Exit-Fail {
    param([string]$Why)
    Write-Both $Why 'ERROR'
    Write-JsonFile -Path (Join-Path $OutDir 'result.json') -InputObject ([pscustomobject]@{ steps = $steps; failures = $failures }) -Depth 4
    exit 1
}

function Get-TreeDigest {
    <# Compute a content digest of a directory: sort by relative path, accumulate each file's SHA-256, then take the overall SHA-256. Read-only. #>
    param([Parameter(Mandatory)][string]$Path)
    $sb = New-Object System.Text.StringBuilder
    $files = Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName
    $total = [int64]0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Path.Length).TrimStart('\') -replace '\\', '/'
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        [void]$sb.AppendLine("$rel`t$($f.Length)`t$h")
        $total += $f.Length
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))).Replace('-', '').ToLower()
    }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ Path = $Path; FileCount = @($files).Count; TotalBytes = $total; Digest = $digest }
}

function Get-ChangedFileList {
    <# Compare the pre-packaging detail against the given directory and list deleted/size-changed/content-changed/added files (paths relative to staging). Read-only. #>
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][hashtable]$Before, [Parameter(Mandatory)][string]$BeforeRoot)
    $out = New-Object System.Collections.Generic.List[string]
    $now = @{ }
    foreach ($f in (Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)) {
        $now[$f.FullName.Substring($Dir.Length).TrimStart('\')] = $f
    }
    foreach ($p in $Before.Keys) {
        $rel = $p.Substring($BeforeRoot.Length).TrimStart('\')
        if (-not $now.ContainsKey($rel)) { $out.Add("deleted $($rel -replace '\\', '/')"); continue }
        $f = $now[$rel]
        if ($f.Length -ne $Before[$p].Size) { $out.Add("size changed $($rel -replace '\\', '/')"); continue }
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        if ($h -ne $Before[$p].Hash) { $out.Add("content changed $($rel -replace '\\', '/')") }
    }
    foreach ($rel in $now.Keys) {
        if (-not $Before.ContainsKey((Join-Path $BeforeRoot $rel))) { $out.Add("added $($rel -replace '\\', '/')") }
    }
    return , $out
}

Write-Both "Repo root: $RepoRoot" 'INFO'
Write-Both "staging: $StageRoot" 'INFO'
Write-Both "Output: $OutDir" 'INFO'

# --- 0. Preconditions (including toolchain registration gate)--------------------------------------------
foreach ($exe in @($binarycreator, $installerbase)) {
    if (-not (Test-Path -LiteralPath $exe)) { Exit-Fail "Missing $exe; run toolchain\install-toolchain.ps1 first" }
}
if (-not (Test-Path -LiteralPath $StageRoot)) { Exit-Fail "Staging tree does not exist: $StageRoot" }
if (-not [System.IO.Path]::IsPathRooted($StageRoot)) { Exit-Fail "StageRoot must be an absolute path: $StageRoot" }

# The build only accepts the toolchain registered in the manifest: abort if the version differs from the registered value or a tool is missing (no "good enough to work" exceptions)
Write-Both '== 0. Toolchain registration check ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$toolchain = Get-QifwToolchainStatus -Manifest $Manifest -RepoRoot $RepoRoot
$sw.Stop()
Add-Step 'Toolchain check' $toolchain.Available (
    "Qt $($toolchain.QtVersion) $($toolchain.Architecture) / QIFW $($toolchain.IfwVersion) (manifest sha256 $($toolchain.ArchiveSha256))" +
    $(if ($toolchain.Reason) { " | unavailable: $($toolchain.Reason)" } else { '' })) $sw.Elapsed.TotalSeconds
if ($toolchain.Warning) { Write-Both "Optional missing (non-blocking): $($toolchain.Warning)" 'WARN' }
if (-not $toolchain.Available) { Exit-Fail 'Toolchain does not match the manifest registration; aborted (no default version, no path substitution)' }

# --- 1. Version (5.1)--------------------------------------------------------
Write-Both '== 1. Resolve version ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$versionInc = Join-Path $UpstreamRepo 'version.inc'
if (-not (Test-Path -LiteralPath $versionInc)) {
    Exit-Fail "Version source not found: $versionInc (no hard-coded default version)"
}
# Anchor to line-start set(SLICER_APP_VERSION "x") to avoid accidentally matching derived lines like SLICER_APP_VERSION_MATCH
$versionLine = Select-String -Path $versionInc -Pattern '^\s*set\(\s*SLICER_APP_VERSION\s+"([^"]+)"\s*\)' |
    Select-Object -First 1
if (-not $versionLine) { Exit-Fail "set(SLICER_APP_VERSION \"...\") not found in version.inc: $versionInc" }
$appVersion = $versionLine.Matches[0].Groups[1].Value.Trim()
$sw.Stop()
Add-Step 'Resolve version' ($appVersion -ne '') "SLICER_APP_VERSION=$appVersion (line $($versionLine.LineNumber) of $versionInc, read-only)" $sw.Elapsed.TotalSeconds

$productName = 'OrbbecSlicer'
$componentId = 'com.orbbec.orbbecslicer'
$archTag = 'x64'
# Artifact name: product-version-arch-Installer.exe; -beta.N is allowed in the version
$installerName = "{0}-{1}-{2}-Installer.exe" -f $productName, $appVersion, $archTag
if ($installerName -notmatch '^[A-Za-z0-9._-]+\.exe$') { Exit-Fail "Artifact name contains invalid characters: $installerName" }
$installerPath = Join-Path $OutDir $installerName

# --- 2. Pre-packaging snapshot (5.2)--------------------------------------------------
Write-Both '== 2. staging tree snapshot (before packaging) ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$snapBefore = Get-TreeDigest -Path $StageRoot
$sw.Stop()
Add-Step 'Snapshot (before)' $true ("{0} files / {1:N0} B / {2}" -f $snapBefore.FileCount, $snapBefore.TotalBytes, $snapBefore.Digest) $sw.Elapsed.TotalSeconds
# Per-file detail is used after packaging to locate "which file changed" (the snapshot itself is not written to result.json, too large)
$filesBefore = @{}
foreach ($f in (Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force)) {
    $filesBefore[$f.FullName] = [pscustomobject]@{ Size = $f.Length; Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower() }
}

# --- 3. Assemble packages (5.2)------------------------------------------------
Write-Both '== 3. Copy staging to packages/<id>/data ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$packagesDir = Join-Path $WorkRoot 'packages'
$pkgDir = Join-Path $packagesDir $componentId
$metaDir = Join-Path $pkgDir 'meta'
$dataDir = Join-Path $pkgDir 'data'
$configDir = Join-Path $WorkRoot 'config'
# Create data/ before copying: after packaging it must be an existing directory so Get-TreeDigest can verify it
New-Item -ItemType Directory -Force -Path $dataDir, $metaDir, $configDir | Out-Null
# robocopy is much faster than Copy-Item, and /MIR guarantees data/ exactly matches staging
$rc = Invoke-Native -FilePath 'robocopy.exe' -ArgumentList @($StageRoot, $dataDir, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:1') -LogPath $LogPath
# robocopy: 0-7 means success
if ($rc.ExitCode -gt 7) { Exit-Fail "robocopy failed to copy staging (exit $($rc.ExitCode))" }
$sw.Stop()
$copied = Get-ChildItem -LiteralPath $dataDir -Recurse -File -Force
Add-Step 'Copy staging' ($copied.Count -eq $snapBefore.FileCount) ("{0} files (source {1})" -f $copied.Count, $snapBefore.FileCount) $sw.Elapsed.TotalSeconds

# Take the icon from the staging tree (read-only) and copy it into config/ for installerbase to use
$iconSrc = Join-Path $StageRoot 'resources\images\app_logo.ico'
$iconName = ''
if (Test-Path -LiteralPath $iconSrc) {
    Copy-Item -LiteralPath $iconSrc -Destination (Join-Path $configDir 'app_logo.ico') -Force
    $iconName = 'app_logo'
}
$iconXml = if ($iconName) { "    <InstallerApplicationIcon>$iconName</InstallerApplicationIcon>`r`n" } else { '' }

$configXmlPath = Join-Path $configDir 'config.xml'
$configXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Installer>
    <Name>$productName</Name>
    <Version>$appVersion</Version>
    <Title>$productName $appVersion</Title>
    <Publisher>Orbbec</Publisher>
    <StartMenuDir>$productName</StartMenuDir>
    <TargetDir>@ApplicationsDir@/$productName</TargetDir>
$iconXml    <!-- Offline installer: no RemoteRepositories configured -->
    <AllowNonAsciiCharacters>true</AllowNonAsciiCharacters>
    <AllowSpaceInPath>true</AllowSpaceInPath>
</Installer>
"@
[System.IO.File]::WriteAllText($configXmlPath, $configXml, (New-Object System.Text.UTF8Encoding($false)))

$packageXmlPath = Join-Path $metaDir 'package.xml'
$packageXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Package>
    <DisplayName>$productName</DisplayName>
    <Description>$productName desktop application (includes OCCT and runtime DLLs).</Description>
    <Version>$appVersion</Version>
    <ReleaseDate>$(Get-Date -Format 'yyyy-MM-dd')</ReleaseDate>
    <Name>$componentId</Name>
    <Default>true</Default>
    <ForcedInstallation>true</ForcedInstallation>
</Package>
"@
[System.IO.File]::WriteAllText($packageXmlPath, $packageXml, (New-Object System.Text.UTF8Encoding($false)))
Write-Both "config.xml / package.xml generated (icon: $(if ($iconName) { 'app_logo.ico' } else { 'none' }))" 'INFO'

# --- 4. Package (5.3)--------------------------------------------------------
Write-Both '== 4. binarycreator packaging ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Native -FilePath $binarycreator -ArgumentList @(
    '--offline-only', '-c', $configXmlPath, '-p', $packagesDir, '-t', $installerbase,
    '--af', $ArchiveFormat, '--ac', "$Compression", $installerPath
) -LogPath $LogPath
$sw.Stop()
$built = Test-Path -LiteralPath $installerPath
Add-Step 'Package' ($r.ExitCode -eq 0 -and $built) "exit=$($r.ExitCode), artifact=$(if ($built) { "{0:N0} B" -f (Get-Item $installerPath).Length } else { 'does not exist' })" $sw.Elapsed.TotalSeconds
if (-not ($r.ExitCode -eq 0 -and $built)) { Exit-Fail 'Packaging failed' }
$installerBytes = (Get-Item -LiteralPath $installerPath).Length
$buildSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)

# --- 5. Post-packaging snapshot (5.2)--------------------------------------------------
Write-Both '== 5. staging tree snapshot (after packaging) ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$snapAfter = Get-TreeDigest -Path $StageRoot
$same = ($snapBefore.FileCount -eq $snapAfter.FileCount) -and
        ($snapBefore.TotalBytes -eq $snapAfter.TotalBytes) -and
        ($snapBefore.Digest -eq $snapAfter.Digest)
if ($same) {
    $sw.Stop()
    Add-Step 'Snapshot (after) and compare' $true ("{0} files / {1:N0} B / {2}" -f $snapAfter.FileCount, $snapAfter.TotalBytes, $snapAfter.Digest) $sw.Elapsed.TotalSeconds
}
else {
    # Point out the specific changed files: added / deleted / size or content changed
    $changed = Get-ChangedFileList -Dir $StageRoot -Before $filesBefore -BeforeRoot $StageRoot
    $sw.Stop()
    $changedPath = Join-Path $OutDir 'staging-changes.txt'
    $changed | Set-Content -LiteralPath $changedPath -Encoding UTF8
    Remove-Item -LiteralPath $installerPath, "$installerPath.sha256" -Force -ErrorAction SilentlyContinue
    Add-Step 'Snapshot (after) and compare' $false ("{0} files / {1:N0} B / {2}; {3} changed item(s){4} (list {5})" -f `
            $snapAfter.FileCount, $snapAfter.TotalBytes, $snapAfter.Digest, $changed.Count,
        $(if ($changed.Count) { ': ' + (($changed | Select-Object -First 10) -join '; ') } else { '' }), $changedPath) $sw.Elapsed.TotalSeconds
    Exit-Fail 'Staging tree changed between before and after packaging (the script must not write to the original project); aborted; artifact discarded, find the source of the change first'
}

# --- 5b. Working copy check -------------------------------------------------------
# The data/ under packages/ is what actually goes into the artifact; staging not changing does not mean it did not change.
# If it changes between the copy finishing and packaging ending (or the copy itself is wrong), the artifact content will not match staging,
# and it must be handled the same as "input tree accidentally modified": non-zero exit, point out the files, discard the artifact.
Write-Both '== 5b. Working copy data/ check ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$snapWork = Get-TreeDigest -Path $dataDir
$sameWork = ($snapWork.FileCount -eq $snapBefore.FileCount) -and
            ($snapWork.TotalBytes -eq $snapBefore.TotalBytes) -and
            ($snapWork.Digest -eq $snapBefore.Digest)
if ($sameWork) {
    $sw.Stop()
    Add-Step 'Working copy check' $true ("{0} files / {1:N0} B / {2} (matches staging)" -f $snapWork.FileCount, $snapWork.TotalBytes, $snapWork.Digest) $sw.Elapsed.TotalSeconds
}
else {
    $workChanged = Get-ChangedFileList -Dir $dataDir -Before $filesBefore -BeforeRoot $StageRoot
    $sw.Stop()
    $changedPath = Join-Path $OutDir 'staging-changes.txt'
    $workChanged | Set-Content -LiteralPath $changedPath -Encoding UTF8
    Add-Step 'Working copy check' $false ("{0} files / {1:N0} B / {2}; {3} difference(s) from staging{4} (list {5})" -f `
            $snapWork.FileCount, $snapWork.TotalBytes, $snapWork.Digest, $workChanged.Count,
        $(if ($workChanged.Count) { ': ' + (($workChanged | Select-Object -First 10) -join '; ') } else { '' }), $changedPath) $sw.Elapsed.TotalSeconds
    # Discard this artifact and checksum file so "exit non-zero but the exe is still there and gets published by mistake" cannot happen
    Remove-Item -LiteralPath $installerPath, "$installerPath.sha256" -Force -ErrorAction SilentlyContinue
    Exit-Fail 'Working copy data/ was modified during packaging; artifact discarded; find the source of the change and rerun'
}

# --- 6. SHA-256 (5.4)-----------------------------------------------------
Write-Both '== 6. Generate and verify SHA-256 ==' 'STEP'
$sha1 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLower()
$shaFile = "$installerPath.sha256"
# Same format as the official Qt .sha256: <hash> *<file name>
[System.IO.File]::WriteAllText($shaFile, "$sha1 *$installerName`n", (New-Object System.Text.ASCIIEncoding))
$recomputed = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLower()
$fromFile = (Get-Content -LiteralPath $shaFile -Raw).Split(' ')[0].Trim().ToLower()
Add-Step 'SHA-256' ($sha1 -eq $recomputed -and $sha1 -eq $fromFile) ("$sha1 (file $shaFile)")
$nameOk = ($installerName -match [regex]::Escape($productName)) -and ($installerName -match [regex]::Escape($appVersion)) -and ($installerName -match [regex]::Escape($archTag))
Add-Step 'Artifact naming' $nameOk $installerName

# --- 6b. Build shell (8.1) and assemble deliverable (8.2)---------------------------------
$setupPath = $null
$setupName = $null
$setupBytes = 0
if ($WithoutSetupUi) {
    Write-Both 'Skipping the shell as requested (-WithoutSetupUi): delivering the QIFW native package' 'WARN'
    $deliverable = 'qifw-native'
} else {
    Write-Both '== 6b. Build installer shell ==' 'STEP'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $shellScript = Join-Path $RepoRoot 'packaging\qifw\setup-ui\build-setup.ps1'
    if (-not (Test-Path -LiteralPath $shellScript)) {
        Add-Step 'Build shell' $false "build-setup.ps1 not found: $shellScript" 0
        Exit-Fail 'Shell source incomplete; aborted (no Setup.exe produced)'
    }
    $r = Invoke-Native -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $shellScript,
        '-Version', $appVersion, '-Selftest'
    ) -LogPath $LogPath
    $sw.Stop()
    $shellExe = Join-Path $RepoRoot 'packaging\qifw\setup-ui\dist\OrbbecSlicerSetup.exe'
    $shellOk = ($r.ExitCode -eq 0) -and (Test-Path -LiteralPath $shellExe)
    Add-Step 'Build shell' $shellOk "exit=$($r.ExitCode), exe=$(if ($shellOk) { "{0:N0} B" -f (Get-Item $shellExe).Length } else { 'does not exist' })" $sw.Elapsed.TotalSeconds
    if (-not $shellOk) {
        # Shell build failed: abort by default and do not produce Setup.exe (Installer.exe is kept as an intermediate artifact).
        Exit-Fail "Shell build failed (see log: $LogPath)"
    }

    Write-Both '== 6c. Assemble single-file Setup.exe ==' 'STEP'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $setupName = "{0}-{1}-{2}-Setup.exe" -f $productName, $appVersion, $archTag
    $setupPath = Join-Path $OutDir $setupName
    $packScript = Join-Path $RepoRoot 'packaging\qifw\setup-ui\package-setup.ps1'
    $launcherExe = Join-Path $RepoRoot 'packaging\qifw\setup-ui\build\OrbbecSlicerSetupLauncher.exe'
    $uninstallerExe = Join-Path $RepoRoot 'packaging\qifw\setup-ui\build\OrbbecSlicerUninstaller.exe'
    $uiDir = Join-Path $RepoRoot 'packaging\qifw\setup-ui\dist'
    if (-not (Test-Path -LiteralPath $launcherExe)) {
        Add-Step 'Assemble deliverable' $false "Launcher not found: $launcherExe" 0
        Exit-Fail 'Launcher missing; aborted (no Setup.exe produced)'
    }
    if (-not (Test-Path -LiteralPath $uninstallerExe)) {
        Add-Step 'Assemble deliverable' $false "Uninstaller not found: $uninstallerExe" 0
        Exit-Fail 'Uninstaller missing; aborted (no Setup.exe produced)'
    }
    $r = Invoke-Native -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $packScript,
        '-LauncherExe', $launcherExe, '-UiDir', $uiDir, '-InstallerExe', $installerPath,
        '-UninstallerExe', $uninstallerExe,
        '-OutputPath', $setupPath, '-Version', $appVersion
    ) -LogPath $LogPath
    $sw.Stop()
    $setupOk = ($r.ExitCode -eq 0) -and (Test-Path -LiteralPath $setupPath)
    if ($setupOk) { $setupBytes = (Get-Item -LiteralPath $setupPath).Length }
    Add-Step 'Assemble deliverable' $setupOk "exit=$($r.ExitCode), artifact=$(if ($setupOk) { "{0:N0} B" -f $setupBytes } else { 'does not exist' })" $sw.Elapsed.TotalSeconds
    if (-not $setupOk) {
        Remove-Item -LiteralPath $setupPath, "$setupPath.sha256" -Force -ErrorAction SilentlyContinue
        Exit-Fail "Failed to assemble Setup.exe (see log: $LogPath)"
    }
    $setupSha = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLower()
    [System.IO.File]::WriteAllText("$setupPath.sha256", "$setupSha *$setupName`n", (New-Object System.Text.ASCIIEncoding))
    $deliverable = 'setup-shell'
    Write-Both ("Deliverable: {0} = {1:N0} B (Installer {2:N0} B, difference {3:N0} B)" -f `
            $setupName, $setupBytes, $installerBytes, ($setupBytes - $installerBytes)) 'INFO'
}

# --- 7. Per-file comparison after install (5.3)--------------------------------------------
$installSeconds = 0
$installOk = $null
$diffCount = $null
$uninstallSeconds = 0
if ($SkipInstallVerify) {
    Write-Both 'Skipping per-file comparison after install as requested (-SkipInstallVerify)' 'WARN'
}
else {
    Write-Both '== 7. Silent install and per-file comparison ==' 'STEP'
    $instDir = Join-Path $OutDir 'install'
    $cacheDir = Join-Path $OutDir 'cache'
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    # Native install is occasionally killed mid-extraction by an external process (security software / resource scanner): exit=-1,
    # missing files in the install directory, maintenancetool.exe not written. Clean the target directory and retry once.
    $installComplete = $false
    $installAttempts = 0
    while (-not $installComplete -and $installAttempts -lt 2) {
        $installAttempts++
        if (Test-Path -LiteralPath $instDir) {
            Start-Sleep -Milliseconds 500
            Remove-Item -LiteralPath $instDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Native -FilePath $installerPath -ArgumentList @(
            '--platform', 'minimal', 'in', '-c', '--confirm-command', '--accept-licenses', '--accept-messages',
            '--cp', $cacheDir, '-t', $instDir
        ) -LogPath $LogPath
        $sw.Stop()
        $installSeconds += [math]::Round($sw.Elapsed.TotalSeconds, 2)
        $installComplete = ($r.ExitCode -eq 0) -and (Test-Path -LiteralPath (Join-Path $instDir 'maintenancetool.exe'))
        if (-not $installComplete -and $installAttempts -lt 2) {
            Write-Both "Silent install incomplete (exit=$($r.ExitCode)); cleaning the target directory and retrying once" 'WARN'
        }
    }
    Add-Step 'Silent install' $installComplete "exit=$($r.ExitCode), $installAttempts attempt(s)" $installSeconds

    Write-Both '== 8. Diff list ==' 'STEP'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $diff = New-Object System.Collections.Generic.List[string]
    $stageFiles = Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force
    foreach ($f in $stageFiles) {
        $rel = $f.FullName.Substring($StageRoot.Length).TrimStart('\')
        $t = Join-Path $instDir $rel
        if (-not (Test-Path -LiteralPath $t)) { $diff.Add("missing $rel"); continue }
        if ((Get-Item -LiteralPath $t).Length -ne $f.Length) { $diff.Add("size mismatch $rel"); continue }
    }
    $sw.Stop()
    $diffCount = $diff.Count
    Add-Step 'Diff list' ($diff.Count -eq 0) ($(if ($diff.Count) { "$($diff.Count) difference(s), first 10: " + (($diff | Select-Object -First 10) -join '; ') } else { "$(@(Get-ChildItem -LiteralPath $instDir -Recurse -File -Force).Count - $stageFiles.Count) installer's own file(s) added, all $($stageFiles.Count) staging files in place" })) $sw.Elapsed.TotalSeconds
    $diff | Set-Content -LiteralPath (Join-Path $OutDir 'install-diff.txt') -Encoding UTF8
    $installOk = ($diff.Count -eq 0) -and $installComplete

    Write-Both '== 9. Uninstall ==' 'STEP'
    $mt = Join-Path $instDir 'maintenancetool.exe'
    if (Test-Path -LiteralPath $mt) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ru = Invoke-Native -FilePath $mt -ArgumentList @(
            '--platform', 'minimal', 'pr', '-c', '--confirm-command', '--accept-licenses', '--accept-messages', '--cp', $cacheDir
        ) -LogPath $LogPath
        $sw.Stop()
        $uninstallSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        # QIFW's pr cannot delete the running maintenancetool.exe, so the native loop always leaves metadata behind;
        # therefore only assert the exit code here and write the residual list to disk for diagnostics; the strong "directory entirely gone"
        # assertion is in the 9c shell loop (the shell deletes it after the child process exits).
        $nativeResidual = @()
        if (Test-Path -LiteralPath $instDir) {
            $nativeResidual = @(
                Get-ChildItem -LiteralPath $instDir -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.FullName.Substring($instDir.Length).TrimStart('\') } |
                    Select-Object -First 20
            )
            if ($nativeResidual.Count -gt 0) {
                $nativeResidual | Set-Content -LiteralPath (Join-Path $OutDir 'install-uninstall-residual.txt') -Encoding UTF8
            }
        }
        $nativeDetail = "exit=$($ru.ExitCode)"
        if ($nativeResidual.Count -gt 0) {
            $nativeDetail += "; QIFW self-delete limitation, $($nativeResidual.Count) residual item(s) (first 5: " + (($nativeResidual | Select-Object -First 5) -join '; ') + ")"
        } else {
            $nativeDetail += '; install directory emptied'
        }
        Add-Step 'Uninstall' ($ru.ExitCode -eq 0) $nativeDetail $uninstallSeconds
    }
}

# --- 9b. Full shell loop verification (8.3)---------------------------------------------
$setupInstallOk = $null
$setupDiffCount = $null
$setupUninstallOk = $null
$uninstallerEntryOk = $null
$uninstallerPath = $null
$uninstallerBytes = 0
$setupShellLog = Join-Path $OutDir 'setup-shell.log'

function Find-OrbbecUninstallEntry([string]$dir) {
    $want = [System.IO.Path]::GetFullPath($dir)
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $v -or $v.DisplayName -ne $productName) { continue }
            try { $loc = [System.IO.Path]::GetFullPath($v.InstallLocation) } catch { continue }
            if ($loc -ieq $want) { return $v }
        }
    }
    return $null
}

function Find-OrbbecEntriesForDir([string]$dir) {
    $want = [System.IO.Path]::GetFullPath($dir)
    $res = New-Object System.Collections.Generic.List[object]
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $v -or $v.DisplayName -ne $productName) { continue }
            try { $loc = [System.IO.Path]::GetFullPath($v.InstallLocation) } catch { continue }
            if ($loc -ieq $want) { $res.Add($v) }
        }
    }
    return $res.ToArray()
}

function Find-AllOrbbecEntries {
    $res = New-Object System.Collections.Generic.List[object]
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $v -and $v.DisplayName -eq $productName) {
                $v | Add-Member -NotePropertyName '_KeyPath' -NotePropertyValue $k.PSPath -Force
                $res.Add($v)
            }
        }
    }
    return $res.ToArray()
}

$iconProbeSrc = @"
using System;
using System.Runtime.InteropServices;
public static class IconProbe {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr LoadLibraryExW(string file, IntPtr h, uint flags);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr h);
    delegate bool EnumProc(IntPtr h, IntPtr type, IntPtr name, IntPtr param);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumResourceNamesW(IntPtr h, IntPtr type, EnumProc cb, IntPtr param);
    static bool _found;
    static bool Cb(IntPtr h, IntPtr type, IntPtr name, IntPtr param) { _found = true; return false; }
    public static bool HasGroupIcon(string path) {
        IntPtr h = LoadLibraryExW(path, IntPtr.Zero, 0x00000002);
        if (h == IntPtr.Zero) return false;
        _found = false;
        EnumResourceNamesW(h, new IntPtr(14), Cb, IntPtr.Zero);
        FreeLibrary(h);
        return _found;
    }
}
"@
if (-not ('IconProbe' -as [type])) { Add-Type $iconProbeSrc }

if ($setupPath -and -not $SkipInstallVerify) {
    # Test hook: redirect both the uninstaller deployment location and the data cleanup root to out/, leaving real user data on this machine untouched.
    $dataRoot = Join-Path $OutDir 'data-root'
    $env:ORBBEC_SETUP_DATA_ROOT = $dataRoot
    New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null

    Write-Both '== 9b. Shell silent install ==' 'STEP'
    $setupInstDir = Join-Path $OutDir 'install-setup'
    # Same retry policy as the outer native install: clean and retry once when killed externally / maintenancetool missing.
    $setupInstallComplete = $false
    $setupInstallAttempts = 0
    $setupInstallSeconds = 0
    while (-not $setupInstallComplete -and $setupInstallAttempts -lt 2) {
        $setupInstallAttempts++
        if (Test-Path -LiteralPath $setupInstDir) {
            Start-Sleep -Milliseconds 500
            Remove-Item -LiteralPath $setupInstDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Native -FilePath $setupPath -ArgumentList @(
            '--log', $setupShellLog, '--with-options', '--silent', 'in', '-t', $setupInstDir
        ) -LogPath $LogPath
        $sw.Stop()
        $setupInstallSeconds += [math]::Round($sw.Elapsed.TotalSeconds, 2)
        $setupInstallComplete = ($r.ExitCode -eq 0) -and (Test-Path -LiteralPath (Join-Path $setupInstDir 'maintenancetool.exe'))
        if (-not $setupInstallComplete -and $setupInstallAttempts -lt 2) {
            Write-Both "Shell silent install incomplete (exit=$($r.ExitCode)); cleaning the target directory and retrying once" 'WARN'
        }
    }
    Add-Step 'Shell silent install' $setupInstallComplete "exit=$($r.ExitCode), $setupInstallAttempts attempt(s) (shell log $setupShellLog)" $setupInstallSeconds

    $setupDiff = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $setupInstDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force)) {
            $rel = $f.FullName.Substring($StageRoot.Length).TrimStart('\')
            $t = Join-Path $setupInstDir $rel
            if (-not (Test-Path -LiteralPath $t)) { $setupDiff.Add("missing $rel"); continue }
            if ((Get-Item -LiteralPath $t).Length -ne $f.Length) { $setupDiff.Add("size mismatch $rel") }
        }
    } else {
        $setupDiff.Add('install directory does not exist')
    }
    $setupDiffCount = $setupDiff.Count
    if ($setupDiffCount -gt 0) {
        $setupDiff | Set-Content -LiteralPath (Join-Path $OutDir 'install-setup-diff.txt') -Encoding UTF8
    }
    Add-Step 'Shell install diff' ($setupDiffCount -eq 0) ($(if ($setupDiffCount) { "$setupDiffCount difference(s), first 10: " + (($setupDiff | Select-Object -First 10) -join '; ') } else { "all $(@(Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force).Count) staging files in place" }))

    $desktopDir = [Environment]::GetFolderPath('Desktop')
    $desktopLnk = Join-Path $desktopDir 'OrbbecSlicer.lnk'
    $desktopCreated = Test-Path -LiteralPath $desktopLnk
    $assocCreated = (Get-ItemProperty 'HKCU:\Software\Classes\.3mf' -ErrorAction SilentlyContinue).'(default)' -eq 'OrbbecSlicer.3mf'
    Add-Step 'Install options applied' ($desktopCreated -and $assocCreated) ("desktop shortcut=$(if ($desktopCreated) { 'yes' } else { 'no' }); .3mf association=$(if ($assocCreated) { 'set' } else { 'not set' })")

    Write-Both '== 9b2. Uninstall entry check ==' 'STEP'
    $entry = Find-OrbbecUninstallEntry $setupInstDir
    $uninstallerEntryOk = $false
    $uninstallerEntryCount = @(Find-OrbbecEntriesForDir $setupInstDir).Count
    if ($entry) {
        $uninstallerPath = $entry.DisplayIcon
        if (Test-Path -LiteralPath $uninstallerPath) { $uninstallerBytes = (Get-Item -LiteralPath $uninstallerPath).Length }
        $fieldsOk = $entry.Publisher -and $entry.DisplayVersion -and $entry.InstallLocation -and
                    $entry.DisplayIcon -and $entry.UninstallString -match 'OrbbecSlicerUninstaller\.exe' -and
                    $entry.QuietUninstallString -match '--uninstall' -and
                    (Test-Path -LiteralPath $entry.DisplayIcon) -and ([int]$entry.EstimatedSize -gt 0)
        $uninstallerEntryOk = $fieldsOk -and ($uninstallerEntryCount -eq 1)
    }
    Add-Step 'Uninstall entry check' $uninstallerEntryOk ($(if ($entry) { "entry count=$uninstallerEntryCount; UninstallString=$($entry.UninstallString); DisplayIcon=$($entry.DisplayIcon); EstimatedSize=$($entry.EstimatedSize)KB" } else { 'no uninstall registration pointing to the branded uninstaller found' }))

    Write-Both '== 9b3. Icon check ==' 'STEP'
    $iconsVerified = [IconProbe]::HasGroupIcon($setupPath)
    if ($uninstallerPath) { $iconsVerified = $iconsVerified -and [IconProbe]::HasGroupIcon($uninstallerPath) }
    Add-Step 'Icon check' $iconsVerified ("Setup.exe=$(if ($iconsVerified) { 'has icon' } else { 'missing icon' }); uninstaller=$uninstallerPath")

    Write-Both '== 9c. Silent uninstall from the uninstall entry ==' 'STEP'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $uninstallExit = -1
    if ($entry -and (Test-Path -LiteralPath $entry.DisplayIcon)) {
        $r = Invoke-Native -FilePath $entry.DisplayIcon -ArgumentList @(
            '--uninstall', '--install-dir', $setupInstDir, '--silent'
        ) -LogPath $LogPath
        $uninstallExit = $r.ExitCode
    }
    $sw.Stop()
    # The uninstaller's self-delete and registration cleanup are delayed (the launcher waits for the UI to exit before deleting the directory): poll for up to 10 seconds.
    $uninstDir = Join-Path $dataRoot 'Local\Orbbec\OrbbecSlicer\uninstaller'
    $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\OrbbecSlicer\Uninstall OrbbecSlicer.lnk'
    $uninstallCleanupVerified = $false
    $dirGone = $false
    for ($i = 0; $i -lt 20; $i++) {
        # The install directory must disappear entirely: checking only maintenancetool.exe would miss QIFW metadata
        # residue such as components.xml, installerResources, network.xml.
        $dirGone = -not (Test-Path -LiteralPath $setupInstDir)
        $entryGone = -not (Find-OrbbecUninstallEntry $setupInstDir)
        $uninstGone = -not (Test-Path -LiteralPath $uninstDir)
        $lnkGone = -not (Test-Path -LiteralPath $lnk)
        $desktopGone = -not (Test-Path -LiteralPath $desktopLnk)
        $assoc = (Get-ItemProperty 'HKCU:\Software\Classes\.3mf' -ErrorAction SilentlyContinue).'(default)'
        $assocReverted = ($assoc -ne 'OrbbecSlicer.3mf')
        $progGone = -not (Test-Path -LiteralPath 'HKCU:\Software\Classes\OrbbecSlicer.3mf')
        $entryCountAfter = @(Find-OrbbecEntriesForDir $setupInstDir).Count
        $uninstallCleanupVerified = $dirGone -and $entryGone -and $uninstGone -and $lnkGone -and
                                    $desktopGone -and $assocReverted -and $progGone -and ($entryCountAfter -eq 0)
        if ($uninstallCleanupVerified) { break }
        Start-Sleep -Milliseconds 500
    }
    # When the directory is left over, write the list to disk and into the step detail so it is easy to see which file was not deleted.
    $uninstallResidual = @()
    if (-not $dirGone -and (Test-Path -LiteralPath $setupInstDir)) {
        $uninstallResidual = @(
            Get-ChildItem -LiteralPath $setupInstDir -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($setupInstDir.Length).TrimStart('\') } |
                Select-Object -First 20
        )
        if ($uninstallResidual.Count -gt 0) {
            $uninstallResidual | Set-Content -LiteralPath (Join-Path $OutDir 'uninstall-residual.txt') -Encoding UTF8
        }
    }
    $setupUninstallOk = ($uninstallExit -eq 0) -and $uninstallCleanupVerified
    $dirDetail = if ($dirGone) { 'deleted' } elseif ($uninstallResidual.Count -gt 0) {
        'residual: ' + ($uninstallResidual -join '; ')
    } else { 'residual' }
    Add-Step 'Silent uninstall from the uninstall entry' $setupUninstallOk ("exit=$uninstallExit; install directory $dirDetail; registration $(if ($entryGone) { 'deleted' } else { 'residual' }); uninstaller $(if ($uninstGone) { 'deleted' } else { 'residual' }); Start Menu $(if ($lnkGone) { 'deleted' } else { 'residual' }); desktop shortcut $(if ($desktopGone) { 'deleted' } else { 'residual' }); .3mf association $(if ($assocReverted) { 'reverted' } else { 'still OrbbecSlicer.3mf' }); ProgId $(if ($progGone) { 'deleted' } else { 'residual' }); remaining entries $entryCountAfter") $sw.Elapsed.TotalSeconds

    $setupInstallOk = $setupInstallComplete -and ($setupDiffCount -eq 0) -and $uninstallerEntryOk -and $setupUninstallOk
    if (-not $setupInstallOk) {
        # On failure discard Setup.exe and the checksum file so they are not published by mistake.
        Remove-Item -LiteralPath $setupPath, "$setupPath.sha256" -Force -ErrorAction SilentlyContinue
        Add-Step 'Shell full loop' $false "Shell silent / uninstall-entry loop failed; Setup.exe and checksum file discarded; logs: $LogPath / $setupShellLog"
        Exit-Fail "Shell full loop failed (logs: $LogPath / $setupShellLog)"
    }
    Add-Step 'Shell full loop' $true "silent install -> per-file comparison -> uninstall entry check -> silent uninstall from entry -> cleanup all passed"
    Remove-Item Env:\ORBBEC_SETUP_DATA_ROOT -ErrorAction SilentlyContinue
} elseif ($setupPath) {
    Write-Both 'Skipping the shell silent loop as requested (-SkipInstallVerify)' 'WARN'
}

# --- 10. Summary -------------------------------------------------------------
$nsisBaseline = 159936312
$deliverable = 'qifw-native'
if (-not $WithoutSetupUi) { $deliverable = 'setup-shell' }
$result = [ordered]@{
    timestamp         = (Get-Date).ToString('o')
    product           = $productName
    version           = $appVersion
    componentId       = $componentId
    architecture      = $archTag
    stageRoot         = $StageRoot
    upstreamRepo      = $UpstreamRepo
    versionSource     = "$versionInc : $($versionLine.LineNumber)"
    toolchain         = [ordered]@{
        qtVersion     = $toolchain.QtVersion
        architecture  = $toolchain.Architecture
        ifwVersion    = $toolchain.IfwVersion
        archiveSha256 = $toolchain.ArchiveSha256
        binarycreator = $binarycreator
        available     = $toolchain.Available
        manifest      = $Manifest._manifestPath
    }
    staging           = [ordered]@{ fileCount = $snapBefore.FileCount; totalBytes = $snapBefore.TotalBytes; digestBefore = $snapBefore.Digest; digestAfter = $snapAfter.Digest; unchanged = $same }
    workCopy          = [ordered]@{ fileCount = $snapWork.FileCount; totalBytes = $snapWork.TotalBytes; digest = $snapWork.Digest; matchesStaging = $sameWork }
    archiveFormat     = $ArchiveFormat
    compression       = $Compression
    binarycreatorArgs = "--offline-only -c <config.xml> -p <packages> -t <installerbase> --af $ArchiveFormat --ac $Compression"
    installerPath     = $installerPath
    installerBytes    = $installerBytes
    installerSha256   = $sha1
    deliverable       = $deliverable
    setupPath         = $setupPath
    setupBytes        = $setupBytes
    setupVsInstallerBytes = $(if ($setupBytes -gt 0) { $setupBytes - $installerBytes } else { 0 })
    setupVsNsis       = $(if ($setupBytes -gt 0) { [math]::Round(($setupBytes - $nsisBaseline) / $nsisBaseline, 4) } else { $null })
    setupInstallVerified = $setupInstallOk
    uninstallerPath   = $uninstallerPath
    uninstallerBytes  = $uninstallerBytes
    uninstallerEntryVerified = $uninstallerEntryOk
    iconsVerified     = $iconsVerified
    uninstallEntryCount = $uninstallerEntryCount
    uninstallCleanupVerified = $uninstallCleanupVerified
    nsisBaselineBytes = $nsisBaseline
    sizeVsNsis        = [math]::Round(($installerBytes - $nsisBaseline) / $nsisBaseline, 4)
    buildSeconds      = $buildSeconds
    installSeconds    = $installSeconds
    uninstallSeconds  = $uninstallSeconds
    installVerified   = $installOk
    diffCount         = $diffCount
    steps             = $steps
    failures          = $failures
    log               = $LogPath
}
Write-JsonFile -Path (Join-Path $OutDir 'result.json') -InputObject ([pscustomobject]$result)

Write-Both ("Artifact: {0} = {1:N0} B (NSIS baseline {2:N0} B, relative {3:P1})" -f $installerName, $installerBytes, $nsisBaseline, (($installerBytes - $nsisBaseline) / $nsisBaseline)) 'INFO'
Write-Both "Result: $(Join-Path $OutDir 'result.json')" 'INFO'
if ($failures.Count -gt 0) { Write-Both "Packaging flow failed at $($failures.Count) step(s)" 'ERROR'; exit 1 }

# After passing, clean up working copies from other batches (~0.5 GB each): logs stay with the result directory and the cache directory is shared via --cp, so neither is cleaned
$workParent = Split-Path -Parent $WorkRoot
foreach ($d in (Get-ChildItem -LiteralPath $workParent -Directory -ErrorAction SilentlyContinue)) {
    if ($d.FullName -ne $WorkRoot) {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Both "Cleaned old working copy: $($d.FullName)" 'INFO'
    }
}
Write-Both 'Product packaging all passed' 'OK'
exit 0
