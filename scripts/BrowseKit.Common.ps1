#Requires -Version 5.1
<#
.SYNOPSIS
    BrowseKit 各环境共用的路径、端口与进程辅助函数。
#>

function Get-BrowseKitRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-BrowseKitProdPorts {
    return [pscustomobject]@{ WebUi = 3000; Mcp = 8931; Mcpo = 8932; Cdp = 8933 }
}

function Get-BrowseKitDevPorts {
    $prod = Get-BrowseKitProdPorts
    return [pscustomobject]@{
        WebUi = ($prod.WebUi + 10)
        Mcp   = ($prod.Mcp + 10)
        Mcpo  = ($prod.Mcpo + 10)
        Cdp   = ($prod.Cdp + 10)
    }
}

function Get-BrowseKitSlotPorts {
    param([Parameter(Mandatory = $true)][int]$Slot)
    if ($Slot -lt 1) { throw '槽位编号必须从 1 开始' }
    if ($Slot -eq 1) { return Get-BrowseKitProdPorts }
    return [pscustomobject]@{
        WebUi = 0
        Mcp   = (8960 + $Slot)
        Mcpo  = 0
        Cdp   = (8950 + $Slot)
    }
}

function Test-BrowseKitTcpPort {
    param([string]$TargetHost = '127.0.0.1', [int]$Port, [int]$TimeoutMs = 800)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) { return $true }
        return $false
    } catch { return $false } finally { try { $client.Close() } catch { } }
}

function Assert-BrowseKitDevPorts {
    param($Ports)
    $banned = @(3000, 8931, 8932, 8933)
    foreach ($name in @('WebUi', 'Mcp', 'Mcpo', 'Cdp')) {
        $value = [int]$Ports.$name
        if ($banned -contains $value) { throw ('开发环境禁止占用生产端口 ' + $value) }
    }
}

function Test-BrowseKitProfileCommandLine {
    param([string]$CommandLine, [string]$ProfileDir)
    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($ProfileDir)) { return $false }
    $norm = [System.IO.Path]::GetFullPath($ProfileDir).TrimEnd('\')
    $cmd = $CommandLine.Replace('/', '\')
    $idx = $cmd.IndexOf($norm, [System.StringComparison]::OrdinalIgnoreCase)
    while ($idx -ge 0) {
        $after = $idx + $norm.Length
        if ($after -ge $cmd.Length) { return $true }
        $ch = $cmd[$after]
        if ($ch -eq '"' -or $ch -eq "'" -or [char]::IsWhiteSpace($ch)) { return $true }
        $idx = $cmd.IndexOf($norm, $after, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return $false
}

function Stop-BrowseKitChromeByProfile {
    param([Parameter(Mandatory = $true)][string]$ProfileDir)
    $full = [System.IO.Path]::GetFullPath($ProfileDir).TrimEnd('\')
    $prod = [System.IO.Path]::GetFullPath((Join-Path (Get-BrowseKitRoot) 'chrome-profile')).TrimEnd('\')
    if ($full.Equals($prod, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '拒绝按配置目录结束生产 Chrome。请手动关闭生产窗口。'
    }
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue)
    $stopped = 0
    foreach ($proc in $procs) {
        if (Test-BrowseKitProfileCommandLine -CommandLine ([string]$proc.CommandLine) -ProfileDir $full) {
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    }
    return $stopped
}

function Initialize-BrowseKitWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceDir,
        [switch]$CopyTemplates
    )
    foreach ($name in @('inbox', 'tasks', 'templates')) {
        $dir = Join-Path $WorkspaceDir $name
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    if ($CopyTemplates) {
        $dest = Join-Path $WorkspaceDir 'templates'
        $src = Join-Path (Get-BrowseKitRoot) 'templates'
        if (-not (Test-Path -LiteralPath $src)) { $src = Join-Path (Get-BrowseKitRoot) 'workspace\templates' }
        if (Test-Path -LiteralPath $src) {
            Get-ChildItem -LiteralPath $src -File -Force | ForEach-Object {
                $target = Join-Path $dest $_.Name
                if (-not (Test-Path -LiteralPath $target)) {
                    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                }
            }
        }
    }
}
