# 清理 fork 中「已合并 / 已关闭 PR」对应的 komac 分支（白名单版本）
#
# 与原来的 `komac cleanup --all` 相比：
#   1. 只处理 komac 自动创建的分支，格式为 <包标识>-<版本>-<UUIDv4 大写 32 位>。
#      手工分支（patch-1 等）一律跳过，不会被删除。
#   2. 每个候选分支都用 GitHub REST API 显式查询 microsoft/winget-pkgs 中
#      head = <forkOwner>:<branch> 的全部 PR：只要还存在 OPEN PR 就跳过；
#      全部为 CLOSED（含 MERGED）且至少有一条记录时才删除。
#   3. 不再依赖 komac 的 associatedPullRequests(first: 5)：同名分支被反复复用时，
#      该列表会被历史 PR 占满，正在审核的 PR 可能被挤出列表，导致分支被误删，
#      而删除 head 分支又会连带关闭仍然 OPEN 的 PR。
#
# 使用：./scripts/cleanup-merged-prs.ps1 [-DryRun] [-ReportFile <path>]
# 依赖：环境变量 WINGET_TOKEN（classic PAT，具备 repo / public_repo 权限）
# 说明：工作流开头的 sync-winget-fork.ps1 已负责同步 fork 默认分支，本脚本不再调用 komac sync。
# 通知：每成功删除一个分支，会往 notification.json 追加 cleanedBranches 记录
#       （id / version / branch），供 send-telegram-notification.ps1 渲染「已清理分支」表格；
#       DryRun 只打印判定结果，不写报告。

param(
    [string]$ForkOwner,
    [string]$UpstreamRepo = "microsoft/winget-pkgs",
    [string]$ForkRepoName = "winget-pkgs",
    [string]$BranchPattern = '^[A-Za-z0-9][A-Za-z0-9._+-]*-[0-9A-F]{32}$',
    [string]$ReportFile,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not $ReportFile) {
    $ReportFile = "$PSScriptRoot/../notification.json"
}

if (-not $env:WINGET_TOKEN) {
    Write-Host "Warning: WINGET_TOKEN not set, skipping PR cleanup" -ForegroundColor Yellow
    exit 0
}

# Windows PowerShell 5.1 可能默认未启用 TLS 1.2（PowerShell 7 不受影响）
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$headers = @{
    Authorization          = "Bearer $env:WINGET_TOKEN"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "WinGet-Tracker-cleanup"
}

function Invoke-GitHubApi {
    param(
        [string]$Uri,
        [string]$Method = "GET"
    )

    return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers
}

function Get-PagedItems {
    param([string]$Uri)

    $items = @()
    $page = 1
    $separator = if ($Uri.Contains("?")) { "&" } else { "?" }

    while ($true) {
        $pageUri = "{0}{1}per_page=100&page={2}" -f $Uri, $separator, $page
        $raw = Invoke-GitHubApi -Uri $pageUri
        if ($null -eq $raw) { break }

        # PowerShell 5.1 的 Invoke-RestMethod 可能把整个 JSON 数组作为单个对象输出，
        # 需要逐层展开，避免把一组分支当成一个分支处理。
        $pageItems = @($raw)
        while ($pageItems.Count -eq 1 -and $pageItems[0] -is [System.Array]) {
            $pageItems = @($pageItems[0])
        }
        if ($pageItems.Count -eq 0) { break }

        foreach ($item in $pageItems) { $items += $item }
        if ($pageItems.Count -lt 100) { break }
        $page++
    }

    return $items
}

function Get-BranchPullRequests {
    param([string]$Branch)

    # head 参数格式为 owner:branch，分支名做 URL 编码以兼容 + 等字符
    $head = "{0}:{1}" -f $ForkOwner, [uri]::EscapeDataString($Branch)
    $uri = "https://api.github.com/repos/$UpstreamRepo/pulls?state=all&head=$head"
    return @(Get-PagedItems -Uri $uri)
}

function Get-KomacBranchParts {
    param([string]$Branch)

    # 分支名格式 <包标识>-<版本>-<UUIDv4 大写 32 位>，包标识本身可能含连字符
    $stem = $Branch -replace '-[0-9A-F]{32}$', ''
    $id = ""
    $version = ""

    # 版本号一般以数字开头；非贪婪匹配可跳过包标识中的连字符（如 mg-chao.snow-shot）
    if ($stem -match '^(?<id>.+?)-(?<version>\d.*)$') {
        $id = $Matches['id']
        $version = $Matches['version']
    }
    elseif ($stem -match '^(?<id>.+)-(?<version>[^-]+)$') {
        # 兜底：版本号非数字开头时按最后一个连字符拆分
        $id = $Matches['id']
        $version = $Matches['version']
    }

    return [PSCustomObject]@{ id = $id; version = $version; branch = $Branch }
}

function Add-CleanedBranchesToReport {
    param(
        [string]$Path,
        [object[]]$Records
    )

    if ($Records.Count -eq 0) { return }

    try {
        $report = $null
        if (Test-Path $Path) {
            $raw = Get-Content $Path -Raw -Encoding UTF8
            $raw = $raw.TrimStart([char]0xFEFF)
            if ($raw.Trim()) { $report = $raw | ConvertFrom-Json }
        }

        if ($null -eq $report) {
            $report = [PSCustomObject]@{
                generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                updates     = @()
                checkErrors = @()
            }
        }

        # 保留报告中已有字段（updates / checkErrors / generatedAt 等），只追加 cleanedBranches
        $merged = [ordered]@{}
        foreach ($property in $report.PSObject.Properties) {
            if ($property.Name -ne 'cleanedBranches') {
                $merged[$property.Name] = $property.Value
            }
        }
        $merged['cleanedBranches'] = @($Records)

        $json = $merged | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Added $($Records.Count) cleaned branch record(s) to $Path" -ForegroundColor Cyan
    }
    catch {
        # 报告写失败不影响清理结果，只告警
        Write-Host "Warning: failed to update notification report: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

try {
    if (-not $ForkOwner) {
        $ForkOwner = (Invoke-GitHubApi -Uri "https://api.github.com/user").login
    }
    $forkRepo = "$ForkOwner/$ForkRepoName"

    Write-Host "Cleaning up merged/closed PR branches (whitelist mode)..." -ForegroundColor Cyan
    Write-Host "Fork: $forkRepo | Upstream: $UpstreamRepo" -ForegroundColor Cyan
    Write-Host "Branch pattern: $BranchPattern" -ForegroundColor Cyan
    Write-Host "Report: $ReportFile" -ForegroundColor Cyan
    if ($DryRun) { Write-Host "DRY RUN: no branch will be deleted" -ForegroundColor Yellow }

    $branches = @(Get-PagedItems -Uri "https://api.github.com/repos/$forkRepo/branches")
    $candidates = @($branches | Where-Object { $_.name -match $BranchPattern })

    Write-Host "Found $($branches.Count) branches, $($candidates.Count) match the komac naming pattern" -ForegroundColor Cyan

    foreach ($ignored in @($branches | Where-Object { $_.name -notmatch $BranchPattern })) {
        Write-Host "  [KEEP] $($ignored.name) : not a komac branch" -ForegroundColor DarkGray
    }

    $deleted = 0
    $skipped = 0
    $failed = 0
    $cleanedBranchRecords = New-Object System.Collections.Generic.List[object]

    foreach ($branch in $candidates) {
        $name = $branch.name

        try {
            $prs = @(Get-BranchPullRequests -Branch $name)
        } catch {
            Write-Host "  [KEEP] $name : failed to query PRs ($($_.Exception.Message))" -ForegroundColor Yellow
            $skipped++
            continue
        }

        if ($prs.Count -eq 0) {
            Write-Host "  [KEEP] $name : no PR found, cannot confirm merged/closed" -ForegroundColor DarkGray
            $skipped++
            continue
        }

        $openPrs = @($prs | Where-Object { $_.state -eq "open" })
        if ($openPrs.Count -gt 0) {
            $openNumbers = ($openPrs | ForEach-Object { "#$($_.number)" }) -join ", "
            Write-Host "  [KEEP] $name : OPEN PR $openNumbers" -ForegroundColor Green
            $skipped++
            continue
        }

        $closedPrs = @($prs | Where-Object { $_.state -eq "closed" })
        $mergedCount = @($closedPrs | Where-Object { $null -ne $_.merged_at }).Count
        $closedOnly = $closedPrs.Count - $mergedCount
        $summary = "$($closedPrs.Count) closed (merged: $mergedCount, closed only: $closedOnly)"

        if ($closedPrs.Count -eq 0) {
            Write-Host "  [KEEP] $name : PR states not recognised" -ForegroundColor Yellow
            $skipped++
            continue
        }

        $parts = Get-KomacBranchParts -Branch $name
        $record = [PSCustomObject]@{
            id      = $parts.id
            version = $parts.version
            branch  = $name
        }

        if ($DryRun) {
            Write-Host "  [DRY-RUN] $name : would delete ($summary)" -ForegroundColor Yellow
            $cleanedBranchRecords.Add($record)
            $deleted++
            continue
        }

        try {
            $refUri = "https://api.github.com/repos/$forkRepo/git/refs/heads/" + [uri]::EscapeDataString($name)
            Invoke-GitHubApi -Uri $refUri -Method Delete | Out-Null
            $cleanedBranchRecords.Add($record)
            Write-Host "  [DELETE] $name ($summary)" -ForegroundColor Cyan
            $deleted++
        } catch {
            Write-Host "  [KEEP] $name : delete failed ($($_.Exception.Message))" -ForegroundColor Red
            $failed++
        }
    }

    Write-Host "Cleanup finished: deleted=$deleted, kept=$skipped, failed=$failed" -ForegroundColor Green
    if ($DryRun) {
        Write-Host "(dry run: 'deleted' counts branches that would be deleted; report not written)" -ForegroundColor Yellow
        if ($cleanedBranchRecords.Count -gt 0) {
            Write-Host "DRY RUN: would add $($cleanedBranchRecords.Count) cleaned branch record(s) to $ReportFile" -ForegroundColor Yellow
        }
    }
    else {
        Add-CleanedBranchesToReport -Path $ReportFile -Records $cleanedBranchRecords.ToArray()
    }
} catch {
    Write-Host "Error during PR cleanup: $_" -ForegroundColor Red
    exit 1
}
