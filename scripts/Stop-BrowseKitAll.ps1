#Requires -Version 5.1
<#
.SYNOPSIS
    一键停止 BrowseKit：先停容器（保留数据卷），再停 Playwright MCP。

.DESCRIPTION
    严格 Windows PowerShell 5.1 语法。
      - docker compose down（不带 -v，数据卷 browsekit-open-webui-data 保留）
      - 调用 Stop-BrowseKitHost.ps1 按 PID 精准停止 MCP
      - 绝不结束 chrome.exe；专用 Chrome 请手动关窗

.PARAMETER KeepChromeHint
    仅控制是否提示手动关闭 Chrome，默认提示。

.EXAMPLE
    .\Stop-BrowseKitAll.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$Root      = Split-Path -Parent $PSScriptRoot
$ScriptDir = $PSScriptRoot
$DockerDir = Join-Path $Root 'docker'
$CdpPort   = 8933
$McpPort   = 8931
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

Write-Host '==============================================' -ForegroundColor Green
Write-Host ' 018-BrowseKit / 一键停止' -ForegroundColor Green
Write-Host '==============================================' -ForegroundColor Green

# ---------------------------------------------------------------- 1) 容器
Write-Host '[1/2] 停止容器（保留数据卷）...' -ForegroundColor Cyan
if (Test-Path -LiteralPath (Join-Path $DockerDir 'docker-compose.yml')) {
    Push-Location $DockerDir
    try {
        & docker compose down 2>&1 | ForEach-Object { Write-Host ('    ' + $_) }
    } finally {
        Pop-Location
    }
} else {
    Write-Warning '未找到 docker\docker-compose.yml，跳过容器停止。'
}

# ---------------------------------------------------------------- 2) MCP
Write-Host ''
Write-Host '[2/2] 停止 Playwright MCP（按 PID）...' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'Stop-BrowseKitHost.ps1')

# ---------------------------------------------------------------- 汇总
Write-Host ''
Write-Host '================ 停止后端口状态 ================' -ForegroundColor Green
foreach ($p in @($WebUiPort, $McpoPort, $McpPort, $CdpPort)) {
    $state = if (Test-TcpPort -Port $p) { 'STILL OPEN' } else { 'CLOSED' }
    Write-Host ('  {0,-6} {1}' -f $p, $state)
}

Write-Host ''
Write-Host '数据卷 browsekit-open-webui-data 已保留（下次启动配置与账号不丢）。' -ForegroundColor Yellow
Write-Host '专用 Chrome 未被关闭；如需释放内存，请手动关闭该 Chrome 窗口（日常浏览器不受影响）。' -ForegroundColor Yellow
