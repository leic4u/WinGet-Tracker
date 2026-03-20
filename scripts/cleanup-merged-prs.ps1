# 使用 komac cleanup 命令清理已合并的 PR 分支
# komac 会自动处理 fork 仓库中已合并或关闭的 PR 分支

# 检查是否设置了 WINGET_TOKEN
if (-not $env:WINGET_TOKEN) {
    Write-Host "Warning: WINGET_TOKEN not set, skipping PR cleanup" -ForegroundColor Yellow
    exit 0
}

try {
    Write-Host "Cleaning up merged/closed PR branches using komac..." -ForegroundColor Cyan
    
    # 使用 komac 的绝对路径（与 submit-winget.ps1 相同的逻辑）
    $komacPath = "$env:LOCALAPPDATA\Programs\Komac\bin\komac.exe"
    if (-not (Test-Path $komacPath)) {
        # 备用路径：如果不在预期位置，尝试使用 PATH 中的
        $komacPath = "komac"
        # 再次检查是否可用
        if (-not (Get-Command $komacPath -ErrorAction SilentlyContinue)) {
            Write-Host "Error: komac command not found. Please install komac." -ForegroundColor Red
            exit 1
        }
    }
    
    # 使用 komac cleanup 命令自动删除所有已合并/关闭的 PR 分支
    # --all 参数用于在 CI 环境中自动确认删除
    & $komacPath cleanup --all --token $env:WINGET_TOKEN 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Cleanup completed successfully" -ForegroundColor Green
    } else {
        Write-Host "Cleanup completed with warnings or errors" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Error during PR cleanup: $_" -ForegroundColor Red
    exit 1
}