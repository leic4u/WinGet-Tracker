function Test-WingetPRExists {
    param(
        [string]$id,
        [string]$version
    )

    # 如果没有设置 WINGET_TOKEN，跳过检查
    if (-not $env:WINGET_TOKEN) {
        Write-Warning "WINGET_TOKEN not set, skipping PR existence check"
        return $false
    }

    try {
        # 设置认证
        $env:GH_TOKEN = $env:WINGET_TOKEN

        # 使用更精确的搜索
        $query = "$id $version"
        Write-Host "  Searching for existing PR with: $query"

        # 获取 PR 列表（检查所有状态：open, closed, merged）
        $prsJson = gh pr list `
            --repo microsoft/winget-pkgs `
            --state all `
            --search "$query" `
            --json number,title,headRefName,author,state,mergedAt `
            2>&1

        # 检查是否是有效的 JSON（不是错误信息）
        if (-not $prsJson -or $prsJson.GetType().Name -eq "ErrorRecord") {
            throw "PR 查重失败：gh 命令未返回有效输出（$($prsJson | Out-String)）"
        }

        # 将输出转换为字符串并清理
        $outputStr = $prsJson | Out-String
        $outputStr = $outputStr.Trim()

        # 尝试提取 JSON 部分（移除可能的警告信息）
        $jsonStart = $outputStr.IndexOf('[')
        $jsonEnd = $outputStr.LastIndexOf(']')
        $jsonStr = if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
            $outputStr.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
        } else {
            $outputStr
        }

        # 解析失败不等于「没有 PR」：komac 自身的查重已被跳过，
        # 这里放行会导致重复提交，因此直接抛出，由调用方记为 error 并跳过该包。
        try {
            $data = $jsonStr | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "PR 查重失败，gh 输出无法解析为 JSON：$($_.Exception.Message)"
        }

        # 遍历检查结果
        foreach ($pr in $data) {
            # 检查 PR 标题是否匹配
            $titleMatch = $pr.title -match [regex]::Escape($id) -and $pr.title -match [regex]::Escape($version)

            # 检查分支名是否匹配
            $branchMatch = $pr.headRefName -match [regex]::Escape($id) -or $pr.headRefName -match [regex]::Escape($version)

            # 检查是否应该跳过提交：OPEN（开放）或 MERGED（已合并）状态
            $shouldSkip = ($pr.state -eq 'OPEN') -or ($pr.state -eq 'MERGED') -or ($null -ne $pr.mergedAt)

            if (($titleMatch -or $branchMatch) -and $shouldSkip) {
                $status = if ($pr.state -eq 'OPEN') { "open" } elseif ($pr.state -eq 'MERGED' -or $null -ne $pr.mergedAt) { "merged" } else { $pr.state }
                Write-Host "  Found existing PR #$($pr.number): $($pr.title) (status: $status)"
                # 返回 PR 信息对象，包含 PR 编号和 URL
                return [PSCustomObject]@{
                    Exists = $true
                    Number = $pr.number
                    Url    = "https://github.com/microsoft/winget-pkgs/pull/$($pr.number)"
                    Title  = $pr.title
                    State  = $status
                }
            }
        }

        Write-Host "  No existing PR found for $id $version"
        return $false
    }
    catch {
        # 查重结果不确定时一律中止该包的处理：不能回写版本号，也不能提交，
        # 否则可能在已有 OPEN PR 的情况下重复提交，或把版本号错误推进。
        throw "PR 查重失败，为防重复提交已中止：$($_.Exception.Message)"
    }
    finally {
        # 清理环境变量
        if ($env:GH_TOKEN) {
            $env:GH_TOKEN = $null
        }
    }
}
