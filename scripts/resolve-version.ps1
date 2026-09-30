# 比较两个版本号字符串，返回 -1 / 0 / 1
# 规则与 check-version.ps1 的 Compare-Versions 保持一致：数值段按数值比较、字母段按字母比较，
# 同一数值段下带预发布后缀的版本更旧，例如 1.1.7 > 1.1.7-rc1 > 1.1.7-beta > 1.1.7-alpha
function Compare-VersionText([string]$v1, [string]$v2) {
    $v1 = ([string]$v1).Trim() -replace '^[vV]', ''
    $v2 = ([string]$v2).Trim() -replace '^[vV]', ''

    if ($v1 -eq $v2) { return 0 }

    $parts1 = @([regex]::Matches($v1, '\d+|[A-Za-z]+') | ForEach-Object { $_.Value })
    $parts2 = @([regex]::Matches($v2, '\d+|[A-Za-z]+') | ForEach-Object { $_.Value })

    $maxCount = [Math]::Max($parts1.Count, $parts2.Count)

    for ($i = 0; $i -lt $maxCount; $i++) {
        $p1 = if ($i -lt $parts1.Count) { $parts1[$i] } else { "" }
        $p2 = if ($i -lt $parts2.Count) { $parts2[$i] } else { "" }

        if ($p1 -eq $p2) { continue }

        $num1 = 0; $num2 = 0
        $isNum1 = [int]::TryParse($p1, [ref]$num1)
        $isNum2 = [int]::TryParse($p2, [ref]$num2)

        if ($isNum1 -and $isNum2) {
            if ($num1 -ne $num2) { return [Math]::Sign($num1 - $num2) }
        }
        elseif ($isNum1) {
            if ($p2 -eq "") {
                if ($num1 -eq 0) { continue }
                return [Math]::Sign($num1)
            }
            return 1
        }
        elseif ($isNum2) {
            if ($p1 -eq "") {
                if ($num2 -eq 0) { continue }
                return -1
            }
            return -1
        }
        else {
            if ($p1 -eq "") { return 1 }
            if ($p2 -eq "") { return -1 }
            $diff = [string]::Compare($p1, $p2, $true)
            if ($diff -ne 0) { return [Math]::Sign($diff) }
        }
    }

    return 0
}

# 从版本列表中选出最新版本
# 不用 Sort-Object + [version] 强转，后者遇到 v1.1.8_snow-shot、1.1.7-beta 这类字符串会直接报错
function Select-LatestVersion($versions) {
    $list = @($versions)
    if ($list.Count -eq 0) { return $null }

    $latest = $list[0]
    foreach ($candidate in $list) {
        if ((Compare-VersionText $candidate $latest) -gt 0) {
            $latest = $candidate
        }
    }
    return $latest
}

function Resolve-Version($config) {
    $url = $config.checkver.url
    $method = if ($config.checkver.method) { $config.checkver.method.ToUpper() } else { "GET" }

    # 自动处理 GitHub 仓库 URL
    $isGitHubRepo = $url -match '^https://github\.com/([^/]+)/([^/]+)/?$'
    if ($isGitHubRepo -and -not $config.checkver.jsonpath) {
        $owner = $matches[1]
        $repo = $matches[2]

        $headers = @{
            "Accept" = "application/vnd.github.v3+json"
            "User-Agent" = "winget-tracker"
        }
        if ($env:WINGET_TOKEN) {
            $headers["Authorization"] = "token $($env:WINGET_TOKEN)"
        }

        $version = $null
        $release = $null

        # 先尝试 GitHub release
        $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/latest"
        Write-Host "  Detected GitHub repository, using release API: $apiUrl"
        try {
            $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
            if ($release.tag_name) {
                $version = $release.tag_name -replace '^[vV]', ''
            } elseif ($release.name) {
                $version = $release.name -replace '^[vV]', ''
            }

            if ($version) {
                Write-Host "  Found version from GitHub release API: $version"
                return [PSCustomObject]@{
                    Version    = $version
                    UrlVersion = $version
                    Data       = $release
                }
            }

            Write-Warning "  Could not extract version from GitHub release API response"
        } catch {
            Write-Warning "  GitHub release API failed: $_"
        }

        # release 不可用时尝试 GitHub tags
        $tagsUrl = "https://api.github.com/repos/$owner/$repo/tags"
        Write-Host "  Trying GitHub tags API: $tagsUrl"
        try {
            $tags = Invoke-RestMethod -Uri $tagsUrl -Headers $headers -ErrorAction Stop
            if ($tags -and $tags.Count -gt 0) {
                $tagVersions = @()
                foreach ($tag in $tags) {
                    if ($tag.name) {
                        $tagName = $tag.name -replace '^[vV]', ''
                        if ($tagName -match '^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9]+)?$') {
                            $tagVersions += $tagName
                        }
                    }
                }

                if ($tagVersions.Count -gt 0) {
                    $version = Select-LatestVersion $tagVersions
                } else {
                    $version = ($tags[0].name -replace '^[vV]', '')
                }

                if ($version) {
                    Write-Host "  Found version from GitHub tags API: $version"
                    return [PSCustomObject]@{
                        Version    = $version
                        UrlVersion = $version
                        Data       = $tags
                    }
                }
            } else {
                Write-Warning "  No tags found from GitHub tags API"
            }
        } catch {
            Write-Warning "  GitHub tags API failed: $_"
        }

        return $null
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

            # 预先编译 regex：它用于从 jsonpath 抽出的原始值中提取版本号，提取结果才参与排序
            $compiledRegex = $null
            if ($config.checkver.regex) {
                try {
                    $compiledRegex = [regex]::new($config.checkver.regex)
                } catch {
                    Write-Warning "  Invalid regex pattern: $($config.checkver.regex) - $_"
                    return $null
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

                    if (-not $itemVersion) { continue }

                    # 应用排除模式过滤（作用于 jsonpath 抽出的原始值）
                    if ($config.checkver.exclude_pattern -and $itemVersion -match $config.checkver.exclude_pattern) {
                        continue
                    }

                    # 用 regex 从原始值中提取版本号
                    if ($compiledRegex) {
                        $match = $compiledRegex.Match($itemVersion)
                        if (-not $match.Success) {
                            Write-Host "  Skipped (regex not matched): $itemVersion"
                            continue
                        }
                        if ($match.Groups["version"].Success) {
                            $itemVersion = $match.Groups["version"].Value.Trim()
                        } elseif ($match.Groups.Count -gt 1) {
                            $itemVersion = $match.Groups[1].Value.Trim()
                        } else {
                            $itemVersion = $match.Value.Trim()
                        }
                    }

                    $versions += $itemVersion
                }

                if ($versions.Count -gt 0) {
                    # 返回最新的版本
                    $version = Select-LatestVersion $versions
                    Write-Host "  Found latest version after filtering: $version"
                } else {
                    Write-Warning "  No versions found after filtering"
                    return $null
                }
            } else {
                Write-Warning "  Could not extract version using jsonpath: $jsonPath"
                return $null
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
