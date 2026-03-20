function Get-VersionFromUrl($html) {
    $versions = @()
    $urls = Select-String -InputObject $html -Pattern 'https?://[^\s'']+' -AllMatches
    foreach ($u in $urls.Matches.Value) {
        if ($u -match '([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)') {
            $versions += $matches[1]
        }
    }
    if ($versions.Count -gt 0) {
        return ($versions | Sort-Object {[version]$_} -Descending)[0]
    }
}