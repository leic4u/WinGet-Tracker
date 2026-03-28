function Resolve-Download($config, $version, $urlVersion = $null, $checkverData = $null) {
    if (-not $urlVersion) { $urlVersion = $version }

    if (-not $config.autoupdate) {
        Write-Warning "No autoupdate config found for $($config.id)"
        return @()
    }

    # 解析未格式化的原始版本号各部分，支持 4 段版本号: 3.28.3.134742 -> major=3, minor=28, patch=3, build=134742
    $versionParts = $urlVersion -split '\.'
    $major = $versionParts[0]
    $minor = if ($versionParts.Length -gt 1) { $versionParts[1] } else { "0" }
    $patch = if ($versionParts.Length -gt 2) { $versionParts[2] } else { "0" }
    $build = if ($versionParts.Length -gt 3) { $versionParts[3] } else { "0" }

    $urls = @()

    foreach ($arch in $config.autoupdate.architecture.Keys) {
        $template = $config.autoupdate.architecture[$arch]
        $templateUrl = $null

        if ($template -is [System.Collections.IDictionary] -and $template.jsonpath) {
            $jsonPath = $template.jsonpath
            if ($checkverData) {
                # 支持点号分隔的路径和数组索引，如 "data.list[0].url" 或 "data.list.url"
                $parts = $jsonPath -split "\."
                $current = @($checkverData)  # 统一用数组包装，简化处理逻辑

                foreach ($part in $parts) {
                    # 检查是否包含数组索引，如 "list[0]"
                    if ($part -match '^(\w+)\[(\d+)\]$') {
                        $propName = $matches[1]
                        $index = [int]$matches[2]
                        $nextCurrent = [System.Collections.ArrayList]::new()
                        foreach ($item in $current) {
                            $value = $null
                            if ($item -is [System.Collections.IDictionary]) {
                                $value = $item[$propName]
                            } elseif ($item.PSObject.Properties[$propName]) {
                                $value = $item.$propName
                            }
                            if ($value -is [System.Array]) {
                                # 取指定索引的元素
                                if ($index -lt $value.Count) {
                                    [void]$nextCurrent.Add($value[$index])
                                }
                            } elseif ($value -ne $null) {
                                [void]$nextCurrent.Add($value)
                            }
                        }
                        $current = @($nextCurrent)
                    } else {
                        # 普通属性访问
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
                    }
                    if ($current.Count -eq 0) {
                        break
                    }
                }

                if ($current.Count -gt 0) {
                    # 如果结果是数组，取第一个元素（通常是最新版本）
                    $templateUrl = $current[0].ToString()
                } else {
                    Write-Warning "Could not extract download URL using jsonpath: $jsonPath from checkver data"
                }
            } else {
                Write-Warning "jsonpath specified for architecture $arch but no checkver data available"
            }
        } else {
            $templateUrl = if ($template -is [string]) { $template } else { $template.url }
        }

        if (-not $templateUrl) {
            continue
        }

        $downloadUrl = $templateUrl -replace '\$url[Vv]ersion', $urlVersion
        $downloadUrl = $downloadUrl -replace '\$url[Mm]ajor', $major -replace '\$url[Mm]inor', $minor -replace '\$url[Pp]atch', $patch -replace '\$url[Bb]uild', $build

        # 保持原版的相对上下文变量
        $downloadUrl = $downloadUrl -replace '\$version', $version
        $downloadUrl = $downloadUrl -replace '\$major', $major -replace '\$minor', $minor -replace '\$patch', $patch -replace '\$build', $build

        # 根据 URL 推断文件类型
        $type = "exe"
        if ($downloadUrl -match "\.msi$") {
            $type = "msi"
        } elseif ($downloadUrl -match "\.msix|\.appx") {
            $type = "msix"
        } elseif ($downloadUrl -match "\.(zip|7z)$") {
            $type = "zip"
        }

        $urls += [PSCustomObject]@{
            arch = $arch
            url  = $downloadUrl
            type = $type
        }
    }

    return $urls
}
