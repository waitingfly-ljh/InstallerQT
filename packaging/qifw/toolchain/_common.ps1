#Requires -Version 5.1
<#
.SYNOPSIS
  QIFW 打包工具的公共函数：仓库根解析、路径守卫、manifest 加载。

.DESCRIPTION
  本文件只应被 dot-source 使用：
    . "$PSScriptRoot\_common.ps1"
  所有路径解析结果都会校验落在仓库根之内，越界即抛错中止，
  以保证不写到 D:\Orbbec\install-qt 之外的任何位置。
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
    throw "无法从 '$StartDir' 向上找到仓库根（.git）。"
}

function Resolve-RepoPath {
    <#
     把相对路径解析为仓库根下的绝对路径。
     若解析结果的真实路径（含已存在的最近祖先）不在仓库根内，则抛错。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$AllowRootItself
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "路径必须是仓库内相对路径，拒绝绝对路径: $RelativePath"
    }

    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $repoFull $RelativePath))

    # 找到已存在的最深祖先，解析其真实路径，防止经由符号链接/junction 逃出仓库
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
            throw "拒绝把仓库根本身作为输出目标: $RelativePath"
        }
        return $realFull
    }
    if (-not $realFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "路径越出仓库根，已中止: '$RelativePath' -> '$realFull'（仓库根 '$repoFull'）。所有产物必须位于本仓库内。"
    }
    return $realFull
}

function Get-ToolchainManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $manifestPath = Resolve-RepoPath -RelativePath 'packaging/qifw/toolchain/manifest.json' -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "找不到 manifest: $manifestPath"
    }
    $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    $manifest = $raw | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName '_manifestPath' -NotePropertyValue $manifestPath -Force
    return $manifest
}

function Get-ToolchainRoot {
    <# 解析并校验 manifest 中的 toolchainRoot，返回仓库内绝对路径。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if (-not $Manifest.toolchainRoot) { throw 'manifest 缺少 toolchainRoot 字段。' }
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
     在 PowerShell 5.1 下安全地运行原生命令。
     $ErrorActionPreference='Stop' 会把原生命令的 stderr 包装成 NativeCommandError，
     直接调用会让整个脚本中断且看不到真实输出。这里改用 Start-Process 重定向，
     返回值：退出码；输出同时打印到屏幕并追加到 $LogPath（可选）。
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
     写 UTF-8（无 BOM）的 JSON 文件。
     Set-Content -Encoding UTF8 在 PowerShell 5.1 下会加 BOM，python/jq 之外的
     不少工具（以及默认 GBK 的读取方）会把中文读成乱码；这里统一去掉 BOM。
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
     按 BOM 判断编码读取文本，无 BOM 时用 UTF-8。
     .NET 5+ 的 PowerShell 写重定向文件默认无 BOM，而 5.1 的
     Get-Content -Encoding UTF8 会把无 BOM 的中文读成乱码。
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
     核对 manifest 登记的工具链是否真正可用，供打包脚本在动手前把关。
     QIFW 的场景「工具链版本未登记」要求"构建以非零状态退出"，
     而 check-env.ps1 只管报告；打包流程需要同一结论，故在此复用其 -Json 输出。

     返回：@{ Available; Reason; QtVersion; IfwVersion; ArchiveSha256; Checks }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $checkEnv = Resolve-RepoPath 'packaging/qifw/toolchain/check-env.ps1' -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $checkEnv)) { throw "找不到 $checkEnv" }

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::ChangeExtension($stdout, '.err')
    try {
        # -Json 只输出 JSON；退出码 0/1 即总体结论，这里不因非 0 中断
        $p = Start-Process -FilePath 'powershell.exe' -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$checkEnv`"", '-Json')
        $raw = Read-Utf8File -Path $stdout
        if (-not $raw -or -not $raw.Trim()) { throw 'check-env.ps1 -Json 未输出任何内容' }
        $doc = $raw | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }

    $failed = @($doc.checks | Where-Object { -not $_.Ok })
    # 可选缺失（如未安装 7-Zip CLI）不阻断，只提示；否则"环境可用"的结论会因可选项被改写
    $failedBlocking = @($failed | Where-Object { $_.Blocking })
    $failedOptional = @($failed | Where-Object { -not $_.Blocking })
    $anyFail = $failedBlocking.Count -gt 0
    # 总体结论与逐项结果必须互相印证，任一方向不一致都按不可用处理
    $consistent = ([bool]$doc.available) -eq (-not $anyFail)
    $reason = if (-not $consistent) {
        "check-env 总体结论 available=$($doc.available) 与逐项结果不一致"
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
    <# 对目录做轻量快照：文件数、总字节、最新修改时间。只读。 #>
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
