if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Error "Required module 'powershell-yaml' is not installed. Install it with: Install-Module powershell-yaml -Scope CurrentUser -Force"
    exit 1
}

Import-Module powershell-yaml

. "$PSScriptRoot/resolve-version.ps1"
. "$PSScriptRoot/scan-url-version.ps1"
. "$PSScriptRoot/calc-hash.ps1"

function Compare-Versions {
    param(
        [string]$v1,
        [string]$v2
    )

    $v1 = $v1.Trim() -replace '^v', ''
    $v2 = $v2.Trim() -replace '^v', ''

    if ($v1 -eq $v2) { return $false }

    try {
        $ver1 = [System.Version]::Parse($v1)
        $ver2 = [System.Version]::Parse($v2)
        return $ver1 -gt $ver2
    }
    catch {
        $parts1 = $v1.Split('.') | ForEach-Object {
            $num = 0
            if ([int]::TryParse($_, [ref]$num)) { $num } else { 0 }
        }
        $parts2 = $v2.Split('.') | ForEach-Object {
            $num = 0
            if ([int]::TryParse($_, [ref]$num)) { $num } else { 0 }
        }

        $max = [Math]::Max($parts1.Count, $parts2.Count)
        for ($i = 0; $i -lt $max; $i++) {
            $p1 = if ($i -lt $parts1.Count) { $parts1[$i] } else { 0 }
            $p2 = if ($i -lt $parts2.Count) { $parts2[$i] } else { 0 }
            if ($p1 -gt $p2) { return $true }
            if ($p1 -lt $p2) { return $false }
        }
        return $false
    }
}

function Update-YamlConfig {
    param(
        [string]$filePath,
        [string]$newVersion,
        [object]$config
    )

    $yaml = Get-Content $filePath -Raw
    $yamlLines = $yaml -split "`r?`n"
    $newLines = @()
    $archsToUpdate = @{}
    $newArchs = @{}

    if ($config.autoupdate -and $config.autoupdate.architecture) {
        # 解析版本号各部分，支持 4 段版本号: 3.28.3.134742 -> major=3, minor=28, patch=3, build=134742
        $versionParts = $newVersion -split '\.'
        $major = $versionParts[0]
        $minor = if ($versionParts.Length -gt 1) { $versionParts[1] } else { "0" }
        $patch = if ($versionParts.Length -gt 2) { $versionParts[2] } else { "0" }
        $build = if ($versionParts.Length -gt 3) { $versionParts[3] } else { "0" }
        
        # 使用模板生成 URL
        foreach ($archName in $config.autoupdate.architecture.Keys) {
            $archValue = $config.autoupdate.architecture[$archName]
            
            # 处理两种可能的配置格式：
            # 1. 直接字符串: x86: "https://..."
            # 2. 对象格式: x86: { url: "https://..." }
            if ($archValue -is [string]) {
                $template = $archValue
            }
            elseif ($archValue -and $archValue.url) {
                $template = $archValue.url
            }
            else {
                Write-Host "  Warning: Invalid architecture configuration for $archName"
                continue
            }
            
            # 确保所有变量都不为 null
            if (-not $template) { Write-Host "  Warning: Template is null for $archName"; continue }
            if (-not $newVersion) { Write-Host "  Warning: newVersion is null for $archName"; continue }
            if (-not $major) { Write-Host "  Warning: major is null for $archName"; continue }
            if (-not $minor) { Write-Host "  Warning: minor is null for $archName"; continue }
            if (-not $patch) { Write-Host "  Warning: patch is null for $archName"; continue }
            if (-not $build) { Write-Host "  Warning: build is null for $archName"; continue }
            
            $newUrl = $template.Replace('$version', $newVersion)
            $newUrl = $newUrl.Replace('$major', $major)
            $newUrl = $newUrl.Replace('$minor', $minor)
            $newUrl = $newUrl.Replace('$patch', $patch)
            $newUrl = $newUrl.Replace('$build', $build)
            if (-not [string]::IsNullOrWhiteSpace($newUrl)) {
                # 只存储 URL，哈希值在 submit-winget 阶段计算
                $archsToUpdate[$archName] = @{
                    url = $newUrl
                    hash = ""  # 空哈希，稍后在 submit-winget 中填充
                }
            }
        }
    }

    # 检查是否有新架构需要添加
    $existingArchs = @()
    if ($config.current_package -and $config.current_package.architecture) {
        # 安全地获取现有架构名称
        if ($config.current_package.architecture -is [hashtable] -or $config.current_package.architecture -is [System.Collections.Specialized.OrderedDictionary]) {
            $existingArchs = $config.current_package.architecture.Keys
        }
        elseif ($config.current_package.architecture.PSObject.Properties) {
            $existingArchs = $config.current_package.architecture.PSObject.Properties.Name
        }
        else {
            $existingArchs = @()
        }
    }
    foreach ($archName in $archsToUpdate.Keys) {
        if ($existingArchs -notcontains $archName) {
            $newArchs[$archName] = $archsToUpdate[$archName]
            Write-Host "  New architecture detected: $archName"
        }
    }

    # 重新构建 YAML 内容
    $i = 0
    $currentPackageIndent = 0
    while ($i -lt $yamlLines.Count) {
        $line = $yamlLines[$i]
        $indent = $line.Length - $line.TrimStart().Length

        # 跳过旧的 current_package 部分，稍后重新添加
        if ($line -match '^current_package:') {
            $currentPackageIndent = $indent
            $i++
            # 跳过 current_package 下的所有内容
            while ($i -lt $yamlLines.Count) {
                $nextLine = $yamlLines[$i]
                $nextIndent = $nextLine.Length - $nextLine.TrimStart().Length
                # 如果遇到相同或更少缩进的行，说明 current_package 结束
                if ($nextLine.Trim() -ne '' -and $nextIndent -le $currentPackageIndent) {
                    break
                }
                $i++
            }
            # 添加新的 current_package 部分
            $newLines += "current_package:"
            $newLines += "  version: `"$newVersion`""
            $newLines += "  architecture:"
            # 合并所有架构（已有的 + 新增的），避免重复
            $allArchs = @{}
            foreach ($archName in $archsToUpdate.Keys) {
                $allArchs[$archName] = $archsToUpdate[$archName]
            }
            foreach ($archName in $newArchs.Keys) {
                if (-not $allArchs.ContainsKey($archName)) {
                    $allArchs[$archName] = $newArchs[$archName]
                }
            }
            # 添加所有架构
            foreach ($archName in ($allArchs.Keys | Sort-Object)) {
                $archInfo = $allArchs[$archName]
                $newLines += "    ${archName}:"
                $newLines += "      url: $($archInfo['url'])"
                $newLines += "      hash: $($archInfo['hash'])"
            }
            continue
        }

        # 跳过旧的 current_version 和 architecture（顶层）
        if ($line -match '^(current_version|architecture):') {
            # 跳过这一行及其子内容
            $oldKeyIndent = $indent
            $i++
            while ($i -lt $yamlLines.Count) {
                $nextLine = $yamlLines[$i]
                $nextIndent = $nextLine.Length - $nextLine.TrimStart().Length
                if ($nextLine.Trim() -ne '' -and $nextIndent -le $oldKeyIndent) {
                    break
                }
                $i++
            }
            continue
        }

        $newLines += $line
        $i++
    }
    $newLines -join "`n" | Set-Content $filePath -Encoding UTF8
}

$packages = Get-ChildItem "$PSScriptRoot/../packages/*.yaml"
$result = @()
$hasError = $false
$logFile = "$PSScriptRoot/../logs/check-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$maxLogAge = 30
$oldLogs = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$maxLogAge) }
if ($oldLogs) {
    $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "Cleaned up $($oldLogs.Count) old log files"
}

enum LogLevel {
    INFO
    WARNING
    ERROR
}

function Write-Log {
    param(
        [string]$message,
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$level] $message"

    switch ($level) {
        "INFO" { Write-Host $logMessage -ForegroundColor Green }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
    }

    Add-Content -Path $logFile -Value $logMessage
}

Write-Log "Starting version check for $($packages.Count) packages"

foreach ($pkg in $packages) {
    try {
        $config = Get-Content $pkg | ConvertFrom-Yaml
        $id = $config.id

        Write-Log "Checking $id" -level "INFO"

        $currentVersion = if ($config.current_package -and $config.current_package.version) { $config.current_package.version } elseif ($config.current_version) { $config.current_version } else { "0.0.0" }
        Write-Log " Current version (from config): $currentVersion" -level "INFO"

        $version = Resolve-Version $config

        if (-not $version) {
            try {
                Write-Log " Primary version check failed, trying fallback..." -level "WARNING"
                $html = Invoke-WebRequest $config.checkver.url -UseBasicParsing -ErrorAction Stop
                $version = Get-VersionFromUrl $html.Content
            }
            catch {
                Write-Log " Warning: Failed to scan URL for version: $_" -level "WARNING"
            }
        }

        if (-not $version) {
            Write-Log " Skipped: Could not determine version" -level "ERROR"
            continue
        }

        Write-Log " Remote version: $version" -level "INFO"
        Write-Log " Comparing versions: current='$currentVersion' vs remote='$version'" -level "INFO"

        if (Compare-Versions -v1 $version -v2 $currentVersion) {
            $result += [PSCustomObject]@{
                id      = $id
                version = $version
                file    = $pkg.Name
            }
            Write-Log " UPDATE AVAILABLE: $currentVersion -> $version" -level "WARNING"

            # 更新 YAML 配置文件
            Update-YamlConfig -filePath $pkg.FullName -newVersion $version -config $config
            Write-Log " Updated config file with new version, urls and hashes" -level "INFO"
        }
        else {
            Write-Log " Up to date" -level "INFO"
        }
    }
    catch {
        $hasError = $true
        Write-Log " Error processing $($pkg.Name): $_" -level "ERROR"
    }
}

Write-Log "Check complete. Found $($result.Count) updates."

if ($result.Count -gt 0) {
    $outputPath = "$PSScriptRoot/../updates.json"
    $result | ConvertTo-Json | Out-File $outputPath -Encoding UTF8
    Write-Log "Results saved to $outputPath" -level "INFO"
    $result | Format-Table -AutoSize
    Write-Log "Updates found, exiting with code 0 for further processing" -level "INFO"
} else {
    Write-Log "No updates found, exiting normally" -level "INFO"
}

if ($hasError) {
    Write-Log "One or more errors occurred during check-version" -level "ERROR"
    exit 1
}

exit 0