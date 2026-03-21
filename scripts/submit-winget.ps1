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
        } else {
            $replacement += "      hash: `"`"`n"
        }
    }

    # 如果原文件没有 current_package 节点，则直接追加到末尾
    if ($yaml -match $pattern) {
        $yaml = $yaml -replace $pattern, $replacement
    } else {
        # 如果不是以换行符结尾，补充一个
        if (-not $yaml.EndsWith("`n")) { $yaml += "`n" }
        $yaml += $replacement
    }

    $yaml | Set-Content $filePath -Encoding UTF8
}

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
        $version = $item.version  # URL 解析出的版本号

        Write-Log "Checking PR existence for $id $version"
        $exists = Test-WingetPRExists $id $version
        $shouldSubmit = -not $exists
        if ($exists) {
            Write-Log "  PR already exists for $id $version, will update local config only"
        } else {
            Write-Log " Processing $id -> $version"
        }

        $downloads = Resolve-Download $config $version
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
                    Success = $true
                    url = $d.url
                    arch = $d.arch
                    hash = $result.Hash
                    filePath = $result.FilePath
                }
            } catch {
                return [PSCustomObject]@{
                    Success = $false
                    url = $d.url
                    arch = $d.arch
                    Error = $_.Exception.Message
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
                    } else {
                        Write-Log "  Could not detect built-in version from installer"
                    }
                }
            } else {
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

        # 决定 manifest 版本号：优先使用安装包内置版本号
        $manifestVersion = $version  # 默认使用 URL 版本号
        $versionReplaced = $false
        if ($detectedVersion -and $detectedVersion -ne $version) {
            $manifestVersion = $detectedVersion
            $versionReplaced = $true
            Write-Log "  Using installer built-in version: $manifestVersion (URL version: $version)"

            # 使用内置版本号再做一次 PR 存在性检查
            if ($shouldSubmit) {
                Write-Log "  Re-checking PR existence with built-in version $manifestVersion"
                $existsWithBuiltIn = Test-WingetPRExists $id $manifestVersion
                if ($existsWithBuiltIn) {
                    Write-Log "  PR already exists for $id $manifestVersion, will update local config only"
                    $shouldSubmit = $false
                }
            }
        } else {
            Write-Log "  Using URL version as manifest version: $manifestVersion"
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

            while (-not $submitSuccess -and $retryCount -lt $maxRetries) {
                try {
                    # 使用参数数组执行命令，指定完整路径
                    $komacPath = "$env:LOCALAPPDATA\Programs\Komac\bin\komac.exe"
                    if (-not (Test-Path $komacPath)) {
                        # 备用路径
                        $komacPath = "komac"  # 如果不在预期位置，尝试使用 PATH 中的
                    }
                    & $komacPath @komacArgs 2>&1

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
                                    --json number,title `
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
                                } else {
                                    Write-Log "  Warning: Could not find the submitted PR to update title"
                                }
                            } catch {
                                Write-Log "  Warning: Failed to update PR title: $_"
                            } finally {
                                $env:GH_TOKEN = $null
                            }
                        }
                        
                        # 只有在真正需要提交新 PR 时才创建本地分支
                        # 如果 komac 检测到已存在的 PR，它会成功退出但不会创建新 PR
                        # 在这种情况下，我们不应该创建本地分支
                        if ($shouldSubmit) {
                            # 创建本地 branch for PR tracking
                            $prBranchName = "${id}-v${manifestVersion}"
                            try {
                                git checkout -b $prBranchName 2>&1
                                git push origin $prBranchName 2>&1
                                Write-Log "  Created local branch: $prBranchName"
                            } catch {
                                Write-Log "  Warning: Failed to create local branch: $_"
                                # 回到 main branch
                                git checkout main 2>&1
                            }
                        }
                    } else {
                        throw "komac exited with code $LASTEXITCODE"
                    }
                } catch {
                    $retryCount++
                    Write-Log "  Attempt $retryCount failed: $_"
                    if ($retryCount -lt $maxRetries) {
                        $delay = 30 * $retryCount
                        Write-Log "  Retrying in $delay seconds..."
                        Start-Sleep -Seconds $delay
                    } else {
                        Write-Log "  Error: Failed after $maxRetries attempts"
                        Write-Log "  Last error: $_"
                    }
                }
            }
        }

        # 如果 PR 已存在或提交成功，则更新本地 YAML 配置
        if (-not $shouldSubmit -or $submitSuccess) {
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
                } catch {
                    Write-Log "  Warning: Failed to push changes to GitHub: $_"
                }
            } catch {
                Write-Log "  Warning: Failed to update current_package: $_"
            }
        }
    } catch {
        Write-Log " Error processing $($item.id): $_"
    }
}

Write-Log "Submission process complete"
