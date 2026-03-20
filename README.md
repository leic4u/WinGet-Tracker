# WinGet Tracker

WinGet Tracker 是一个自动化工具，用于监控软件包更新并自动向 Microsoft 的 [winget-pkgs](https://github.com/microsoft/winget-pkgs) 仓库提交更新请求。

## 功能特性

- **自动版本检测**：定期检查已配置软件包的新版本
- **智能更新机制**：根据配置的规则从官方源获取最新版本信息
- **哈希计算**：自动下载安装包并计算 SHA256 哈希值
- **重复 PR 检查**：避免重复提交相同的版本更新
- **自动提交**：使用 `wingetcreate` 工具自动向 winget-pkgs 提交 PR
- **日志记录**：完整的操作日志便于追踪和调试

## 项目结构

```
winget-auto-update/
├── .github/workflows/     # GitHub Actions 工作流配置
├── packages/               # 软件包配置文件目录
├── scripts/                # PowerShell 脚本目录
│   ├── calc-hash.ps1       # 计算安装包哈希值
│   ├── check-existing-pr.ps1  # 检查是否已存在相同版本的 PR
│   ├── check-version.ps1   # 检查软件包新版本
│   ├── resolve-download.ps1  # 解析下载链接
│   ├── resolve-version.ps1 # 解析版本号
│   ├── scan-url-version.ps1 # 从 URL 扫描版本
│   ├── submit-winget.ps1   # 提交更新到 winget-pkgs
│   └── validate-config.ps1 # 验证配置文件
└── logs/                   # 日志文件目录
```

## 配置文件格式

每个软件包需要一个 YAML 配置文件，放置在 `packages/` 目录下：

```yaml
id: Publisher.AppName
current_package:
  version: "1.0.0"
  architecture:
    x64:
      url: https://example.com/app-1.0.0-x64.exe
      hash: "SHA256_HASH"
checkver:
  url: https://example.com/releases
  regex: Version ([\d.]+)
autoupdate:
  architecture:
    x64:
      url: https://example.com/app-$version-x64.exe
```

### 字段说明

| 字段 | 说明 |
|------|------|
| `id` | Winget 包标识符（格式：Publisher.AppName） |
| `current_package.version` | 当前已知的最新版本 |
| `current_package.architecture` | 支持的架构及对应的下载信息 |
| `checkver.url` | 版本检查的目标 URL |
| `checkver.regex` | 从页面提取版本的正则表达式 |
| `checkver.jsonpath` | 从 JSON 响应提取版本的路径（可选） |
| `checkver.method` | HTTP 请求方法（GET/POST/PUT，默认 GET） |
| `checkver.update_version` | 可选，自定义用于更新 `current_package.version` 的版本格式，支持 `$major.$minor.$patch.$build` 等变量 |
| `autoupdate.architecture` | 自动更新 URL 模板，支持 `$version`, `$major`, `$minor`, `$patch`, `$build` 等变量 |

## 版本检查模式 (checkver)

`checkver` 支持三种版本检查模式，根据 `url` 的格式自动识别：

### 模式一：GitHub Releases

适用于发布在 GitHub Releases 的软件包。

```yaml
checkver:
  url: https://github.com/owner/repo
```

**说明**：
- URL 格式为 `https://github.com/用户名/仓库名`
- 自动调用 GitHub API 获取最新 release 的 `tag_name`
- 自动去除版本号前缀的 `v`
- 支持通过 `WINGET_TOKEN` 环境变量进行 API 认证，提高请求限制

**示例**：
```yaml
checkver:
  url: https://github.com/microsoft/winget-create
```

---

### 模式二：Web 网页（正则匹配）

适用于需要从网页 HTML 中提取版本号的情况。

```yaml
checkver:
  url: https://example.com/download
  regex: Version ([\d.]+)
```

**说明**：
- 发送 HTTP GET 请求获取网页内容
- 使用正则表达式从 HTML 中提取版本号
- 支持命名捕获组 `(?<version>[\d.]+)`，优先使用
- 也支持数字捕获组，使用第一个匹配组

**高级选项**：

| 选项 | 说明 | 示例 |
|------|------|------|
| `regex` | 用于匹配版本号的正则表达式 | `Version ([\d.]+)` |
| `update_version` | 可选，自定义用于更新 `current_package.version` 的版本格式。支持变量 `$major`, `$minor`, `$patch`, `$build` | `$major.$minor.$patch` |

**变量说明**：
- `$version`: 完整的版本号（从 regex 提取的结果）
- `$major`: 主版本号（第一段）
- `$minor`: 次版本号（第二段）  
- `$patch`: 修订版本号（第三段）
- `$build`: 构建号（第四段，如果存在）

**示例**：
```yaml
checkver:
  url: https://www.example.com/download
  regex: "Latest version: ([\\d.]+)"
```

**高级示例（4段版本号处理）**：
```yaml
# 从完整版本号 3.28.3.134742 中提取前3段作为 current_package.version
checkver:
  url: https://downloads.sparkmailapp.com/Spark3/win/dist/appcast.xml
  regex: Version (\d+\.\d+\.\d+\.\d+)
  update_version: $major.$minor.$patch
autoupdate:
  architecture:
    x64:
      url: https://downloads.sparkmailapp.com/Spark3/win/dist/$major.$minor.$patch.$build/Spark.exe
```

---

### 模式三：API 请求（JSON 解析）

适用于通过 REST API 获取版本信息的场景。

```yaml
checkver:
  url: https://api.example.com/v1/version
  method: GET
  jsonpath: data.version
  regex: "([\\d.]+)"
```

**说明**：
- 支持 GET/POST/PUT/PATCH 等 HTTP 方法
- 使用 `jsonpath` 从 JSON 响应中提取版本字段
- 支持嵌套路径，如 `data.version`
- 可配合 `regex` 进一步提取版本号
- 支持自定义请求头 `headers` 和请求体 `body`

**高级选项**：

| 选项 | 说明 | 示例 |
|------|------|------|
| `method` | HTTP 请求方法，默认 GET | `POST`, `PUT`, `PATCH` |
| `jsonpath` | JSON 字段路径，支持嵌套 | `version`, `data.version` |
| `regex` | 对提取的值进一步正则匹配 | `([\d.]+)` |
| `update_version` | 可选，自定义用于更新 `current_package.version` 的版本格式。支持变量 `$major`, `$minor`, `$patch`, `$build` | `$major.$minor.$patch` |
| `headers` | 自定义请求头 | `Authorization: Bearer xxx` |
| `body` | 请求体（用于 POST/PUT） | JSON 字符串 |

**POST 请求示例**：
```yaml
checkver:
  url: https://api.example.com/v1/check
  method: POST
  headers:
    Content-Type: application/json
    Authorization: Bearer token_here
  body: '{"product": "appname"}'
  jsonpath: latestVersion
```

**直接使用 GitHub API 示例**：
```yaml
checkver:
  url: https://api.github.com/repos/owner/repo/releases/latest
  jsonpath: tag_name
  regex: "v?([\\d.]+)"
```

---

### 模式对比

| 模式 | URL 特征 | 必需字段 | 适用场景 |
|------|---------|---------|---------|
| GitHub Releases | 包含 `github.com` | `url` | 软件发布在 GitHub |
| Web 网页 | 普通 URL | `url`, `regex` | 官网下载页面 |
| API 请求 | 包含 `api.` 或使用 POST | `url`, `jsonpath` | 版本检查 API |

---

### 版本号变量支持

系统支持将版本号拆分为多个部分，并在配置中使用以下变量：

| 变量 | 说明 | 示例（版本 `3.28.3.134742`） |
|------|------|----------------------------|
| `$version` | 完整版本号 | `3.28.3.134742` |
| `$major` | 主版本号（第一段） | `3` |
| `$minor` | 次版本号（第二段） | `28` |
| `$patch` | 修订版本号（第三段） | `3` |
| `$build` | 构建号（第四段） | `134742` |

**使用场景**：
- `checkver.update_version`: 自定义 `current_package.version` 的格式
- `autoupdate.architecture`: 构建包含完整版本信息的下载 URL

**注意**：如果版本号段数不足，缺失的段默认为 `"0"`。

## 使用方法

### 1. 设置环境变量

```powershell
$env:WINGET_TOKEN="your_github_personal_access_token"
```

### 2. 运行版本检查

```powershell
.\scripts\check-version.ps1
```

此脚本会：
- 遍历 `packages/` 目录下的所有 YAML 配置文件
- 根据 `checkver` 规则检查远程版本
- 发现新版本时更新配置文件中的版本信息

### 3. 提交更新

```powershell
.\scripts\submit-winget.ps1
```

此脚本会：
- 读取版本检查结果
- 检查是否已有相同的 PR 存在
- 下载安装包并计算哈希值
- 使用 `wingetcreate` 提交更新到 winget-pkgs
- 更新本地配置文件的 `current_package` 信息

## GitHub Actions 自动化

项目包含 GitHub Actions 工作流，可自动运行：

- **触发方式**：
  - 根据配置的 cron 表达式自动运行
  - 手动触发 (`workflow_dispatch`)

- **所需 Secrets**：
  - `WINGET_TOKEN`: GitHub Personal Access Token，用于提交 PR

## 脚本说明

| 脚本 | 功能 |
|------|------|
| `check-version.ps1` | 检查所有软件包的新版本，支持4段版本号和 `update_version` 自定义 |
| `submit-winget.ps1` | 提交更新到 winget-pkgs 仓库，使用 komac 绝对路径 |
| `calc-hash.ps1` | 下载安装包并计算 SHA256 哈希 |
| `check-existing-pr.ps1` | 检查 winget-pkgs 是否已存在相同版本的 PR，改进错误处理 |
| `resolve-version.ps1` | 根据配置解析远程版本号，支持 `update_version` 参数 |
| `resolve-download.ps1` | 根据配置解析下载链接，支持 `$major`, `$minor`, `$patch`, `$build` 变量 |
| `validate-config.ps1` | 验证软件包配置文件格式 |
| `cleanup-merged-prs.ps1` | 清理已合并的 PR 分支，使用 komac 绝对路径 |

## 日志管理

- 日志文件保存在 `logs/` 目录
- 自动清理 30 天前的日志文件
- 日志格式：`submit-YYYYMMDD-HHmmss.log`

## PR 提交说明

所有通过本工具提交的 PR 都会包含以下说明：

> Pull request has been created with [WinGet Tracker](https://github.com/leic4u/winget-tracker) 📦

## 许可证

MIT License
