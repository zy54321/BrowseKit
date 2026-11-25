# Official self-contained release package.
# Output: E:\01_Work\03_Release\01_Personal\018-BrowseKit\vX.Y.Z
# Does not write Prod and does not copy login data or secrets.

param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$OutputRoot = 'E:\01_Work\03_Release\01_Personal\018-BrowseKit'

function Fail([string]$Message) {
    Write-Host "[package-release] FAIL: $Message"
    exit 1
}

if ($Version -notmatch '^v\d+\.\d+\.\d+$') { Fail "Version must be vX.Y.Z. Current: $Version" }

$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$head = @(& git -C $RepoRoot rev-parse HEAD 2>$null)
$gitCode = $LASTEXITCODE
$dirty = @(& git -C $RepoRoot status --porcelain)
$dirtyCode = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($gitCode -ne 0 -or $head.Count -eq 0) { Fail 'OFFICIAL_RELEASE_BLOCKED_NO_GIT_HEAD. No package directory was created.' }
$gitRevision = ([string]$head[0]).Trim()
if ($gitRevision -notmatch '^[0-9a-f]{40}$') { Fail "OFFICIAL_RELEASE_BLOCKED_INVALID_GIT_HEAD: $gitRevision" }
if ($dirtyCode -ne 0 -or $dirty.Count -gt 0) { Fail 'OFFICIAL_RELEASE_BLOCKED_DIRTY_TREE. No package directory was created.' }

$releaseRoot = Join-Path $OutputRoot $Version
if (Test-Path -LiteralPath $releaseRoot) { Fail "Release directory already exists and will not be overwritten: $releaseRoot" }

$required = @(
    'docker\docker-compose.prod.yml',
    'docker\mcpo-config.json',
    'docker\tools\Dockerfile',
    'docker\tools\server.py',
    'docker\.env.example',
    'scripts\prod\Start-BrowseKit.ps1',
    'scripts\prod\Stop-BrowseKit.ps1',
    'scripts\prod\BrowseKit-Tray.ps1',
    'scripts\prod\tools\BrowseKit.Desktop.ps1',
    'scripts\prod\tools\BrowseKit.Shell.cs',
    'scripts\prod\tools\BrowseKit.Shell.dll',
    'scripts\release\runtime\03_发布Prod.bat',
    'scripts\release\runtime\publish-prod.ps1',
    'scripts\release\runtime\confirm-yn.ps1',
    'mcp-host\package.json',
    'mcp-host\package-lock.json'
)
foreach ($rel in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $rel))) { Fail "Missing required file: $rel" }
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ('browsekit-release-stage-' + [Guid]::NewGuid().ToString('N'))
$parentExisted = Test-Path -LiteralPath $OutputRoot
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'docker\tools') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'scripts\tools') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'mcp-host') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'workspace-templates') | Out-Null

    $compose = [IO.File]::ReadAllText((Join-Path $RepoRoot 'docker\docker-compose.prod.yml'), [Text.Encoding]::UTF8)
    if ($compose -notmatch '__BROWSEKIT_VERSION__') { throw 'docker-compose.prod.yml is missing the version placeholder' }
    $compose = $compose.Replace('__BROWSEKIT_VERSION__', $Version.ToLower())
    $mounted = $false
    foreach ($line in ($compose -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#')) { continue }
        if ($trimmed -match 'chrome-profile') { $mounted = $true }
    }
    if ($mounted) { throw 'prod compose mounts chrome-profile' }
    [IO.File]::WriteAllText((Join-Path $stage 'docker\docker-compose.yml'), $compose, (New-Object Text.UTF8Encoding $false))
    Copy-Item (Join-Path $RepoRoot 'docker\mcpo-config.json') (Join-Path $stage 'docker\mcpo-config.json')
    Copy-Item (Join-Path $RepoRoot 'docker\tools\Dockerfile') (Join-Path $stage 'docker\tools\Dockerfile')
    Copy-Item (Join-Path $RepoRoot 'docker\tools\server.py') (Join-Path $stage 'docker\tools\server.py')
    Copy-Item (Join-Path $RepoRoot 'docker\.env.example') (Join-Path $stage 'docker\.env.example')

    Copy-Item (Join-Path $RepoRoot 'scripts\prod\Start-BrowseKit.ps1') (Join-Path $stage 'scripts\Start-BrowseKit.ps1')
    Copy-Item (Join-Path $RepoRoot 'scripts\prod\Stop-BrowseKit.ps1') (Join-Path $stage 'scripts\Stop-BrowseKit.ps1')
    Copy-Item (Join-Path $RepoRoot 'scripts\prod\BrowseKit-Tray.ps1') (Join-Path $stage 'scripts\BrowseKit-Tray.ps1')
    foreach ($tool in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts\prod\tools') -File -Force | Where-Object { $_.Name -notlike '_*' })) {
        Copy-Item -LiteralPath $tool.FullName -Destination (Join-Path $stage ('scripts\tools\' + $tool.Name))
    }
    Copy-Item (Join-Path $RepoRoot 'scripts\release\runtime\03_发布Prod.bat') (Join-Path $stage 'scripts\03_发布Prod.bat')
    Copy-Item (Join-Path $RepoRoot 'scripts\release\runtime\publish-prod.ps1') (Join-Path $stage 'scripts\publish-prod.ps1')
    Copy-Item (Join-Path $RepoRoot 'scripts\release\runtime\confirm-yn.ps1') (Join-Path $stage 'scripts\confirm-yn.ps1')

    $templateRoot = Join-Path $RepoRoot 'templates'
    if (-not (Test-Path -LiteralPath $templateRoot)) { throw 'tracked templates directory is missing' }
    foreach ($file in @(Get-ChildItem -LiteralPath $templateRoot -File -Force)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $stage ('workspace-templates\' + $file.Name))
    }
    if (Test-Path -LiteralPath (Join-Path $RepoRoot '018_browsekit.md')) {
        $doc = [IO.File]::ReadAllText((Join-Path $RepoRoot '018_browsekit.md'), [Text.Encoding]::UTF8)
        $doc = [regex]::Replace($doc, '当前版本：v\d+\.\d+\.\d+', ('当前版本：' + $Version))
        [IO.File]::WriteAllText((Join-Path $stage '018_browsekit.md'), $doc, (New-Object Text.UTF8Encoding $false))
    }
    Copy-Item (Join-Path $RepoRoot 'mcp-host\package.json') (Join-Path $stage 'mcp-host\package.json')
    Copy-Item (Join-Path $RepoRoot 'mcp-host\package-lock.json') (Join-Path $stage 'mcp-host\package-lock.json')
    $modules = Join-Path $RepoRoot 'mcp-host\node_modules'
    if (-not (Test-Path -LiteralPath $modules)) { throw 'mcp-host node_modules is missing' }
    & robocopy $modules (Join-Path $stage 'mcp-host\node_modules') /E /NFL /NDL /NJH /NJS /NC /NS /NP /XD .playwright-mcp | Out-Null
    if ($LASTEXITCODE -ge 8) { throw 'robocopy node_modules failed' }

    [IO.File]::WriteAllText((Join-Path $stage 'VERSION'), ($Version + "`r`n"), (New-Object Text.UTF8Encoding $false))
    $builtAt = [DateTime]::UtcNow.ToString('o')
    $manifest = [ordered]@{
        product = '018-BrowseKit'
        version = $Version
        gitRevision = $gitRevision
        releaseStatus = 'official'
        builtAt = $builtAt
        prodData = 'E:\01_Work\04_Prod\01_Personal\018-BrowseKit\data'
        excludes = @('chrome-profile', 'workspace', '.run', '.env')
    }
    [IO.File]::WriteAllText(
        (Join-Path $stage 'RELEASE-MANIFEST.json'),
        (($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding $false)
    )

    $forbidden = @(Get-ChildItem -LiteralPath $stage -File -Recurse -Force | Where-Object {
        $rel = $_.FullName.Substring($stage.Length).TrimStart('\')
        if ($rel -match '(?i)^mcp-host\\node_modules\\') { return $false }
        $_.Name -eq '.env' -or
        ($_.Name -like '.env.*' -and $_.Name -ne '.env.example') -or
        $rel -match '(?i)^(chrome-profile|workspace|\.run)(\\|$)' -or
        $rel -match '(?i)\\chrome-profile\\' -or
        $_.Name -like '*.log'
    })
    if ($forbidden.Count -gt 0) { throw 'Package contains a forbidden secret, profile, or runtime file' }

    if (-not $parentExisted) { New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null }
    Move-Item -LiteralPath $stage -Destination $releaseRoot
    Write-Host "[package-release] PASS $releaseRoot"
}
catch {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not $parentExisted -and (Test-Path -LiteralPath $OutputRoot)) {
        $left = @(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) { Remove-Item -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "[package-release] FAIL: $($_.Exception.Message)"
    exit 1
}
exit 0
