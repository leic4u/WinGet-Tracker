function Get-VersionFromFilename($url) {
    $file = Split-Path $url -Leaf
    if ($file -match "([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)") {
        return $matches[1]
    }
}
