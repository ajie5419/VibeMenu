# VibeMenu

VibeMenu 是一个 macOS 状态栏工具，支持在 Finder 当前目录快速新建常用文档，并提供 Finder 右键菜单扩展。

## 功能

- 状态栏菜单新建文件
  - 新建 Markdown 文档（`.md`）
  - 新建文本文档（`.txt`）
  - 新建 Word 文档（`.docx`）
  - 新建 Excel 表格（`.xlsx`）
- Finder 右键菜单新建文件（带系统风格图标）
- 自动命名防冲突（`未命名`、`未命名 1`、`未命名 2`…）
- 扩展写入失败时自动回退到主程序创建（避免静默失败）

## 运行环境

- macOS（建议 Sonoma/Sequoia 及以上）
- Xcode 15+

## 快速开始（开发运行）

1. 用 Xcode 打开 `VibeMenu.xcodeproj`
2. 选择 `VibeMenu` scheme，运行（`Run`）
3. 首次运行后，按提示在系统设置开启 Finder 扩展：
   - 系统设置 -> 隐私与安全性 -> 扩展程序 -> 访达 -> 打开 `VibeFinderSync`
4. 重启 Finder（必要时）：
   - `killall Finder`

## 打包

在项目根目录执行：

```bash
xcodebuild -scheme VibeMenu -configuration Release -sdk macosx build
```

构建产物示例路径（DerivedData）：

`~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/VibeMenu.app`

建议将打包产物复制到：

`./release/VibeMenu.app`

> 注意：`release/*.app` 已在 `.gitignore` 中忽略，不再提交到仓库。

## 使用说明

- 状态栏图标：点击后可直接在 Finder 当前目录新建文件。
- Finder 右键：在目录空白处右键，使用 “新建 Word 文档 / 新建 Excel 表格 / 新建 文本文档 / 新建 Markdown 文档”。

## 常见问题

### 1) 右键菜单不显示

- 确认扩展已开启：系统设置 -> 隐私与安全性 -> 扩展程序 -> 访达。
- 执行：

```bash
killall Finder
```

### 2) 点击右键新建没反应

- 通常是 Finder 扩展沙盒写权限限制。
- 当前实现会自动委托主程序兜底创建，请确认主程序 `VibeMenu` 正在运行。

### 3) 给别人分发能直接用吗？

- 开发签名版本通常不适合直接分发给普通用户。
- 正式分发建议使用：
  - `Developer ID Application` 签名
  - Apple 公证（notarization）

## 项目结构

- `VibeMenu/`：主程序（状态栏 App）
- `VibeFinderSync/`：Finder Sync 扩展
- `VibeFinderSync-Info.plist`：扩展配置
- `VibeMenu.xcodeproj/`：Xcode 工程

## License

暂无（可按需补充）。
