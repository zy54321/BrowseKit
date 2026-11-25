function Normalize-SemVer([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $trimmed = $Value.Trim().TrimStart('v', 'V')
    if ($trimmed -notmatch '^(\d+)\.(\d+)\.(\d+)$') { return $null }
    return [version]$trimmed
}

function Write-DirectoryVersions([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $parsed = Normalize-SemVer $dir.Name
        if ($null -ne $parsed) { Write-Output $parsed }
    }
}

function Write-FileVersion([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    $parsed = Normalize-SemVer ([IO.File]::ReadAllText($Path).Trim())
    if ($null -ne $parsed) { Write-Output $parsed }
}

function Write-LocalTagVersions([string]$RepoRoot) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = @(& git -C $RepoRoot tag --list 2>$null)
    $ErrorActionPreference = $prev
    foreach ($line in $lines) {
        $parsed = Normalize-SemVer ([string]$line)
        if ($null -ne $parsed) { Write-Output $parsed }
    }
}

function Format-ReleaseVersion([version]$Version) {
    return 'v' + $Version.ToString()
}

function Resolve-NextReleaseVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [string]$ReleaseRoot = 'E:\01_Work\03_Release\01_Personal\018-BrowseKit',
        [string]$ProdRoot = 'E:\01_Work\04_Prod\01_Personal\018-BrowseKit'
    )

    $groups = @(
        @{ Name = '本地 Release 目录'; Items = @(Write-DirectoryVersions $ReleaseRoot) },
        @{ Name = '正式 Prod'; Items = @(Write-DirectoryVersions $ProdRoot) + @(Write-FileVersion (Join-Path $ProdRoot 'current.txt')) },
        @{ Name = '仓库 VERSION'; Items = @(Write-FileVersion (Join-Path $RepoRoot 'VERSION')) },
        @{ Name = '本地 Git Tag'; Items = @(Write-LocalTagVersions $RepoRoot) }
    )

    $latest = $null
    $sourceNames = New-Object System.Collections.Generic.List[string]
    foreach ($group in $groups) {
        $found = $false
        foreach ($parsed in @($group.Items)) {
            if ($parsed -isnot [version]) { continue }
            $found = $true
            if ($null -eq $latest -or $parsed -gt $latest) { $latest = $parsed }
        }
        if ($found) { [void]$sourceNames.Add([string]$group.Name) }
    }

    if ($null -eq $latest) {
        $latest = [version]'0.0.0'
        [void]$sourceNames.Add('无历史版本')
    }

    $next = [version]::new($latest.Major, $latest.Minor, $latest.Build + 1)
    return [pscustomobject]@{
        LatestVersion = (Format-ReleaseVersion $latest)
        NextVersion = (Format-ReleaseVersion $next)
        VersionSource = ($sourceNames -join ' / ')
    }
}

function Test-ReleaseVersionAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [string]$ReleaseRoot = 'E:\01_Work\03_Release\01_Personal\018-BrowseKit',
        [string]$ProdRoot = 'E:\01_Work\04_Prod\01_Personal\018-BrowseKit'
    )

    $normalized = Normalize-SemVer $Version
    if ($null -eq $normalized) { throw "版本号无效：$Version" }
    $label = Format-ReleaseVersion $normalized
    $target = Join-Path $ReleaseRoot $label
    if (Test-Path -LiteralPath $target) {
        throw "Release 目录已存在，不会覆盖：$target"
    }
    $prodTarget = Join-Path $ProdRoot $label
    if (Test-Path -LiteralPath $prodTarget) {
        throw "Prod 里已经有 $label 目录，不会覆盖。请使用更高版本号。"
    }
}