function Resolve-Version($config) {
    $url = $config.checkver.url
    $method = if ($config.checkver.method) { $config.checkver.method.ToUpper() } else { "GET" }

    # 自动处理 GitHub 仓库 URL
    $isGitHubRepo = $url -match '^https://github\.com/([^/]+)/([^/]+)/?$'
    if ($isGitHubRepo -and -not $config.checkver.jsonpath) {
        # 转换为 GitHub API URL
        $owner = $matches[1]
        $repo = $matches[2]
        $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/latest"
        Write-Host "  Detected GitHub repository, using API: $apiUrl"

        try {
            $headers = @{
                "Accept" = "application/vnd.github.v3+json"
                "User-Agent" = "winget-tracker"
            }
            if ($env:WINGET_TOKEN) {
                $headers["Authorization"] = "token $($env:WINGET_TOKEN)"
            }

            $release = Invoke-RestMethod $apiUrl -Headers $headers -ErrorAction Stop

            if ($release.tag_name) {
                $version = $release.tag_name.TrimStart("v")
                Write-Host "  Found version from GitHub API: $version"
                return $version
            }
            if ($release.name) {
                $version = $release.name.TrimStart("v")
                Write-Host "  Found version from GitHub API: $version"
                return $version
            }

            Write-Warning "  Could not extract version from GitHub API response"
            return $null
        } catch {
            Write-Warning "  Failed to fetch version from GitHub API: $_"
            return $null
        }
    }

    # 方式1: API 请求查找更新（当配置了 jsonpath 时）
    if ($config.checkver.jsonpath) {
        try {
            Write-Host "  Fetching version from URL: $url (Method: $method)"

            # 构建请求头
            $headers = @{}
            if ($config.checkver.headers) {
                foreach ($key in $config.checkver.headers.Keys) {
                    $headers[$key] = $config.checkver.headers[$key]
                }
            }

            # 获取请求体（仅适用于 POST/PUT/PATCH）
            $body = $null
            if ($method -eq "POST" -or $method -eq "PUT" -or $method -eq "PATCH") {
                if ($config.checkver.body) {
                    $body = $config.checkver.body
                    Write-Host "  Request body: $body"
                }
            }

            # 发送请求
            $irmParams = @{
                Uri = $url
                Method = $method
                ErrorAction = "Stop"
            }
            if ($headers.Count -gt 0) {
                $irmParams["Headers"] = $headers
            }
            if ($body) {
                $irmParams["Body"] = $body
            }

            $response = Invoke-RestMethod @irmParams

            # 从 JSON 响应中提取版本号
            $jsonPath = $config.checkver.jsonpath
            Write-Host "  Extracting version using jsonpath: $jsonPath"

            # 支持点号分隔的路径，如 "data.version"
            # 当路径中遇到数组时，自动遍历数组并继续解析剩余路径
            $parts = $jsonPath -split "\."
            $current = @($response)  # 统一用数组包装，简化处理逻辑

            foreach ($part in $parts) {
                $nextCurrent = [System.Collections.ArrayList]::new()
                foreach ($item in $current) {
                    if ($item -is [System.Collections.IDictionary]) {
                        if ($item[$part]) {
                            $value = $item[$part]
                            if ($value -is [System.Array]) {
                                [void]$nextCurrent.AddRange($value)
                            } else {
                                [void]$nextCurrent.Add($value)
                            }
                        }
                    } elseif ($item.PSObject.Properties[$part]) {
                        $value = $item.$part
                        if ($value -is [System.Array]) {
                            [void]$nextCurrent.AddRange($value)
                        } else {
                            [void]$nextCurrent.Add($value)
                        }
                    } elseif ($item -is [System.Array]) {
                        # 如果当前项是数组，继续遍历
                        [void]$nextCurrent.AddRange($item)
                    }
                }
                $current = @($nextCurrent)
                if ($current.Count -eq 0) {
                    break
                }
            }

            if ($current.Count -gt 0) {
                # 收集所有版本号
                $versions = @()
                foreach ($item in $current) {
                    $itemVersion = $null
                    if ($item -is [string]) {
                        $itemVersion = $item
                    } elseif ($item.PSObject.Properties["app_version"]) {
                        $itemVersion = $item.app_version.ToString()
                    } elseif ($item.PSObject.Properties["version"]) {
                        $itemVersion = $item.version.ToString()
                    } elseif ($item -is [System.Collections.IDictionary] -or $item.PSObject.Properties.Count -gt 0) {
                        # 尝试转换为字符串
                        $itemVersion = $item.ToString()
                    }

                    if ($itemVersion) {
                        # 应用排除模式过滤
                        if ($config.checkver.exclude_pattern) {
                            if ($itemVersion -notmatch $config.checkver.exclude_pattern) {
                                $versions += $itemVersion
                            }
                        } else {
                            $versions += $itemVersion
                        }
                    }
                }

                if ($versions.Count -gt 0) {
                    # 返回最新的版本
                    $version = $versions | Sort-Object { [version]$_ } -Descending | Select-Object -First 1
                    Write-Host "  Found latest version after filtering: $version"
                } else {
                    Write-Warning "  No versions found after filtering"
                    return $null
                }
            } else {
                Write-Warning "  Could not extract version using jsonpath: $jsonPath"
                return $null
            }

            # 如果配置了 regex，对原始版本号进行进一步截取
            if ($config.checkver.regex) {
                $regex = $config.checkver.regex
                try {
                    $compiledRegex = [regex]::new($regex)
                    $match = $compiledRegex.Match($version)
                    if ($match.Success) {
                        if ($match.Groups["version"].Success) {
                            $version = $match.Groups["version"].Value.Trim()
                        } elseif ($match.Groups.Count -gt 1) {
                            $version = $match.Groups[1].Value.Trim()
                        } else {
                            $version = $match.Value.Trim()
                        }
                        Write-Host "  Extracted via regex from jsonpath: $version"
                    } else {
                        Write-Warning "  Regex pattern did not match JSON extracted value: $version"
                        return $null
                    }
                } catch {
                    Write-Warning "  Invalid regex pattern: $regex - $_"
                    return $null
                }
            }

            $urlVersion = $version

            # 仅保留原始版本号返回
            return [PSCustomObject]@{
                Version = $version
                UrlVersion = $urlVersion
                Data = $response
            }
        } catch {
            Write-Warning "  Failed to fetch version from $url : $_"
            return $null
        }
    }

    # 方式2和3: Web网页查找更新 或 GitHub release查找更新（当没有配置 jsonpath 时）
    else {
        try {
            Write-Host "  Fetching version from URL: $url"
            $resp = Invoke-WebRequest $url -UseBasicParsing -ErrorAction Stop
            $content = $resp.Content

            if (-not $config.checkver.regex) {
                Write-Warning "  No regex pattern specified in checkver"
                return $null
            }

            $regex = $config.checkver.regex

            # 验证正则表达式
            try {
                $compiledRegex = New-Object System.Text.RegularExpressions.Regex($regex)
            } catch {
                Write-Warning "  Invalid regex pattern: $regex - $_"
                return $null
            }

            $match = $compiledRegex.Match($content)
            if ($match.Success) {
                $extractedVersion = $null

                # 优先使用命名捕获组
                if ($match.Groups["version"].Success) {
                    $extractedVersion = $match.Groups["version"].Value.Trim()
                    Write-Host "  Found version (named group): $extractedVersion"
                } elseif ($match.Groups.Count -gt 1) {
                    # 使用第一个捕获组
                    $extractedVersion = $match.Groups[1].Value.Trim()
                    Write-Host "  Found version (positional): $extractedVersion"
                }

                $version = $extractedVersion

                # 验证版本号格式
                if ($version -and $version -match '^\d+(\.\d+)*(-[a-zA-Z0-9]+)?') {
                    return [PSCustomObject]@{
                        Version = $version
                        UrlVersion = $extractedVersion
                    }
                } elseif ($version) {
                    Write-Warning "  Version format looks unusual: $version"
                    return [PSCustomObject]@{
                        Version = $version
                        UrlVersion = $extractedVersion
                    }
                }
            } else {
                Write-Warning "  Regex pattern did not match any content"
            }
        } catch {
            Write-Warning "  Failed to fetch version from $url : $_"
            return $null
        }
    }
}
