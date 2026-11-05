#Requires -Version 5.1
<#
.SYNOPSIS
  QIFW packaging environment health check. Exit code 0 = available, non-zero = not available.

.DESCRIPTION
  Checks are done in three levels:
    1. Prerequisites: OS bitness, MSVC 2022, CMake, VC runtime — missing items are only reported,
       but the VC runtime and 64-bit OS required to run Qt/QIFW block the conclusion.
    2. Tool existence: binarycreator / installerbase / archivegen / repogen
       execute, and print path and version.
    3. Version consistency: for executables that report a version, cross-check against the value
       registered in the manifest.
  An additional path guard check: after resolution, toolchainRoot must land inside this repository.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1
  # JSON result only
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1 -Json
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$ManifestPath = ''
)

. "$PSScriptRoot\_common.ps1"

# -Json is for script consumption: stdout must contain only JSON. Write-Host (including Write-Log) does not go
# through PowerShell 5.1's stdout redirection and is written straight into the pipeline, so in JSON mode progress lines are written to stderr.
if ($Json) {
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    function Write-Log {
        param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO')
        [Console]::Error.WriteLine(("[" + (Get-Date).ToString('HH:mm:ss') + "] [" + $Level + "] " + $Message))
    }
}

$RepoRoot = Get-RepoRoot
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Group, [string]$Name, [bool]$Ok, [string]$Detail, [string]$Fix = '', [switch]$Blocking)
    $results.Add([pscustomobject]@{
            Group    = $Group
            Name     = $Name
            Ok       = $Ok
            Detail   = $Detail
            Fix      = $Fix
            Blocking = [bool]$Blocking
        })
}

# --- 1. Prerequisites -----------------------------------------------------
Write-Log '== Prerequisites ==' 'STEP'

$os64 = [Environment]::Is64BitOperatingSystem
Add-Result 'Prerequisites' 'OS 64-bit' $os64 ($(if ($os64) { "$([Environment]::OSVersion.VersionString)" } else { '32-bit system' })) 'Install 64-bit Windows 10/11' -Blocking

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$msvcOk = $false; $msvcDetail = 'vswhere does not exist'
if (Test-Path -LiteralPath $vswhere) {
    $vs = & $vswhere -latest -version '[17.0,18.0)' -products * -format json 2>$null | ConvertFrom-Json
    if ($vs) {
        $msvcDetail = "$($vs.displayName) $($vs.installationVersion)"
        $toolset = Join-Path $vs.installationPath 'VC\Tools\MSVC'
        $msvcOk = Test-Path -LiteralPath $toolset
        if (-not $msvcOk) { $msvcDetail += ' (VC\Tools\MSVC not found)' }
    }
    else { $msvcDetail = 'VS 2022 not found' }
}
Add-Result 'Prerequisites' 'MSVC 2022' $msvcOk $msvcDetail 'Install Visual Studio 2022 (with C++ build tools)'

$cmake = Get-Command cmake -ErrorAction SilentlyContinue
$cmakeOk = [bool]$cmake
Add-Result 'Prerequisites' 'CMake' $cmakeOk ($(if ($cmakeOk) { (& cmake --version 2>$null | Select-Object -First 1) } else { 'not in PATH' })) 'Install CMake and add it to PATH'

$vcr = @('vcruntime140.dll', 'vcruntime140_1.dll') | ForEach-Object { Join-Path $env:SystemRoot "System32\$_" }
$vcrMissing = $vcr | Where-Object { -not (Test-Path -LiteralPath $_) }
$vcrOk = $vcrMissing.Count -eq 0
Add-Result 'Prerequisites' 'VC++ runtime' $vcrOk ($(if ($vcrOk) { 'vcruntime140 / vcruntime140_1 present' } else { "missing: $($vcrMissing -join ', ')" })) 'Install Microsoft Visual C++ 2015-2022 Redistributable' -Blocking

$sevenZip = Get-Command 7z -ErrorAction SilentlyContinue
if (-not $sevenZip) { $sevenZip = @(Get-Item 'C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe' -ErrorAction SilentlyContinue) | Select-Object -First 1 }
$sevenZipPath = if ($sevenZip) { if ($sevenZip.Source) { $sevenZip.Source } else { $sevenZip.FullName } } else { '' }
Add-Result 'Prerequisites' '7-Zip CLI (optional)' ([bool]$sevenZip) ($(if ($sevenZip) { $sevenZipPath } else { 'not installed; binarycreator has 7z archiving built in, not needed during smoke stage' })) '' -Blocking:$false

# --- 2. Path guard --------------------------------------------------------
Write-Log '== Path guard ==' 'STEP'

$ManifestOk = $false; $Manifest = $null; $ToolchainRoot = $null
try {
    $mPath = if ($ManifestPath) { $ManifestPath } else { Resolve-RepoPath 'packaging/qifw/toolchain/manifest.json' $RepoRoot }
    $Manifest = Get-Content -LiteralPath $mPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ToolchainRoot = Resolve-RepoPath -RelativePath $Manifest.toolchainRoot -RepoRoot $RepoRoot
    $ManifestOk = $true
    Add-Result 'Path guard' 'manifest readable and tool root inside repository' $true "toolchainRoot=$ToolchainRoot"
}
catch {
    Add-Result 'Path guard' 'manifest readable and tool root inside repository' $false $_.Exception.Message 'Fix manifest.json toolchainRoot to a relative path inside this repository' -Blocking
}

# --- 3. Tool existence ----------------------------------------------------
Write-Log '== Tools ==' 'STEP'

$toolFindings = @()
$expectedIfwRoot = $null
if ($ManifestOk) {
    $expectedIfwRoot = Resolve-RepoPath $Manifest.ifw.installDir $RepoRoot
    foreach ($tool in $Manifest.tools) {
        $found = $null
        $searched = @()

        # Prefer the relative path declared in the manifest, then look up by name under the tool root
        $declared = if ($tool.relativePath) { Join-Path $ToolchainRoot ($tool.relativePath -replace '/', '\') } else { $null }
        if ($declared) {
            $searched += $declared
            $direct = Get-Item -LiteralPath $declared -ErrorAction SilentlyContinue
            if ($direct) { $found = $direct }
        }
        if (-not $found) {
            $rel = if ($tool.relativePath) { $tool.relativePath } else { "$($tool.name).exe" }
            $leaf = Split-Path -Leaf $rel
            $hit = Get-ChildItem -LiteralPath $ToolchainRoot -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $found = $hit }
        }

        if (-not $found) {
            $expectHint = if ($tool.relativePath) { Join-Path $ToolchainRoot ($tool.relativePath -replace '/', '\') } else { "$ToolchainRoot\bin\$($tool.name).exe" }
            Add-Result 'Tools' $tool.name $false "not found; expected at $expectHint" 'Run install-toolchain.ps1 to fetch the toolchain' -Blocking
            $toolFindings += $tool.name
            continue
        }

        # Runnable determination:
        #   - launch failure (missing DLL / not a valid Win32 program) -> not available;
        #   - launches but reports an argument error ("Unknown option" / "Usage:" / missing config) -> available.
        #   So we only look for evidence that "the process can run", not at the exit code.
        $probeText = ''
        $runnable = $false
        $argList = @($tool.versionArgs | Where-Object { $_ })
        try {
            $out = & $found.FullName @argList 2>&1
            $exit = $LASTEXITCODE
            $probeText = ($out | Out-String).Trim()
            $startsUp = $probeText -match 'Usage:|Error:|--help|Options:|Cannot execute|unknown option'
            $loadFailure = $probeText -match '0xc000007b|0xc0000135|is not recognized|not a valid Win32'
            $runnable = $startsUp -and -not $loadFailure
        }
        catch {
            $probeText = $_.Exception.Message
            $runnable = $false
        }

        $detail = $found.FullName
        $firstLine = ($probeText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($firstLine) { $detail += " | $firstLine" }
        Add-Result 'Tools' $tool.name $runnable $detail 'Check that the VC++ runtime is complete, or re-fetch the toolchain' -Blocking

        # --- 4. Version consistency ---
        # None of the QIFW tools report their own version (--help only prints Usage, and the path inside it happens to
        # contain the version directory name, which is not a self-reported version). So version consistency is done with
        # two independent checks:
        #   a) the directory name where the tool actually landed must be manifest.ifw.version;
        #   b) the tool must be inside manifest.ifw.installDir.
        # When both come from the same source they pass together; changing only one (manifest version, directory,
        # tools[].relativePath) will be reported.
        $actualVer = [regex]::Match($found.FullName, 'QtInstallerFramework\\(\d+\.\d+(?:\.\d+)?)').Groups[1].Value
        $foundRelToRoot = $found.FullName.Substring($ToolchainRoot.Length).TrimStart('\') -replace '\\', '/'
        $declaredRel = if ($tool.relativePath) { $tool.relativePath } else { '' }
        $samePath = ($foundRelToRoot -eq $declaredRel)
        if (-not $samePath) {
            Add-Result 'Version' $tool.name $false "expected $($Manifest.ifw.version) / actual $(if ($actualVer) { $actualVer } else { 'unknown' }) (actual path $($found.FullName))" 'Update manifest ifw.version / installDir / tools[].relativePath, or re-fetch the matching toolchain version' -Blocking
        }
        elseif ($actualVer -and $actualVer -ne $Manifest.ifw.version) {
            Add-Result 'Version' $tool.name $false "expected $($Manifest.ifw.version) / actual $actualVer ($($found.FullName))" 'Update manifest.ifw.version and installDir, or re-fetch the matching toolchain version' -Blocking
        }
        elseif ($expectedIfwRoot -and -not $found.FullName.StartsWith($expectedIfwRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Result 'Version' $tool.name $false "expected $($Manifest.ifw.version) / actual $(if ($actualVer) { $actualVer } else { 'unknown' }) (not under $expectedIfwRoot)" 'Update manifest.ifw.installDir, or re-fetch the matching toolchain version' -Blocking
        }
    }
}

# --- 5. Overall conclusion ------------------------------------------------
$failedBlocking = @($results | Where-Object { -not $_.Ok -and $_.Blocking })
$failedWarn = @($results | Where-Object { -not $_.Ok -and -not $_.Blocking })
$available = $failedBlocking.Count -eq 0

if ($Json) {
    [pscustomobject]@{
        available = $available
        repoRoot  = $RepoRoot
        checks    = $results
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Host ''
    Write-Log '== Results ==' 'STEP'
    foreach ($g in ($results | Group-Object Group)) {
        Write-Host "  [$($g.Name)]"
        foreach ($r in $g.Group) {
            $mark = if ($r.Ok) { 'OK  ' } else { if ($r.Blocking) { 'FAIL' } else { 'WARN' } }
            $color = if ($r.Ok) { 'Green' } elseif ($r.Blocking) { 'Red' } else { 'Yellow' }
            Write-Host ("    {0} {1,-28} {2}" -f $mark, $r.Name, $r.Detail) -ForegroundColor $color
            if (-not $r.Ok -and $r.Fix) { Write-Host ("         -> $($r.Fix)") -ForegroundColor DarkYellow }
        }
    }
    Write-Host ''
    if ($failedBlocking.Count -gt 0) {
        Write-Log "Missing/mismatched (blocking): $($failedBlocking.Count) item(s)" 'ERROR'
    }
    if ($failedWarn.Count -gt 0) {
        Write-Log "Optional missing (non-blocking): $($failedWarn.Count) item(s)" 'WARN'
    }
    if ($available) { Write-Log 'Overall conclusion: available' 'OK' } else { Write-Log 'Overall conclusion: not available' 'ERROR' }
}

exit $(if ($available) { 0 } else { 1 })
