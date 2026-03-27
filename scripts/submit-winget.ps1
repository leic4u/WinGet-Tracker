Import-Module powershell-yaml
. "$PSScriptRoot/resolve-download.ps1"
. "$PSScriptRoot/calc-hash.ps1"
. "$PSScriptRoot/check-existing-pr.ps1"
. "$PSScriptRoot/get-installer-version.ps1"

function Update-PackageCurrentInfo {
    param(
        [string]$filePath,
        [string]$version,
        [array]$downloads
    )

    $yaml = Get-Content $filePath -Raw

    # 清除旧版遗留の current_version 和 top-level architecture
    $yaml = $yaml -replace '(?m)^current_version:.*\r?\n?', ''
    $yaml = $yaml -replace '(?m)^architecture:\r?\n(?:^[ \t]+.*\r?\n?)*', ''

    # 匹配现有的 current_package 整个缩进块
    $pattern = '(?m)^current_package:\r?\n(?:^[ \t]+.*\r?\n?)*'

    # 构建并拼接新的 current_package 节点
    $replacement = "current_package:`n  version: `"$version`"`n  architecture:`n"
    foreach ($d in $downloads) {
        $replacement += "    $($d.arch):`n      url: $($d.url)`n"
        if ($d.hash) {
            $replacement += "      hash: $($d.hash)`n"
        }
        else {
            $replacement += "      hash: `"`"`n"
        }
    }

    # 如果原文件没有 current_package 节点，则直接追加到末尾
    if ($yaml -match $pattern) {
        $yaml = $yaml -replace $pattern, $replacement
    }
    else {
        # 如果不是以换行符结尾，补充一个
        if (-not $yaml.EndsWith("`n")) { $yaml += "`n" }
        $yaml += $replacement
    }

    $yaml = $yaml.TrimEnd()
    $yaml | Set-Content $filePath -Encoding UTF8
}

$hasFatalError = $false
$updatesFile = "$PSScriptRoot/../updates.json"
$logFile = "$PSScriptRoot/../logs/submit-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# 确保日志目录存在
$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# 清理超过 30 天的日志文件
$maxLogAge = 30
$oldLogs = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$maxLogAge) }
if ($oldLogs) {
    $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "Cleaned up $($oldLogs.Count) old log files"
}

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

if (-not (Test-Path $updatesFile)) {
    Write-Log "No updates to process (updates.json not found)"
    exit 0
}

$updates = Get-Content $updatesFile | ConvertFrom-Json

if (-not $updates -or $updates.Count -eq 0) {
    Write-Log "No updates to process"
    exit 0
}

Write-Log "Processing $($updates.Count) updates"

foreach ($item in $updates) {
    try {
        $file = "$PSScriptRoot/../packages/$($item.file)"
        if (-not (Test-Path $file)) {
            Write-Log "Warning: Package config not found: $file"
            continue
        }

        $config = Get-Content $file | ConvertFrom-Yaml
        $id = $config.id
        $version = $item.version  # URL 解析出的格式化版本号
        $urlVersion = if ($item.PSObject.Properties['url_version']) { $item.url_version } else { $version }
        $checkverData = if ($item.PSObject.Properties['data']) { $item.data } else { $null }

        Write-Log "Checking PR existence for $id $version"
        $exists = Test-WingetPRExists $id $version
        $shouldSubmit = -not $exists
        if ($exists) {
            Write-Log "  PR already exists for $id $version, will update local config only"
        }
        else {
            Write-Log " Processing $id -> $version"
        }

        $downloads = Resolve-Download $config $version $urlVersion $checkverData
        if (-not $downloads -or $downloads.Count -eq 0) {
            Write-Log "  Warning: No download URLs found"
            continue
        }

        # 存储下载结果记录，以及临时文件路径列表
        $processedDownloads = @()
        $tempFiles = @()
        $detectedVersion = $null

        Write-Log " Starting parallel downloads for $($downloads.Count) architectures..."
        
        $downloadResults = $downloads | ForEach-Object -ThrottleLimit 5 -Parallel {
            $d = $_
            $scriptRoot = $using:PSScriptRoot
            . "$scriptRoot/calc-hash.ps1"
            
            try {
                $result = Get-InstallerHash $d.url
                return [PSCustomObject]@{
                    Success  = $true
                    url      = $d.url
                    arch     = $d.arch
                    hash     = $result.Hash
                    filePath = $result.FilePath
                }
            }
            catch {
                return [PSCustomObject]@{
                    Success = $false
                    url     = $d.url
                    arch    = $d.arch
                    Error   = $_.Exception.Message
                }
            }
        }

        foreach ($res in $downloadResults) {
            if ($res.Success) {
                $processedDownloads += [PSCustomObject]@{
                    url  = $res.url
                    arch = $res.arch
                    hash = $res.hash
                }
                $tempFiles += $res.filePath
                Write-Log "  Successfully downloaded $($res.arch): hash $($res.hash)"

                # 从下载的安装包中提取内置版本号（取第一个成功提取的）
                if (-not $detectedVersion) {
                    Write-Log "  Extracting built-in version from installer..."
                    $detectedVersion = Get-InstallerVersion $res.filePath
                    if ($detectedVersion) {
                        Write-Log "  Detected installer built-in version: $detectedVersion"
                    }
                    else {
                        Write-Log "  Could not detect built-in version from installer"
                    }
                }
            }
            else {
                Write-Log "  Error calculating hash for $($res.arch): $($res.Error)"
            }
        }

        # 清理所有临时文件
        foreach ($tmpFile in $tempFiles) {
            if (Test-Path $tmpFile) {
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
                Write-Log "  Temporary file cleaned up: $tmpFile"
            }
        }

        if ($processedDownloads.Count -eq 0) {
            Write-Log "  Error: No valid downloads after hash calculation"
            continue
        }

        # 决定 manifest 版本号
        $manifestVersion = $version  # 默认使用 URL 版本号
        $versionReplaced = $false

        # 如果配置了 version_format，则应用格式化（无论是否检测到内置版本号）
        if ($config.autoupdate.version_format) {
            # PKG 变量部分 - 优先使用检测到的版本号，如果没有则回退到 URL 版本号
            $pkgBaseVersion = if ($detectedVersion) { $detectedVersion } else { $urlVersion }
            $vParts = $pkgBaseVersion -split '\.'
            $rMajor = $vParts[0]
            $rMinor = if ($vParts.Count -gt 1) { $vParts[1] } else { "0" }
            $rPatch = if ($vParts.Count -gt 2) { $vParts[2] } else { "0" }
            $rBuild = if ($vParts.Count -gt 3) { $vParts[3] } else { "0" }
            
            # URL 变量部分
            $uParts = $urlVersion -split '\.'
            $uMajor = $uParts[0]
            $uMinor = if ($uParts.Count -gt 1) { $uParts[1] } else { "0" }
            $uPatch = if ($uParts.Count -gt 2) { $uParts[2] } else { "0" }
            $uBuild = if ($uParts.Count -gt 3) { $uParts[3] } else { "0" }
            
            $vTemplate = $config.autoupdate.version_format
            
            # 开始替换
            $manifestVersion = $vTemplate -replace '\$url_?version', $urlVersion
            $manifestVersion = $manifestVersion -replace '\$url_?major', $uMajor -replace '\$url_?minor', $uMinor -replace '\$url_?patch', $uPatch -replace '\$url_?build', $uBuild
            
            $manifestVersion = $manifestVersion -replace '\$pkg_?version', $pkgBaseVersion
            $manifestVersion = $manifestVersion -replace '\$pkg_?major', $rMajor -replace '\$pkg_?minor', $rMinor -replace '\$pkg_?patch', $rPatch -replace '\$pkg_?build', $rBuild
            
            # 兼容原有相对上下文变量 (在此上下文中，$version/$major 等始终代表原始 URL 版本)
            $manifestVersion = $manifestVersion -replace '\$version', $urlVersion
            $manifestVersion = $manifestVersion -replace '\$major', $uMajor -replace '\$minor', $uMinor -replace '\$patch', $uPatch -replace '\$build', $uBuild
            
            Write-Log "  Formatted manifest version using version_format: $manifestVersion"
        }
        elseif ($detectedVersion -and $detectedVersion -ne $version) {
            # 如果没有配置 version_format 但检测到了不同的内置版本号，则直接使用内置版本号
            $manifestVersion = $detectedVersion
            Write-Log "  No version_format found, using raw installer built-in version: $manifestVersion"
        }

        # 如果最终确定的版本号与 URL 原始格式化后的版本号不同
        if ($manifestVersion -ne $version) {
            $versionReplaced = $true
            Write-Log "  Manifest version ($manifestVersion) differs from URL version ($version)"

            # 使用新版本号再做一次 PR 存在性检查
            if ($shouldSubmit) {
                Write-Log "  Re-checking PR existence with version $manifestVersion"
                $existsWithNewVersion = Test-WingetPRExists $id $manifestVersion
                if ($existsWithNewVersion) {
                    Write-Log "  PR already exists for $id $manifestVersion, will update local config only"
                    $shouldSubmit = $false
                }
            }
        }
        else {
            Write-Log "  Final manifest version: $manifestVersion"
        }



        # 如果需要提交 PR（PR 不存在）
        if ($shouldSubmit) {
            Write-Log "  Submitting to winget-pkgs..."

            # 构建 komac 参数数组
            # komac update <package-id> --version <version> --urls <url1> <url2> ... --token <token> --submit
            $komacArgs = @(
                "update",
                $id,
                "--version", $manifestVersion,
                "--token", $env:WINGET_TOKEN,
                "--submit",
                "--created-with", "WinGet Tracker",
                "--created-with-url", "https://github.com/leic4u/winget-tracker"
            )
            # 添加 --urls 参数和所有 URL
            if ($processedDownloads.Count -eq 0) {
                Write-Log "  Error: No URLs found for package $id"
                continue
            }
            $komacArgs += "--urls"
            foreach ($pd in $processedDownloads) {
                if (-not [string]::IsNullOrWhiteSpace($pd.url)) {
                    $komacArgs += $pd.url
                }
            }

            # 添加重试机制
            $maxRetries = 3
            $retryCount = 0
            $submitSuccess = $false
            $packageNotFound = $false

            while (-not $submitSuccess -and $retryCount -lt $maxRetries) {
                try {
                    # 使用参数数组执行命令，指定完整路径
                    $komacPath = "$env:LOCALAPPDATA\Programs\Komac\bin\komac.exe"
                    if (-not (Test-Path $komacPath)) {
                        # 备用路径
                        $komacPath = "komac"  # 如果不在预期位置，尝试使用 PATH 中的
                    }
                    
                    $komacOutput = & $komacPath @komacArgs 2>&1
                    $outputStr = $komacOutput | Out-String
                    Write-Host $outputStr
                    
                    if ($LASTEXITCODE -eq 0) {
                        $submitSuccess = $true
                        Write-Log "  Successfully submitted $id $manifestVersion"

                        # 如果版本号被替换，修改 PR 标题以包含 URL 版本号
                        if ($versionReplaced) {
                            Write-Log "  Updating PR title to include URL version..."
                            try {
                                $env:GH_TOKEN = $env:WINGET_TOKEN

                                # 搜索刚刚创建的 PR
                                $searchQuery = "$id $manifestVersion"
                                $prsJson = gh pr list `
                                    --repo microsoft/winget-pkgs `
                                    --state open `
                                    --search "$searchQuery" `
                                    --author "@me" `
                                    --json number, title `
                                    2>&1

                                $prs = $prsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                                if ($prs -and $prs.Count -gt 0) {
                                    $pr = $prs[0]
                                    $newTitle = "$($pr.title) ($version)"
                                    gh pr edit $pr.number `
                                        --repo microsoft/winget-pkgs `
                                        --title "$newTitle" `
                                        2>&1
                                    Write-Log "  PR title updated to: $newTitle"
                                }
                                else {
                                    Write-Log "  Warning: Could not find the submitted PR to update title"
                                }
                            }
                            catch {
                                Write-Log "  Warning: Failed to update PR title: $_"
                            }
                            finally {
                                $env:GH_TOKEN = $null
                            }
                        }
                    }
                    else {
                        if ($outputStr -match "does not exist in microsoft/winget-pkgs") {
                            Write-Log "  Package $id does not exist in winget-pkgs. Skipping PR submission."
                            $packageNotFound = $true
                            break
                        }
                        else {
                            throw "komac exited with code $LASTEXITCODE"
                        }
                    }
                }
                catch {
                    $retryCount++
                    Write-Log "  Attempt $retryCount failed: $_"
                    if ($retryCount -lt $maxRetries) {
                        $delay = 30 * $retryCount
                        Write-Log "  Retrying in $delay seconds..."
                        Start-Sleep -Seconds $delay
                    }
                    else {
                        Write-Log "  Error: Failed after $maxRetries attempts"
                        Write-Log "  Last error: $_"
                        $hasFatalError = $true
                    }
                }
            }
        }

        # 只有在不需要提交、提交成功、或者确认包不在仓库时，才更新本地 YAML
        if (-not $shouldSubmit -or $submitSuccess -or $packageNotFound) {
            Write-Log " Updating current_package in $file"
            try {
                Update-PackageCurrentInfo -filePath $file -version $manifestVersion -downloads $processedDownloads
                Write-Log "  Successfully updated current_package"

                # 提交并推送更改到 GitHub 仓库
                Write-Log "  Committing changes to GitHub..."
                try {
                    $relativePath = $file.Replace("$PSScriptRoot/../", "").Replace("\", "/")
                    git config user.email "github-actions[bot]@users.noreply.github.com"
                    git config user.name "github-actions[bot]"
                    git add $relativePath
                    git commit -m "Update $id to $manifestVersion" -m "- Update current_package with version, urls and hashes" 2>&1
                    git push 2>&1
                    Write-Log "  Successfully pushed changes to GitHub"
                }
                catch {
                    Write-Log "  Warning: Failed to push changes to GitHub: $_"
                }
            }
            catch {
                Write-Log "  Warning: Failed to update current_package: $_"
            }
        }
    }
    catch {
        Write-Log " Error processing $($item.id): $_"
        $hasFatalError = $true
    }
}

if ($hasFatalError) {
    Write-Log "Submission process completed with fatal errors."
    exit 1
}
else {
    Write-Log "Submission process complete."
    exit 0
}
