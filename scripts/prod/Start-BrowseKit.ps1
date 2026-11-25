#Requires -Version 5.1
<#
.SYNOPSIS
    生产环境一键启动：Docker 容器 -> Playwright MCP -> 专用 Chrome -> 第 2 虚拟桌面 -> 托盘 -> 健康检查。

.DESCRIPTION
    本脚本位于 <生产根>\<版本>\scripts\ 下，依靠自身位置推导相对路径：
        版本目录 = 本脚本上一级
        生产根   = 版本目录上一级
        数据目录 = 生产根\data
    Windows PowerShell 5.1 语法；UTF-8 with BOM。

.PARAMETER SkipChrome
    跳过专用 Chrome 启动。

.PARAMETER WaitSeconds
    等待 Open WebUI 就绪的最长秒数，默认 150。
#>
[CmdletBinding()]
param(
    [switch]$SkipChrome,
    [int]$WaitSeconds = 150
)

$ErrorActionPreference = 'Stop'

$ScriptDir   = $PSScriptRoot
$VersionDir  = Split-Path -Parent $ScriptDir
$ProdRoot    = Split-Path -Parent $VersionDir
$DataDir     = Join-Path $ProdRoot 'data'
$RunDir      = Join-Path $DataDir '.run'
$ComposeFile = Join-Path $VersionDir 'docker\docker-compose.yml'
$EnvFile     = Join-Path $DataDir '.env'
$ChromeExe   = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$ProfileDir  = Join-Path $DataDir 'chrome-profile'
$PrefsPath   = Join-Path (Join-Path $ProfileDir 'Default') 'Preferences'
$InboxDir    = Join-Path $DataDir 'workspace\inbox'
$PidFile     = Join-Path $RunDir 'playwright-mcp.pid'
$LogFile     = Join-Path $RunDir 'playwright-mcp.log'
$ErrFile     = Join-Path $RunDir 'playwright-mcp.err.log'
$CdpPort     = 8933
$McpPort     = 8931
$WebUiPort   = 3000

function Test-TcpPort {
    param([string]$TargetHost = '127.0.0.1', [int]$Port, [int]$TimeoutMs = 800)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) { return $true }
        return $false
    } catch { return $false } finally { try { $client.Close() } catch { } }
}

function Resolve-McpCli {
    if ($env:BROWSEKIT_MCP_CLI -and (Test-Path -LiteralPath $env:BROWSEKIT_MCP_CLI)) {
        return $env:BROWSEKIT_MCP_CLI
    }
    $local = Join-Path $VersionDir 'mcp-host\node_modules\@playwright\mcp\cli.js'
    if (Test-Path -LiteralPath $local) { return $local }
    return $null
}

Write-Host '==============================================' -ForegroundColor Green
Write-Host (' BrowseKit 生产启动  ' + (Split-Path -Leaf $VersionDir)) -ForegroundColor Green
Write-Host '==============================================' -ForegroundColor Green

foreach ($p in @($ComposeFile, $EnvFile)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Error ('缺少必需文件：' + $p); exit 1 }
}
if (-not (Test-Path -LiteralPath $RunDir)) { New-Item -ItemType Directory -Path $RunDir -Force | Out-Null }

# ---------------------------------------------------------------- 1) Chrome
$chromeFreshStart = $false
if (-not $SkipChrome) {
    if (Test-TcpPort -Port $CdpPort) {
        Write-Host ('[1/3] Chrome 调试端口 ' + $CdpPort + ' 已开放，跳过启动和窗口前置') -ForegroundColor Yellow
    } else {
        $chromeFreshStart = $true
        Write-Host '[1/3] 启动专用 Chrome ...' -ForegroundColor Cyan
        $defaultDir = Join-Path $ProfileDir 'Default'
        if (-not (Test-Path -LiteralPath $defaultDir)) { New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $InboxDir)) { New-Item -ItemType Directory -Path $InboxDir -Force | Out-Null }

        if (Test-Path -LiteralPath $PrefsPath) {
            Copy-Item -LiteralPath $PrefsPath -Destination ($PrefsPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
            try {
                $prefs = Get-Content -LiteralPath $PrefsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { $prefs = New-Object PSObject }
        } else { $prefs = New-Object PSObject }

        foreach ($name in @('download', 'savefile')) {
            if ($prefs.PSObject.Properties.Name -notcontains $name) {
                $prefs | Add-Member -MemberType NoteProperty -Name $name -Value (New-Object PSObject)
            }
        }
        $prefs.download | Add-Member -MemberType NoteProperty -Name 'default_directory' -Value $InboxDir -Force
        $prefs.download | Add-Member -MemberType NoteProperty -Name 'prompt_for_download' -Value $false -Force
        $prefs.savefile | Add-Member -MemberType NoteProperty -Name 'default_directory' -Value $InboxDir -Force
        [System.IO.File]::WriteAllText($PrefsPath, (ConvertTo-Json -InputObject $prefs -Depth 32), (New-Object System.Text.UTF8Encoding($false)))

        $argLine = '--user-data-dir="' + $ProfileDir + '" --remote-debugging-port=' + $CdpPort + ' --no-first-run --no-default-browser-check'
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $ChromeExe
        $startInfo.Arguments = $argLine
        $startInfo.UseShellExecute = $false
        [void][System.Diagnostics.Process]::Start($startInfo)

        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and -not (Test-TcpPort -Port $CdpPort)) { Start-Sleep -Milliseconds 500 }
        if (-not (Test-TcpPort -Port $CdpPort)) { Write-Error 'Chrome 调试端口未就绪'; exit 1 }
    }

    $desk = Join-Path $ScriptDir 'tools\BrowseKit.Desktop.ps1'
    if (Test-Path -LiteralPath $desk) {
        try { . $desk } catch { Write-Warning ('加载桌面隔离组件失败：' + $_.Exception.Message) }
        if ($chromeFreshStart -and (Get-Command Move-BrowseKitChromeToSecondDesktop -ErrorAction SilentlyContinue)) {
            try {
                Move-BrowseKitChromeToSecondDesktop -ProfileDir $ProfileDir -DebugPort $CdpPort | Out-Null
            } catch {
                Write-Warning ('送入第 2 虚拟桌面失败：' + $_.Exception.Message + '。可稍后用托盘或 Win+Ctrl+→。')
            }
        }
        if (Get-Command Start-BrowseKitTray -ErrorAction SilentlyContinue) {
            try {
                Start-BrowseKitTray -ScriptRoot $ScriptDir -ProfileDir $ProfileDir
            } catch {
                Write-Warning ('托盘启动失败：' + $_.Exception.Message)
            }
        }
    } else {
        Write-Warning ('未找到桌面隔离组件：' + $desk)
    }
} else {
    Write-Host '[1/3] 跳过 Chrome（-SkipChrome）' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 2) MCP
Write-Host '[2/3] 启动 Playwright MCP ...' -ForegroundColor Cyan
if (Test-TcpPort -Port $McpPort) {
    Write-Host ('    端口 ' + $McpPort + ' 已开放，跳过启动') -ForegroundColor Yellow
} else {
    $cli = Resolve-McpCli
    if (-not $cli) {
        Write-Error '未找到 @playwright/mcp CLI：请设置环境变量 BROWSEKIT_MCP_CLI，或确认版本目录内 mcp-host 存在'
        exit 1
    }
    $nodeExe = (Get-Command node.exe -ErrorAction Stop).Source
    $hosts = 'host.docker.internal,host.docker.internal:' + $McpPort + ',127.0.0.1,127.0.0.1:' + $McpPort + ',localhost,localhost:' + $McpPort
    foreach ($f in @($LogFile, $ErrFile)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    $proc = Start-Process -FilePath $nodeExe `
        -ArgumentList @(('"' + $cli + '"'), '--cdp-endpoint', ('http://127.0.0.1:' + $CdpPort), '--port', [string]$McpPort, '--host', '127.0.0.1', '--allowed-hosts', $hosts) `
        -WorkingDirectory (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $cli))) `
        -WindowStyle Hidden -RedirectStandardOutput $LogFile -RedirectStandardError $ErrFile -PassThru
    [System.IO.File]::WriteAllText($PidFile, [string]$proc.Id, (New-Object System.Text.UTF8Encoding($false)))

    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and -not (Test-TcpPort -Port $McpPort)) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-TcpPort -Port $McpPort)) { Write-Error ('MCP 未就绪，见 ' + $ErrFile); exit 1 }
}

# ---------------------------------------------------------------- 3) 容器
Write-Host '[3/3] 启动生产容器 ...' -ForegroundColor Cyan

# 工具镜像按版本号打标：首次使用自动构建，之后秒启
$VerTag = (Split-Path -Leaf $VersionDir).ToLower()
$ToolImage = 'browsekit-tools:' + $VerTag
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker image inspect $ToolImage *> $null
    $imageExists = ($LASTEXITCODE -eq 0)
} finally {
    $ErrorActionPreference = $prevEap
}

if ($imageExists) {
    Write-Host ('    镜像 ' + $ToolImage + ' 已存在，跳过构建（秒启）') -ForegroundColor Yellow
} else {
    Write-Host ('    首次使用：镜像 ' + $ToolImage + ' 不存在，开始构建（仅首次，约 1-3 分钟）') -ForegroundColor Yellow
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location (Split-Path -Parent $ComposeFile)
        & docker compose --env-file $EnvFile -f $ComposeFile build browsekit-tools 2>&1 | ForEach-Object { Write-Host ('    ' + $_) }
        $buildCode = $LASTEXITCODE
        Pop-Location
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($buildCode -ne 0) { Write-Error ('镜像构建失败：' + $ToolImage); exit 1 }
    Write-Host ('    镜像构建完成：' + $ToolImage) -ForegroundColor Green
}

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    Push-Location (Split-Path -Parent $ComposeFile)
    & docker compose --env-file $EnvFile -f $ComposeFile up -d 2>&1 | ForEach-Object { Write-Host ('    ' + $_) }
    $code = $LASTEXITCODE
    Pop-Location
} finally {
    $ErrorActionPreference = $prevEap
}
if ($code -ne 0) { Write-Error 'docker compose up 失败'; exit 1 }

Write-Host ''
Write-Host '等待 Open WebUI 就绪 ...' -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$ok = $false
while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $WebUiPort + '/api/version') -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ([int]$r.StatusCode -eq 200) { $ok = $true; break }
    } catch { }
    Start-Sleep -Seconds 4
}

if (-not $ok) { Write-Warning 'Open WebUI 尚未就绪，请稍后自查：docker logs browsekit-webui' }

Write-Host ''
Write-Host '================ 启动结果 ================' -ForegroundColor Green
Write-Host ('  Chrome CDP 8933 : ' + $(if (Test-TcpPort -Port $CdpPort) { 'UP' } else { 'DOWN' }))
Write-Host ('  MCP       8931 : ' + $(if (Test-TcpPort -Port $McpPort) { 'UP' } else { 'DOWN' }))
Write-Host ('  WebUI     3000 : ' + $(if ($ok) { 'HTTP 200' } else { '未就绪' }))
Write-Host ('  MCPO      8932 : ' + $(if (Test-TcpPort -Port 8932) { 'UP' } else { 'DOWN' }))
Write-Host ''
Write-Host '访问地址：http://browsekit.familyos.test:7580' -ForegroundColor Yellow
Write-Host '本地直连：http://127.0.0.1:3000' -ForegroundColor Yellow
