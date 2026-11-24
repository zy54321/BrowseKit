#Requires -Version 5.1
<#
.SYNOPSIS
    在后台启动本地 @playwright/mcp，通过 CDP 接管专用 Chrome，并监听 8931 供本机与 Docker 访问。

.DESCRIPTION
    - 严格 Windows PowerShell 5.1 语法。
    - 端口存活一律使用 System.Net.Sockets.TcpClient 探测。
    - 参数依据 @playwright/mcp 0.0.86 的 --help 实测：
        --cdp-endpoint <endpoint>   连接已在运行的浏览器
        --port <port>               监听端口（该版本以 SSE 传输暴露）
        --host <host>               绑定地址，默认 localhost；0.0.0.0 为全部网卡
                                    Phase 2 实测：绑 127.0.0.1 时 Docker 容器经
                                    host.docker.internal 仍可访问（Docker Desktop
                                    网关代理到宿主回环），故默认收紧为 127.0.0.1
        --allowed-hosts <hosts...>  逗号分隔的允许主机名；默认仅 localhost/回环/--host 值，
                                    因此 Docker 侧必须显式加入 host.docker.internal
    - 进程 PID 写入 .run\playwright-mcp.pid，标准输出/错误分别写入 .run\playwright-mcp.log 与 .run\playwright-mcp.err.log。

.PARAMETER CdpPort
    专用 Chrome 的调试端口，默认 8933。

.PARAMETER McpPort
    MCP 服务监听端口，默认 8931。

.PARAMETER WaitSeconds
    等待端口开放的最长秒数，默认 20。

.EXAMPLE
    .\Start-PlaywrightMcp.ps1
#>
[CmdletBinding()]
param(
    [int]$CdpPort     = 8933,
    [int]$McpPort     = 8931,
    [int]$WaitSeconds = 20,
    [string]$BindHost = '127.0.0.1',
    [string]$RunDir
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 路径常量
$Root      = Split-Path -Parent $PSScriptRoot
if (-not $RunDir) { $RunDir = Join-Path $Root '.run' }
$PidFile   = Join-Path $RunDir 'playwright-mcp.pid'
$LogFile   = Join-Path $RunDir 'playwright-mcp.log'
$ErrFile   = Join-Path $RunDir 'playwright-mcp.err.log'
$CliPath   = Join-Path $Root 'mcp-host\node_modules\@playwright\mcp\cli.js'
$CdpUrl    = 'http://127.0.0.1:' + $CdpPort

# 实测结论（@playwright/mcp 0.0.86）：--allowed-hosts 比对的是完整 Host 头，
# 因此必须同时给出"带端口"和"不带端口"两种形式；只写裸主机名会被 403 拒绝。
$AllowedHosts = @(
    'host.docker.internal', ('host.docker.internal:' + $McpPort),
    '127.0.0.1',            ('127.0.0.1:' + $McpPort),
    'localhost',            ('localhost:' + $McpPort)
) -join ','

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

function Get-HttpProbe {
    param(
        [string]$TargetHost = '127.0.0.1',
        [int]$Port,
        [string]$Path = '/',
        [int]$TimeoutMs = 2500
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(1500, $false)) { return 'CONNECT-TIMEOUT' }
        $client.EndConnect($async)
        $client.ReceiveTimeout = $TimeoutMs
        $stream = $client.GetStream()
        $req = 'GET ' + $Path + ' HTTP/1.1' + "`r`n" +
               'Host: 127.0.0.1:' + $Port + "`r`n" +
               'Accept: text/event-stream, application/json, */*' + "`r`n" +
               'Connection: close' + "`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $buf = New-Object byte[] 512
        $read = $stream.Read($buf, 0, $buf.Length)
        if ($read -le 0) { return 'NO-RESPONSE' }
        $txt = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
        $statusLine = ($txt -split "`r`n")[0]
        $ctype = ''
        $m = [regex]::Match($txt, '(?im)^Content-Type:\s*(.+)$')
        if ($m.Success) { $ctype = $m.Groups[1].Value.Trim() }
        if ($ctype) { return ($statusLine + ' | Content-Type: ' + $ctype) }
        return $statusLine
    } catch {
        return ('ERROR: ' + $_.Exception.Message)
    } finally {
        try { $client.Close() } catch { }
    }
}

function Invoke-McpInitialize {
    param(
        [string]$TargetHost = '127.0.0.1',
        [int]$Port,
        [int]$TimeoutMs = 4000
    )
    $body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"browsekit-smoke","version":"1.0"}}}'
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(1500, $false)) { return 'CONNECT-TIMEOUT' }
        $client.EndConnect($async)
        $client.ReceiveTimeout = $TimeoutMs
        $stream = $client.GetStream()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $head = 'POST /mcp HTTP/1.1' + "`r`n" +
                'Host: 127.0.0.1:' + $Port + "`r`n" +
                'Content-Type: application/json' + "`r`n" +
                'Accept: application/json, text/event-stream' + "`r`n" +
                'Content-Length: ' + $bytes.Length + "`r`n" +
                'Connection: close' + "`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $buf = New-Object byte[] 2048
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return 'NO-RESPONSE' }
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        $status = ($text -split "`r`n")[0]
        $snippet = ''
        $m = [regex]::Match($text, '"serverInfo":\{[^}]*\}')
        if ($m.Success) { $snippet = $m.Value }
        if ($snippet) { return ($status + ' | ' + $snippet) }
        return $status
    } catch {
        return ('ERROR: ' + $_.Exception.Message)
    } finally {
        try { $client.Close() } catch { }
    }
}

# ---------------------------------------------------------------- 前置检查
Write-Host '=== BrowseKit / Start-PlaywrightMcp ===' -ForegroundColor Green

if (-not (Test-Path -LiteralPath $CliPath)) {
    throw ('未找到 @playwright/mcp CLI：' + $CliPath + '；请先在 mcp-host 执行 npm install @playwright/mcp')
}
if (-not (Test-Path -LiteralPath $RunDir)) {
    New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
}

Write-Host ('CLI           : ' + $CliPath)
Write-Host ('CDP 端点      : ' + $CdpUrl)
Write-Host ('MCP 监听      : ' + $BindHost + ':' + $McpPort)

# Chrome 调试端口必须先就绪
if (-not (Test-TcpPort -Port $CdpPort)) {
    Write-Host ''
    Write-Error ('CDP 端口 ' + $CdpPort + ' 未开放：请先运行 .\Start-AIChrome.ps1')
    exit 1
}
Write-Host ('CDP 端口 ' + $CdpPort + ' 已开放')

# 已在运行则直接回报
if (Test-TcpPort -Port $McpPort) {
    Write-Host ''
    Write-Host ('端口 ' + $McpPort + ' 已开放：Playwright MCP 看起来已在运行，跳过启动。') -ForegroundColor Yellow
    if (Test-Path -LiteralPath $PidFile) {
        $ep = (Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8).Trim()
        $pr = Get-Process -Id ([int]$ep) -ErrorAction SilentlyContinue
        if ($pr) { Write-Host ('记录中的 PID : ' + $ep + ' (' + $pr.ProcessName + ')') }
    }
    Write-Host ('SSE  : http://127.0.0.1:' + $McpPort + '/sse')
    Write-Host ('MCP  : http://127.0.0.1:' + $McpPort + '/mcp')
    Write-Host ('Docker 侧 : http://host.docker.internal:' + $McpPort + '/sse')
    return
}

# ---------------------------------------------------------------- 启动
$nodeExe = (Get-Command node.exe -ErrorAction Stop).Source
Write-Host ('node          : ' + $nodeExe + ' (' + (& node.exe -v) + ')')

$argList = @(
    ('"' + $CliPath + '"'),
    '--cdp-endpoint', $CdpUrl,
    '--port', [string]$McpPort,
    '--host', $BindHost,
    '--allowed-hosts', $AllowedHosts
)

Write-Host ''
Write-Host '--- 启动命令 ---' -ForegroundColor Cyan
Write-Host ('node ' + ($argList -join ' '))

# 清理陈旧日志，保证本次日志可判定
foreach ($f in @($LogFile, $ErrFile)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}

$proc = Start-Process -FilePath $nodeExe `
                      -ArgumentList $argList `
                      -WorkingDirectory (Join-Path $Root 'mcp-host') `
                      -WindowStyle Hidden `
                      -RedirectStandardOutput $LogFile `
                      -RedirectStandardError $ErrFile `
                      -PassThru

[System.IO.File]::WriteAllText($PidFile, [string]$proc.Id, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('已启动，PID = ' + $proc.Id + '（已写入 ' + (Split-Path -Leaf $PidFile) + '）')

# ---------------------------------------------------------------- 等待端口
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$ready = $false
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { break }
    if (Test-TcpPort -Port $McpPort -TimeoutMs 400) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
}

if ($proc.HasExited) {
    Write-Host ''
    Write-Error ('进程已退出，退出码 = ' + $proc.ExitCode + '。请查看日志：' + $ErrFile)
    if (Test-Path -LiteralPath $ErrFile) { Get-Content -LiteralPath $ErrFile -Tail 40 }
    if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail 40 }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    exit 1
}

if (-not $ready) {
    Write-Host ''
    Write-Error ('等待 ' + $WaitSeconds + ' 秒后端口 ' + $McpPort + ' 仍未开放。日志：' + $ErrFile)
    exit 1
}

Write-Host ('端口 ' + $McpPort + ' 已开放') -ForegroundColor Green

# ---------------------------------------------------------------- 端点探测
Write-Host ''
Write-Host '--- 端点探测（原始 HTTP 状态行）---' -ForegroundColor Cyan
$rootProbe = Get-HttpProbe -Port $McpPort -Path '/'
$mcpProbe  = Get-HttpProbe -Port $McpPort -Path '/mcp'
$sseProbe  = Get-HttpProbe -Port $McpPort -Path '/sse'
$initProbe = Invoke-McpInitialize -Port $McpPort
Write-Host ('GET /     -> ' + $rootProbe)
Write-Host ('GET /mcp  -> ' + $mcpProbe)
Write-Host ('GET /sse  -> ' + $sseProbe)
Write-Host ('POST /mcp initialize -> ' + $initProbe)

$sseOk  = ($sseProbe -match '^HTTP/1\.[01] 200') -and ($sseProbe -match '(?i)text/event-stream')
$mcpOk  = ($initProbe -match '^HTTP/1\.[01] 200')
$denied = ($sseProbe -match '^HTTP/1\.[01] 403') -or ($mcpProbe -match '^HTTP/1\.[01] 403')

Write-Host ''
Write-Host '--- 日志尾部 ---' -ForegroundColor Cyan
if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail 15 }
if (Test-Path -LiteralPath $ErrFile) {
    $errTail = Get-Content -LiteralPath $ErrFile -Tail 15
    if ($errTail) { Write-Host '[stderr]' -ForegroundColor DarkYellow; $errTail }
}

Write-Host ''
Write-Host '=== MCP 端点 ===' -ForegroundColor Green
if ($sseOk) {
    Write-Host ('本机 SSE : http://127.0.0.1:' + $McpPort + '/sse')
    Write-Host ('Docker   : http://host.docker.internal:' + $McpPort + '/sse')
}
if ($mcpOk) {
    Write-Host ('本机 MCP : http://127.0.0.1:' + $McpPort + '/mcp')
    Write-Host ('Docker   : http://host.docker.internal:' + $McpPort + '/mcp')
}
if (-not $sseOk -and -not $mcpOk) {
    if ($denied) {
        Write-Warning '端点返回 403：Host 头未通过 --allowed-hosts 校验，请检查白名单是否包含"主机:端口"形式。'
    } else {
        Write-Warning '未能判定标准端点，请以日志中的实际监听信息为准。'
    }
}

Write-Host ''
Write-Host ('停止方式 : .\Stop-BrowseKitHost.ps1')
Write-Host ('日志     : ' + $LogFile)
