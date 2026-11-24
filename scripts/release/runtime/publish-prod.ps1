# Publish this Release directory into the existing Prod root.
# Double-click entry: scripts\03_发布Prod.bat inside the release package.
# Adds a new version directory and switches current.txt.
# Does not delete or replace data\chrome-profile, data\workspace, data\.env, or Docker volumes.

param(
    [string]$ReleaseRoot = '',
    [string]$ProdRoot = '',
    [string]$ConfirmProd = '',
    [switch]$NonInteractive,
    [switch]$PreconditionsOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'confirm-yn.ps1')
$RealProd = 'E:\01_Work\04_Prod\01_Personal\018-BrowseKit'

function Fail([string]$Message) {
    Write-Host "[Prod] 失败：$Message"
    exit 1
}

function Say([string]$Message) {
    Write-Host "[Prod] $Message"
}

function Copy-Tree([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    & robocopy $Source $Destination /E /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "复制失败：$Source" }
}

if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = Split-Path -Parent $PSScriptRoot
}
$ReleaseRoot = (Resolve-Path -LiteralPath $ReleaseRoot).Path
if ([string]::IsNullOrWhiteSpace($ProdRoot)) { $ProdRoot = $RealProd }

Say '从当前 Release 目录发布到正式 Prod。'
Say '不会删除 data\chrome-profile、data\workspace、data\.env，也不会执行 docker compose down -v。'
Say "Release：$ReleaseRoot"
Say "Prod：$ProdRoot"

$manifestPath = Join-Path $ReleaseRoot 'RELEASE-MANIFEST.json'
$versionPath = Join-Path $ReleaseRoot 'VERSION'
foreach ($required in @($manifestPath, $versionPath, (Join-Path $ReleaseRoot 'scripts\Start-BrowseKit.ps1'), (Join-Path $ReleaseRoot 'docker\docker-compose.yml'))) {
    if (-not (Test-Path -LiteralPath $required)) { Fail "Release 包不完整：$required" }
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$version = ([IO.File]::ReadAllText($versionPath)).Trim()
if ([string]$manifest.version -ne $version -or $version -notmatch '^v\d+\.\d+\.\d+$') {
    Fail 'Release 版本与清单不一致。没有修改 Prod。'
}
if ([string]$manifest.releaseStatus -ne 'official') { Fail '这不是正式 Release。没有修改 Prod。' }

$prodFull = [IO.Path]::GetFullPath($ProdRoot).TrimEnd('\')
$releaseFull = [IO.Path]::GetFullPath($ReleaseRoot).TrimEnd('\')
if ($releaseFull.StartsWith($prodFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Fail '不能从 Prod 目录内部发布。没有修改 Prod。'
}
if (-not (Test-Path -LiteralPath $ProdRoot)) { Fail '正式 Prod 目录不存在。没有创建新的生产根。' }

$dataDir = Join-Path $ProdRoot 'data'
$profile = Join-Path $dataDir 'chrome-profile'
$workspace = Join-Path $dataDir 'workspace'
$envFile = Join-Path $dataDir '.env'
foreach ($required in @($profile, $workspace, $envFile)) {
    if (-not (Test-Path -LiteralPath $required)) { Fail "正式数据不完整：$required 。没有修改 Prod。" }
}

$target = Join-Path $ProdRoot $version
$currentFile = Join-Path $ProdRoot 'current.txt'
$previous = ''
if (Test-Path -LiteralPath $currentFile) { $previous = ([IO.File]::ReadAllText($currentFile)).Trim() }
Say "当前 Prod 版本：$previous"
Say "计划切换到：$version"
Say '数据目录保持原路径。'

if ($previous -eq $version) {
    Say 'current.txt 已经指向这个版本。没有重复发布。'
    exit 0
}
if (Test-Path -LiteralPath $target) {
    Fail "Prod 里已经有 $version 目录，不会覆盖。没有切换 current.txt。"
}

if (-not $NonInteractive) {
    if (-not (Confirm-YesNo -Prompt 'YES-PROD (Y/N):')) {
        Say '已取消。没有复制文件，也没有停止正式服务。'
        exit 0
    }
}
elseif (-not (Test-YesAnswer -Answer $ConfirmProd -LegacyAccepted @('YES-PROD'))) {
    Say '已取消。没有复制文件，也没有停止正式服务。'
    exit 0
}

if ($PreconditionsOnly) {
    Say '预检查通过。按测试模式停止，没有复制文件，也没有停止正式服务。'
    exit 0
}

Say '正在复制新版本目录。正式数据目录不在复制范围内。'
try {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($name in @('docker', 'mcp-host', 'workspace-templates')) {
        Copy-Tree (Join-Path $ReleaseRoot $name) (Join-Path $target $name)
    }
    Copy-Tree (Join-Path $ReleaseRoot 'scripts') (Join-Path $target 'scripts')
    foreach ($name in @('03_发布Prod.bat', 'publish-prod.ps1', 'confirm-yn.ps1')) {
        $extra = Join-Path $target "scripts\$name"
        if (Test-Path -LiteralPath $extra) { Remove-Item -LiteralPath $extra -Force }
    }
    Copy-Item (Join-Path $ReleaseRoot 'VERSION') (Join-Path $target 'VERSION') -Force
    Copy-Item $manifestPath (Join-Path $target 'RELEASE-MANIFEST.json') -Force
    $doc = Join-Path $ReleaseRoot '018_browsekit.md'
    if (Test-Path -LiteralPath $doc) { Copy-Item $doc (Join-Path $target '018_browsekit.md') -Force }
    $leaked = @(Get-ChildItem -LiteralPath $target -Recurse -Force -File | Where-Object {
        $_.Name -eq '.env' -or $_.FullName -match '\\chrome-profile\\' -or $_.FullName -match '\\data\\'
    })
    if ($leaked.Count -gt 0) { throw '新版本目录出现了密钥或登录数据' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'scripts\Start-BrowseKit.ps1'))) { throw '新版本缺少启动脚本' }
}
catch {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
    Fail ("复制没有完成，已撤回新版本目录。正式服务未停止。 " + $_.Exception.Message)
}

foreach ($path in @($profile, $workspace, $envFile)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        Fail '复制后正式数据路径消失。已撤回新版本目录，没有切换 current.txt。'
    }
}
if ($target.StartsWith($dataDir, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    Fail '新版本目录落进了 data。已撤回。'
}

if (-not [string]::IsNullOrWhiteSpace($previous)) {
    $stop = Join-Path $ProdRoot "$previous\scripts\Stop-BrowseKit.ps1"
    if (-not (Test-Path -LiteralPath $stop)) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        Fail '找不到当前版本的停止脚本。已撤回新版本目录，没有切换 current.txt。'
    }
    Say "正在停止 $previous 。不会删除数据卷，也不会结束 chrome.exe。"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $stop
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        Fail '停止当前版本失败。已撤回新版本目录，current.txt 未改。'
    }
}

$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText($currentFile, ($version + "`r`n"), $utf8)
Say "current.txt 已切换到 $version"

$start = Join-Path $target 'scripts\Start-BrowseKit.ps1'
Say '正在按新版本启动。登录配置和工作区仍使用 Prod\data。'
& powershell -NoProfile -ExecutionPolicy Bypass -File $start
if ($LASTEXITCODE -ne 0) {
    if (-not [string]::IsNullOrWhiteSpace($previous)) {
        [IO.File]::WriteAllText($currentFile, ($previous + "`r`n"), $utf8)
        $oldStart = Join-Path $ProdRoot "$previous\scripts\Start-BrowseKit.ps1"
        if (Test-Path -LiteralPath $oldStart) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $oldStart
        }
        Fail "新版本启动失败。current.txt 已回到 $previous 。数据目录未替换。"
    }
    Fail '新版本启动失败。数据目录未替换。'
}

Say "发布完成。当前版本 $version 。data\chrome-profile 与 data\workspace 仍在原路径。"
exit 0
