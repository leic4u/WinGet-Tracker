# 配置字段读取层：统一 version / url_version / pkg_version / submit_version 四个版本名。
# 键名归一化后比较，因此配置里写蛇形（url_version）或驼峰（urlVersion）都能读取。
# 仅处理「会出现在配置里 / 跨脚本传递」的字段；脚本内部临时变量不在此列。

function Get-ConfigField {
    param($obj, [string]$name)

    if ($null -eq $obj) { return $null }
    $canonical = $name.ToLowerInvariant() -replace '_', ''

    $entries = @()
    if ($obj -is [System.Collections.IDictionary]) {
        foreach ($key in $obj.Keys) {
            $entries += [PSCustomObject]@{ Key = [string]$key; Value = $obj[$key] }
        }
    }
    else {
        foreach ($prop in $obj.PSObject.Properties) {
            $entries += [PSCustomObject]@{ Key = [string]$prop.Name; Value = $prop.Value }
        }
    }

    foreach ($entry in $entries) {
        $entryKey = ([string]$entry.Key).ToLowerInvariant() -replace '_', ''
        if ($entryKey -ne $canonical) { continue }
        if ($null -ne $entry.Value -and ([string]$entry.Value).Trim() -ne '') {
            return [string]$entry.Value
        }
    }
    return $null
}

function Get-CurrentPackageVersion {
    param($config)

    # current_package.version 与 current_package.url_version 等价，都是当前已知的真实版本号
    $value = Get-ConfigField $config.current_package 'version'
    if ($value) { return $value }
    $value = Get-ConfigField $config.current_package 'url_version'
    if ($value) { return $value }

    # 兼容旧配置里的顶层 current_version
    $value = Get-ConfigField $config 'current_version'
    if ($value) { return $value }
    return "0.0.0"
}

function Get-UpdateDetectedVersion {
    param($item)

    # updates.json 里 url_version 是 checkver 检测到的真实版本号；
    # 旧格式没有 url_version 时回退到 version，保证中间文件向前兼容。
    if ($item -and $item.PSObject.Properties['url_version'] -and $item.url_version) {
        return [string]$item.url_version
    }
    if ($item -and $item.PSObject.Properties['version'] -and $item.version) {
        return [string]$item.version
    }
    return ""
}

function Get-SubmitVersionFormat {
    param($config)

    # autoupdate.submit_version 是生成提交版本号的模板；旧字段 version_format 保留兼容回退
    $value = Get-ConfigField $config.autoupdate 'submit_version'
    if ($value) { return $value }
    $value = Get-ConfigField $config.autoupdate 'version_format'
    if ($value) { return $value }
    return $null
}
