function Test-PackageConfig {
    param(
        [object]$config,
        [string]$fileName
    )

    $errors = @()
    $warnings = @()

    # 验证必填字段
    if (-not $config.id) {
        $errors += "Missing required field: 'id'"
    }
    else {
        # 验证 ID 格式 (应该包含至少一个点)
        if ($config.id -notmatch '\.') {
            $warnings += "Package ID '$($config.id)' should contain at least one dot (e.g., Publisher.PackageName)"
        }
    }

    if (-not $config.checkver) {
        $errors += "Missing required field: 'checkver'"
    }
    else {
        if (-not $config.checkver.url) {
            $errors += "Missing required field: 'checkver.url'"
        }
        else {
            # 验证 URL 格式
            if ($config.checkver.url -notmatch '^https?://') {
                $errors += "Invalid URL format in 'checkver.url': $($config.checkver.url)"
            }

            # 验证 GitHub URL 格式
            if ($config.checkver.url -match "github.com") {
                if (-not $config.checkver.url -match "github.com/[^/]+/[^/]+") {
                    $errors += "Invalid GitHub URL format. Expected: https://github.com/owner/repo"
                }
            }
        }

        # 如果有 regex，验证其有效性
        if ($config.checkver.regex) {
            try {
                $null = [System.Text.RegularExpressions.Regex]::Match("", $config.checkver.regex)
            }
            catch {
                $errors += "Invalid regex pattern in 'checkver.regex': $($config.checkver.regex)"
            }
        }
    }

    # 验证 autoupdate 配置
    if ($config.autoupdate) {
        if (-not $config.autoupdate.architecture) {
            $errors += "Missing 'autoupdate.architecture' configuration"
        }
        else {
            $validArchs = @('x64', 'x86', 'arm64')
            foreach ($arch in $config.autoupdate.architecture.Keys) {
                if ($validArchs -notcontains $arch) {
                    $warnings += "Unknown architecture: '$arch'. Valid values are: $($validArchs -join ', ')"
                }
                $url = $config.autoupdate.architecture[$arch]
                if (-not $url) {
                    $errors += "Missing URL for architecture: '$arch'"
                }
                elseif ($url -notmatch '^https?://') {
                    $errors += "Invalid URL format for architecture '$arch': $url"
                }
            }
        }
    }

    # 输出结果
    $isValid = $errors.Count -eq 0

    if ($warnings.Count -gt 0) {
        Write-Host " Warnings:" -ForegroundColor Yellow
        foreach ($warning in $warnings) {
            Write-Host " - $warning" -ForegroundColor Yellow
        }
    }

    if ($errors.Count -gt 0) {
        Write-Host " Errors:" -ForegroundColor Red
        foreach ($err in $errors) {
            Write-Host " - $err" -ForegroundColor Red
        }
    }

    return $isValid
}

# 导出函数
Export-ModuleMember -Function Test-PackageConfig