#Requires -Version 5.1
<#
.SYNOPSIS
    把开发目录打包成"生产版本目录"，并更新生产根的 current.txt 与启停入口。

.DESCRIPTION
    产物结构（ProdRoot 默认 E:\01_Work\04_Prod\01_Personal\018-BrowseKit）：
        ProdRoot\
          current.txt                 <- 指向当前版本
          启动BrowseKit.bat / 停止BrowseKit.bat
          <版本>\
            docker\docker-compose.yml  (由 docker-compose.prod.yml 复制)
            docker\mcpo-config.json
            docker\tools\Dockerfile, server.py
            scripts\Start-BrowseKit.ps1, Stop-BrowseKit.ps1, BrowseKit-Tray.ps1
            scripts\tools\               (虚拟桌面组件与托盘依赖，运行期零联网)
            workspace-templates\
            mcp-host\                  (仅 package*.json + node_modules，运行时依赖)
            ARCHITECTURE.md            (开发目录存在时)
            VERSION
            RELEASE_MANIFEST.txt

    安全约束：绝不打包 docker\.env（只生成脱敏 .env.example）、chrome-profile、workspace\inbox、
    workspace\tasks、日志。脚本结束前会扫描产物做禁止项校验。

.PARAMETER Version
    版本号（如 v1.0.0）。缺省时读开发目录 VERSION，仍无则交互输入。

.PARAMETER Force
    目标版本目录已存在时允许覆盖（先删除旧目录）。

.PARAMETER ProdRoot
    生产根目录。

.EXAMPLE
    .\Export-ProdRelease.ps1 -Version v1.0.0
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Force,
    [string]$ProdRoot = 'E:\01_Work\04_Prod\01_Personal\018-BrowseKit',
    [switch]$ConfirmProdExport
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmProdExport) {
    throw '请先双击 02_制作Release.bat，再在 Release 包里双击 scripts\03_发布Prod.bat。本脚本会直接写入 04_Prod，默认已停用。'
}

$DevRoot = Split-Path -Parent $PSScriptRoot
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$Gbk = [System.Text.Encoding]::GetEncoding(936)

function Write-Step([string]$msg) { Write-Host ('[+] ' + $msg) -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host ('    ' + $msg) -ForegroundColor DarkGray }

# ---------------------------------------------------------------- 版本号
if (-not $Version) {
    $verFile = Join-Path $DevRoot 'VERSION'
    if (Test-Path -LiteralPath $verFile) {
        $Version = (Get-Content -LiteralPath $verFile -Raw -Encoding UTF8).Trim()
        Write-Host ('读取 VERSION 文件：' + $Version)
    }
}
if (-not $Version) {
    $Version = (Read-Host '请输入版本号（如 v1.0.0）').Trim()
}
if ($Version -notmatch '^v\d+\.\d+\.\d+$') {
    throw ('版本号格式非法（应为 vX.Y.Z）：' + $Version)
}

$TargetDir = Join-Path $ProdRoot $Version

Write-Host '==============================================' -ForegroundColor Green
Write-Host (' BrowseKit 生产打包  ' + $Version) -ForegroundColor Green
Write-Host '==============================================' -ForegroundColor Green
Write-Host ('开发目录：' + $DevRoot)
Write-Host ('目标目录：' + $TargetDir)
Write-Host ''

# ---------------------------------------------------------------- 前置校验
$required = @(
    'docker\docker-compose.prod.yml',
    'docker\mcpo-config.json',
    'docker\tools\Dockerfile',
    'docker\tools\server.py',
    'scripts\prod\Start-BrowseKit.ps1',
    'scripts\prod\Stop-BrowseKit.ps1',
    'scripts\prod\BrowseKit-Tray.ps1',
    'scripts\prod\tools\BrowseKit.Desktop.ps1',
    'scripts\prod\tools\BrowseKit.Shell.cs',
    'scripts\prod\tools\BrowseKit.Shell.dll'
)
foreach ($rel in $required) {
    $p = Join-Path $DevRoot $rel
    if (-not (Test-Path -LiteralPath $p)) { throw ('缺少必需文件：' + $p) }
}

if (-not (Test-Path -LiteralPath $ProdRoot)) {
    New-Item -ItemType Directory -Path $ProdRoot -Force | Out-Null
}
if (Test-Path -LiteralPath $TargetDir) {
    if (-not $Force) {
        throw ('目标版本目录已存在：' + $TargetDir + '（如确认覆盖请加 -Force）')
    }
    Write-Warning ('已存在且指定 -Force，删除旧目录：' + $TargetDir)
    Remove-Item -LiteralPath $TargetDir -Recurse -Force
}
New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

$packaged = New-Object System.Collections.ArrayList
function Add-ReleaseFile {
    param([string]$SourcePath, [string]$RelativePath)
    $dest = Join-Path $TargetDir $RelativePath
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
    [void]$packaged.Add($RelativePath)
}

# ---------------------------------------------------------------- 1) 编排与工具
Write-Step '打包 docker 编排与工具镜像定义'
Add-ReleaseFile (Join-Path $DevRoot 'docker\docker-compose.prod.yml') 'docker\docker-compose.yml'
$composeRel = 'docker\docker-compose.yml'
$composeDest = Join-Path $TargetDir $composeRel
$composeBody = [System.IO.File]::ReadAllText($composeDest, [System.Text.Encoding]::UTF8)
if ($composeBody -notmatch '__BROWSEKIT_VERSION__') {
    throw 'docker-compose.prod.yml 缺少 __BROWSEKIT_VERSION__ 占位符，拒绝导出（避免生产误用 :local）'
}
$verTag = $Version.ToLower()
$composeBody = $composeBody.Replace('__BROWSEKIT_VERSION__', $verTag)
[System.IO.File]::WriteAllText($composeDest, $composeBody, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok ('工具镜像标签 -> browsekit-tools:' + $verTag)
Add-ReleaseFile (Join-Path $DevRoot 'docker\mcpo-config.json') 'docker\mcpo-config.json'
Add-ReleaseFile (Join-Path $DevRoot 'docker\tools\Dockerfile') 'docker\tools\Dockerfile'
Add-ReleaseFile (Join-Path $DevRoot 'docker\tools\server.py') 'docker\tools\server.py'

# ---------------------------------------------------------------- 2) 启停脚本与托盘
Write-Step '打包生产启停脚本、托盘与虚拟桌面组件'
Add-ReleaseFile (Join-Path $DevRoot 'scripts\prod\Start-BrowseKit.ps1') 'scripts\Start-BrowseKit.ps1'
Add-ReleaseFile (Join-Path $DevRoot 'scripts\prod\Stop-BrowseKit.ps1') 'scripts\Stop-BrowseKit.ps1'
Add-ReleaseFile (Join-Path $DevRoot 'scripts\prod\BrowseKit-Tray.ps1') 'scripts\BrowseKit-Tray.ps1'
$toolsSrc = Join-Path $DevRoot 'scripts\prod\tools'
$toolFiles = @(Get-ChildItem -LiteralPath $toolsSrc -File -Force | Where-Object { $_.Name -notlike '_*' })
if ($toolFiles.Count -eq 0) { throw ('没有可打包的虚拟桌面组件：' + $toolsSrc) }
foreach ($tool in $toolFiles) {
    Add-ReleaseFile $tool.FullName ('scripts\tools\' + $tool.Name)
}

# ---------------------------------------------------------------- 3) 模板
Write-Step '打包工作区模板 -> workspace-templates'
$tplSrc = Join-Path $DevRoot 'workspace\templates'
if (Test-Path -LiteralPath $tplSrc) {
    foreach ($f in Get-ChildItem -LiteralPath $tplSrc -File -Force) {
        Add-ReleaseFile $f.FullName ('workspace-templates\' + $f.Name)
    }
}

# ---------------------------------------------------------------- 4) ARCHITECTURE
$arch = Join-Path $DevRoot 'ARCHITECTURE.md'
if (Test-Path -LiteralPath $arch) {
    Write-Step '打包 ARCHITECTURE.md'
    Add-ReleaseFile $arch 'ARCHITECTURE.md'
}

# ---------------------------------------------------------------- 5) MCP 运行时
Write-Step '打包 mcp-host 运行时（package*.json + node_modules）'
$mcpHost = Join-Path $DevRoot 'mcp-host'
if (Test-Path -LiteralPath $mcpHost) {
    foreach ($f in Get-ChildItem -LiteralPath $mcpHost -File -Force | Where-Object { $_.Name -match '^package(-lock)?\.json$' }) {
        Add-ReleaseFile $f.FullName ('mcp-host\' + $f.Name)
    }
    $nm = Join-Path $mcpHost 'node_modules'
    if (Test-Path -LiteralPath $nm) {
        $destNm = Join-Path $TargetDir 'mcp-host\node_modules'
        New-Item -ItemType Directory -Path (Split-Path -Parent $destNm) -Force | Out-Null
        Copy-Item -LiteralPath $nm -Destination $destNm -Recurse -Force
        Write-Ok ('node_modules 已复制：' + ((Get-ChildItem -LiteralPath $destNm -Recurse -File -Force | Measure-Object).Count) + ' 个文件')
    }
}

# ---------------------------------------------------------------- 6) VERSION + .env.example
Write-Step '生成 VERSION 与脱敏 .env.example'
[System.IO.File]::WriteAllText((Join-Path $TargetDir 'VERSION'), ($Version + "`r`n"), $Utf8Bom)
[void]$packaged.Add('VERSION')

$devEnv = Join-Path $DevRoot 'docker\.env'
$envLines = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $devEnv) {
    foreach ($line in Get-Content -LiteralPath $devEnv -Encoding UTF8) {
        if ($line -match '^OPENAI_API_KEYS=') { [void]$envLines.Add('OPENAI_API_KEYS=REPLACE_WITH_YOUR_DEEPSEEK_API_KEY') }
        elseif ($line -match '^WEBUI_SECRET_KEY=') { [void]$envLines.Add('WEBUI_SECRET_KEY=REPLACE_WITH_RANDOM_32_HEX') }
        elseif ($line -match '^MCPO_API_KEY=') { [void]$envLines.Add('MCPO_API_KEY=REPLACE_WITH_RANDOM_32_HEX') }
        elseif ($line -match '^\s*#' -or $line -match '^[A-Z_]+=') { [void]$envLines.Add($line) }
    }
} else {
    [void]$envLines.Add('# 生产环境变量模板：复制为 data\.env 后填写')
    [void]$envLines.Add('OPENAI_API_BASE_URLS=https://api.deepseek.com/v1')
    [void]$envLines.Add('OPENAI_API_KEYS=REPLACE_WITH_YOUR_DEEPSEEK_API_KEY')
    [void]$envLines.Add('ENABLE_OLLAMA_API=false')
    [void]$envLines.Add('WEBUI_SECRET_KEY=REPLACE_WITH_RANDOM_32_HEX')
    [void]$envLines.Add('MCPO_API_KEY=REPLACE_WITH_RANDOM_32_HEX')
    [void]$envLines.Add('ENABLE_SIGNUP=true')
}
[System.IO.File]::WriteAllText((Join-Path $TargetDir 'docker\.env.example'), (($envLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
[void]$packaged.Add('docker\.env.example')

# ---------------------------------------------------------------- 7) 生产根入口
Write-Step '生成生产根 current.txt 与启停 .bat'
$startBat = @"
@echo off
chcp 936 >nul
setlocal enabledelayedexpansion
set "ROOT=%~dp0"
if not exist "%ROOT%current.txt" (
  echo [错误] 未找到 current.txt，无法确定当前版本。
  pause
  exit /b 1
)
for /f "usebackq delims=" %%v in ("%ROOT%current.txt") do set "VER=%%v"
set "VER=!VER: =!"
if not exist "%ROOT%!VER!\scripts\Start-BrowseKit.ps1" (
  echo [错误] 版本目录不存在：%ROOT%!VER!
  pause
  exit /b 1
)
echo 正在启动 BrowseKit !VER! ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%!VER!\scripts\Start-BrowseKit.ps1" %*
set "RC=!errorlevel!"
echo.
if "!RC!"=="0" (echo [完成] 启动流程结束。) else (echo [失败] 启动流程异常，退出码 !RC!。)
pause
"@
$stopBat = @"
@echo off
chcp 936 >nul
setlocal enabledelayedexpansion
set "ROOT=%~dp0"
if not exist "%ROOT%current.txt" (
  echo [错误] 未找到 current.txt，无法确定当前版本。
  pause
  exit /b 1
)
for /f "usebackq delims=" %%v in ("%ROOT%current.txt") do set "VER=%%v"
set "VER=!VER: =!"
if not exist "%ROOT%!VER!\scripts\Stop-BrowseKit.ps1" (
  echo [错误] 版本目录不存在：%ROOT%!VER!
  pause
  exit /b 1
)
echo 正在停止 BrowseKit !VER! ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%!VER!\scripts\Stop-BrowseKit.ps1"
set "RC=!errorlevel!"
echo.
if "!RC!"=="0" (echo [完成] 停止流程结束。) else (echo [失败] 停止流程异常，退出码 !RC!。)
pause
"@
[System.IO.File]::WriteAllText((Join-Path $ProdRoot '启动BrowseKit.bat'), ($startBat -replace "`r?`n", "`r`n"), $Gbk)
[System.IO.File]::WriteAllText((Join-Path $ProdRoot '停止BrowseKit.bat'), ($stopBat -replace "`r?`n", "`r`n"), $Gbk)
$currentFile = Join-Path $ProdRoot 'current.txt'
if (Test-Path -LiteralPath $currentFile) {
    $existing = (Get-Content -LiteralPath $currentFile -Raw -Encoding UTF8).Trim()
    Write-Host ('    current.txt 已存在（' + $existing + '），保持不动：打包与上线切换解耦') -ForegroundColor Yellow
    $currentVer = $existing
} else {
    [System.IO.File]::WriteAllText($currentFile, ($Version + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('    已初始化 current.txt -> ' + $Version) -ForegroundColor Yellow
    $currentVer = $Version
}

# ---------------------------------------------------------------- 8) 清单
Write-Step '生成 RELEASE_MANIFEST.txt（含 SHA256）'
$manifest = New-Object System.Collections.ArrayList
[void]$manifest.Add('BrowseKit Release Manifest')
[void]$manifest.Add('=========================')
[void]$manifest.Add(('Version      : ' + $Version))
[void]$manifest.Add(('BuiltAt      : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')))
[void]$manifest.Add(('SourceDevDir : ' + $DevRoot))
[void]$manifest.Add(('TargetDir    : ' + $TargetDir))
[void]$manifest.Add('')
[void]$manifest.Add('Files (relative path | size bytes | sha256):')
[void]$manifest.Add('------------------------------------------------------------')
$total = 0
foreach ($rel in ($packaged | Sort-Object)) {
    $full = Join-Path $TargetDir $rel
    if (Test-Path -LiteralPath $full) {
        $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        $len = (Get-Item -LiteralPath $full).Length
        [void]$manifest.Add(('{0} | {1} | {2}' -f $rel, $len, $h))
        $total++
    }
}
$nmCount = 0
if (Test-Path -LiteralPath (Join-Path $TargetDir 'mcp-host\node_modules')) {
    $nmCount = (Get-ChildItem -LiteralPath (Join-Path $TargetDir 'mcp-host\node_modules') -Recurse -File -Force | Measure-Object).Count
    [void]$manifest.Add(('mcp-host\node_modules\ | (runtime deps) | {0} files, not hashed individually' -f $nmCount))
}
[void]$manifest.Add('')
[void]$manifest.Add(('Hashed files : ' + $total))
[void]$manifest.Add(('node_modules : ' + $nmCount + ' files'))
[void]$manifest.Add('Excluded     : docker\.env, chrome-profile, workspace\inbox, workspace\tasks, logs')
[System.IO.File]::WriteAllText((Join-Path $TargetDir 'RELEASE_MANIFEST.txt'), (($manifest -join "`r`n") + "`r`n"), $Utf8Bom)

# ---------------------------------------------------------------- 9) 禁止项校验
Write-Step '产物安全检查（禁止项扫描）'
$forbidden = @()
$forbidden += Get-ChildItem -LiteralPath $TargetDir -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq '.env' -or $_.Name -like '*.log' -or $_.FullName -match '\\chrome-profile\\' -or $_.FullName -match '\\workspace\\inbox\\' -or $_.FullName -match '\\workspace\\tasks\\' }
if ($forbidden.Count -gt 0) {
    $forbidden | ForEach-Object { Write-Host ('    [违规] ' + $_.FullName) -ForegroundColor Red }
    throw '产物包含禁止项，打包中止。'
}
Write-Ok '未发现 .env / chrome-profile / inbox / tasks / 日志'

# ---------------------------------------------------------------- 10) 汇总
$sizeMb = ((Get-ChildItem -LiteralPath $TargetDir -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum / 1MB)
Write-Host ''
Write-Host '================ 打包完成 ================' -ForegroundColor Green
Write-Host (' 版本目录 : ' + $TargetDir)
Write-Host (' 文件数   : ' + $total + ' (+ node_modules ' + $nmCount + ')')
Write-Host (' 体积     : {0:N1} MB' -f $sizeMb)
Write-Host (' current  : ' + $currentVer + $(if ($currentVer -ne $Version) { '  (未切换；如需上线请手工改 current.txt)' } else { '' }))
Write-Host ''
Write-Host '下一步：初始化 data 目录（复制 .env / workspace / chrome-profile），然后运行生产根 启动BrowseKit.bat' -ForegroundColor Yellow
