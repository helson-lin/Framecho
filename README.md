# Framecho

原生 macOS 截图、录屏与编辑工具。支持简体中文界面、本地素材库、非破坏性编辑，以及部署到自己 Cloudflare 账号的云端分享。

Framecho 基于 [Screendrop](https://github.com/fayazara/Screendrop) 开发，由 [helson-lin](https://github.com/helson-lin) 独立维护。本项目使用自己的应用标识、签名、公证、发布渠道和 Sparkle 更新源。源码目录、Xcode 工程与 scheme 保留 `Screendrop` 名称，便于维护和合并上游改进。

**系统要求：macOS 26.4 或更高版本。发布包同时支持 Apple Silicon 和 Intel。**

[下载最新 Framecho.dmg](https://github.com/helson-lin/Screendrop/releases/latest/download/Framecho.dmg) · [发布记录](https://github.com/helson-lin/Screendrop/releases) · [反馈问题](https://github.com/helson-lin/Screendrop/issues)

> 项目仍在持续开发中。请在反馈问题时附上 macOS 版本、Framecho 版本和复现步骤。

## 安装与更新

1. 下载最新的 `Framecho.dmg`。
2. 打开 DMG，将 **Framecho** 拖入「应用程序」文件夹。
3. 启动 Framecho，按提示授予屏幕录制权限。正常启动会打开素材库，菜单栏提供截图和录屏入口；登录时启动会留在菜单栏。

正式发布包使用 Developer ID 签名，并经过 Apple 公证。录屏使用摄像头、麦克风或按键字幕时，会分别请求相应权限。

Framecho 使用 Sparkle 检查更新，更新源为：

[https://raw.githubusercontent.com/helson-lin/Screendrop/main/appcast.xml](https://raw.githubusercontent.com/helson-lin/Screendrop/main/appcast.xml)

`appcast.xml` 保存在本仓库的 `main` 分支，DMG 保存在 GitHub Release 附件中；更新源无需作为每个 Release 的附件。已安装当前最新版时不会出现更新提示。Debug 构建不启动更新检查。

本项目暂未提供自己的 Homebrew cask。上游的 `fayazara/tap/screendrop` 安装的是 Screendrop，请使用上面的 Framecho 下载链接。

## 主要功能

### 截图与素材库

- 全屏、窗口和区域截图；区域选择时按空格可切换到窗口截图。
- 定时截图、窗口阴影、PNG / JPEG 导出及自定义保存目录。
- 本地 OCR：选择屏幕区域，识别并复制文字，无需保存截图。
- 可调整大小、位置和操作顺序的浮动预览卡片。
- 复制、保存、压缩、编辑、上传、置顶和删除等截图后操作。
- 置顶截图支持通过滚轮调整透明度。
- 素材库统一管理截图、视频和可编辑录屏项目，支持搜索、排序、网格 / 列表视图与批量操作。
- 从 Finder 打开图片时导入副本进行编辑，保留原文件。

### 图片标注与背景

- 矩形、圆形、箭头、直线、自由绘制、文字、编号及高亮。
- 模糊、像素化和敏感文字自动遮挡。
- 裁剪、撤销与重做；保留原图和 `.screendrop` 编辑 sidecar，可再次打开修改。
- 纯色、渐变、自定义壁纸和按需下载的壁纸包。
- 留白、圆角、阴影、边框、水印及画布比例。
- 截图透视、旋转、缩放、平移和渐进模糊效果。
- 导入、导出 `.screendroppreset` 背景预设；本地壁纸文件不会随预设一起导出。

### 录屏与视频编辑

- 录制显示器、窗口或区域，可同时录制摄像头、麦克风和系统音频。
- 暂停、继续、重新录制；原始屏幕和摄像头轨道分别保存。
- 提词器，可通过设备端语音识别跟随讲述进度。
- 时间线分割、裁剪、删除片段和调整播放速度。
- 自动 / 手动缩放、鼠标跟随、重建光标、点击效果及按键字幕。
- 可调整摄像头位置、大小和圆角；保存背景与布局预设。
- 设备端转写、字幕编辑、逐词高亮，以及按转写文本剪辑视频。
- 原始比例、横屏、竖屏和方形导出；支持视频画面单独裁剪。
- 质量、编码、分辨率、30 / 60 fps、运动模糊和音频导出设置。
- 导出与分享使用项目编辑结果，支持进度显示和取消。

### 自托管分享与自动化

- 使用自己的 Cloudflare Workers、R2 和 D1 分享截图与视频。
- 视频分享页支持播放器、拖动预览、可搜索转写文本和评论。
- 截图与录屏分别配置自动保存、复制、上传和打开编辑器等动作。
- 上传与上传后复制分享链接可以分别设置。
- 支持 Apple Shortcuts、Siri 和 App Intents。

## 默认快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌥1` | 全屏截图 |
| `⌥2` | 窗口截图 |
| `⌥3` | 区域截图 |
| `⌥4` | 打开录屏选择器 |
| `⌥5` | 识别并复制屏幕文字 |
| `⌥6` | 倒计时后截图 |
| `⌘⇧L` | 打开素材库 |

六个截图 / 录屏全局快捷键可在设置中修改。如果新快捷键无法注册，应用会保留原先可用的设置并提示原因。

## 壁纸资源包

壁纸包在点击安装时下载，安装后保存在本地 `~/Library/Application Support/Framecho/Wallpapers/`。截图和视频编辑均可使用这些壁纸；也可以直接选择自己的图片作为背景。

两个内置包现由 Framecho 维护者通过 Cloudflare R2 托管，应用直接使用以下公开 HTTPS 地址下载：

| 包 ID | 资源包 | 原作者 | 下载地址 |
| --- | --- | --- | --- |
| `uihssn` | UIHSSN | [Ahmed Hassan](https://x.com/uihssn) | [uihssn-wallpaper-pack.zip](https://r2.jarin.me/Frameecho/uihssn-wallpaper-pack.zip) |
| `fayaz` | Fayazara | [Fayaz Ahmed](https://x.com/fayazara) | [fayaz-wallpaper-pack.zip](https://r2.jarin.me/Frameecho/fayaz-wallpaper-pack.zip) |

托管包与原始下载包的 SHA-256 一致，包 ID、内部文件名和目录结构保持不变，已有本地壁纸与已保存的引用可继续使用。对象路径中的 `Frameecho` 是当前 R2 路径，大小写和拼写须保持一致。

两个包分别包含 12 张和 5 张图片。下载失败时，可继续使用已有壁纸、纯色、渐变或自定义图片。应用内的下载器目前不进行资源摘要校验，也未配置镜像回退。

资源来自上游壁纸包，保留原作者署名。迁移托管不改变素材许可；本仓库的 CC0 许可不自动适用于外部壁纸。

## 云端分享配置

Framecho 不提供统一的公共上传服务器。云端分享需要部署到你自己的 Cloudflare 账号。

配套服务由本项目独立维护：[Framecho-worker](https://github.com/helson-lin/Framecho-worker)。截图和录屏分享使用 Workers + R2 + D1；壁纸下载桶可独立使用。首次部署只需填写 `UPLOAD_TOKEN`，GitHub / Google OAuth 用于评论和点赞，可在部署后选配。

1. 打开 **设置 → 云端**，复制生成的上传令牌。
2. 使用设置中的部署入口，将 Worker 部署到自己的 Cloudflare 账号。
3. 将上传令牌配置为 Worker 的 `UPLOAD_TOKEN` secret，并完成 R2 / D1 绑定。
4. 将部署后的 Worker URL 填回 Framecho，验证连接后即可上传。

手动部署时，可通过 Wrangler 设置令牌：

```bash
npx wrangler secret put UPLOAD_TOKEN
```

上传令牌存储在 macOS 钥匙串中。文件只会在手动上传或已启用的自动上传动作触发时发送到你配置的服务。

## 本地数据与权限

截图、录屏原始轨道、编辑项目与转写文本保存在 Mac 本地。语音转写在设备端运行；首次使用时，系统可能下载所需语言模型。

| 权限 | 用途 |
| --- | --- |
| 屏幕与系统音频录制 | 截图、录屏和系统音频 |
| 摄像头 | 摄像头预览及独立视频轨道 |
| 麦克风 | 旁白与提词器语音跟随 |
| 输入监控 | 可编辑的按键字幕 |

默认排除 Framecho 自身窗口。需要录制预览卡片、控制条或设置界面时，可在通用设置中开启捕获自身窗口。

## 从源码构建

需要 macOS 26.4 或更高版本，以及包含所需 macOS SDK 的 Xcode。Xcode 会自动解析 Sparkle 和 DockProgress 依赖。

```bash
git clone https://github.com/helson-lin/Screendrop.git
cd Screendrop

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Screendrop.xcodeproj \
  -scheme Screendrop \
  -configuration Debug \
  -destination "platform=macOS"
```

仓库中的签名配置使用维护者的 Apple 开发者团队。其他开发者需在 Xcode 中选择自己的团队与可用证书；仅进行本地编译验证时，可在命令后加 `CODE_SIGNING_ALLOWED=NO`，该产物不用于正式分发。

工程和 scheme 名称仍为 `Screendrop`，生成的应用名称为 `Framecho.app`，Bundle ID 为 `com.jarinhe.Framecho`。项目没有 Xcode 测试 target，构建成功是基本自动验证；性能专项检查见 [视频导出性能](docs/export-performance.md) 和 [编辑器性能](docs/editor-performance.md)。

## 发布流程

发布工具位于 `cmd/screendrop-release`，发布目标为 `helson-lin/Screendrop`。完整流程需要 Go、`create-dmg`、已登录的 `gh`、Xcode、Developer ID Application 证书、Sparkle 签名密钥，以及名为 `framecho-notary` 的公证凭据配置。

```bash
brew install create-dmg

# 示例：在 0.34.1（build 33）之后发布下一版。
go run ./cmd/screendrop-release -build -yes \
  -set-version 0.34.2 -set-build 34 \
  -notes-file /path/to/release-notes.txt
```

更新说明文件每行一条。每次发布递增 build 号，并在发布前提交待发布的代码。工具会归档、Developer ID 签名导出、公证、附加公证票据、生成并进行 Sparkle 签名的 DMG，推送提交，创建 GitHub Release，最后更新并推送 `appcast.xml`。

不使用 `-build` 时，工具读取已经导出到 `~/Downloads/Framecho.app` 的应用进行打包和发布。当前未配置 Homebrew tap，不会发布或更新 cask。

Sparkle 的 EdDSA 私钥保存在维护者钥匙串的 `com.jarinhe.Framecho` 账户中。公证凭据与私钥不要提交到仓库；请安全备份签名密钥，以便持续向已安装版本提供可信更新。

## 来源与许可

感谢 [Screendrop](https://github.com/fayazara/Screendrop) 及其贡献者提供项目基础。Framecho 的应用发布与维护在本仓库进行，问题请提交到 [Framecho Issues](https://github.com/helson-lin/Screendrop/issues)。

本仓库沿用 [CC0 1.0 Universal](LICENSE)。外部壁纸、第三方依赖及云端 Worker 的许可应分别查看各自来源，不能将本仓库许可自动套用到这些资源。
