#Requires -Version 5.1
<#
.SYNOPSIS
    开发环境：独立目录与 +10 端口。prepare 只建目录，up/down 不碰生产。
#>
[CmdletBinding()]
param(
    [ValidateSet('prepare', 'up', 'down')]
    [string]$Action = 'up'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BrowseKit.Common.ps1')

$Root = Get-BrowseKitRoot
$Ports = Get-BrowseKitDevPorts
Assert-BrowseKitDevPorts -Ports $Ports

$ProfileDir = Join-Path $Root 'chrome-profile-dev'
$WorkspaceDir = Join-Path $Root 'workspace-dev'
$RunDir = Join-Path $Root '.run-dev'
$ProdProfile = Join-Path $Root 'chrome-profile'
$ComposeFile = Join-Path $Root 'docker\docker-compose.dev.yml'

if ([System.IO.Path]::GetFullPath($ProfileDir) -eq [System.IO.Path]::GetFullPath($ProdProfile)) {
    throw '开发配置目录解析到了生产 chrome-profile，已中止。'
}

function Set-DevEnvironment {
    $env:BROWSEKIT_ENV = 'dev'
    $env:BROWSEKIT_PROFILE_DIR = $ProfileDir
    $env:BROWSEKIT_WORKSPACE_DIR = $WorkspaceDir
    $env:BROWSEKIT_RUN_DIR = $RunDir
    $env:BROWSEKIT_CDP_PORT = [string]$Ports.Cdp
    $env:BROWSEKIT_MCP_PORT = [string]$Ports.Mcp
    $env:BROWSEKIT_MCPO_PORT = [string]$Ports.Mcpo
    $env:BROWSEKIT_WEBUI_PORT = [string]$Ports.WebUi
}

function Initialize-DevDirs {
    if (-not (Test-Path -LiteralPath $RunDir)) { New-Item -ItemType Directory -Path $RunDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $ProfileDir)) { New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null }
    Initialize-BrowseKitWorkspace -WorkspaceDir $WorkspaceDir -CopyTemplates
    $note = @(
        ('BROWSEKIT_ENV=dev'),
        ('BROWSEKIT_CDP_PORT=' + $Ports.Cdp),
        ('BROWSEKIT_MCP_PORT=' + $Ports.Mcp),
        ('BROWSEKIT_MCPO_PORT=' + $Ports.Mcpo),
        ('BROWSEKIT_WEBUI_PORT=' + $Ports.WebUi),
        ('BROWSEKIT_PROFILE_DIR=' + $ProfileDir),
        ('BROWSEKIT_WORKSPACE_DIR=' + $WorkspaceDir)
    )
    [System.IO.File]::WriteAllLines((Join-Path $RunDir 'ports.txt'), $note, (New-Object System.Text.UTF8Encoding $true))
}

function Show-DevPlan {
    Write-Host '======== BrowseKit 开发环境 ========' -ForegroundColor Green
    Write-Host ('配置目录 : ' + $ProfileDir)
    Write-Host ('工作区   : ' + $WorkspaceDir)
    Write-Host ('运行目录 : ' + $RunDir)
    Write-Host ('CDP      : ' + $Ports.Cdp)
    Write-Host ('MCP      : ' + $Ports.Mcp)
    Write-Host ('MCPO     : ' + $Ports.Mcpo)
    Write-Host ('WebUI    : ' + $Ports.WebUi)
    Write-Host ('容器     : browsekit-webui-dev / browsekit-tools-dev')
    Write-Host '生产 chrome-profile、workspace、3000/8931/8932/8933 不在此流程内。'
}

if ($Action -eq 'prepare') {
    Initialize-DevDirs
    Show-DevPlan
    Write-Host 'PREPARE_OK'
    exit 0
}

if ($Action -eq 'down') {
    Show-DevPlan
    Write-Host '[1/3] 停止开发 MCP ...' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Stop-BrowseKitHost.ps1') -RunDir $RunDir
    Write-Host '[2/3] 停止开发容器（保留开发数据卷）...' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $ComposeFile) {
        Push-Location (Split-Path -Parent $ComposeFile)
        try {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & docker compose -f $ComposeFile -p browsekit-dev down 2>&1 | ForEach-Object { Write-Host ('    ' + $_) }
            } finally { $ErrorActionPreference = $prev }
        } finally { Pop-Location }
    }
    Write-Host '[3/3] 关闭开发专用 Chrome ...' -ForegroundColor Cyan
    $n = Stop-BrowseKitChromeByProfile -ProfileDir $ProfileDir -DebugPort $Ports.Cdp
    Write-Host ('    已结束开发 Chrome 进程数：' + $n)
    Write-Host 'DEV_DOWN_OK'
    exit 0
}

Initialize-DevDirs
Set-DevEnvironment
Show-DevPlan
$composeText = [System.IO.File]::ReadAllText($ComposeFile)
if ($composeText -match '127\.0\.0\.1:3000:' -or $composeText -match '127\.0\.0\.1:8932:') {
    throw 'docker-compose.dev.yml 含生产端口，拒绝启动。'
}
if ($composeText -notmatch 'browsekit-webui-dev' -or $composeText -notmatch 'workspace-dev') {
    throw 'docker-compose.dev.yml 缺少开发隔离标记，拒绝启动。'
}

Write-Host '[1/3] 启动开发 Chrome ...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Start-AIChrome.ps1') -DebugPort $Ports.Cdp -ProfileDir $ProfileDir -InboxDir (Join-Path $WorkspaceDir 'inbox')
if (-not (Test-BrowseKitTcpPort -Port $Ports.Cdp)) { throw '开发 CDP 未就绪' }

Write-Host '[2/3] 启动开发 MCP ...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Start-PlaywrightMcp.ps1') -CdpPort $Ports.Cdp -McpPort $Ports.Mcp -RunDir $RunDir
if (-not (Test-BrowseKitTcpPort -Port $Ports.Mcp)) { throw '开发 MCP 未就绪' }

Write-Host '[3/3] 启动开发容器 ...' -ForegroundColor Cyan
$envFile = Join-Path $Root 'docker\.env'
if (-not (Test-Path -LiteralPath $envFile)) { throw '缺少 docker\.env（不会打印其内容）。请由 .env.example 复制后填写。' }
Push-Location (Join-Path $Root 'docker')
try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker compose --env-file $envFile -f $ComposeFile -p browsekit-dev up -d --build 2>&1 | ForEach-Object { Write-Host ('    ' + $_) }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw '开发容器启动失败' }
} finally { Pop-Location }

Write-Host ''
Write-Host 'DEV_UP_OK' -ForegroundColor Green
Write-Host ('开发控制台：http://127.0.0.1:' + $Ports.WebUi)
Write-Host ('开发 MCP ：http://127.0.0.1:' + $Ports.Mcp + '/mcp')
Write-Host '关闭开发环境：powershell -File scripts\Dev-BrowseKit.ps1 -Action down'
