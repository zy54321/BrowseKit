# Build an official release only from a clean revision that matches GitHub.
# Double-click entry: 02_制作Release.bat. Does not deploy Prod.

param(
    [string]$Version = '',
    [string]$ConfirmRelease = '',
    [switch]$NonInteractive,
    [switch]$PreconditionsOnly,
    [string]$RepoRoot = '',
    [string]$ReleaseRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = 'E:\01_Work\03_Release\01_Personal\018-BrowseKit'
}

function Fail([string]$Message) {
    Write-Host "[Release] 失败：$Message"
    exit 1
}

function Say([string]$Message) {
    Write-Host "[Release] $Message"
}

Say '从当前开发目录制作正式 Release。'
Say '不会安装或升级 Prod。'

. (Join-Path $PSScriptRoot 'confirm-yn.ps1')
. (Join-Path $RepoRoot 'scripts\release\resolve-release-version.ps1')

$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$headText = @(& git -C $RepoRoot rev-parse HEAD 2>$null)
$headCode = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($headCode -ne 0 -or $headText.Count -eq 0) {
    Fail '没有 Git 修订，不能制作正式 Release。请先双击 01_提交GitHub.bat。没有创建版本目录。'
}
$head = ([string]$headText[0]).Trim()
$branch = ((& git -C $RepoRoot rev-parse --abbrev-ref HEAD) | Out-String).Trim()
$dirty = @(& git -C $RepoRoot status --porcelain)
if ($dirty.Count -gt 0) {
    Fail '工作区有未提交的修改。不能从未提交的内容制作正式 Release。'
}

$remotes = @(& git -C $RepoRoot remote)
if ($remotes -notcontains 'origin') {
    Fail '没有 GitHub 远程仓库，修订尚未被远程确认。没有创建版本目录。'
}
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$remoteLines = @(& git -C $RepoRoot ls-remote --heads origin "refs/heads/$branch" 2>&1)
$remoteCode = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($remoteCode -ne 0) {
    Fail '无法确认 GitHub 上的修订。没有创建版本目录。'
}
$remoteSha = ''
foreach ($line in $remoteLines) {
    if ([string]$line -match '^([0-9a-f]{40})\s+') { $remoteSha = $Matches[1] }
}
if ($remoteSha -ne $head) {
    Fail "本地修订 $head 与 GitHub 分支 $branch 的修订不一致。没有创建版本目录。"
}

$ProdRoot = 'E:\01_Work\04_Prod\01_Personal\018-BrowseKit'
$versionInfo = $null
if ([string]::IsNullOrWhiteSpace($Version)) {
    try {
        $versionInfo = Resolve-NextReleaseVersion -RepoRoot $RepoRoot -ReleaseRoot $ReleaseRoot -ProdRoot $ProdRoot
        $Version = $versionInfo.NextVersion
    }
    catch {
        Fail $_.Exception.Message
    }
}
elseif ($Version -notmatch '^v\d+\.\d+\.\d+$') {
    Fail "版本号必须是 vX.Y.Z。当前：$Version"
}

try {
    Test-ReleaseVersionAvailable -Version $Version -ReleaseRoot $ReleaseRoot -ProdRoot $ProdRoot
}
catch {
    Fail $_.Exception.Message
}

if ($null -eq $versionInfo) {
    $versionInfo = [pscustomobject]@{
        LatestVersion = '参数指定'
        NextVersion = $Version
        VersionSource = '参数指定'
    }
}

$target = Join-Path $ReleaseRoot $Version

Write-Host '================================'
Write-Host 'BrowseKit Release'
Write-Host '================================'
Write-Host ''
Write-Host ("已有最新版本：{0}" -f $versionInfo.LatestVersion)
Write-Host ("本次计划发布版本：{0}" -f $Version)
Write-Host ("版本来源：{0}" -f $versionInfo.VersionSource)
Write-Host '版本检查：通过'
Write-Host '重复版本检查：通过'
Write-Host ''
Write-Host '即将开始制作 Release。'
Write-Host ''

Say "版本：$Version"
Say "分支：$branch"
Say "Git 修订：$head"
Say "目标目录：$target"
Say '影响范围：只打包正式 Release，不会安装或升级 Prod。'
Say '不会读取或复制 chrome-profile、workspace 任务数据、.run 或 .env。'

if (-not $NonInteractive) {
    if (-not (Confirm-YesNo -Prompt '制作 Release (Y/N):')) {
        Say '已取消。没有创建版本目录。'
        exit 0
    }
}
elseif (-not (Test-YesAnswer -Answer $ConfirmRelease -LegacyAccepted @("YES-RELEASE $Version"))) {
    Say '已取消。没有创建版本目录。'
    exit 0
}

if ($PreconditionsOnly) {
    Say '预检查通过。按测试模式停止，没有创建版本目录。'
    exit 0
}

try {
    Test-ReleaseVersionAvailable -Version $Version -ReleaseRoot $ReleaseRoot -ProdRoot $ProdRoot
}
catch {
    Fail $_.Exception.Message
}

Say '正在执行脚本语法检查。'
$bad = 0
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -Recurse -Filter '*.ps1' -File)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and @($errors).Count -gt 0) {
        Say ("语法错误：" + $file.FullName)
        $bad++
    }
}
if ($bad -gt 0) { Fail '脚本语法检查失败。没有创建版本目录。' }

Say '正在打包正式 Release。'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\release\package-release.ps1') -Version $Version
if ($LASTEXITCODE -ne 0) {
    Fail '打包失败。失败目录不会被记成成功发布。没有发布 Prod。'
}
if (-not (Test-Path -LiteralPath $target)) {
    Fail '打包程序没有留下版本目录。'
}

Say "正式 Release 已完成：$target"
Say "版本 $Version ，修订 $head 。没有部署 Prod。"
Say '下一步：打开上述目录，双击 scripts\03_发布Prod.bat。'
exit 0
