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
    foreach ($marker in @(
            ('--user-data-dir="' + $norm + '"'),
            ("--user-data-dir='" + $norm + "'"),
            ('--user-data-dir=' + $norm)
        )) {
        $idx = $cmd.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
        while ($idx -ge 0) {
            $after = $idx + $marker.Length
            $quoted = $marker.EndsWith('"') -or $marker.EndsWith("'")
            if ($quoted -or $after -ge $cmd.Length) { return $true }
            $ch = $cmd[$after]
            if ($ch -eq '"' -or $ch -eq "'" -or [char]::IsWhiteSpace($ch)) { return $true }
            $idx = $cmd.IndexOf($marker, $after, [System.StringComparison]::OrdinalIgnoreCase)
        }
    }
    return $false
}

function Test-BrowseKitDedicatedCommandLine {
    param([string]$CommandLine, [string]$ProfileDir, [int]$DebugPort)
    if ($DebugPort -le 0) { return $false }
    if (-not (Test-BrowseKitProfileCommandLine -CommandLine $CommandLine -ProfileDir $ProfileDir)) { return $false }
    $cmd = $CommandLine.Replace('/', '\')
    $token = '--remote-debugging-port=' + $DebugPort
    $idx = $cmd.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase)
    if ($idx -lt 0) { return $false }
    $after = $idx + $token.Length
    if ($after -lt $cmd.Length) {
        $ch = $cmd[$after]
        if ($ch -ge '0' -and $ch -le '9') { return $false }
    }
    return $true
}

function Get-BrowseKitDedicatedChromePids {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [Parameter(Mandatory = $true)][int]$DebugPort
    )
    $all = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue)
    $roots = New-Object System.Collections.Generic.List[int]
    foreach ($proc in $all) {
        $cmd = [string]$proc.CommandLine
        if ($cmd -match '(?i)(^|\s)--type=') { continue }
        if (Test-BrowseKitDedicatedCommandLine -CommandLine $cmd -ProfileDir $ProfileDir -DebugPort $DebugPort) {
            $roots.Add([int]$proc.ProcessId)
        }
    }
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($id in $roots) { [void]$set.Add($id) }
    $guard = 0
    $changed = $true
    while ($changed -and $guard -lt 20) {
        $guard++
        $changed = $false
        foreach ($proc in $all) {
            $id = [int]$proc.ProcessId
            if ($set.Contains($id)) { continue }
            if (-not $set.Contains([int]$proc.ParentProcessId)) { continue }
            $cmd = [string]$proc.CommandLine
            if ($cmd -match '(?i)\\Google\\Chrome\\User Data') { continue }
            if (-not (Test-BrowseKitProfileCommandLine -CommandLine $cmd -ProfileDir $ProfileDir)) { continue }
            if ($cmd -match '(?i)--remote-debugging-port=(\d+)' -and [int]$Matches[1] -ne $DebugPort) { continue }
            [void]$set.Add($id)
            $changed = $true
        }
    }
    Write-Output -NoEnumerate $set
}

function Stop-BrowseKitChromeByProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [Parameter(Mandatory = $true)][int]$DebugPort
    )
    if ($DebugPort -le 0) { throw '结束专用 Chrome 必须同时指定调试端口。' }
    $full = [System.IO.Path]::GetFullPath($ProfileDir).TrimEnd('\')
    $prod = [System.IO.Path]::GetFullPath((Join-Path (Get-BrowseKitRoot) 'chrome-profile')).TrimEnd('\')
    if ($full.Equals($prod, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '拒绝按配置目录结束生产 Chrome。请手动关闭生产窗口。'
    }
    $ids = Get-BrowseKitDedicatedChromePids -ProfileDir $full -DebugPort $DebugPort
    $stopped = 0
    foreach ($id in @($ids)) {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $id) -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        if ([string]$proc.Name -ne 'chrome.exe') { continue }
        $cmd = [string]$proc.CommandLine
        if ($cmd -match '(?i)\\Google\\Chrome\\User Data') { continue }
        $own = Test-BrowseKitDedicatedCommandLine -CommandLine $cmd -ProfileDir $full -DebugPort $DebugPort
        $child = (-not $own) -and (Test-BrowseKitProfileCommandLine -CommandLine $cmd -ProfileDir $full) -and $ids.Contains([int]$proc.ParentProcessId)
        if (-not $own -and -not $child) { continue }
        Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue
        $stopped++
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
