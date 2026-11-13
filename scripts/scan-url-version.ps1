# 判断候选值是否是合理的版本号，而不是 URL 里的 IP 地址。
# 注意不能把所有「四段数字」都当成 IP：仓库里 11.3.3.2 就是真实版本号。
# 因此只拦截环回、私有、链路本地、组播以及文档示例等保留网段。
function Test-PlausibleVersion([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }

    $text = $value.Trim()
    $m = [regex]::Match($text, '^[vV]?(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
    if (-not $m.Success) { return $true }

    $a = [int]$m.Groups[1].Value
    $b = [int]$m.Groups[2].Value
    $c = [int]$m.Groups[3].Value
    $d = [int]$m.Groups[4].Value
    if ($a -gt 255 -or $b -gt 255 -or $c -gt 255 -or $d -gt 255) { return $true }

    # 0.0.0.0/8、10.0.0.0/8、127.0.0.0/8、224.0.0.0/4 及以上
    if ($a -eq 0 -or $a -eq 10 -or $a -eq 127 -or $a -ge 224) { return $false }
    # 169.254.0.0/16 链路本地
    if ($a -eq 169 -and $b -eq 254) { return $false }
    # 172.16.0.0/12 私有
    if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $false }
    # 192.168.0.0/16 私有
    if ($a -eq 192 -and $b -eq 168) { return $false }
    # 文档示例网段 192.0.2.0/24、198.51.100.0/24、203.0.113.0/24
    if ($a -eq 192 -and $b -eq 0 -and $c -eq 2) { return $false }
    if ($a -eq 198 -and $b -eq 51 -and $c -eq 100) { return $false }
    if ($a -eq 203 -and $b -eq 0 -and $c -eq 113) { return $false }

    return $true
}

function Get-VersionFromUrl($html) {
    $versions = @()
    $urls = Select-String -InputObject $html -Pattern 'https?://[^\s''"]+' -AllMatches
    foreach ($u in $urls.Matches.Value) {
        # 先单独取出主机名判断是否为 IP。不能依赖 URL 的结尾字符：
        # HTML 里的 URL 后面常跟标签或字面转义（例如 http://127.0.0.1:8888\n），
        # 旧写法要求 IP 后面紧跟 / 或字符串结尾，这种情况下会漏判。
        $authority = (($u -replace '^https?://', '') -split '[/?#\\]', 2)[0]
        if ($authority -match '^(\d{1,3}\.){3}\d{1,3}(:\d+)?$') {
            continue
        }

        $pathPortion = $u -replace '^https?://[^/]+/', ''
        if ($pathPortion -match '([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)') {
            $candidate = $matches[1]

            # 兜底：候选值本身像环回 / 私有 IP 时忽略，避免被版本比较判成「极高版本」
            if (-not (Test-PlausibleVersion $candidate)) {
                continue
            }

            $versions += $candidate
        }
    }
    if ($versions.Count -gt 0) {
        # 用 @() 包裹，避免只有一个候选时 [0] 被当成字符串取首字符
        return @($versions | Sort-Object { [version]$_ } -Descending)[0]
    }
}