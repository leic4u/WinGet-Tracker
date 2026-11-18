function Get-DownloadErrorText {
    param($ErrorRecord, [int]$MaxLength = 160)

    # Invoke-WebRequest 遇到 404/403 时会把整个 HTML 响应体塞进 ErrorRecord，
    # 直接写日志会让单个 run 膨胀到几百 KB。这里只保留简洁的错误摘要。
    $message = if ($ErrorRecord -and $ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    $text = ($message -split "`r?`n")[0].Trim()

    $statusCode = $null
    try {
        if ($ErrorRecord.Exception.Response) {
            $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
        }
    } catch { }

    if ($text -match '<!DOCTYPE|<html|Page not found') {
        $text = "response body omitted"
    }
    if ($statusCode) {
        $text = "HTTP $statusCode $text"
    }
    if (-not $text) { $text = "unknown error" }
    if ($text.Length -gt $MaxLength) {
        $text = $text.Substring(0, $MaxLength) + "..."
    }
    return $text
}

function Test-IsNotFoundResponse {
    param($ErrorRecord)

    try {
        if ($ErrorRecord.Exception.Response -and [int]$ErrorRecord.Exception.Response.StatusCode -eq 404) {
            return $true
        }
    } catch { }

    $message = if ($ErrorRecord.Exception) { [string]$ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    return ($message -match '\(404\)|404 Not Found')
}

function Get-InstallerHash {
    param(
        [string]$url
    )
    
    # 根据 URL 推断文件扩展名，保留正确的扩展名以便后续版本提取
    $urlExtension = ""
    if ($url -match '\.([a-zA-Z0-9]+)(\?.*)?$') {
        $urlExtension = ".$($matches[1].ToLower())"
    }
    if (-not $urlExtension -or $urlExtension -eq ".") {
        $urlExtension = ".tmp"
    }

    # 生成唯一的临时文件名（带正确扩展名）
    $tmp = Join-Path $env:TEMP "winget-$([guid]::NewGuid())$urlExtension"
    
    try {
        # 添加重试机制
        $maxRetries = 3
        $retryCount = 0
        $success = $false
        
        while (-not $success -and $retryCount -lt $maxRetries) {
            try {
                Write-Host "  Downloading from: $url (Attempt $($retryCount + 1)/$maxRetries)"
                Invoke-WebRequest $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
                $success = $true
            } catch {
                $errorText = Get-DownloadErrorText $_

                # 404 通常是 release 已发布但资产尚未上传完成，短时间内重试没有意义。
                # 直接失败，由调用方整批跳过，等下一轮定时任务资产齐了再处理。
                if (Test-IsNotFoundResponse $_) {
                    throw "Asset not found (404), likely still uploading: $errorText"
                }

                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Write-Warning "  Download failed, retrying ($retryCount/$maxRetries): $errorText"
                    Start-Sleep -Seconds (5 * $retryCount)  # 指数退避
                } else {
                    throw "Failed to download after $maxRetries attempts: $errorText"
                }
            }
        }
        
        Write-Host "  Calculating SHA256 hash..."
        $hash = Get-FileHash $tmp -Algorithm SHA256

        # 返回哈希值和临时文件路径，调用方负责清理临时文件
        return [PSCustomObject]@{
            Hash     = $hash.Hash
            FilePath = $tmp
        }
    } catch {
        # 出错时清理临时文件
        if (Test-Path $tmp) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}
