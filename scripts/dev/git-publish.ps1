# Commit reviewed files and push the current branch with a normal git push.
# Double-click entry: 01_提交GitHub.bat. Refuses force push, pull, rebase, and empty commits.
# Does not make a Release and does not publish Prod.

param(
    [string]$RepoRoot = '',
    [string]$CommitMessage = '',
    [string]$ConfirmCommit = '',
    [string]$ConfirmPush = '',
    [string]$ConfirmPublic = '',
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'confirm-yn.ps1')

function Fail([string]$Message) {
    Write-Host "[GitHub] 失败：$Message"
    exit 1
}

function Say([string]$Message) {
    Write-Host "[GitHub] $Message"
}

function Invoke-Git([string[]]$ArgumentList) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $pieces = @('-c', 'core.quotepath=false', '-c', 'i18n.logOutputEncoding=utf-8', '-C', $RepoRoot) + $ArgumentList
    $psi.Arguments = (($pieces | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $utf8 = New-Object Text.UTF8Encoding $false
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    [void]$proc.WaitForExit()
    [void]$outTask.Wait()
    [void]$errTask.Wait()
    $text = [string]$outTask.Result
    $err = [string]$errTask.Result
    if (-not [string]::IsNullOrWhiteSpace($err)) {
        if ([string]::IsNullOrWhiteSpace($text)) { $text = $err } else { $text = $text.TrimEnd() + "`n" + $err.Trim() }
    }
    return @{ Code = $proc.ExitCode; Text = $text }
}

function Test-SensitivePath([string]$Relative) {
    $normalized = ($Relative -replace '\\', '/').TrimStart('./')
    $name = Split-Path -Leaf ($normalized -replace '/', '\')
    if ($name -eq '.env' -or $name -eq '.env.compose') { return $true }
    if ($name -like '.env.*' -and $name -notlike '*.example') { return $true }
    if ($name -match '(?i)\.(pem|p12|pfx|key|log|pid)$') { return $true }
    if ($normalized -match '(?i)(^|/)(chrome-profile|chrome-profile-|workspace|workspace-|workspace-dev|workspace-slot|\.run|\.run-)(/|$)') { return $true }
    if ($normalized -match '(?i)(^|/)node_modules(/|$)') { return $true }
    if ($normalized -match '(?i)(^|/)__pycache__(/|$)') { return $true }
    return $false
}

function Test-SensitiveBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes) { return $false }
    if ($Bytes.Length -gt 5MB) { return $true }
    $take = [Math]::Min($Bytes.Length, 65536)
    $sample = [Text.Encoding]::GetEncoding(28591).GetString($Bytes, 0, $take)
    if ($sample -match 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY') { return $true }
    if ($sample -match 'AKIA[0-9A-Z]{16}') { return $true }
    return $false
}

function Get-FullPath([string]$Relative) {
    return Join-Path $RepoRoot (($Relative -replace '/', '\').TrimStart('\'))
}

function Get-GitHubCredentialToken {
    $previousInput = [Console]::InputEncoding
    $savedPrompt = $env:GIT_TERMINAL_PROMPT
    $savedGcm = $env:GCM_INTERACTIVE
    $token = $null
    try {
        [Console]::InputEncoding = New-Object Text.UTF8Encoding $false
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        $psi.Arguments = 'credential fill'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $writer = New-Object IO.StreamWriter($proc.StandardInput.BaseStream, (New-Object Text.UTF8Encoding $false))
        $writer.NewLine = "`n"
        $writer.WriteLine('protocol=https')
        $writer.WriteLine('host=github.com')
        $writer.WriteLine('')
        $writer.Flush()
        $writer.Close()
        if (-not $proc.WaitForExit(20000)) {
            try { $proc.Kill() } catch {}
            return $null
        }
        foreach ($line in ($proc.StandardOutput.ReadToEnd() -split "`n")) {
            if ($line.StartsWith('password=')) { $token = $line.Substring(9).Trim() }
        }
    }
    catch { return $null }
    finally {
        try { [Console]::InputEncoding = $previousInput } catch {}
        if ($null -eq $savedPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $savedPrompt }
        if ($null -eq $savedGcm) { Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue } else { $env:GCM_INTERACTIVE = $savedGcm }
    }
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    return $token
}

function Get-GitHubVisibility([string]$Owner, [string]$Repo) {
    $headers = @{
        'User-Agent' = 'browsekit-git-publish'
        Accept       = 'application/vnd.github+json'
    }
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $raw = & gh api "repos/$Owner/$Repo" --jq '{private:.private,visibility:.visibility}' 2>$null
        $ghCode = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($ghCode -eq 0 -and $raw) {
            try {
                $payload = ($raw | Out-String) | ConvertFrom-Json
                if ($payload.private -eq $true) { return 'private' }
                if ([string]$payload.visibility -eq 'public') { return 'public' }
            } catch {}
        }
    }
    $token = Get-GitHubCredentialToken
    if (-not [string]::IsNullOrWhiteSpace($token)) { $headers.Authorization = "Bearer $token" }
    try {
        $response = Invoke-WebRequest -Uri ('https://api.github.com/repos/{0}/{1}' -f $Owner, $Repo) -Headers $headers -UseBasicParsing -TimeoutSec 20
        $payload = $response.Content | ConvertFrom-Json
        if ($payload.private -eq $true) { return 'private' }
        if ([string]$payload.visibility -eq 'public') { return 'public' }
    }
    catch { return 'unknown' }
    finally { $token = $null; $headers.Authorization = $null }
    return 'unknown'
}

Say '从当前开发目录检查、提交并推送。'
Say '不会强推，不会自动 pull 或 rebase。不会制作 Release，也不会发布 Prod。'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$inside = Invoke-Git @('rev-parse', '--is-inside-work-tree')
if ($inside.Code -ne 0) { Fail '这里不是可用的 Git 仓库。没有写入。' }

$branch = (Invoke-Git @('branch', '--show-current')).Text.Trim()
if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq 'HEAD') { Fail '当前处于游离 HEAD，已停止。' }
$headResult = Invoke-Git @('rev-parse', 'HEAD')
$hasHead = $headResult.Code -eq 0 -and $headResult.Text.Trim() -match '^[0-9a-f]{40}$'
$head = ''
if ($hasHead) { $head = $headResult.Text.Trim() }

Say "仓库：$RepoRoot"
Say "分支：$branch"
if ($hasHead) { Say "本地修订：$head" } else { Say '本地还没有提交。确认后会创建第一次提交。' }

$remote = Invoke-Git @('remote')
$remoteNames = @($remote.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($remoteNames -notcontains 'origin') { Fail '没有名为 origin 的 GitHub 远程仓库。已停止，没有创建提交。' }
$remoteUrl = (Invoke-Git @('remote', 'get-url', 'origin')).Text.Trim()
$displayUrl = $remoteUrl -replace '://[^/\s@]+@', '://***@'
Say "远程 origin：$displayUrl"

$visibility = 'unknown'
if ($remoteUrl -match '^[A-Za-z]:\\' -or $remoteUrl -match '^\\\\' -or $remoteUrl -match '^/' -or $remoteUrl -match '^file://') {
    $visibility = 'local'
}
elseif ($remoteUrl -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?$') {
    $visibility = Get-GitHubVisibility $Matches[1] $Matches[2]
}
$visibilityLabel = switch ($visibility) {
    'private' { '私有' }
    'public' { '公开' }
    'local' { '本地' }
    default { '无法确认' }
}
Say "仓库可见性：$visibilityLabel"
if ($visibility -eq 'unknown') { Fail '无法确认远程仓库是否公开。已停止，没有创建提交。请确认本机 Git 已登录 GitHub 后重试。' }

$remoteSha = ''
if ($hasHead) {
    Say '正在读取远程分支状态。'
    $remoteLines = Invoke-Git @('ls-remote', '--heads', 'origin', "refs/heads/$branch")
    if ($remoteLines.Code -ne 0) { Fail '无法读取 GitHub 远程状态。已停止，没有创建提交。' }
    foreach ($line in ($remoteLines.Text -split "`n")) {
        if ($line -match '^([0-9a-f]{40})\s+') { $remoteSha = $Matches[1] }
    }
    if (-not [string]::IsNullOrWhiteSpace($remoteSha)) {
        $fetch = Invoke-Git @('fetch', 'origin', $branch, '--quiet')
        if ($fetch.Code -ne 0) { Fail '无法获取远程修订。已停止，没有合并，也没有创建提交。' }
        $remoteIsAncestor = (Invoke-Git @('merge-base', '--is-ancestor', $remoteSha, 'HEAD')).Code -eq 0
        $localIsAncestor = (Invoke-Git @('merge-base', '--is-ancestor', 'HEAD', $remoteSha)).Code -eq 0
        if (-not $remoteIsAncestor -and -not $localIsAncestor) {
            Fail '本地和远程历史已经分叉。不会自动合并、pull 或 rebase。'
        }
        if ($localIsAncestor -and $remoteSha -ne $head) {
            Fail '远程分支比本地更新。不会自动 pull。请先由 Owner 处理后再运行。'
        }
        Say "远程修订：$remoteSha"
    }
    else {
        Say "远程还没有 $branch 分支。这不是分叉，推送时不会使用 --force。"
    }
}

$status = Invoke-Git @('status', '--porcelain=v1', '--untracked-files=all')
if ($status.Code -ne 0) { Fail '无法读取工作区文件清单。没有创建提交。' }
$candidates = New-Object System.Collections.Generic.List[string]
foreach ($line in ($status.Text -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) { continue }
    $path = $line.Substring(3).Trim()
    if ($path.StartsWith('"') -and $path.EndsWith('"')) { $path = $path.Substring(1, $path.Length - 2) }
    if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1].Trim() }
    $full = Get-FullPath $path
    if ((Test-Path -LiteralPath $full) -and (Get-Item -LiteralPath $full).PSIsContainer) {
        foreach ($file in @(Get-ChildItem -LiteralPath $full -Recurse -File -Force)) {
            $rel = $file.FullName.Substring($RepoRoot.Length).TrimStart('\') -replace '\\', '/'
            if (-not $candidates.Contains($rel)) { [void]$candidates.Add($rel) }
        }
    }
    elseif (-not $candidates.Contains($path)) {
        [void]$candidates.Add(($path -replace '\\', '/'))
    }
}

$ahead = 0
if ($hasHead) {
    if (-not [string]::IsNullOrWhiteSpace($remoteSha)) {
        $ahead = [int](Invoke-Git @('rev-list', '--count', "$remoteSha..HEAD")).Text.Trim()
    }
    else {
        $ahead = [int](Invoke-Git @('rev-list', '--count', 'HEAD')).Text.Trim()
    }
}
if ($candidates.Count -eq 0 -and $ahead -eq 0) {
    Say '没有需要提交或推送的内容。没有创建空提交。'
    exit 0
}

$toAdd = New-Object System.Collections.Generic.List[string]
if ($candidates.Count -gt 0) {
    Say '计划纳入提交的文件：'
    foreach ($path in $candidates) {
        $ignored = Invoke-Git @('check-ignore', '-q', '--', $path)
        if ($ignored.Code -eq 0) {
            Say " - $path （已忽略，不会添加）"
            continue
        }
        Say " - $path"
        if (Test-SensitivePath $path) { Fail "敏感文件不能提交：$path" }
        $full = Get-FullPath $path
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full
            if ($item.PSIsContainer) { Fail "仍然是目录，不能整目录添加：$path" }
            if ($item.Length -gt 5MB) { Fail "文件超过 5MB，已停止：$path" }
            $bytes = [IO.File]::ReadAllBytes($full)
            if (Test-SensitiveBytes $bytes) { Fail "文件内容含有密钥特征，已停止：$path" }
        }
        [void]$toAdd.Add($path)
    }
}
if ($toAdd.Count -eq 0 -and $ahead -eq 0) {
    Say '没有需要提交或推送的内容。没有创建空提交。'
    exit 0
}
Say "尚未推送的本地提交数：$ahead"

if ($visibility -eq 'public') {
    Say '警告：origin 是公开的 GitHub 仓库。继续推送会把当前分支的全部历史公开到互联网。'
    $publicOk = $false
    if (-not $NonInteractive) { $publicOk = Confirm-YesNo -Prompt '公开推送 (Y/N):' }
    else { $publicOk = Test-YesAnswer -Answer $ConfirmPublic -LegacyAccepted @('YES-PUBLIC-PUSH') }
    if (-not $publicOk) {
        Say '已取消。公开仓库没有得到明确确认。没有创建提交，也没有推送。'
        exit 0
    }
}

if ($toAdd.Count -gt 0) {
    if (-not $NonInteractive) {
        $CommitMessage = Read-Host '请输入提交说明'
    }
    if ([string]::IsNullOrWhiteSpace($CommitMessage)) { Fail '提交说明为空。没有创建提交。' }
    $commitOk = $false
    if (-not $NonInteractive) { $commitOk = Confirm-YesNo -Prompt '确认提交 (Y/N):' }
    else { $commitOk = Test-YesAnswer -Answer $ConfirmCommit -LegacyAccepted @('YES-COMMIT') }
    if (-not $commitOk) {
        Say '已取消。没有创建提交，也没有推送。'
        exit 0
    }
    Say '正在提交已列出的文件。'
    $add = Invoke-Git (@('add', '--') + @($toAdd.ToArray()))
    if ($add.Code -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($add.Text)) { Say $add.Text.Trim() }
        Fail 'git add 失败。没有推送。'
    }
    $staged = Invoke-Git @('diff', '--cached', '--name-only')
    $stagedNames = @($staged.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($stagedNames.Count -eq 0) { Fail '暂存区没有文件。没有创建提交。' }
    foreach ($path in $stagedNames) {
        if (Test-SensitivePath $path) { Fail "暂存区出现敏感文件，已停止提交：$path" }
        $ignored = Invoke-Git @('check-ignore', '-q', '--', $path)
        if ($ignored.Code -eq 0) { Fail "暂存区包含已被忽略的文件，已停止提交：$path" }
    }
    $commit = Invoke-Git @('commit', '-m', $CommitMessage)
    if ($commit.Code -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($commit.Text)) { Say $commit.Text.Trim() }
        Fail 'git commit 失败。没有推送。本脚本不会修改 git config。'
    }
    $head = (Invoke-Git @('rev-parse', 'HEAD')).Text.Trim()
    Say "本地提交已创建：$head"
}

if (-not $NonInteractive) {
    if (-not (Confirm-YesNo -Prompt '推送 (Y/N):')) {
        Say '本地已提交，远程未更新。'
        exit 2
    }
}
elseif (-not (Test-YesAnswer -Answer $ConfirmPush -LegacyAccepted @('YES-PUSH'))) {
    Say '本地已提交，远程未更新。'
    exit 2
}

Say "正在推送 origin $branch。不会使用 --force。"
$push = Invoke-Git @('push', 'origin', "HEAD:refs/heads/$branch")
$head = (Invoke-Git @('rev-parse', 'HEAD')).Text.Trim()
if ($push.Code -ne 0) {
    if (-not [string]::IsNullOrWhiteSpace($push.Text)) { Say $push.Text.Trim() }
    Say "本地修订：$head"
    Fail '本地已提交或本地修订仍在，远程未更新。'
}
Say "推送完成。本地修订：$head"
Say "远程分支：origin/$branch"
Say '下一步：双击 02_制作Release.bat。这一步没有发布 Prod。'
exit 0
