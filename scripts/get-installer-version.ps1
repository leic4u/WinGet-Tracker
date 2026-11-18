# 从安装包文件中提取内置版本号
# 支持 EXE、MSI、MSIX/APPX 格式
# 如果无法提取则返回 $null

function Get-InstallerVersion {
    param(
        [string]$filePath
    )

    if (-not (Test-Path $filePath)) {
        Write-Warning "  File not found: $filePath"
        return $null
    }

    $extension = [System.IO.Path]::GetExtension($filePath).ToLower()
    $version = $null

    switch ($extension) {
        { $_ -in '.exe', '.tmp' } {
            $version = Get-ExeVersion $filePath
        }
        '.msi' {
            $version = Get-MsiVersion $filePath
        }
        { $_ -in '.msix', '.appx' } {
            $version = Get-MsixVersion $filePath
        }
        default {
            # 尝试用 EXE 方式提取（临时文件可能没有正确扩展名）
            $version = Get-ExeVersion $filePath
            if (-not $version) {
                Write-Host "  Unsupported file type for version extraction: $extension"
            }
        }
    }

    # 统一规范化：子函数返回的可能是带前后空白的字符串（如 MSI Property），
    # 必须 Trim 后再交给版本比较与提交，避免 " 1.2.3" 被当成不同于 "1.2.3"。
    if ($version) {
        $version = ([string]$version).Trim()
    }
    return $version
}

function Get-ExeVersion {
    param([string]$filePath)

    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($filePath)

        # 优先使用 ProductVersion（通常包含完整版本信息，如 0.8.92+2026020201）
        if ($versionInfo.ProductVersion -and $versionInfo.ProductVersion.Trim() -ne '') {
            $version = $versionInfo.ProductVersion.Trim()
            Write-Host "  Detected EXE ProductVersion: $version"
            return $version
        }

        # 回退到 FileVersion
        if ($versionInfo.FileVersion -and $versionInfo.FileVersion.Trim() -ne '') {
            $version = $versionInfo.FileVersion.Trim()
            Write-Host "  Detected EXE FileVersion: $version"
            return $version
        }

        Write-Host "  No version info found in EXE"
        return $null
    }
    catch {
        Write-Warning "  Failed to extract EXE version: $_"
        return $null
    }
}

function Get-MsiVersion {
    param([string]$filePath)

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember(
            'OpenDatabase',
            'InvokeMethod',
            $null,
            $installer,
            @($filePath, 0)  # 0 = msiOpenDatabaseModeReadOnly
        )

        $query = "SELECT Value FROM Property WHERE Property = 'ProductVersion'"
        $view = $database.GetType().InvokeMember(
            'OpenView',
            'InvokeMethod',
            $null,
            $database,
            @($query)
        )

        # Execute 无返回值，但 InvokeMember 会把 $null 写进函数输出管道，
        # 导致 Get-InstallerVersion 返回 @($null, $version)，字符串化后出现前导空格。
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)

        $record = $view.GetType().InvokeMember(
            'Fetch',
            'InvokeMethod',
            $null,
            $view,
            $null
        )

        if ($record) {
            $version = $record.GetType().InvokeMember(
                'StringData',
                'GetProperty',
                $null,
                $record,
                @(1)
            )
            Write-Host "  Detected MSI ProductVersion: $version"

            # 释放 COM 对象
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($record) | Out-Null
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($view) | Out-Null
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($database) | Out-Null
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null

            return $version
        }

        Write-Host "  No ProductVersion found in MSI"
        return $null
    }
    catch {
        Write-Warning "  Failed to extract MSI version: $_"
        return $null
    }
}

function Get-MsixVersion {
    param([string]$filePath)

    try {
        # MSIX/APPX 是 ZIP 格式，解压读取 AppxManifest.xml
        $tempDir = Join-Path $env:TEMP "winget-msix-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($filePath)

            $manifest = $zip.Entries | Where-Object { $_.Name -eq 'AppxManifest.xml' } | Select-Object -First 1
            if ($manifest) {
                $manifestPath = Join-Path $tempDir 'AppxManifest.xml'
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($manifest, $manifestPath, $true)

                [xml]$xml = Get-Content $manifestPath -Raw
                $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                $ns.AddNamespace('ns', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')

                $identity = $xml.SelectSingleNode('//ns:Identity', $ns)
                if ($identity -and $identity.GetAttribute('Version')) {
                    $version = $identity.GetAttribute('Version')
                    Write-Host "  Detected MSIX Version: $version"
                    return $version
                }
            }

            Write-Host "  No AppxManifest.xml found in MSIX"
            return $null
        }
        finally {
            if ($zip) { $zip.Dispose() }
            if (Test-Path $tempDir) {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Warning "  Failed to extract MSIX version: $_"
        return $null
    }
}
