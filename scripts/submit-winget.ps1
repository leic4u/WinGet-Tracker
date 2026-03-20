Import-Module powershell-yaml
. "$PSScriptRoot/resolve-download.ps1"
. "$PSScriptRoot/calc-hash.ps1"
. "$PSScriptRoot/check-existing-pr.ps1"

# 函数：更新 YAML 文件中的 current_package 信息
function Update-PackageCurrentInfo {
    param(
        [string]$filePath,
        [string]$version,
        [array]$downloads
    )

    $yaml = Get-Content $filePath -Raw
    $yamlLines = $yaml -split "`r?`n"
    $newLines = @()
    $i = 0

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
                if ($nextLine.Trim() -ne '' -and $nextIndent -le $currentPackageIndent) {
                    break
                }
                $i++
            }
            # 添加新的 current_package 部分
            $newLines += "current_package:"
            $newLines += "  version: `"$version`""
            $newLines += "  architecture:"
            # 添加下载信息
            foreach ($d in $downloads) {
                $archName = $d.arch
                $newLines += "    ${archName}:"
                $newLines += "      url: $($d.url)"
                # 如果 downloads 中有 hash 信息，使用它
                if ($d.hash) {
                    $newLines += "      hash: $($d.hash)"
                } else {
                    $newLines += '      hash: ""'
                }
            }
            continue
        }

        # 跳过旧的 current_version 和 architecture（顶层）
        if ($line -match '^(current_version|architecture):') {
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
        $version = $item.version

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

        $urlParts = @()
        foreach ($d in $downloads) {
            Write-Log " Downloading $($d.url) for hash calculation..."
            try {
                $hash = Get-InstallerHash $d.url
                # 格式：URL|架构|哈希
                $urlParts += "$($d.url)|$($d.arch)|$($hash)"
                Write-Log "  Hash: $hash"
            } catch {
                Write-Log "  Error calculating hash: $_"
                continue
            }
        }

        if ($urlParts.Count -eq 0) {
            Write-Log "  Error: No valid downloads after hash calculation"
            continue
        }

        # 构建 downloads 数组（包含 hash）用于更新本地配置
        $downloadsWithHash = @()
        for ($j = 0; $j -lt $downloads.Count; $j++) {
            $d = $downloads[$j]
            $hash = $urlParts[$j].Split('|')[2]
            $downloadsWithHash += [PSCustomObject]@{
                arch = $d.arch
                url  = $d.url
                hash = $hash
            }
        }

        # 如果需要提交 PR（PR 不存在）
        if ($shouldSubmit) {
            Write-Log "  Submitting to winget-pkgs..."

            # 构建 komac 参数数组
            # komac update <package-id> --version <version> --urls <url1> <url2> ... --token <token> --submit
            $komacArgs = @(
                "update",
                $id,
                "--version", $version,
                "--token", $env:WINGET_TOKEN,
                "--submit",
                "--created-with", "WinGet Tracker",
                "--created-with-url", "https://github.com/leic4u/winget-tracker"
            )
            # 添加 --urls 参数和所有 URL
            if ($urlParts.Count -eq 0) {
                Write-Log "  Error: No URLs found for package $id"
                continue
            }
            $komacArgs += "--urls"
            foreach ($urlPart in $urlParts) {
                $url = ($urlPart -split '\|')[0]
                if (-not [string]::IsNullOrWhiteSpace($url)) {
                    $komacArgs += $url
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
                        Write-Log "  Successfully submitted $id $version"
                        
                        # 只有在真正需要提交新 PR 时才创建本地分支
                        # 如果 komac 检测到已存在的 PR，它会成功退出但不会创建新 PR
                        # 在这种情况下，我们不应该创建本地分支
                        if ($shouldSubmit) {
                            # 创建本地 branch for PR tracking
                            $prBranchName = "${id}-v${version}"
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
                Update-PackageCurrentInfo -filePath $file -version $version -downloads $downloadsWithHash
                Write-Log "  Successfully updated current_package"

                # 提交并推送更改到 GitHub 仓库
                Write-Log "  Committing changes to GitHub..."
                try {
                    $relativePath = $file.Replace("$PSScriptRoot/../", "").Replace("\", "/")
                    git config user.email "github-actions[bot]@users.noreply.github.com"
                    git config user.name "github-actions[bot]"
                    git add $relativePath
                    git commit -m "Update $id to $version" -m "- Update current_package with version, urls and hashes" 2>&1
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
