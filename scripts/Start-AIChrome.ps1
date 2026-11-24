#Requires -Version 5.1
<#
.SYNOPSIS
    启动 BrowseKit 专用 Chrome（独立 user-data-dir + 远程调试端口）。

.DESCRIPTION
    - 严格 Windows PowerShell 5.1 语法，不使用 PS7 专有特性（?? / ?. / 三元 / -Parallel）。
    - 端口存活一律使用 System.Net.Sockets.TcpClient 探测，不依赖 netstat。
    - 仅使用本目录下的 chrome-profile，绝不触碰用户日常 Chrome 配置。
    - 绝不按进程名结束 chrome.exe；本脚本不会 kill 任何进程。

.PARAMETER DebugPort
    Chrome DevTools 调试端口，默认 8933。

.PARAMETER WaitSeconds
    等待调试通道就绪的最长秒数，默认 15。

.EXAMPLE
    .\Start-AIChrome.ps1
#>
[CmdletBinding()]
param(
    [int]$DebugPort   = 8933,
    [int]$WaitSeconds = 15,
    [string]$ProfileDir,
    [string]$InboxDir
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 路径常量
$Root       = Split-Path -Parent $PSScriptRoot
$ChromeExe  = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (-not $ProfileDir) { $ProfileDir = Join-Path $Root 'chrome-profile' }
if (-not $InboxDir) { $InboxDir = Join-Path $Root 'workspace\inbox' }
$DefaultDir = Join-Path $ProfileDir 'Default'
$PrefsPath  = Join-Path $DefaultDir 'Preferences'
$VersionUrl = 'http://127.0.0.1:' + $DebugPort + '/json/version'

# ---------------------------------------------------------------- 工具函数
function Test-TcpPort {
    param(
        [string]$TargetHost = '127.0.0.1',
        [int]$Port,
        [int]$TimeoutMs = 800
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-DebugVersion {
    param([string]$Url)
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
    $text = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    $obj  = ConvertFrom-Json -InputObject $text
    return $obj
}

function Show-DebugSummary {
    param($Info)
    Write-Host ''
    Write-Host '--- DevTools /json/version ---' -ForegroundColor Cyan
    Write-Host ('Browser              : ' + $Info.Browser)
    Write-Host ('Protocol-Version     : ' + $Info.'Protocol-Version')
    Write-Host ('User-Agent           : ' + $Info.'User-Agent')
    Write-Host ('V8-Version           : ' + $Info.'V8-Version')
    Write-Host ('webSocketDebuggerUrl : ' + $Info.webSocketDebuggerUrl)
    Write-Host ''
}

function Ensure-ObjectProperty {
    param($InputObject, [string]$Name)
    if ($InputObject.PSObject.Properties.Name -notcontains $Name) {
        $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value (New-Object PSObject)
    }
    return $InputObject.$Name
}

# ---------------------------------------------------------------- 前置检查
Write-Host '=== BrowseKit / Start-AIChrome ===' -ForegroundColor Green

if (-not (Test-Path -LiteralPath $ChromeExe)) {
    throw ('未找到 Chrome：' + $ChromeExe)
}
Write-Host ('Chrome 可执行文件 : ' + $ChromeExe)
Write-Host ('专用配置目录      : ' + $ProfileDir)
Write-Host ('调试端口          : ' + $DebugPort)

# 已在运行则直接回报，不重复启动
if (Test-TcpPort -Port $DebugPort) {
    Write-Host ''
    Write-Host ('端口 ' + $DebugPort + ' 已开放：调试 Chrome 已在运行，跳过启动。') -ForegroundColor Yellow
    try {
        $info = Get-DebugVersion -Url $VersionUrl
        Show-DebugSummary -Info $info
    } catch {
        Write-Warning ('端口已开放但 /json/version 读取失败：' + $_.Exception.Message)
    }
    return
}

# 检测"同一 profile 已被无调试端口实例占用"的情况：Chrome 单例会把新参数吞掉
$sameProfile = @()
try {
    $sameProfile = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $ProfileDir + '*') })
} catch { }
if ($sameProfile.Count -gt 0) {
    Write-Warning ('检测到已有 Chrome 实例在使用本专用配置目录但未开启调试端口（PID: ' + (($sameProfile | ForEach-Object { $_.ProcessId }) -join ', ') + '）。')
    Write-Warning 'Chrome 为单例进程，直接重启可能复用旧实例导致调试端口不生效。'
    Write-Warning '请手动关闭该专用 Chrome 窗口（不影响日常浏览器），然后重新运行本脚本。'
    return
}

# ---------------------------------------------------------------- 下载目录偏好
Write-Host ''
Write-Host '--- 写入下载目录偏好 ---' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $DefaultDir)) {
    New-Item -ItemType Directory -Path $DefaultDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $InboxDir)) {
    New-Item -ItemType Directory -Path $InboxDir -Force | Out-Null
}

$prefs = $null
if (Test-Path -LiteralPath $PrefsPath) {
    try {
        $raw = Get-Content -LiteralPath $PrefsPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { $prefs = New-Object PSObject }
        else { $prefs = ConvertFrom-Json -InputObject $raw }
    } catch {
        $bak = $PrefsPath + '.broken-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $PrefsPath -Destination $bak -Force
        Write-Warning ('Preferences 解析失败，已备份到 ' + $bak + '，将重建最小偏好文件。')
        $prefs = New-Object PSObject
    }
} else {
    $prefs = New-Object PSObject
}

# 修改前留一份备份（仅在本目录内）
if (Test-Path -LiteralPath $PrefsPath) {
    $bak2 = $PrefsPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $PrefsPath -Destination $bak2 -Force
    Write-Host ('已备份原 Preferences -> ' + (Split-Path -Leaf $bak2))
}

$download = Ensure-ObjectProperty -InputObject $prefs -Name 'download'
$savefile = Ensure-ObjectProperty -InputObject $prefs -Name 'savefile'

$download | Add-Member -MemberType NoteProperty -Name 'default_directory'   -Value $InboxDir -Force
$download | Add-Member -MemberType NoteProperty -Name 'prompt_for_download' -Value $false     -Force
$savefile | Add-Member -MemberType NoteProperty -Name 'default_directory'   -Value $InboxDir -Force

$json = ConvertTo-Json -InputObject $prefs -Depth 32
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($PrefsPath, $json, $utf8NoBom)

Write-Host ('download.default_directory        = ' + $InboxDir)
Write-Host ('download.prompt_for_download      = false')
Write-Host ('savefile.default_directory        = ' + $InboxDir)

# ---------------------------------------------------------------- 启动
Write-Host ''
Write-Host '--- 启动专用 Chrome ---' -ForegroundColor Cyan

$argLine = '--user-data-dir="' + $ProfileDir + '"' +
           ' --remote-debugging-port=' + $DebugPort +
           ' --no-first-run' +
           ' --no-default-browser-check'

Write-Host ('启动参数 : ' + $argLine)
Start-Process -FilePath $ChromeExe -ArgumentList $argLine | Out-Null

# ---------------------------------------------------------------- 等待就绪
$deadline  = (Get-Date).AddSeconds($WaitSeconds)
$info      = $null
$lastError = ''

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (-not (Test-TcpPort -Port $DebugPort -TimeoutMs 500)) { continue }
    try {
        $info = Get-DebugVersion -Url $VersionUrl
        break
    } catch {
        $lastError = $_.Exception.Message
    }
}

if ($null -eq $info) {
    Write-Host ''
    Write-Error ('等待 ' + $WaitSeconds + ' 秒后调试通道仍未就绪。端口状态：' + (Test-TcpPort -Port $DebugPort) + '；最后错误：' + $lastError)
    Write-Host '排查建议：确认没有其他实例占用同一 user-data-dir；确认 8933 未被安全软件拦截。' -ForegroundColor Yellow
    exit 1
}

Show-DebugSummary -Info $info
Write-Host ('调试通道已就绪：http://127.0.0.1:' + $DebugPort) -ForegroundColor Green

# ---------------------------------------------------------------- 提示
Write-Host ''
Write-Host '提示：首次使用建议在该 Chrome 窗口手动打开 chrome://settings/downloads，' -ForegroundColor Yellow
Write-Host '      确认"下载位置"显示为 workspace\inbox，且未被企业策略（DownloadDirectory 等）覆盖。' -ForegroundColor Yellow
Write-Host '      若显示被策略接管，请以浏览器内实际生效路径为准，不要强行改注册表。' -ForegroundColor Yellow
