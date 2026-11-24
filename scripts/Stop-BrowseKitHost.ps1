#Requires -Version 5.1
<#
.SYNOPSIS
    停止由 Start-PlaywrightMcp.ps1 启动的 Playwright MCP 进程。

.DESCRIPTION
    - 仅依据 .run\playwright-mcp.pid 精准停止对应 PID，并清理 PID 文件。
    - 停止前校验该 PID 确实是 node 进程且命令行包含 playwright/mcp，避免 PID 复用误杀。
    - 绝不按进程名批量结束 chrome.exe；如需关闭专用 Chrome，请用户手动关闭窗口。

.PARAMETER Force
    跳过命令行校验（仅在确认 PID 归属时使用）。

.EXAMPLE
    .\Stop-BrowseKitHost.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$RunDir
)

$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $PSScriptRoot
if (-not $RunDir) { $RunDir = Join-Path $Root '.run' }
$PidFile  = Join-Path $RunDir 'playwright-mcp.pid'
$LogFile  = Join-Path $RunDir 'playwright-mcp.log'

Write-Host '=== BrowseKit / Stop-BrowseKitHost ===' -ForegroundColor Green

if (-not (Test-Path -LiteralPath $PidFile)) {
    Write-Host ('未发现 PID 文件：' + $PidFile) -ForegroundColor Yellow
    Write-Host '说明：Playwright MCP 可能未启动，或已由其他方式停止。'
    return
}

$rawPid = (Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8).Trim()
$targetPid = 0
if (-not [int]::TryParse($rawPid, [ref]$targetPid) -or $targetPid -le 0) {
    Write-Warning ('PID 文件内容非法（' + $rawPid + '），直接删除该文件，不做任何进程操作。')
    Remove-Item -LiteralPath $PidFile -Force
    return
}

Write-Host ('PID 文件指向 : ' + $targetPid)

$proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
if ($null -eq $proc) {
    Write-Host ('PID ' + $targetPid + ' 已不存在（进程早已退出），清理 PID 文件。') -ForegroundColor Yellow
    Remove-Item -LiteralPath $PidFile -Force
    return
}

# 归属校验：必须是 node 进程，且命令行含 playwright + mcp
$cmdLine = ''
try {
    $wmi = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $targetPid) -ErrorAction SilentlyContinue
    if ($wmi) { $cmdLine = [string]$wmi.CommandLine }
} catch { }

Write-Host ('进程名       : ' + $proc.ProcessName)
if ($cmdLine) { Write-Host ('命令行       : ' + $cmdLine) }

$looksLikeMcp = ($proc.ProcessName -match '^node') -and
                ($cmdLine -match '(?i)playwright') -and
                ($cmdLine -match '(?i)mcp')

if (-not $looksLikeMcp -and -not $Force) {
    Write-Warning '该 PID 不像是本次启动的 Playwright MCP 进程（PID 可能已被复用）。'
    Write-Warning '为避免误杀，已放弃停止操作，仅保留 PID 文件供人工核对。'
    Write-Warning '确认无误后可执行：.\Stop-BrowseKitHost.ps1 -Force'
    return
}

Write-Host ('正在停止 PID ' + $targetPid + ' ...') -ForegroundColor Cyan
try {
    Stop-Process -Id $targetPid -Force -ErrorAction Stop
    Start-Sleep -Milliseconds 600
} catch {
    throw ('停止失败：' + $_.Exception.Message)
}

if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
    throw '进程仍然存在，请人工检查。'
}

Remove-Item -LiteralPath $PidFile -Force
Write-Host ('已停止并清理 PID 文件：' + (Split-Path -Leaf $PidFile)) -ForegroundColor Green
if (Test-Path -LiteralPath $LogFile) {
    Write-Host ('历史日志保留在：' + $LogFile)
}

Write-Host ''
Write-Host '注意：本脚本不会关闭专用 Chrome。如窗口仍开着，请手动关闭该窗口（日常 Chrome 不受影响）。' -ForegroundColor Yellow
