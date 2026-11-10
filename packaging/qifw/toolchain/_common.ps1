#Requires -Version 5.1
<#
.SYNOPSIS
  Common functions for the QIFW packaging tools: repository root resolution, path guard, manifest loading.

.DESCRIPTION
  This file should only be used via dot-source:
    . "$PSScriptRoot\_common.ps1"
  Every resolved path is validated to fall inside the repository root; going out of bounds throws and aborts,
  guaranteeing nothing is written outside D:\Orbbec\install-qt.
#>

$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    [CmdletBinding()]
    param([string]$StartDir = $PSScriptRoot)

    $dir = (Resolve-Path -LiteralPath $StartDir).ProviderPath
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $dir }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir -or -not $parent) { break }
        $dir = $parent
    }
    throw "Cannot find the repository root (.git) walking up from '$StartDir'."
}

function Resolve-RepoPath {
    <#
      Resolve a relative path to an absolute path under the repository root.
      If the real path of the result (including the nearest existing ancestor) is not inside the repository root, throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$AllowRootItself
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Path must be relative to the repository; absolute paths rejected: $RelativePath"
    }

    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $repoFull $RelativePath))

    # Find the deepest existing ancestor and resolve its real path, preventing escape via symlink/junction
    $probe = $candidate
    $missingTail = New-Object System.Collections.Generic.List[string]
    while ($probe -and -not (Test-Path -LiteralPath $probe)) {
        $missingTail.Insert(0, (Split-Path -Leaf $probe))
        $next = Split-Path -Parent $probe
        if ($next -eq $probe) { break }
        $probe = $next
    }

    if ($probe -and (Test-Path -LiteralPath $probe)) {
        $realProbe = (Resolve-Path -LiteralPath $probe).ProviderPath
        $real = $realProbe
        foreach ($seg in $missingTail) { $real = Join-Path $real $seg }
    }
    else {
        $real = $candidate
    }

    $realFull = [System.IO.Path]::GetFullPath($real).TrimEnd('\')
    $prefix = $repoFull + '\'
    if ($realFull -eq $repoFull) {
        if (-not $AllowRootItself) {
            throw "Refusing to use the repository root itself as the output target: $RelativePath"
        }
        return $realFull
    }
    if (-not $realFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the repository root, aborted: '$RelativePath' -> '$realFull' (repository root '$repoFull'). All artifacts must stay inside this repository."
    }
    return $realFull
}

function Get-ToolchainManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $manifestPath = Resolve-RepoPath -RelativePath 'packaging/qifw/toolchain/manifest.json' -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "manifest not found: $manifestPath"
    }
    $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    $manifest = $raw | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName '_manifestPath' -NotePropertyValue $manifestPath -Force
    return $manifest
}

function Get-ToolchainRoot {
    <# Resolve and validate toolchainRoot from the manifest, returning an absolute path inside the repository. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if (-not $Manifest.toolchainRoot) { throw 'manifest is missing the toolchainRoot field.' }
    return Resolve-RepoPath -RelativePath $Manifest.toolchainRoot -RepoRoot $RepoRoot
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'OK' { Write-Host $line -ForegroundColor Green }
        'STEP' { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function Invoke-Native {
    <#
      Run native commands safely under PowerShell 5.1.
      $ErrorActionPreference='Stop' wraps native command stderr as NativeCommandError;
      calling directly aborts the whole script and hides the real output. So this uses Start-Process with redirection.
      Returns: exit code; output is printed to screen and appended to $LogPath (optional).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$LogPath = ''
    )

    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $stdout = if (Test-Path $tmpOut) { Read-Utf8File -Path $tmpOut } else { '' }
        $stderr = if (Test-Path $tmpErr) { Read-Utf8File -Path $tmpErr } else { '' }
        foreach ($chunk in @($stdout, $stderr)) {
            if ($chunk -and $chunk.Trim()) {
                Write-Host $chunk.TrimEnd()
                if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $chunk.TrimEnd() -Encoding UTF8 }
            }
        }
        return [pscustomobject]@{
            ExitCode = $p.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
            Combined = ("$stdout`n$stderr").Trim()
        }
    }
    finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

function Write-JsonFile {
    <#
      Write a UTF-8 (no BOM) JSON file.
      Set-Content -Encoding UTF8 adds a BOM under PowerShell 5.1; many tools other than python/jq
      (and readers defaulting to GBK) would read Chinese as garbage; so the BOM is removed uniformly here.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject,
        [int]$Depth = 5
    )
    $json = $InputObject | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Utf8File {
    <#
      Read text using the encoding implied by the BOM; use UTF-8 when there is no BOM.
      PowerShell on .NET 5+ writes redirection files without a BOM by default, while 5.1's
      Get-Content -Encoding UTF8 would read BOM-less Chinese as garbage.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return $utf8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    return $utf8.GetString($bytes)
}

function Get-QifwToolchainStatus {
    <#
      Verify whether the toolchain registered in the manifest is actually usable, so the packaging script can gate before acting.
      The QIFW scenario "toolchain version not registered" requires "the build to exit with a non-zero status",
      while check-env.ps1 only reports; the packaging flow needs the same conclusion, so its -Json output is reused here.

      Returns: @{ Available; Reason; QtVersion; IfwVersion; ArchiveSha256; Checks }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $checkEnv = Resolve-RepoPath 'packaging/qifw/toolchain/check-env.ps1' -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $checkEnv)) { throw "not found: $checkEnv" }

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::ChangeExtension($stdout, '.err')
    try {
        # -Json outputs JSON only; exit code 0/1 is the overall conclusion, so a non-zero code does not abort here
        $p = Start-Process -FilePath 'powershell.exe' -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$checkEnv`"", '-Json')
        $raw = Read-Utf8File -Path $stdout
        if (-not $raw -or -not $raw.Trim()) { throw 'check-env.ps1 -Json produced no output' }
        $doc = $raw | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }

    $failed = @($doc.checks | Where-Object { -not $_.Ok })
    # Optional missing items (e.g. 7-Zip CLI not installed) do not block, only warn; otherwise the "environment available" conclusion would be flipped by optional items
    $failedBlocking = @($failed | Where-Object { $_.Blocking })
    $failedOptional = @($failed | Where-Object { -not $_.Blocking })
    $anyFail = $failedBlocking.Count -gt 0
    # The overall conclusion and the per-item results must corroborate each other; any inconsistency is treated as not available
    $consistent = ([bool]$doc.available) -eq (-not $anyFail)
    $reason = if (-not $consistent) {
        "check-env overall conclusion available=$($doc.available) is inconsistent with the per-item results"
    }
    elseif ($anyFail) {
        ($failedBlocking | ForEach-Object { "[$($_.Group)] $($_.Name): $($_.Detail)" }) -join '; '
    }
    else { '' }
    $warning = ($failedOptional | ForEach-Object { "$($_.Name)" }) -join ', '

    return [pscustomobject]@{
        Available     = ([bool]$doc.available -and $consistent -and $p.ExitCode -eq 0)
        Reason        = $reason
        Warning       = $warning
        QtVersion     = $Manifest.qt.version
        Architecture  = $Manifest.qt.architecture
        IfwVersion    = $Manifest.ifw.version
        ArchiveSha256 = $Manifest.ifw.archiveSha256
        Checks        = $doc.checks
    }
}

function Get-DirectorySnapshot {
    <# Take a lightweight snapshot of a directory: file count, total bytes, latest write time. Read-only. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Path = $Path; Exists = $false; FileCount = 0; TotalBytes = 0; LatestWrite = $null }
    }
    $files = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue
    $latest = if ($files) { ($files | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum } else { $null }
    $bytes = if ($files) { ($files | Measure-Object -Property Length -Sum).Sum } else { 0 }
    return [pscustomobject]@{
        Path       = $Path
        Exists     = $true
        FileCount  = @($files).Count
        TotalBytes = [int64]$bytes
        LatestWrite = $latest
    }
}
