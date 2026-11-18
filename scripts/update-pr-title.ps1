# 当「提交到 winget 的版本号」与「真实版本号」不一致时，在 PR 标题末尾补上真实版本号。
# 例如：New version: Readdle.Spark version 3.32.4 (3.32.4.141552)
# 与 packages/*.yaml 的 current_package.submit_version / current_package.version 两个字段对应。

function Update-SubmittedPRTitle {
    param(
        [string]$PrUrl,
        [object]$PrInfo,
        [string]$Id,
        [string]$SubmitVersion,
        [string]$RealVersion
    )

    # 两个版本号相同时，komac 生成的标题本身已经包含正确版本号，无需修改。
    # 比较前统一 Trim：历史上 MSI 内置版本带过前导空格（" 1.2.3"），
    # 若不规范化，" 1.2.3" 与 "1.2.3" 字符串判等失败会误触发标题补充。
    $SubmitVersion = ([string]$SubmitVersion).Trim()
    $RealVersion = ([string]$RealVersion).Trim()
    if ($SubmitVersion -eq $RealVersion) {
        Write-Log "  Submit version equals real version ($RealVersion), PR title unchanged"
        return $true
    }

    $prNumber = $null
    $prTitle = $null

    $env:GH_TOKEN = $env:WINGET_TOKEN
    try {
        # 全部走 REST（gh api），不用 gh pr view/edit：
        # gh 的高层 pr 命令内部使用 GraphQL，会附带读取组织的 login/name/slug 字段，
        # 这些字段要求 read:org scope；只有 repo scope 的 token 会报 INSUFFICIENT_SCOPES。
        # REST 端点只按 repo/public_repo 校验，因此 token 无需额外组织权限。

        # 优先复用调用方已查到的 PR 信息，其次用 komac 输出中的 PR URL
        if ($PrInfo -and $PrInfo.number) {
            $prNumber = $PrInfo.number
            $prTitle = $PrInfo.title
        }
        elseif ($PrUrl -match 'github\.com/microsoft/winget-pkgs/pull/(\d+)') {
            $prNumber = $Matches[1]
        }

        # REST: GET /repos/{owner}/{repo}/pulls/{number} 读取标题
        if ($prNumber -and -not $prTitle) {
            $prJson = gh api "repos/microsoft/winget-pkgs/pulls/$prNumber" 2>&1
            $prView = $prJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($prView -and $prView.title) {
                $prTitle = $prView.title
            }
        }

        # 回退：REST issue search，按包名 + 提交版本号搜索本账号刚提交的 PR。
        # search/issues 的 item.number 即为 PR number，author:@me 限定本账号。
        if (-not $prTitle) {
            $searchQuery = "repo:microsoft/winget-pkgs is:pr is:open author:@me $Id $SubmitVersion"
            $encodedQuery = [uri]::EscapeDataString($searchQuery)
            $prsJson = gh api "search/issues?q=$encodedQuery&per_page=10" 2>&1
            $searchResult = $prsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            # 必须显式 [array]：PS 5.1 下单元素数组经 if 表达式赋值会被降为标量，
            # 标量 PSCustomObject 没有 Count 属性，会导致命中结果被误判为空。
            [array]$items = if ($searchResult -and $searchResult.items) { @($searchResult.items) } else { @() }
            if ($items.Count -gt 0) {
                $prNumber = $items[0].number
                $prTitle = $items[0].title
            }
        }

        if (-not $prNumber -or -not $prTitle) {
            Write-Log "  Warning: Could not find the submitted PR to update title"
            return $false
        }

        # 括号风格沿用既有 PR 标题（ASCII 括号 + 前置空格）
        $suffix = "($RealVersion)"
        if ($prTitle.TrimEnd().EndsWith($suffix)) {
            Write-Log "  PR title already includes real version: $prTitle"
            return $true
        }

        $newTitle = "$prTitle $suffix"
        # REST: PATCH /repos/{owner}/{repo}/pulls/{number} 修改标题。
        # -f 以字符串字段提交 JSON body，标题里的空格/括号无需额外转义。
        $editOutput = gh api -X PATCH "repos/microsoft/winget-pkgs/pulls/$prNumber" -f "title=$newTitle" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  Warning: Failed to update PR title: $($editOutput | Out-String)"
            return $false
        }
        Write-Log "  PR title updated to: $newTitle"
        return $true
    }
    catch {
        Write-Log "  Warning: Failed to update PR title: $_"
        return $false
    }
    finally {
        $env:GH_TOKEN = $null
    }
}
