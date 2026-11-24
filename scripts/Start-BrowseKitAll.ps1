#Requires -Version 5.1
<#
.SYNOPSIS
    一键拉起 BrowseKit：专用 Chrome -> Playwright MCP -> Open WebUI + MCPO 工具容器。

.DESCRIPTION
    严格 Windows PowerShell 5.1 语法。执行顺序：
      1) scripts\Start-AIChrome.ps1        （专用 Chrome，CDP 8933）
      2) scripts\Start-PlaywrightMcp.ps1   （Playwright MCP，8931，绑定 127.0.0.1）
      3) docker compose up -d              （browsekit-webui:3000 / browsekit-tools:8932）
    最后做端口与 HTTP 健康汇总；任何一步失败即中止并给出定位提示。

.PARAMETER SkipChrome
    跳过 Chrome 启动（已有实例在跑时可用）。

.PARAMETER WebUiTimeoutSec
    等待 Open WebUI 就绪的最长秒数，默认 180。

.PARAMETER McpoTimeoutSec
    等待 MCPO 工具服务就绪的最长秒数，默认 300（首次启动需联网拉取 npx/uvx 依赖）。

.EXAMPLE
    .\Start-BrowseKitAll.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipChrome,
    [int]$WebUiTimeoutSec = 180,
    [int]$McpoTimeoutSec  = 300
)

$ErrorActionPreference = 'Stop'

$Root      = Split-Path -Parent $PSScriptRoot
$ScriptDir = $PSScriptRoot
$DockerDir = Join-Path $Root 'docker'
$McpPort   = 8931
$CdpPort   = 8933
$WebUiPort = 3000
$McpoPort  = 8932

function Test-TcpPort {
    param([string]$TargetHost = '127.0.0.1', [int]$Port, [int]$TimeoutMs = 800)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) { return $true }
        return $false
    } catch { return $false } finally { try { $client.Close() } catch { } }
}

function Get-HttpCode {
    param([string]$Url, [int]$TimeoutSec = 5)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

function Wait-HttpOk {
    param([string]$Url, [int]$TimeoutSec, [string]$Label)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $code = Get-HttpCode -Url $Url -TimeoutSec 4
        if ($code -ge 200 -and $code -lt 400) { return $code }
        Start-Sleep -Seconds 3
    }
    return 0
}

Write-Host '==============================================' -ForegroundColor Green
Write-Host ' 018-BrowseKit / 一键启动' -ForegroundColor Green
Write-Host '==============================================' -ForegroundColor Green

# ---------------------------------------------------------------- 1) Chrome
if ($SkipChrome) {
    Write-Host '[1/3] 跳过 Chrome 启动（-SkipChrome）' -ForegroundColor Yellow
} else {
    Write-Host '[1/3] 启动专用 Chrome ...' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'Start-AIChrome.ps1')
    if ($LASTEXITCODE -ne 0) { Write-Error 'Start-AIChrome.ps1 失败，中止。'; exit 1 }
}
if (-not (Test-TcpPort -Port $CdpPort)) { Write-Error ('CDP 端口 ' + $CdpPort + ' 未就绪，中止。'); exit 1 }

# ---------------------------------------------------------------- 2) MCP
Write-Host ''
Write-Host '[2/3] 启动 Playwright MCP ...' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'Start-PlaywrightMcp.ps1')
if ($LASTEXITCODE -ne 0) { Write-Error 'Start-PlaywrightMcp.ps1 失败，中止。'; exit 1 }
if (-not (Test-TcpPort -Port $McpPort)) { Write-Error ('MCP 端口 ' + $McpPort + ' 未就绪，中止。'); exit 1 }

# ---------------------------------------------------------------- 3) Compose
Write-Host ''
Write-Host '[3/3] 启动 BrowseKit 容器（docker compose up -d）...' -ForegroundColor Cyan
Push-Location $DockerDir
try {
    $envFile = Join-Path $DockerDir '.env'
    if (-not (Test-Path -LiteralPath $envFile)) {
        Write-Error ('缺少 ' + $envFile + '，请先由 .env.example 复制并填写。')
        exit 1
    }
    # 原生命令的 stderr 在 EAP=Stop 下会被当成终止错误，这里临时放宽并自行判定退出码
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker compose up -d 2>&1 | ForEach-Object { Write-Host ('    ' + $_) }
        $composeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($composeExit -ne 0) { Write-Error 'docker compose up -d 失败，中止。'; exit 1 }
} finally {
    Pop-Location
}

Write-Host ''
Write-Host '容器已创建，等待服务就绪 ...' -ForegroundColor Cyan

$webCode = Wait-HttpOk -Url ('http://127.0.0.1:' + $WebUiPort + '/') -TimeoutSec $WebUiTimeoutSec -Label 'Open WebUI'
if ($webCode -eq 0) { Write-Warning ('Open WebUI 在 ' + $WebUiTimeoutSec + ' 秒内未返回 2xx/3xx，请查看 docker logs browsekit-webui') }

# MCPO 需要子进程拉起，首次可能较慢
$mcpoCode = 0
$deadline = (Get-Date).AddSeconds($McpoTimeoutSec)
while ((Get-Date) -lt $deadline) {
    if (Test-TcpPort -Port $McpoPort) { $mcpoCode = Get-HttpCode -Url ('http://127.0.0.1:' + $McpoPort + '/docs') -TimeoutSec 4; if ($mcpoCode -gt 0) { break } }
    Start-Sleep -Seconds 3
}

# ---------------------------------------------------------------- 汇总
Write-Host ''
Write-Host '================ 健康汇总 ================' -ForegroundColor Green
$rows = @(
    [pscustomobject]@{ 组件 = 'Chrome CDP';      地址 = ('http://127.0.0.1:' + $CdpPort + '/json/version'); 状态 = $(if (Test-TcpPort -Port $CdpPort) { 'UP' } else { 'DOWN' }) },
    [pscustomobject]@{ 组件 = 'Playwright MCP';  地址 = ('http://127.0.0.1:' + $McpPort + '/mcp');          状态 = $(if (Test-TcpPort -Port $McpPort) { 'UP' } else { 'DOWN' }) },
    [pscustomobject]@{ 组件 = 'Open WebUI';      地址 = ('http://127.0.0.1:' + $WebUiPort);                  状态 = $(if ($webCode -gt 0) { 'HTTP ' + $webCode } else { 'DOWN' }) },
    [pscustomobject]@{ 组件 = 'MCPO 工具';       地址 = ('http://127.0.0.1:' + $McpoPort);                   状态 = $(if ($mcpoCode -gt 0) { 'HTTP ' + $mcpoCode } else { 'DOWN' }) }
)
$rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Host

Write-Host '容器状态：' -ForegroundColor Cyan
$prevEap2 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker compose -f (Join-Path $DockerDir 'docker-compose.yml') ps 2>&1 | ForEach-Object { Write-Host $_ }
} finally {
    $ErrorActionPreference = $prevEap2
}

Write-Host ''
Write-Host '下一步：浏览器打开 http://127.0.0.1:3000 ，在 设置 -> 工具 中按报告里的 3 个地址接入工具。' -ForegroundColor Yellow
Write-Host 'API Key 见 docker\.env 的 MCPO_API_KEY，不要外传。' -ForegroundColor Yellow
