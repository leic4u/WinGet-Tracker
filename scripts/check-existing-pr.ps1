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
            Write-Warning "Failed to execute gh command: $($prsJson | Out-String)"
            return $false
        }
        
        # 将输出转换为字符串并清理
        $outputStr = $prsJson | Out-String
        $outputStr = $outputStr.Trim()

        # 尝试提取 JSON 部分（移除可能的警告信息）
        $jsonStart = $outputStr.IndexOf('[')
        $jsonEnd = $outputStr.LastIndexOf(']')

        if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
            # 提取 JSON 数组部分
            $jsonStr = $outputStr.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
            $data = $jsonStr | ConvertFrom-Json -ErrorAction SilentlyContinue
        }
        else {
            # 直接尝试解析
            $data = $prsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        }

        # 遍历检查结果
        foreach ($pr in $data) {
            # 检查 PR 标题是否匹配
            $titleMatch = $pr.title -match [regex]::Escape($id) -and $pr.title -match [regex]::Escape($version)
            
            # 检查分支名是否匹配
            $branchMatch = $pr.headRefName -match [regex]::Escape($id) -or $pr.headRefName -match [regex]::Escape($version)
            
            # 检查是否已合并（通过 state 为 MERGED 或 mergedAt 有值）
            $isMerged = ($pr.state -eq 'MERGED') -or ($null -ne $pr.mergedAt)
            
            if (($titleMatch -or $branchMatch) -and $isMerged) {
                $status = if ($isMerged) { "merged" } else { "open/closed" }
                Write-Host "  Found existing PR #$($pr.number): $($pr.title) (status: $status)"
                return $true
            }
        }
        
        Write-Host "  No existing PR found for $id $version"
        return $false
    }
    catch {
        Write-Warning "Failed to check existing PRs: $_"
        return $false
    }
    finally {
        # 清理环境变量
        if ($env:GH_TOKEN) {
            $env:GH_TOKEN = $null
        }
    }
}
