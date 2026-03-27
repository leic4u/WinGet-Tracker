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
                $parts = $jsonPath -split "\."
                $current = $checkverData
                foreach ($part in $parts) {
                    if ($current -is [System.Collections.IDictionary]) {
                        $current = $current[$part]
                    }
                    elseif ($current.PSObject.Properties[$part]) {
                        $current = $current.$part
                    }
                    else {
                        $current = $null
                        break
                    }
                }
                if ($current) {
                    $templateUrl = $current.ToString()
                }
                else {
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
        if ($downloadUrl -match "\.msi$") { $type = "msi" }
        elseif ($downloadUrl -match "\.msix|\.appx") { $type = "msix" }
        elseif ($downloadUrl -match "\.(zip|7z)$") { $type = "zip" }

        $urls += [PSCustomObject]@{
            arch = $arch
            url  = $downloadUrl
            type = $type
        }
    }
    return $urls
}
