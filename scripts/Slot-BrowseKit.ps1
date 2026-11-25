#Requires -Version 5.1
<#
.SYNOPSIS
    按需启停额外浏览器槽位。槽位 1 是生产主槽，不在这里启动。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('start', 'stop', 'status')]
    [string]$Command,
    [Parameter(Position = 1)]
    [int]$Slot = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BrowseKit.Common.ps1')

$Root = Get-BrowseKitRoot

function Get-SlotLayout {
    param([int]$Number)
    $ports = Get-BrowseKitSlotPorts -Slot $Number
    if ($Number -eq 1) {
        return [pscustomobject]@{
            Slot = 1
            Ports = $ports
            ProfileDir = Join-Path $Root 'chrome-profile'
            WorkspaceDir = Join-Path $Root 'workspace'
            RunDir = Join-Path $Root '.run'
            ManagedHere = $false
        }
    }
    return [pscustomobject]@{
        Slot = $Number
        Ports = $ports
        ProfileDir = Join-Path $Root ('chrome-profile-slot' + $Number)
        WorkspaceDir = Join-Path $Root ('workspace-slot' + $Number)
        RunDir = Join-Path $Root ('.run-slot' + $Number)
        ManagedHere = $true
    }
}

function Show-SlotRow {
    param($Layout)
    $cdp = $(if (Test-BrowseKitTcpPort -Port $Layout.Ports.Cdp) { 'UP' } else { 'DOWN' })
    $mcp = $(if ($Layout.Ports.Mcp -gt 0 -and (Test-BrowseKitTcpPort -Port $Layout.Ports.Mcp)) { 'UP' } else { 'DOWN' })
    $mode = $(if ($Layout.ManagedHere) { '按需' } else { '生产主槽' })
    Write-Host ('槽位 {0}  {1}  CDP {2}={3}  MCP {4}={5}  {6}' -f $Layout.Slot, $mode, $Layout.Ports.Cdp, $cdp, $Layout.Ports.Mcp, $mcp, $Layout.ProfileDir)
}

if ($Command -eq 'status') {
    Write-Host '======== BrowseKit 槽位 ========' -ForegroundColor Green
    Show-SlotRow (Get-SlotLayout -Number 1)
    for ($n = 2; $n -le 3; $n++) { Show-SlotRow (Get-SlotLayout -Number $n) }
    Write-Host '更多槽位：scripts\slot.bat status 只展示 1-3；start/stop 可指定更大编号。'
    exit 0
}

if ($Slot -lt 1) { throw '请指定槽位编号，例如 scripts\slot.bat start 2' }
if ($Slot -eq 1) {
    Write-Host '槽位 1 是生产主槽，请使用 04_Prod 的 启动BrowseKit.bat。本命令不会改动生产 Chrome。'
    exit 0
}
if ($Slot -gt 9) { throw '槽位编号限制为 2 到 9，以免端口规划溢出。' }

$layout = Get-SlotLayout -Number $Slot
Assert-BrowseKitDevPorts -Ports $layout.Ports

if ($Command -eq 'stop') {
    & (Join-Path $PSScriptRoot 'Stop-BrowseKitHost.ps1') -RunDir $layout.RunDir
    $n = Stop-BrowseKitChromeByProfile -ProfileDir $layout.ProfileDir -DebugPort $layout.Ports.Cdp
    Write-Host ('槽位 ' + $Slot + ' 已停止。结束的 Chrome 进程数：' + $n)
    exit 0
}

if (-not (Test-Path -LiteralPath $layout.ProfileDir)) { New-Item -ItemType Directory -Path $layout.ProfileDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $layout.RunDir)) { New-Item -ItemType Directory -Path $layout.RunDir -Force | Out-Null }
Initialize-BrowseKitWorkspace -WorkspaceDir $layout.WorkspaceDir -CopyTemplates
& (Join-Path $PSScriptRoot 'Start-AIChrome.ps1') -DebugPort $layout.Ports.Cdp -ProfileDir $layout.ProfileDir -InboxDir (Join-Path $layout.WorkspaceDir 'inbox')
& (Join-Path $PSScriptRoot 'Start-PlaywrightMcp.ps1') -CdpPort $layout.Ports.Cdp -McpPort $layout.Ports.Mcp -RunDir $layout.RunDir
Write-Host ('槽位 ' + $Slot + ' MCP：http://127.0.0.1:' + $layout.Ports.Mcp + '/mcp')
Write-Host '该槽位不会随生产部署自动启动。用完请执行 scripts\slot.bat stop ' $Slot
