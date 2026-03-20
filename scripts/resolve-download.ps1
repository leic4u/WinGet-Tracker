function Resolve-Download($config, $version) {

    if (-not $config.autoupdate) {
        Write-Warning "No autoupdate config found for $($config.id)"
        return @()
    }

    # 解析版本号各部分，支持 4 段版本号: 3.28.3.134742 -> major=3, minor=28, patch=3, build=134742
    $versionParts = $version -split '\.'
    $major = $versionParts[0]
    $minor = if ($versionParts.Length -gt 1) { $versionParts[1] } else { "0" }
    $patch = if ($versionParts.Length -gt 2) { $versionParts[2] } else { "0" }
    $build = if ($versionParts.Length -gt 3) { $versionParts[3] } else { "0" }

    $urls = @()
    foreach ($arch in $config.autoupdate.architecture.Keys) {
        $template = $config.autoupdate.architecture[$arch]
        $templateUrl = if ($template -is [string]) { $template } else { $template.url }
        $downloadUrl = $templateUrl.Replace('$version', $version)
        $downloadUrl = $downloadUrl.Replace('$major', $major)
        $downloadUrl = $downloadUrl.Replace('$minor', $minor)
        $downloadUrl = $downloadUrl.Replace('$patch', $patch)
        $downloadUrl = $downloadUrl.Replace('$build', $build)

        # Infer file type from URL
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
