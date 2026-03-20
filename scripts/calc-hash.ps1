function Get-InstallerHash {
    param(
        [string]$url
    )
    
    # 生成唯一的临时文件名（带扩展名）
    $tmp = Join-Path $env:TEMP "winget-$([guid]::NewGuid()).tmp"
    
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
        return $hash.Hash
    } finally {
        # 确保临时文件被清理
        if (Test-Path $tmp) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Write-Host "  Temporary file cleaned up"
        }
    }
}
