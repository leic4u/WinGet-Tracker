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
            --json number,title,headRefName,author,merged `
            2>&1
        
        # 检查是否是有效的 JSON（不是错误信息）
        if (-not $prsJson -or $prsJson.GetType().Name -eq "ErrorRecord") {
            Write-Warning "Failed to execute gh command: $($prsJson | Out-String)"
            return $false
        }
        
        # 检查输出是否以 [ 开头（JSON 数组），如果不是则可能是错误信息
        $outputStr = $prsJson | Out-String
        if (-not $outputStr.Trim().StartsWith("[")) {
            Write-Warning "gh command returned non-JSON response: $outputStr"
            return $false
        }
        
        $data = $prsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data) {
            Write-Warning "Failed to parse JSON response from gh command"
            return $false
        }
        
        # 遍历检查结果
        foreach ($pr in $data) {
            # 检查 PR 标题是否匹配
            $titleMatch = $pr.title -match [regex]::Escape($id) -and $pr.title -match [regex]::Escape($version)
            
            # 检查分支名是否匹配
            $branchMatch = $pr.headRefName -match [regex]::Escape($id) -or $pr.headRefName -match [regex]::Escape($version)
            
            # 检查是否已合并
            $isMerged = $pr.merged -eq $true
            
            if (($titleMatch -or $branchMatch) -or $isMerged) {
                $status = if ($isMerged) { "merged" } else { "open/closed" }
                Write-Host "  Found existing PR #$($pr.number): $($pr.title) (status: $status)"
                return $true
            }
        }
        
        Write-Host "  No existing PR found for $id $version"
        return $false
    } catch {
        Write-Warning "Failed to check existing PRs: $_"
        return $false
    } finally {
        # 清理环境变量
        if ($env:GH_TOKEN) {
            $env:GH_TOKEN = $null
        }
    }
}
