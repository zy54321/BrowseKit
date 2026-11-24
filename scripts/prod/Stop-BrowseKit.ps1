#Requires -Version 5.1
<#
.SYNOPSIS
    生产环境一键停止：关闭托盘 -> 停止容器（保留数据卷）-> 停止 Playwright MCP。

.DESCRIPTION
    位于 <生产根>\<版本>\scripts\；绝不使用 docker compose down -v，绝不结束 chrome.exe。
    会先优雅退出 BrowseKit 托盘（释放热键并销毁图标）。专用 Chrome 需要释放内存时请手动关闭其窗口。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$ScriptDir   = $PSScriptRoot
$VersionDir  = Split-Path -Parent $ScriptDir
$ProdRoot    = Split-Path -Parent $VersionDir
$DataDir     = Join-Path $ProdRoot 'data'
$ProfileDir  = Join-Path $DataDir 'chrome-profile'
$RunDir      = Join-Path $DataDir '.run'
$PidFile     = Join-Path $RunDir 'playwright-mcp.pid'
$ComposeFile = Join-Path $VersionDir 'docker\docker-compose.yml'
$EnvFile     = Join-Path $DataDir '.env'

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
Write-Host (' BrowseKit 生产停止  ' + (Split-Path -Leaf $VersionDir)) -ForegroundColor Green
Write-Host '==============================================' -ForegroundColor Green

# ---------------------------------------------------------------- 1) 托盘
Write-Host '[1/3] 关闭系统托盘 ...' -ForegroundColor Cyan
$desk = Join-Path $ScriptDir 'tools\BrowseKit.Desktop.ps1'
if (Test-Path -LiteralPath $desk) {
    try {
        . $desk
        Stop-BrowseKitTray -ProfileDir $ProfileDir
    } catch {
        Write-Warning ('关闭托盘时出现问题：' + $_.Exception.Message)
    }
} else {
    Write-Warning ('未找到托盘辅助脚本：' + $desk)
}

# ---------------------------------------------------------------- 2) 容器
Write-Host ''
Write-Host '[2/3] 停止容器（保留数据卷）...' -ForegroundColor Cyan
if ((Test-Path -LiteralPath $ComposeFile) -and (Test-Path -LiteralPath $EnvFile)) {
    Push-Location (Split-Path -Parent $ComposeFile)
    & docker compose --env-file $EnvFile -f $ComposeFile down 2>&1 | ForEach-Object { Write-Host ('    ' + $_) }
    Pop-Location
} else {
    Write-Warning '未找到生产编排或 data\.env，跳过容器停止。'
}

# ---------------------------------------------------------------- 3) MCP
Write-Host ''
Write-Host '[3/3] 停止 Playwright MCP（按 PID）...' -ForegroundColor Cyan
if (Test-Path -LiteralPath $PidFile) {
    $raw = (Get-Content -LiteralPath $PidFile -Raw).Trim()
    $targetPid = 0
    if ([int]::TryParse($raw, [ref]$targetPid) -and $targetPid -gt 0) {
        $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
        if ($proc) {
            $cmd = ''
            try { $w = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $targetPid) -ErrorAction SilentlyContinue; if ($w) { $cmd = [string]$w.CommandLine } } catch { }
            if ($proc.ProcessName -match '^node' -and $cmd -match '(?i)playwright') {
                Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
                Write-Host ('    已停止 MCP PID ' + $targetPid) -ForegroundColor Green
            } else {
                Write-Warning ('PID ' + $targetPid + ' 不像本次 MCP（可能已复用），未结束')
            }
        } else {
            Write-Host ('    PID ' + $targetPid + ' 已不存在') -ForegroundColor Yellow
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
} else {
    Write-Host '    未发现 MCP PID 文件' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '================ 停止后端口 ================' -ForegroundColor Green
foreach ($p in @(3000, 8932, 8931, 8933)) {
    Write-Host ('  {0,-6} {1}' -f $p, $(if (Test-TcpPort -Port $p) { 'STILL OPEN' } else { 'CLOSED' }))
}
Write-Host ''
Write-Host '数据卷 browsekit-open-webui-data 已保留（账号/模型/历史不会丢失）。' -ForegroundColor Yellow
Write-Host '专用 Chrome 未被关闭；如需释放内存，请手动关闭该窗口（日常浏览器不受影响）。' -ForegroundColor Yellow
