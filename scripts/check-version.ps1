if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Error "Required module 'powershell-yaml' is not installed. Install it with: Install-Module powershell-yaml -Scope CurrentUser -Force"
    exit 1
}

Import-Module powershell-yaml

. "$PSScriptRoot/resolve-version.ps1"
. "$PSScriptRoot/scan-url-version.ps1"
. "$PSScriptRoot/resolve-download.ps1"
. "$PSScriptRoot/calc-hash.ps1"

function Compare-Versions {
    param(
        [string]$v1,
        [string]$v2
    )

    $v1 = $v1.Trim() -replace '^v', ''
    $v2 = $v2.Trim() -replace '^v', ''

    if ($v1 -eq $v2) { return $false }

    $parts1 = [regex]::Matches($v1, '\d+|[A-Za-z]+') | ForEach-Object { $_.Value }
    $parts2 = [regex]::Matches($v2, '\d+|[A-Za-z]+') | ForEach-Object { $_.Value }

    $maxCount = [Math]::Max($parts1.Count, $parts2.Count)
    
    for ($i = 0; $i -lt $maxCount; $i++) {
        $p1 = if ($i -lt $parts1.Count) { $parts1[$i] } else { "" }
        $p2 = if ($i -lt $parts2.Count) { $parts2[$i] } else { "" }

        if ($p1 -eq $p2) { continue }

        $isNum1 = [int]::TryParse($p1, [ref]$null)
        $isNum2 = [int]::TryParse($p2, [ref]$null)

        if ($isNum1 -and $isNum2) {
            $diff = [int]$p1 - [int]$p2
            if ($diff -ne 0) { return $diff -gt 0 }
        }
        elseif ($isNum1 -and -not $isNum2) {
            if ($p2 -eq "") {
                if ([int]$p1 -eq 0) { continue }
                return [int]$p1 -gt 0
            }
            return $true 
        }
        elseif (-not $isNum1 -and $isNum2) {
            if ($p1 -eq "") {
                if ([int]$p2 -eq 0) { continue }
                return $false
            }
            return $false
        }
        else {
            if ($p1 -eq "") { return $true }
            if ($p2 -eq "") { return $false }
            $diff = [string]::Compare($p1, $p2, $true)
            if ($diff -ne 0) { return $diff -gt 0 }
        }
    }
    
    return $false
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

$funcCompare = ${function:Compare-Versions}.ToString()

$parallelResults = $packages | ForEach-Object -ThrottleLimit 5 -Parallel {
    $pkg = $_
    $pkgName = $pkg.BaseName
    $currentId = $pkgName
    $threadLogs = New-Object System.Collections.Generic.List[string]
    function Write-ThreadLog($message, $level = 'INFO') {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $threadLogs.Add("[$timestamp] [$currentId] [$level] $message")
    }

    # 覆盖标准输出命令，将其捕获到我们的线程日志中
    function Write-Host {
        param([Parameter(ValueFromRemainingArguments)]$Object)
        if ($null -ne $Object) { Write-ThreadLog -message ($Object -join " ") -level "INFO" }
    }
    function Write-Warning {
        param([string]$Message)
        Write-ThreadLog -message $Message -level "WARNING"
    }
    function Write-Error {
        param($Message)
        $msg = if ($Message -is [System.Management.Automation.ErrorRecord]) { $Message.Exception.Message } else { $Message }
        Write-ThreadLog -message $msg -level "ERROR"
    }

    $scriptRoot = $using:PSScriptRoot
    Set-Item -Path "Function:\Compare-Versions" -Value ([scriptblock]::Create($using:funcCompare))

    Import-Module powershell-yaml -ErrorAction SilentlyContinue
    . "$scriptRoot/resolve-version.ps1"
    . "$scriptRoot/scan-url-version.ps1"
    . "$scriptRoot/resolve-download.ps1"

    $update = $null
    $threadHasError = $false

    try {
        $config = Get-Content $pkg | ConvertFrom-Yaml
        $id = $config.id
        if ($id) { $currentId = $id }

        Write-ThreadLog "Checking $id" -level "INFO"

        $currentVersion = if ($config.current_package -and $config.current_package.version) { $config.current_package.version } elseif ($config.current_version) { $config.current_version } else { "0.0.0" }
        Write-ThreadLog " Current version (from config): $currentVersion" -level "INFO"

        $versionResult = Resolve-Version $config
        if ($versionResult -is [System.Management.Automation.PSCustomObject] -and $null -ne $versionResult.Version) {
            $version = $versionResult.Version
            $urlVersion = if ($versionResult.PSObject.Properties['UrlVersion']) { $versionResult.UrlVersion } else { $version }
            $checkverData = $versionResult.Data
        } else {
            $version = $versionResult
            $urlVersion = $version
            $checkverData = $null
        }

        if (-not $version) {
            try {
                Write-ThreadLog " Primary version check failed, trying fallback..." -level "WARNING"
                $html = Invoke-WebRequest $config.checkver.url -UseBasicParsing -ErrorAction Stop
                $version = Get-VersionFromUrl $html.Content
            }
            catch {
                Write-ThreadLog " Warning: Failed to scan URL for version: $_" -level "WARNING"
            }
        }

        if (-not $version) {
            Write-ThreadLog " Skipped: Could not determine version" -level "ERROR"
        }
        else {
            Write-ThreadLog " Remote version: $version" -level "INFO"
            Write-ThreadLog " Comparing versions: current='$currentVersion' vs remote='$version'" -level "INFO"

            if (Compare-Versions -v1 $version -v2 $currentVersion) {
                # 检查解析后的 URL 是否与当前 URL 匹配，以避免重复更新
                $isUrlMatching = $false
                if ($config.autoupdate -and $config.autoupdate.architecture -and $config.current_package -and $config.current_package.architecture) {
                    try {
                        $resolvedUrls = Resolve-Download $config $version $urlVersion $checkverData
                        $hasVariables = $false
                        $allMatch = $true
                        $checkedCount = 0
                        
                        foreach ($rUrl in $resolvedUrls) {
                            $arch = $rUrl.arch
                            $template = $config.autoupdate.architecture.$arch
                            $templateUrl = if ($template -is [string]) { $template } else { $template.url }
                            
                            # 检查通用版本变量
                            if ($templateUrl -match '\$(version|major|minor|patch|build|url[Vv]ersion|url[Mm]ajor|url[Mm]inor|url[Pp]atch|url[Bb]uild)') {
                                $hasVariables = $true
                                # 保护架构属性访问的安全措施
                                $currentArch = if ($config.current_package.architecture -is [System.Collections.IDictionary]) { $config.current_package.architecture[$arch] } else { $config.current_package.architecture.$arch }
                                $currentUrl = if ($currentArch -is [System.Collections.IDictionary]) { $currentArch['url'] } else { $currentArch.url }
                                
                                if ($currentUrl) {
                                    $checkedCount++
                                    if ($rUrl.url -ne $currentUrl) {
                                        $allMatch = $false
                                        break
                                    }
                                } else {
                                    $allMatch = $false
                                    break
                                }
                            }
                        }
                        
                        if ($hasVariables -and $allMatch -and $checkedCount -gt 0) {
                            $isUrlMatching = $true
                        }
                    } catch {
                        Write-ThreadLog " Warning: Failed to resolve download URL for matching check: $_" -level "WARNING"
                    }
                }

                if ($isUrlMatching) {
                    Write-ThreadLog " Skipping update: Resolved URL matches current URL even though version string differs" -level "INFO"
                } else {
                    $update = [PSCustomObject]@{
                        id          = $id
                        version     = $version
                        url_version = $urlVersion
                        file        = $pkg.Name
                        data        = $checkverData
                    }
                    Write-ThreadLog " UPDATE AVAILABLE: $currentVersion -> $version" -level "WARNING"
                }
            }
            else {
                Write-ThreadLog " Up to date" -level "INFO"
            }
        }
    }
    catch {
        $threadHasError = $true
        Write-ThreadLog " Error processing $($pkg.Name): $_" -level "ERROR"
    }

    return [PSCustomObject]@{
        Logs     = $threadLogs.ToArray()
        Update   = $update
        HasError = $threadHasError
    }
}

foreach ($res in $parallelResults) {
    if ($res.HasError) { $hasError = $true }
    if ($null -ne $res.Update) { $result += $res.Update }
    
    foreach ($log in $res.Logs) {
        if ($log -match '\[INFO\]') { Write-Host $log -ForegroundColor Green }
        elseif ($log -match '\[WARNING\]') { Write-Host $log -ForegroundColor Yellow }
        elseif ($log -match '\[ERROR\]') { Write-Host $log -ForegroundColor Red }
        Add-Content -Path $logFile -Value $log
    }
}

Write-Log "Check complete. Found $($result.Count) updates."

if ($result.Count -gt 0) {
    $outputPath = "$PSScriptRoot/../updates.json"
    $result | ConvertTo-Json -Depth 10 | Out-File $outputPath -Encoding UTF8
    Write-Log "Results saved to $outputPath" -level "INFO"
    $result | Format-Table -AutoSize
    Write-Log "Updates found, exiting with code 0 for further processing" -level "INFO"
}
else {
    Write-Log "No updates found, exiting normally" -level "INFO"
}

if ($hasError) {
    Write-Log "One or more errors occurred during check-version" -level "ERROR"
    exit 1
}

exit 0