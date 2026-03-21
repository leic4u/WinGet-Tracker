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
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Write-Warning "  Download failed, retrying ($retryCount/$maxRetries): $_"
                    Start-Sleep -Seconds (5 * $retryCount)  # 指数退避
                } else {
                    throw "Failed to download after $maxRetries attempts: $_"
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
