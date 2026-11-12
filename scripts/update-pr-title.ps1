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

    # 两个版本号相同时，komac 生成的标题本身已经包含正确版本号，无需修改
    if ($SubmitVersion -eq $RealVersion) {
        Write-Log "  Submit version equals real version ($RealVersion), PR title unchanged"
        return $true
    }

    $prNumber = $null
    $prTitle = $null

    $env:GH_TOKEN = $env:WINGET_TOKEN
    try {
        # 优先复用 gh pr list 已查到的 PR 信息，其次用 komac 输出中的 PR URL 读取标题
        if ($PrInfo -and $PrInfo.number) {
            $prNumber = $PrInfo.number
            $prTitle = $PrInfo.title
        }
        elseif ($PrUrl -match 'github\.com/microsoft/winget-pkgs/pull/(\d+)') {
            $prNumber = $Matches[1]
            $prJson = gh pr view $prNumber --repo microsoft/winget-pkgs --json title 2>&1
            $prView = $prJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($prView -and $prView.title) {
                $prTitle = $prView.title
            }
        }

        # 回退：按包名 + 提交版本号搜索本账号刚提交的 PR
        if (-not $prTitle) {
            $searchQuery = "$Id $SubmitVersion"
            $prsJson = gh pr list `
                --repo microsoft/winget-pkgs `
                --state open `
                --search "$searchQuery" `
                --author "@me" `
                --json number,title `
                2>&1
            $prs = $prsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($prs -and $prs.Count -gt 0) {
                $prNumber = $prs[0].number
                $prTitle = $prs[0].title
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
        $editOutput = gh pr edit $prNumber `
            --repo microsoft/winget-pkgs `
            --title "$newTitle" `
            2>&1
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
