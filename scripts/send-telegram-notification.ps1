<#
.SYNOPSIS
    通过 Telegram Bot 发送 WinGet Tracker 运行报告。

.DESCRIPTION
    读取 check-version.ps1 / submit-winget.ps1 生成的 notification.json，
    汇总「检查到新版本」「已提交 PR」「已存在 PR」「提交出错」等信息，并发送到 Telegram。

    发送方式（自动降级）：
      1. sendRichMessage + Rich Markdown（兼容 GFM，支持真正的表格语法 | a | b |）
      2. sendMessage + MarkdownV2（等宽代码块对齐列宽模拟表格）
      3. sendMessage 纯文本

    需要以下环境变量（GitHub Actions 中通过 Secrets 注入）：
      TG_BOT  - Telegram Bot Token
      TG_USER - 消息接收者的 Chat ID

    需要 PowerShell 5.1+（推荐 PowerShell 7）。

.PARAMETER ReportFile
    运行报告文件路径，默认 <仓库根目录>/notification.json。

.PARAMETER BotToken
    Telegram Bot Token，默认取环境变量 TG_BOT。

.PARAMETER ChatId
    消息接收者 Chat ID，默认取环境变量 TG_USER。

.PARAMETER RichMessageMaxLength
    富文本消息单条最大长度（Bot API 限制 32768 字符）。

.PARAMETER LegacyMaxLength
    传统 sendMessage 单条最大长度（Bot API 限制 4096 字符）。

.PARAMETER NoRichMessage
    跳过 sendRichMessage，直接使用 MarkdownV2 代码块表格发送。

.PARAMETER DryRun
    只打印将要发送的消息内容，不实际发送。

.EXAMPLE
    ./scripts/send-telegram-notification.ps1

.EXAMPLE
    ./scripts/send-telegram-notification.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$ReportFile,
    [string]$BotToken = $env:TG_BOT,
    [string]$ChatId = $env:TG_USER,
    [int]$RichMessageMaxLength = 30000,
    [int]$LegacyMaxLength = 3800,
    [switch]$NoRichMessage,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not $ReportFile) {
    $ReportFile = "$PSScriptRoot/../notification.json"
}

# ==================== 通用工具 ====================

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = ""
    )

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return $property.Value
}

function Get-SafeText {
    param([object]$Value)

    if ($null -eq $Value) { return "" }
    return ([string]$Value).Trim()
}

function Format-CellValue {
    param(
        [string]$Text,
        [string]$Fallback = '-'
    )

    $value = Get-SafeText $Text
    if (-not $value) { return $Fallback }
    return $value
}

function Limit-Text {
    param(
        [string]$Text,
        [int]$MaxLength = 300
    )

    $value = Get-SafeText $Text
    if ($value.Length -le $MaxLength) { return $value }
    return $value.Substring(0, $MaxLength) + "..."
}

function Get-DisplayWidth {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return 0 }

    $width = 0
    foreach ($char in $Text.ToCharArray()) {
        $code = [int]$char
        $isWide = ($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)

        if ($isWide) { $width += 2 } else { $width += 1 }
    }

    return $width
}

function Format-PaddedCell {
    param(
        [string]$Text,
        [int]$Width
    )

    $current = Get-DisplayWidth $Text
    if ($current -ge $Width) { return $Text }
    return $Text + (' ' * ($Width - $current))
}

# ==================== 转义处理 ====================

function Format-RichMarkdownInline {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return "" }

    # 表格单元格内不能包含换行
    $value = ($Text -replace "\r?\n", " ").Trim()

    # Rich Markdown 兼容 GFM：反斜杠转义 ASCII 标点。
    # 这里只转义真正会影响解析的字符（保留 URL 中的 : / ? = & 等，避免破坏自动链接）
    $specialChars = '\`*_~[]<>|'

    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $value.ToCharArray()) {
        if ($specialChars.IndexOf($char) -ge 0) {
            [void]$builder.Append('\')
        }
        [void]$builder.Append($char)
    }

    return $builder.ToString()
}

function ConvertTo-MarkdownV2Escaped {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return "" }

    # MarkdownV2 需要转义的特殊字符
    $specialChars = '_*[]()~`>#+-=|{}.!\'

    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Text.ToCharArray()) {
        if ($specialChars.IndexOf($char) -ge 0) {
            [void]$builder.Append('\')
        }
        [void]$builder.Append($char)
    }

    return $builder.ToString()
}

function ConvertTo-CodeBlockText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return "" }

    # 代码块中只需转义反斜杠和反引号
    return $Text.Replace('\', '\\').Replace('`', '\`')
}

function ConvertFrom-MarkdownV2 {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return "" }

    $plain = $Text -replace '(?m)^\s*```\s*$', ''
    $specialChars = '_*[]()~`>#+-=|{}.!\'

    $builder = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt $plain.Length; $index++) {
        $char = $plain[$index]
        if ($char -eq '\' -and ($index + 1) -lt $plain.Length -and $specialChars.IndexOf($plain[$index + 1]) -ge 0) {
            continue
        }
        [void]$builder.Append($char)
    }

    return $builder.ToString()
}

# ==================== 表格渲染 ====================

function Format-AlignedTable {
    param(
        [string[]]$Headers,
        [object[]]$Rows
    )

    $columnCount = $Headers.Count
    $widths = New-Object System.Collections.Generic.List[int]

    for ($column = 0; $column -lt $columnCount; $column++) {
        $width = Get-DisplayWidth $Headers[$column]
        foreach ($row in $Rows) {
            if ($column -lt $row.Count) {
                $cellWidth = Get-DisplayWidth ([string]$row[$column])
                if ($cellWidth -gt $width) { $width = $cellWidth }
            }
        }
        $widths.Add($width)
    }

    $lines = New-Object System.Collections.Generic.List[string]

    $headerCells = New-Object System.Collections.Generic.List[string]
    $separatorCells = New-Object System.Collections.Generic.List[string]
    for ($column = 0; $column -lt $columnCount; $column++) {
        $headerCells.Add((Format-PaddedCell -Text $Headers[$column] -Width $widths[$column]))
        $separatorCells.Add(('-' * $widths[$column]))
    }
    $lines.Add(($headerCells -join '  '))
    $lines.Add(($separatorCells -join '  '))

    foreach ($row in $Rows) {
        $cells = New-Object System.Collections.Generic.List[string]
        for ($column = 0; $column -lt $columnCount; $column++) {
            $cellText = if ($column -lt $row.Count) { [string]$row[$column] } else { "" }
            if ($column -eq $columnCount - 1) {
                $cells.Add($cellText)
            } else {
                $cells.Add((Format-PaddedCell -Text $cellText -Width $widths[$column]))
            }
        }
        $lines.Add(($cells -join '  '))
    }

    return ($lines -join "`n")
}

function New-RichTableText {
    param(
        [string]$Title,
        [string[]]$Headers,
        [object[]]$Rows
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("### " + (Format-RichMarkdownInline $Title))

    $headerCells = @($Headers | ForEach-Object { Format-RichMarkdownInline $_ })
    $lines.Add("| " + ($headerCells -join " | ") + " |")
    $lines.Add("|" + (($Headers | ForEach-Object { ":---" }) -join "|") + "|")

    foreach ($row in $Rows) {
        $cells = New-Object System.Collections.Generic.List[string]
        for ($column = 0; $column -lt $Headers.Count; $column++) {
            $value = if ($column -lt $row.Count) { [string]$row[$column] } else { "" }
            $cells.Add((Format-RichMarkdownInline $value))
        }
        $lines.Add("| " + ($cells -join " | ") + " |")
    }

    return ($lines -join "`n")
}

function New-LegacyTableText {
    param(
        [string]$Title,
        [string[]]$Headers,
        [object[]]$Rows
    )

    $table = Format-AlignedTable -Headers $Headers -Rows $Rows

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine("*$(ConvertTo-MarkdownV2Escaped $Title)*")
    [void]$builder.AppendLine('```')
    [void]$builder.AppendLine((ConvertTo-CodeBlockText $table))
    [void]$builder.Append('```')

    return $builder.ToString()
}

# ==================== 消息组装 ====================

function Get-SectionRenderer {
    param([string]$Style)

    if ($Style -eq "Rich") {
        return { param($Section) New-RichTableText -Title $Section.title -Headers $Section.headers -Rows $Section.rows }
    }

    return { param($Section) New-LegacyTableText -Title $Section.title -Headers $Section.headers -Rows $Section.rows }
}

function Split-SectionByRows {
    param(
        $Section,
        [int]$MaxLength,
        [scriptblock]$Renderer
    )

    $groups = New-Object System.Collections.Generic.List[object]
    $currentRows = New-Object System.Collections.Generic.List[object]
    $title = $Section.title

    foreach ($row in $Section.rows) {
        $currentRows.Add($row)
        $candidate = [PSCustomObject]@{ title = $title; headers = $Section.headers; rows = $currentRows.ToArray() }

        if ((& $Renderer $candidate).Length -gt $MaxLength -and $currentRows.Count -gt 1) {
            # 超出长度限制时另起一个表格（重复表头）
            $currentRows.RemoveAt($currentRows.Count - 1)
            $groups.Add([PSCustomObject]@{ title = $title; headers = $Section.headers; rows = $currentRows.ToArray() })
            $title = "$($Section.title)（续）"
            $currentRows = New-Object System.Collections.Generic.List[object]
            $currentRows.Add($row)
        }
    }

    if ($currentRows.Count -gt 0) {
        $groups.Add([PSCustomObject]@{ title = $title; headers = $Section.headers; rows = $currentRows.ToArray() })
    }

    return $groups
}

function Format-ReportMessages {
    param(
        [array]$Sections,
        [string]$Preamble,
        [string]$Footer,
        [int]$MaxLength,
        [string]$Style
    )

    $renderer = Get-SectionRenderer -Style $Style

    $budget = $MaxLength - $Preamble.Length - $Footer.Length
    if ($budget -lt 500) { $budget = 500 }

    $blocks = New-Object System.Collections.Generic.List[string]
    foreach ($section in $Sections) {
        foreach ($group in (Split-SectionByRows -Section $section -MaxLength $budget -Renderer $renderer)) {
            $blocks.Add((& $renderer $group))
        }
    }

    $messages = New-Object System.Collections.Generic.List[string]
    $current = ""
    foreach ($block in $blocks) {
        if ($current -and ($current.Length + $block.Length + 2) -gt $budget) {
            $messages.Add($current.TrimEnd())
            $current = ""
        }
        if ($current) { $current += "`n`n$block" } else { $current = $block }
    }
    if ($current) { $messages.Add($current.TrimEnd()) }
    if ($messages.Count -eq 0) { $messages.Add("") }

    $messages[0] = ($Preamble + "`n`n" + $messages[0]).TrimEnd()
    if ($Footer) {
        $messages[$messages.Count - 1] = ($messages[$messages.Count - 1] + "`n`n" + $Footer).TrimEnd()
    }

    return $messages
}

# ==================== 发送消息 ====================

function Send-RichTelegramMessage {
    param([string]$Markdown)

    $uri = "https://api.telegram.org/bot$BotToken/sendRichMessage"
    $richMessage = @{ markdown = $Markdown } | ConvertTo-Json -Compress -Depth 5
    $body = @{
        chat_id      = $ChatId
        rich_message = $richMessage
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded; charset=utf-8' -ErrorAction Stop
        if (-not $response.ok) {
            throw "Telegram API 返回 ok=false"
        }
        return $true
    }
    catch {
        Write-Host "  sendRichMessage 发送失败：$($_.Exception.Message)"
        return $false
    }
}

function Send-TelegramMessage {
    param(
        [string]$Text,
        [string]$ParseMode
    )

    $uri = "https://api.telegram.org/bot$BotToken/sendMessage"
    $body = @{
        chat_id              = $ChatId
        text                 = $Text
        link_preview_options = '{"is_disabled":true}'
    }

    if ($ParseMode) {
        $body['parse_mode'] = $ParseMode
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded; charset=utf-8' -ErrorAction Stop
        if (-not $response.ok) {
            throw "Telegram API 返回 ok=false"
        }
        return $true
    }
    catch {
        Write-Host "  sendMessage 发送失败（parse_mode=$ParseMode）：$($_.Exception.Message)"
        return $false
    }
}

# ==================== 读取运行报告 ====================

if (-not $DryRun -and (-not $BotToken -or -not $ChatId)) {
    Write-Host "TG_BOT / TG_USER 未配置，跳过 Telegram 通知。"
    exit 0
}

Write-Host "Reading report: $ReportFile"

if (-not (Test-Path $ReportFile)) {
    Write-Host "报告文件不存在，无需通知。"
    exit 0
}

try {
    $rawReport = Get-Content $ReportFile -Raw -Encoding UTF8
    $rawReport = $rawReport.TrimStart([char]0xFEFF)
    $report = $rawReport | ConvertFrom-Json
}
catch {
    Write-Host "报告文件解析失败：$_"
    exit 0
}

$updates = @((Get-PropertyValue -Object $report -Name 'updates' -Default @()))
$checkErrors = @((Get-PropertyValue -Object $report -Name 'checkErrors' -Default @()))

$items = New-Object System.Collections.Generic.List[object]
foreach ($update in $updates) {
    if ($null -eq $update) { continue }

    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($warning in @((Get-PropertyValue -Object $update -Name 'warnings' -Default @()))) {
        $warningText = Get-SafeText $warning
        if ($warningText) { $warnings.Add($warningText) }
    }

    $items.Add([PSCustomObject]@{
            id             = Get-SafeText (Get-PropertyValue -Object $update -Name 'id')
            currentVersion = Get-SafeText (Get-PropertyValue -Object $update -Name 'currentVersion')
            newVersion     = Get-SafeText (Get-PropertyValue -Object $update -Name 'newVersion')
            status         = (Get-SafeText (Get-PropertyValue -Object $update -Name 'status' -Default 'pending')).ToLower()
            prUrl          = Get-SafeText (Get-PropertyValue -Object $update -Name 'prUrl')
            error          = Get-SafeText (Get-PropertyValue -Object $update -Name 'error')
            warnings       = $warnings
        })
}

$validCheckErrors = New-Object System.Collections.Generic.List[object]
foreach ($checkError in $checkErrors) {
    if ($null -eq $checkError) { continue }
    $validCheckErrors.Add($checkError)
}

if ($items.Count -eq 0 -and $validCheckErrors.Count -eq 0) {
    Write-Host "报告中没有检测到更新，也无需报告的异常，跳过通知。"
    exit 0
}

# ==================== 构建消息数据 ====================

$submittedItems = @($items | Where-Object { $_.status -eq 'submitted' })
$existingItems = @($items | Where-Object { $_.status -eq 'existing' })
$errorItems = @($items | Where-Object { $_.status -eq 'error' })
$skippedItems = @($items | Where-Object { $_.status -eq 'skipped' })
$pendingItems = @($items | Where-Object { $_.status -eq 'pending' })
$warningItems = @($items | Where-Object { $_.warnings.Count -gt 0 })

$generatedAtValue = Get-PropertyValue -Object $report -Name 'generatedAt'
if ($generatedAtValue -is [datetime]) {
    # PowerShell 7 的 ConvertFrom-Json 会自动把 ISO 时间字符串转成 DateTime
    $generatedAt = $generatedAtValue.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
}
else {
    $generatedAt = Get-SafeText $generatedAtValue
    if (-not $generatedAt) {
        $generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $generatedAt = ($generatedAt -replace 'T', ' ' -replace 'Z', '').Trim()
}

$summary = "共检测到 $($items.Count) 个更新"
$summaryDetails = New-Object System.Collections.Generic.List[string]
if ($submittedItems.Count -gt 0) { $summaryDetails.Add("已提交 $($submittedItems.Count)") }
if ($existingItems.Count -gt 0) { $summaryDetails.Add("已存在 $($existingItems.Count)") }
if ($errorItems.Count -gt 0) { $summaryDetails.Add("出错 $($errorItems.Count)") }
if ($skippedItems.Count -gt 0) { $summaryDetails.Add("已跳过 $($skippedItems.Count)") }
if ($pendingItems.Count -gt 0) { $summaryDetails.Add("未处理 $($pendingItems.Count)") }
if ($summaryDetails.Count -gt 0) {
    $summary += "（" + ($summaryDetails -join "，") + "）"
}

$sections = New-Object System.Collections.Generic.List[object]

# 1. 检查到新版本
if ($items.Count -gt 0) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        $rows.Add([string[]]@(
                (Format-CellValue $item.id),
                (Format-CellValue $item.currentVersion),
                (Format-CellValue $item.newVersion)
            ))
    }
    $sections.Add([PSCustomObject]@{
            title   = "📦 检查到新版本（$($items.Count)）"
            headers = @('包名', '当前版本', '新版本')
            rows    = $rows.ToArray()
        })
}

# 2. 已提交 PR
if ($submittedItems.Count -gt 0) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $submittedItems) {
        $rows.Add([string[]]@((Format-CellValue $item.id), (Format-CellValue $item.prUrl '未获取到 PR 链接')))
    }
    $sections.Add([PSCustomObject]@{
            title   = "✅ 已提交 PR（$($submittedItems.Count)）"
            headers = @('包名', 'PR 链接')
            rows    = $rows.ToArray()
        })
}

# 3. 已存在 PR，未重复提交
if ($existingItems.Count -gt 0) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $existingItems) {
        $rows.Add([string[]]@((Format-CellValue $item.id), (Format-CellValue $item.prUrl '未获取到 PR 链接')))
    }
    $sections.Add([PSCustomObject]@{
            title   = "🔁 已存在 PR，未重复提交（$($existingItems.Count)）"
            headers = @('包名', 'PR 链接')
            rows    = $rows.ToArray()
        })
}

# 4. 提交 PR 出错
if ($errorItems.Count -gt 0) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $errorItems) {
        $rows.Add([string[]]@((Format-CellValue $item.id), (Format-CellValue (Limit-Text $item.error 300) '未知错误')))
    }
    $sections.Add([PSCustomObject]@{
            title   = "❌ 提交 PR 出错（$($errorItems.Count)）"
            headers = @('包名', '错误信息')
            rows    = $rows.ToArray()
        })
}

# 5. 警告（例如部分架构下载失败）
if ($warningItems.Count -gt 0) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $warningItems) {
        $warningText = ($item.warnings | ForEach-Object { Limit-Text $_ 200 }) -join '；'
        $rows.Add([string[]]@((Format-CellValue $item.id), $warningText))
    }
    $sections.Add([PSCustomObject]@{
            title   = "⚠️ 警告（$($warningItems.Count)）"
            headers = @('包名', '警告信息')
            rows    = $rows.ToArray()
        })
}

# 6. 已跳过提交（例如 winget-pkgs 中不存在该包）
if ($skippedItems.Count -gt 0) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $skippedItems) {
        $rows.Add([string[]]@((Format-CellValue $item.id), (Format-CellValue (Limit-Text $item.error 200) '已跳过')))
    }
    $sections.Add([PSCustomObject]@{
            title   = "⏭️ 已跳过提交（$($skippedItems.Count)）"
            headers = @('包名', '原因')
            rows    = $rows.ToArray()
        })
}

# 7. 未处理（工作流可能在中途中断）
if ($pendingItems.Count -gt 0) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $pendingItems) {
        $rows.Add([string[]]@((Format-CellValue $item.id), '检测到更新，但未执行提交'))
    }
    $sections.Add([PSCustomObject]@{
            title   = "🕓 未处理（$($pendingItems.Count)）"
            headers = @('包名', '说明')
            rows    = $rows.ToArray()
        })
}

# 8. 版本检查异常
if ($validCheckErrors.Count -gt 0) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($checkError in $validCheckErrors) {
        $rows.Add([string[]]@(
                (Format-CellValue (Get-SafeText (Get-PropertyValue -Object $checkError -Name 'id'))),
                (Format-CellValue (Limit-Text (Get-SafeText (Get-PropertyValue -Object $checkError -Name 'message')) 200) '检查失败')
            ))
    }
    $sections.Add([PSCustomObject]@{
            title   = "⚠️ 版本检查异常（$($validCheckErrors.Count)）"
            headers = @('包名', '错误信息')
            rows    = $rows.ToArray()
        })
}

# 抬头与页脚
$preambleRich = @(
    "🚀 **WinGet Tracker 运行报告**",
    "🕒 时间：$(Format-RichMarkdownInline $generatedAt) UTC",
    "🔍 $(Format-RichMarkdownInline $summary)"
) -join "`n"

$preambleLegacy = @(
    "🚀 *WinGet Tracker 运行报告*",
    "🕒 时间：$(ConvertTo-MarkdownV2Escaped $generatedAt) UTC",
    "🔍 $(ConvertTo-MarkdownV2Escaped $summary)"
) -join "`n"

$footer = ""
if ($env:GITHUB_RUN_ID -and $env:GITHUB_REPOSITORY) {
    $serverUrl = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL } else { 'https://github.com' }
    $runUrl = "$serverUrl/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
    $footer = "🔗 [查看本次运行日志]($runUrl)"
}

$richMessages = @(Format-ReportMessages -Sections $sections.ToArray() -Preamble $preambleRich -Footer $footer -MaxLength $RichMessageMaxLength -Style "Rich")
$legacyMessages = @(Format-ReportMessages -Sections $sections.ToArray() -Preamble $preambleLegacy -Footer $footer -MaxLength $LegacyMaxLength -Style "Legacy")

if ($DryRun) {
    $dryRunMessages = if ($NoRichMessage) { $legacyMessages } else { $richMessages }
    $dryRunStyle = if ($NoRichMessage) { "传统 MarkdownV2 代码块表格" } else { "富文本 / Rich Markdown" }

    Write-Host "----- DryRun：以下为将要发送的消息（$dryRunStyle）-----"
    foreach ($message in $dryRunMessages) {
        Write-Host $message
        Write-Host "----- 消息分隔 -----"
    }
    Write-Host "----- DryRun 结束 -----"
    exit 0
}

# ==================== 发送消息 ====================

$allSent = $true
$richSucceeded = $false

if (-not $NoRichMessage) {
    Write-Host "Sending $($richMessages.Count) rich message(s) to Telegram..."
    $richSucceeded = $true

    for ($index = 0; $index -lt $richMessages.Count; $index++) {
        if (-not (Send-RichTelegramMessage -Markdown $richMessages[$index])) {
            $richSucceeded = $false
            break
        }
        if ($index -lt ($richMessages.Count - 1)) {
            Start-Sleep -Milliseconds 500
        }
    }
}

if ($richSucceeded) {
    Write-Host "Telegram 通知发送完成（Rich Markdown）。"
    exit 0
}

# 降级：sendMessage + MarkdownV2 代码块表格，再降级为纯文本
Write-Host "降级为 MarkdownV2 代码块表格发送（$($legacyMessages.Count) 条）..."
for ($index = 0; $index -lt $legacyMessages.Count; $index++) {
    $sent = Send-TelegramMessage -Text $legacyMessages[$index] -ParseMode 'MarkdownV2'

    if (-not $sent) {
        Write-Host "  尝试以纯文本方式重发（第 $($index + 1) 条）..."
        $sent = Send-TelegramMessage -Text (ConvertFrom-MarkdownV2 $legacyMessages[$index]) -ParseMode ''
    }

    if (-not $sent) {
        $allSent = $false
    } elseif ($index -lt ($legacyMessages.Count - 1)) {
        Start-Sleep -Milliseconds 500
    }
}

if ($allSent) {
    Write-Host "Telegram 通知发送完成（MarkdownV2 降级模式）。"
} else {
    Write-Host "Warning: 部分 Telegram 消息发送失败。"
}

exit 0
