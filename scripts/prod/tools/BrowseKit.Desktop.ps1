#Requires -Version 5.1
<#
.SYNOPSIS
    BrowseKit 专用 Chrome 的虚拟桌面与托盘辅助函数。

.DESCRIPTION
    供 Start-BrowseKit.ps1、Stop-BrowseKit.ps1、BrowseKit-Tray.ps1 点源。
    只按传入的 chrome-profile 路径识别窗口，不操作其他 Chrome。
    Windows PowerShell 5.1；UTF-8 with BOM。
#>

function Import-BrowseKitShell {
    if ('BrowseKit.Shell.VirtualDesktopHost' -as [type]) { return }
    $dll = Join-Path $PSScriptRoot 'BrowseKit.Shell.dll'
    $cs = Join-Path $PSScriptRoot 'BrowseKit.Shell.cs'
    $useSource = -not (Test-Path -LiteralPath $dll)
    if ((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $cs)) {
        $csTime = (Get-Item -LiteralPath $cs).LastWriteTimeUtc
        $dllTime = (Get-Item -LiteralPath $dll).LastWriteTimeUtc
        if ($csTime -gt $dllTime) { $useSource = $true }
    }
    if (-not $useSource) {
        Add-Type -Path $dll
        return
    }
    if (-not (Test-Path -LiteralPath $cs)) { throw ('缺少虚拟桌面组件：' + $cs) }
    Add-Type -Path $cs -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing')
}

function Get-BrowseKitInstanceToken {
    param([Parameter(Mandatory = $true)][string]$ProfileDir)
    $norm = [System.IO.Path]::GetFullPath($ProfileDir).TrimEnd('\').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('browsekit-tray|' + $norm))
    } finally {
        $sha.Dispose()
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $hash) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString().Substring(0, 20)
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

function Get-BrowseKitChromeProcessIds {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [int]$DebugPort = 8933
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
    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($id in $roots) { $ids.Add($id) }
    $guard = 0
    $changed = $true
    while ($changed -and $guard -lt 20) {
        $guard++
        $changed = $false
        foreach ($proc in $all) {
            $id = [int]$proc.ProcessId
            if ($ids.Contains($id)) { continue }
            if (-not $ids.Contains([int]$proc.ParentProcessId)) { continue }
            $cmd = [string]$proc.CommandLine
            if ($cmd -match '(?i)\\Google\\Chrome\\User Data') { continue }
            if (-not (Test-BrowseKitProfileCommandLine -CommandLine $cmd -ProfileDir $ProfileDir)) { continue }
            $ids.Add($id)
            $changed = $true
        }
    }
    Write-Output -NoEnumerate $ids
}

function Get-BrowseKitChromeMainWindow {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [int]$DebugPort = 8933
    )
    Import-BrowseKitShell | Out-Null
    $ids = Get-BrowseKitChromeProcessIds -ProfileDir $ProfileDir -DebugPort $DebugPort
    if ($null -eq $ids -or $ids.Count -eq 0) {
        Write-Output -NoEnumerate ([int64]0)
        return
    }
    $arr = [int[]]$ids.ToArray()
    $args = New-Object object[] 1
    $args[0] = $arr
    $method = [BrowseKit.Shell.ChromeWindows].GetMethod('FindMainWindow')
    $hwnd = $method.Invoke($null, $args)
    Write-Output -NoEnumerate ([int64]$hwnd)
}

function Wait-BrowseKitChromeWindow {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [int]$DebugPort = 8933,
        [int]$TimeoutSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $hwnd = [int64](Get-BrowseKitChromeMainWindow -ProfileDir $ProfileDir -DebugPort $DebugPort)
        if ($hwnd -ne 0) { return $hwnd }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return [int64]0
}

function Move-BrowseKitChromeToSecondDesktop {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [int]$DebugPort = 8933
    )
    Import-BrowseKitShell
    $hwnd = [int64](Wait-BrowseKitChromeWindow -ProfileDir $ProfileDir -DebugPort $DebugPort -TimeoutSec 20)
    if ($hwnd -eq 0) {
        Write-Warning '未找到专用 Chrome 主窗口，跳过送入第 2 桌面。'
        return $false
    }
    $before = [BrowseKit.Shell.VirtualDesktopHost]::GetCount()
    $currentBefore = [BrowseKit.Shell.VirtualDesktopHost]::GetCurrentIndex()
    $count = [BrowseKit.Shell.VirtualDesktopHost]::EnsureDesktopCount(2)
    $currentAfter = [BrowseKit.Shell.VirtualDesktopHost]::GetCurrentIndex()
    if ($currentAfter -ne $currentBefore) {
        [BrowseKit.Shell.VirtualDesktopHost]::SwitchToIndex($currentBefore)
    }
    [BrowseKit.Shell.VirtualDesktopHost]::MoveWindowToDesktop($hwnd, 1)
    $idx = [BrowseKit.Shell.VirtualDesktopHost]::GetWindowDesktopIndex($hwnd)
    Write-Host ('    专用 Chrome 已送入虚拟桌面索引 ' + $idx + '（桌面数 ' + $count + '，原先 ' + $before + '）')
    return ($idx -eq 1)
}

function Start-BrowseKitTray {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptRoot,
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [string]$StatusFile
    )
    $tray = Join-Path $ScriptRoot 'BrowseKit-Tray.ps1'
    if (-not (Test-Path -LiteralPath $tray)) { throw ('缺少托盘脚本：' + $tray) }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argLine = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $tray + '" -ProfileDir "' + $ProfileDir + '"'
    if ($StatusFile) { $argLine += ' -StatusFile "' + $StatusFile + '"' }
    Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Write-Host '    已无黑框拉起系统托盘（重复启动会因 Mutex 自动退出）'
}

function Stop-BrowseKitTray {
    param([Parameter(Mandatory = $true)][string]$ProfileDir)
    $token = Get-BrowseKitInstanceToken -ProfileDir $ProfileDir
    $eventName = 'Local\BrowseKit.Tray.Stop.' + $token
    $signaled = $false
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting($eventName)
        $ev.Set() | Out-Null
        $ev.Dispose()
        $signaled = $true
        Write-Host '    已通知托盘退出'
    } catch {
        Write-Host '    未发现正在等待的托盘停止信号'
    }

    $norm = [System.IO.Path]::GetFullPath($ProfileDir).TrimEnd('\').ToLowerInvariant()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $cmd = [string]$_.CommandLine
        $cmd -and ($cmd.ToLowerInvariant().Contains('browsekit-tray.ps1')) -and ($cmd.ToLowerInvariant().Contains($norm))
    })
    foreach ($proc in $procs) {
        $targetId = [int]$proc.ProcessId
        $deadline = (Get-Date).AddSeconds(6)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Id $targetId -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 200
        }
        if (Get-Process -Id $targetId -ErrorAction SilentlyContinue) {
            Stop-Process -Id $targetId -Force -ErrorAction SilentlyContinue
            Write-Host ('    已强制结束托盘 PID ' + $targetId)
        } else {
            Write-Host ('    托盘 PID ' + $targetId + ' 已退出')
        }
    }
    if ($procs.Count -eq 0 -and -not $signaled) {
        Write-Host '    没有正在运行的 BrowseKit 托盘'
    }
}
