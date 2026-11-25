#Requires -Version 5.1
<#
.SYNOPSIS
    BrowseKit 专用 Chrome 的系统托盘与 Ctrl+Alt+B 召回/送回。

.DESCRIPTION
    只操作系统传入的 chrome-profile 对应窗口。
    左键单击托盘图标，或 Ctrl+Alt+B：不在当前桌面则召回并置顶，已在当前桌面则送回第 2 桌面。
    Windows PowerShell 5.1 + WinForms，UTF-8 with BOM。命名 Mutex 保证单实例。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileDir,
    [string]$ConsoleUrl = 'http://browsekit.familyos.test:7580/',
    [string]$StatusFile
)

$ErrorActionPreference = 'Stop'

if (-not ('BrowseKitConsoleHide' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BrowseKitConsoleHide {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@
}
$console = [BrowseKitConsoleHide]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { [BrowseKitConsoleHide]::ShowWindow($console, 0) | Out-Null }

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -ProfileDir "' + $ProfileDir + '" -ConsoleUrl "' + $ConsoleUrl + '"'
    if ($StatusFile) { $relaunch += ' -StatusFile "' + $StatusFile + '"' }
    Start-Process -FilePath $psExe -ArgumentList $relaunch -WindowStyle Hidden | Out-Null
    exit 0
}

$helper = Join-Path $PSScriptRoot 'tools\BrowseKit.Desktop.ps1'
if (-not (Test-Path -LiteralPath $helper)) { throw ('缺少辅助脚本：' + $helper) }
. $helper

$script:ProfileNorm = [System.IO.Path]::GetFullPath($ProfileDir).TrimEnd('\')
$script:ConsoleUrl = $ConsoleUrl
$script:StatusFile = $StatusFile
$script:HotkeyState = 'PENDING'
$script:ComState = 'PENDING'
$script:TipText = 'BrowseKit 浏览器'
$script:LastAction = ''
$script:LastHwnd = 0
$script:LastForeground = $false
$script:busy = $false
$script:closing = $false
$script:mutexOwned = $false

$token = Get-BrowseKitInstanceToken -ProfileDir $script:ProfileNorm
$mutexName = 'Local\BrowseKit.Tray.' + $token
$script:mutex = New-Object System.Threading.Mutex($false, $mutexName)
try {
    $script:mutexOwned = $script:mutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $script:mutexOwned = $true
}
if (-not $script:mutexOwned) {
    $script:mutex.Dispose()
    exit 0
}

$stopName = 'Local\BrowseKit.Tray.Stop.' + $token
$script:shutdownEvent = New-Object System.Threading.EventWaitHandle($false, ([System.Threading.EventResetMode]::ManualReset), $stopName)

function Write-TrayStatus {
    param([string]$Extra)
    if (-not $script:StatusFile) { return }
    $lines = @(
        ('PID=' + $PID),
        ('HOTKEY=' + $script:HotkeyState),
        ('COM=' + $script:ComState),
        ('TIP=' + $script:TipText),
        ('ACTION=' + $script:LastAction),
        ('HWND=' + $script:LastHwnd),
        ('FOREGROUND=' + $script:LastForeground),
        ('TIME=' + (Get-Date -Format 'HH:mm:ss.fff'))
    )
    if ($Extra) { $lines += $Extra }
    $dir = Split-Path -Parent $script:StatusFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllLines($script:StatusFile, $lines, (New-Object System.Text.UTF8Encoding $true))
}

function Show-BrowseKitBalloon {
    param([string]$Title, [string]$Message)
    if (-not $script:ni) { return }
    $script:ni.BalloonTipTitle = $Title
    $script:ni.BalloonTipText = $Message
    $script:ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
    $script:ni.ShowBalloonTip(6000)
}

function Update-BrowseKitTrayTip {
    if ($script:closing -or -not $script:ni) { return }
    $hwnd = [int64]0
    try { $hwnd = [int64](Get-BrowseKitChromeMainWindow -ProfileDir $script:ProfileNorm) } catch { $hwnd = [int64]0 }
    $script:LastHwnd = $hwnd
    if ($hwnd -eq 0) {
        $script:TipText = 'BrowseKit 浏览器：未找到专用窗口'
    } else {
        try {
            $on = [BrowseKit.Shell.VirtualDesktopHost]::IsWindowOnCurrentDesktop($hwnd)
            $script:ComState = 'OK'
            if ($on) {
                $script:TipText = 'BrowseKit 浏览器：已在当前桌面（点击或 Ctrl+Alt+B 送回）'
            } else {
                $idx = [int][BrowseKit.Shell.VirtualDesktopHost]::GetWindowDesktopIndex($hwnd)
                $n = $idx + 1
                if ($n -lt 1) { $n = 2 }
                $script:TipText = 'BrowseKit 浏览器：后台第 ' + $n + ' 桌面（点击或 Ctrl+Alt+B 召回）'
            }
        } catch {
            $script:ComState = 'FAIL'
            $script:TipText = 'BrowseKit：虚拟桌面不可用，请用 Win+Ctrl+→'
        }
    }
    if ($script:TipText.Length -gt 63) { $script:TipText = $script:TipText.Substring(0, 63) }
    $script:ni.Text = $script:TipText
}

function Invoke-BrowseKitToggle {
    if ($script:busy -or $script:closing) { return }
    $script:busy = $true
    try {
        $hwnd = [int64](Get-BrowseKitChromeMainWindow -ProfileDir $script:ProfileNorm -DebugPort 8933)
        $script:LastHwnd = $hwnd
        if ($hwnd -eq 0) {
            Show-BrowseKitBalloon -Title 'BrowseKit' -Message '未找到专用 Chrome 窗口。请先启动 BrowseKit。日常办公 Chrome 不会被操作。'
            Update-BrowseKitTrayTip
            return
        }
        $ownerPid = [uint32]0
        [void][BrowseKitConsoleHide]::GetWindowThreadProcessId(([IntPtr]$hwnd), [ref]$ownerPid)
        $allowed = @(Get-BrowseKitChromeProcessIds -ProfileDir $script:ProfileNorm -DebugPort 8933)
        if ($allowed -notcontains [int]$ownerPid) {
            Show-BrowseKitBalloon -Title 'BrowseKit' -Message '窗口不属于专用 Chrome，已放弃操作。日常浏览器不会被切换或关闭。'
            return
        }
        $on = $false
        try {
            $on = [BrowseKit.Shell.VirtualDesktopHost]::IsWindowOnCurrentDesktop($hwnd)
            $script:ComState = 'OK'
        } catch {
            $script:ComState = 'FAIL'
            Show-BrowseKitBalloon -Title 'BrowseKit 虚拟桌面不可用' -Message (([string]$_.Exception.Message) + ' 请用 Win+Ctrl+→ 手动切换。托盘单击仍可重试。')
            Update-BrowseKitTrayTip
            return
        }
        if (-not $on) {
            $current = [int][BrowseKit.Shell.VirtualDesktopHost]::GetCurrentIndex()
            [BrowseKit.Shell.VirtualDesktopHost]::MoveWindowToDesktop($hwnd, $current)
            $script:LastForeground = [BrowseKit.Shell.WindowActivator]::RestoreAndForeground($hwnd)
            $script:LastAction = 'recall'
        } else {
            [void][BrowseKit.Shell.VirtualDesktopHost]::EnsureDesktopCount(2)
            [BrowseKit.Shell.VirtualDesktopHost]::MoveWindowToDesktop($hwnd, 1)
            $script:LastForeground = $false
            $script:LastAction = 'send'
        }
        Update-BrowseKitTrayTip
    } catch {
        $script:ComState = 'FAIL'
        Show-BrowseKitBalloon -Title 'BrowseKit 切换失败' -Message (([string]$_.Exception.Message) + ' 可改用 Win+Ctrl+→ 手动切换。托盘单击仍可重试。')
    } finally {
        $script:busy = $false
        try { Write-TrayStatus } catch { }
    }
}

function Test-BrowseKitTrayTick {
    if ($script:closing) { return }
    try {
        if ($script:shutdownEvent.WaitOne(0)) { Close-BrowseKitTray; return }
    } catch { }
    $script:tick++
    if (($script:tick % 5) -eq 0 -and -not $script:busy) {
        try { Update-BrowseKitTrayTip } catch { }
    }
}

function Close-BrowseKitTray {
    if ($script:closing) { return }
    $script:closing = $true
    try { if ($script:timer) { $script:timer.Stop(); $script:timer.Dispose() } } catch { }
    try {
        if ($script:form -and $script:form.IsHandleCreated) {
            [BrowseKit.Shell.HotkeyNative]::Unregister($script:form.Handle)
        }
    } catch { }
    try {
        if ($script:ni) {
            $script:ni.Visible = $false
            $script:ni.Dispose()
            $script:ni = $null
        }
    } catch { }
    try { if ($script:trayIcon) { $script:trayIcon.Dispose() } } catch { }
    try { Write-TrayStatus 'EXIT=GRACEFUL' } catch { }
    try { if ($script:mutexOwned -and $script:mutex) { $script:mutex.ReleaseMutex() } } catch { }
    try { if ($script:mutex) { $script:mutex.Dispose() } } catch { }
    try { if ($script:form) { $script:form.Dispose() } } catch { }
    try { [System.Windows.Forms.Application]::Exit() } catch { }
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $eventArgs)
        try {
            Show-BrowseKitBalloon -Title 'BrowseKit' -Message ([string]$eventArgs.Exception.Message)
        } catch { }
    })
    Import-BrowseKitShell

    $script:trayIcon = [BrowseKit.Shell.TrayIconFactory]::Create()
    $script:ni = New-Object System.Windows.Forms.NotifyIcon
    $script:ni.Icon = $script:trayIcon
    $script:ni.Visible = $true
    $script:ni.Text = 'BrowseKit 浏览器'

    # WinForms 回调不一定能看见脚本函数，入口固定挂到本进程全局。
    $global:BkTrayToggle = ${function:Invoke-BrowseKitToggle}
    $global:BkTrayExit = ${function:Close-BrowseKitTray}
    $global:BkConsoleUrl = $script:ConsoleUrl

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miToggle = $menu.Items.Add('召回 / 送回专用浏览器 (Ctrl+Alt+B)')
    $miConsole = $menu.Items.Add('打开 BrowseKit 控制台')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit = $menu.Items.Add('退出托盘')
    $miToggle.add_Click({ try { & $global:BkTrayToggle } catch { } })
    $miConsole.add_Click({
        try { Start-Process -FilePath $global:BkConsoleUrl | Out-Null } catch { }
    })
    $miExit.add_Click({ try { & $global:BkTrayExit } catch { } })
    $script:ni.ContextMenuStrip = $menu
    $script:ni.add_MouseClick({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            try { & $global:BkTrayToggle } catch { }
        }
    })

    $script:form = New-Object BrowseKit.Shell.HotkeyForm
    $null = $script:form.Handle
    $script:form.add_HotkeyPressed({ try { & $global:BkTrayToggle } catch { } })
    $hotkeyError = [BrowseKit.Shell.HotkeyNative]::TryRegisterCtrlAltB($script:form.Handle)
    if ($hotkeyError) {
        $script:HotkeyState = 'FAIL'
        Show-BrowseKitBalloon -Title 'BrowseKit 热键未注册' -Message ($hotkeyError + '。请改用托盘图标单击，或用 Win+Ctrl+→ 手动切换。')
    } else {
        $script:HotkeyState = 'OK'
    }

    try {
        [void][BrowseKit.Shell.VirtualDesktopHost]::GetCount()
        $script:ComState = 'OK'
    } catch {
        $script:ComState = 'FAIL'
        Show-BrowseKitBalloon -Title 'BrowseKit 虚拟桌面不可用' -Message (([string]$_.Exception.Message) + ' 请用 Win+Ctrl+→ 手动切换。托盘单击仍可重试。')
    }
    Update-BrowseKitTrayTip

    $script:tick = 0
    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 400
    $global:BkTrayTick = ${function:Test-BrowseKitTrayTick}
    $script:timer.add_Tick({ try { & $global:BkTrayTick } catch { } })
    $script:timer.Start()
    Write-TrayStatus

    $context = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($context)
} catch {
    try { Write-TrayStatus ('FATAL=' + $_.Exception.Message) } catch { }
    try { if ($script:ni) { $script:ni.Visible = $false; $script:ni.Dispose() } } catch { }
    try { if ($script:mutexOwned -and $script:mutex) { $script:mutex.ReleaseMutex() } } catch { }
    exit 1
}
