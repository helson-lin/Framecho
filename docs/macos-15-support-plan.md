# Framecho 支持 macOS 15 改造方案

状态：第 1–5 步（界面退路、预览卡片拖拽、字幕清理、语音识别权限、录屏转写）已在 `macos-15-support` 分支实现，其余未实施。

依据：2026-10-11 在 `main`（v0.44.0）上，用 `MACOSX_DEPLOYMENT_TARGET=15.0` 和整模块编译（`SWIFT_COMPILATION_MODE=wholemodule`，一次报出全部错误）构建得到的编译器错误清单，以及对相关代码的阅读。复现命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Framecho.xcodeproj -scheme Framecho -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  MACOSX_DEPLOYMENT_TARGET=15.0 SWIFT_COMPILATION_MODE=wholemodule CODE_SIGNING_ALLOWED=NO
```

## 1. 目标与边界

- 最低系统从 macOS 26.4 降到 **macOS 15.0**。
- macOS 26 上的外观和行为保持不变；macOS 15 上功能尽量等价，只有依赖 macOS 26 新框架的部分降级。
- 不在本次范围：macOS 14 及更早版本（`@Observable` 等需要重写状态层，见第 8 节）。

## 2. 现状结论

编译器只报出 **12 个文件、51 处错误，全部是 macOS 26 的 API**。代码里用到的 macOS 15 API（`Synchronization.Mutex`、`SCRecordingOutput`、Vision 的 Swift API、SwiftUI 15 修饰符）都满足 15.0，不需要改。Sparkle 和 DockProgress 在 15.0 下编译通过。

| 类别 | 文件 | 错误数 | 难度 |
| --- | --- | --- | --- |
| 录屏转写（SpeechAnalyzer） | `RecordingTranscription.swift` | 7 | 高 |
| 提词器语音跟随（SpeechAnalyzer） | `TeleprompterSpeechEngine.swift` | 14 | 中 |
| 字幕清理（FoundationModels） | `CaptionCleanupEngine.swift` | 9 | 低 |
| Liquid Glass 外观 | `AnnotationEditorChrome`、`AnnotationToolStrip`、`PinnedScreenshotViews`、`PreviewOverlayInteraction`、`RecordingBarChrome`、`RecordingBarPresenter`、`RecordingPickerBar` | 17 | 低 |
| 工具栏（`ToolbarSpacer`、`sharedBackgroundVisibility`） | `CaptureLibraryView.swift` | 3 | 低 |
| 拖拽开始与结束（`onDragSessionUpdated`） | `PreviewCardView.swift` | 1 | 中 |

现有代码只有 `ViewModifiers.swift` 里两处 `#available(macOS 26.0, *)`（`scrollEdgeEffectSoftIfAvailable`、`safeAreaBarIfAvailable`），本方案沿用这种写法。

## 3. 界面退路（低风险，不改变 26 上的表现）

### 3.1 Liquid Glass

在 `ViewModifiers.swift` 的 “macOS 26 Availability Helpers” 中新增：

- `glassSurface(in shape: some Shape, interactive: Bool = false)`：26 上调用 `glassEffect(interactive ? .regular.interactive() : .regular, in: shape)`；15 上用 `background(.regularMaterial, in: shape)`。不额外加描边：录制条、选择器、提示气泡和预览标签在玻璃之后已经自己画了边，再加会出现双层边框。`interactive` 在 15 上没有对应效果，直接忽略。
- `glassSurface(interactive:)`：用于原来不传形状的 `.glassEffect()`。26 上仍用系统默认的 `DefaultGlassEffectShape`，保证外观不变；15 上用胶囊形。
- `GlassSurfaceContainer(spacing:content:)`：26 上包一层 `GlassEffectContainer`，15 上原样返回内容。

需要替换的位置（共 17 处）：

| 文件:行 | 现在的写法 |
| --- | --- |
| `AnnotationEditorChrome.swift:41` | `.glassEffect(.regular.interactive())`，默认形状为胶囊 |
| `AnnotationEditorChrome.swift:67` | `.glassEffect(.regular, in: .capsule)` |
| `AnnotationEditorChrome.swift:129` | `.glassEffect(.regular, in: .rect(cornerRadius: 12))` |
| `AnnotationEditorChrome.swift:148`、`:186` | `.glassEffect()` |
| `AnnotationToolStrip.swift:46` | `.rect(cornerRadius: 14)` |
| `PinnedScreenshotViews.swift:145` | `.rect(cornerRadius: 14)` |
| `PinnedScreenshotViews.swift:200`、`:266`、`:331` | `.capsule` |
| `PreviewOverlayInteraction.swift:175` | `.regular.interactive()`，`in: shape` |
| `RecordingBarChrome.swift:209` | `in: shape` |
| `RecordingBarPresenter.swift:321`、`:365` | `in: barShape`、`in: visibilityBannerShape` |
| `RecordingPickerBar.swift:58` | `GlassEffectContainer(spacing:)` |
| `RecordingPickerBar.swift:138`、`:259` | `in: surfaceShape` |

需要设计确认：录制控制条、置顶截图的按钮和预览卡片浮在任意内容之上。15 上换成 Material 后，深色或花哨背景下的对比度要逐一看，必要时用 `.thickMaterial` 或加深描边。

### 3.2 素材库工具栏

`CaptureLibraryView.swift:287`、`:348` 的 `.sharedBackgroundVisibility(.hidden)` 和 `:289` 的 `ToolbarSpacer(.flexible)`：在 `ToolbarContent` 上加 `sharedBackgroundHiddenIfAvailable()` 扩展，并用 `if #available(macOS 26.0, *)` 包住 `ToolbarSpacer`。如果 `ToolbarContentBuilder` 不接受这种可用性分支，就为 26 和 15 各写一套工具栏内容。15 上搜索框会排在系统默认的位置，需要看一眼布局。

### 3.3 预览卡片的拖拽开始与结束（中）

`PreviewCardView.swift:109` 用 `onDragSessionUpdated` 判断拖拽开始和结束，用来：

- 开始时关闭 Quick Look（`ScreenshotPreviewStack.beginDrag`）；
- 结束时，如果开启了「拖出后关闭」（`FramechoPreferences.previewCloseAfterDragging`），就移除卡片（`finishDrag`）。

15 上没有这个 API。实现（`PreviewCardView.swift` 末尾的 `draggableFile` / `FileDragModifier`）：

- 26 上保持 `.draggable(url)` + `onDragSessionUpdated`，行为不变。
- 15 上改用 `.onDrag { … } preview: { … }`：系统在拖拽真正开始时才请求 `NSItemProvider`，在这里回调「开始」；拖出的内容是 `NSItemProvider(object: url as NSURL)`，和 `.draggable(url)` 一样提供文件 URL。
- 拖拽只在鼠标左键按住期间存在，所以「开始」之后每 30ms 检查一次系统级的 `NSEvent.pressedMouseButtons`，左键松开就回调「结束」。无论放到 Finder、别的 App 还是取消，都能检测到；只在拖拽期间检查。

没有采用 AppKit 拖拽源（`NSViewRepresentable` + `NSDraggingSource`）：卡片上叠着悬停操作按钮、双击和右键菜单，用一个 `NSView` 接管鼠标事件很容易破坏这些交互。

在 15 上需要验证：拖到 Finder 能复制文件；拖拽开始时 Quick Look 关闭；「拖出后关闭」开启时，放下和取消拖拽都会移除卡片，与 26 上的行为一致。

## 4. 字幕清理（低）

`CaptionCleanupEngine.swift` 已经有两个实现：Apple 设备端模型（`OnDeviceCaptionEngine`）和 OpenAI 兼容的云端接口。并且当设备端不可用时，默认提供方会自动选云端（`:107`）。只需要：

- 给 `OnDeviceCaptionEngine` 加 `@available(macOS 26.0, *)`；
- `CaptionCleanupEngines.onDeviceUnavailableReason`（`:199`）在 26 以下返回「Apple Intelligence 需要 macOS 26 或更高版本，请改用 OpenAI 兼容 API。」（新字符串，已加中文翻译），`engine(for:)` 中的设备端分支包一层 `#available`。

设置页（`SettingsCaptionAIPane.swift:40`）已经会显示不可用原因，不用改。

## 5. 录屏转写（高，工作量最大）

`RecordingTranscription.swift` 对外只有 `transcribe(screenMovieURL:) -> RecordingTranscript` 和 `resolveLocale()`。字幕、按文字剪辑、MCP 的 `transcribe` / `cut_words` / `tighten_narration` 都只依赖 `RecordingTranscript` 里带时间的逐词结果，所以只在引擎层加一个 15 的实现，上层不用改。

### 5.1 15 上的实现（已实现，`LegacySpeechTranscription.swift`）

`transcribe(screenMovieURL:)` 在 26 上走原有的 SpeechAnalyzer（移到 `transcribeWithSpeechAnalyzer`，代码不变），26 以下走 `LegacySpeechTranscription.transcribe(narrationURL:locale:)`。`extractNarrationAudio(from:)` 和 `makeCues(from:)` 两条路径共用。

- `SFSpeechAudioBufferRecognitionRequest`：`requiresOnDeviceRecognition = true`、`addsPunctuation = true`、`shouldReportPartialResults = true`，识别回调放在专用队列上。
- **分段 → 词**（`LegacyTranscriptAssembly.words`）：从 `formattedString` 里两个分段之间的文字还原空格和标点，标点并到前一个词，空格作为下一个词的前缀，和 SpeechAnalyzer 的词格式一致，中文、英文都适用。
- **长停顿后重新开始**：实测发现，长停顿后识别器会重新开始一段新的转写，最终结果只包含最后一段。中间结果的分段时间全部是 0；只有带 `speechRecognitionMetadata` 的结果（每段话结束时）和最终结果才有真实时间。所以只收集这两类结果，按时间归并（`LegacyTranscriptAssembly.merge`）：和上一段重叠的是修订或重复，替换；在上一段之后开始的是新的一段，追加。
- 一块里有「检测不到语音」的错误（`kAFAssistantErrorDomain` 1110）时按空块处理。

### 5.2 语言

`RecordingTranscriptionService.bestLocale(among:for:)` 抽出了原有的选择顺序（完全匹配 → 同语种 → 英文），两条路径共用。15 上只从 `supportsOnDeviceRecognition == true` 的语言里选，都不支持时提示用户可在「系统设置 → 键盘」中为该语言打开听写。

**不会为了能用就回退到服务器识别**：网站和 README 都承诺「语音不上传」。

### 5.3 长录音

旁白按最长 55 秒切块，切点选在每块最后 8 秒里能量最低的 0.25 秒（`LegacyTranscriptAssembly.quietestSample`），各块时间戳加上偏移后合并；使用空格分词的语言，在块与块之间补空格。

### 5.4 权限

`SFSpeechRecognizer` 需要「语音识别」授权，SpeechAnalyzer 不需要。现在 `Info.plist` 里没有这个说明：

- `Info.plist` 新增 `NSSpeechRecognitionUsageDescription`，`InfoPlist.xcstrings` 中补上中文（已实现）；
- `AppPermission` 新增 `speechRecognition`，`AppPermission.applicable` 在 macOS 26 及以上把它排除；设置的权限列表改为显示 `applicable`（已实现）；
- **不放进首次启动的权限引导**（`isListedInOnboarding`）：引导卡片固定 520pt 高，第 6 行加上「重新打开」提示会超出约 40pt；而且在用到时再请求，系统弹窗出现得更自然；
- 第一次转写或开启提词器前调用 `AppPermissionCenter.ensureSpeechRecognition()`：未决定时弹出系统授权，已拒绝时返回 false（第 5、6 步接入）；
- README「隐私与权限」表格增加一行：语音识别（仅 macOS 15）。

### 5.5 实测（2026-10-11，macOS 27 上直接调用 15 的代码路径）

用 `say` 合成的中文旁白测试：

- 70 秒（2 块）：3 秒识别完；修正「长停顿后重新开始」之前前 23 秒全部丢失，修正后完整、无重复，时间戳单调递增，切点前后衔接正确。
- 4.5 分钟（5 块）：9.8 秒识别完，切点处没有丢失内容。
- 准确度不如 SpeechAnalyzer：「Framecho」被识别为「reach」「remain」，同一句话重复 4 次，有一次漏了「演示一下」；有一处约 2 秒的短句（「录完以后」）识别器在任何回调里都没给出。
- 测试机没有英文的设备端识别模型，所以英文只由 `scripts/check-legacy-transcription.swift` 覆盖，需要在装了英文听写的 macOS 15 上实测。

## 6. 提词器语音跟随（中）

`TeleprompterSpeechEngine` 对外只有 `preflightAssets()`、`start()`、`ingest(_:)` 和进度回调，并且本来就是「尽力而为」：识别失败时提词器只是停止自动滚动，不影响录制。

- 把识别部分抽成文件内的私有协议，两个实现：26 上是现有的 SpeechAnalyzer 实现；15 上是 `SFSpeechAudioBufferRecognitionRequest`（`shouldReportPartialResults = true`、`requiresOnDeviceRecognition = true`），`ingest` 里把转换后的 `AVAudioPCMBuffer` 用 `append(_:)` 送进去。
- 15 上的部分结果每次给出完整文本，所以直接对全部文本重新匹配，用不到现有的「已确定 + 临时」拼接逻辑；进度只前进不后退的规则不变。
- 识别任务在长时间静音后可能自行结束，结束后要重新创建一个请求继续识别。
- `preflightAssets()` 在 15 上改为请求语音识别授权，并检查所选语言是否支持设备端识别。

## 7. 工程、发布与文档

| 位置 | 改动 |
| --- | --- |
| `Framecho.xcodeproj` | 工程级和目标级共 6 处 `MACOSX_DEPLOYMENT_TARGET`（Debug、Release、Debug Dev）从 `26.4` 改为 `15.0` |
| `Framecho/Info.plist` | 新增 `NSSpeechRecognitionUsageDescription` |
| `cmd/framecho-release/main.go:56` | `minSystemVer = "26.4"` 写死了 appcast 的 `sparkle:minimumSystemVersion`，不改的话 15 的用户收不到更新。建议改为从导出的 `.app` 中读取 `LSMinimumSystemVersion`，同时更新 `main_test.go:32` |
| `scripts/run-checks.sh:45` | `swiftc` 没有指定 `-target`，默认按本机系统编译，测不出 15 的兼容问题。加上 `-target "$(uname -m)-apple-macos15.0"` |
| `AGENTS.md` | 改部署目标那一行；新增约定：macOS 26 专属 API 必须加版本判断，并优先用 `ViewModifiers.swift` 里的 `…IfAvailable` 辅助方法 |
| `README.md` | 徽章、系统要求、从源码构建、权限表 |
| 官网 | 系统要求从 appcast 自动读取，不用改 |

### 7.1 两项必须在真机上确认的风险

- **FoundationModels 的弱链接**：macOS 15 上没有 `FoundationModels.framework`。如果它被强链接，App 在 15 上**一启动就会崩溃**。改完后用 `otool -l` 检查，`FoundationModels` 必须是 `LC_LOAD_WEAK_DYLIB`；如果不是，在 `OTHER_LDFLAGS` 里加 `-weak_framework FoundationModels`。
- **Metal 着色器**：本次构建在 Swift 编译阶段就失败了，`StudioMotionBlur.metal` 还没有按 15.0 编译过。Swift 部分改完后要确认它能编译，并在 15 上验证导出时的运动模糊。

## 8. 为什么不考虑 macOS 14 及更早

- `@Observable` / `@Bindable` 需要 macOS 14，覆盖 46 个文件、79 处，是整个 App 的状态层；降到 13 及以下要改回 `ObservableObject`，与 AGENTS.md 的约定相反。
- macOS 14 还要额外处理 15 的 API：`AnnotationMeasureScanner.swift` 的 `Mutex`、`ScreenRecordingManager.swift` 的 `SCRecordingOutput` 和麦克风采集、两个 OCR 文件的 Vision Swift API、6 个文件的 SwiftUI 15 修饰符。
- macOS 11 到 12.2 没有 ScreenCaptureKit，截图和录屏要另写一套管线。

## 9. 验证

**构建**：部署目标为 15.0 时零错误；`scripts/run-checks.sh`、`go test ./cmd/...` 通过。部署目标改成 15.0 后，CI 的常规构建会自动拦下没加版本判断的 macOS 26 API。

**macOS 15 实机**：在 Apple Silicon 上用虚拟化（如 UTM、Tart）装一台 macOS 15。

- 启动、权限引导（包括新的语音识别权限）
- `⌥1`–`⌥8` 全部截图方式，中文 OCR，自动遮挡
- 图片编辑器、置顶截图、录制控制条：玻璃效果的退路在浅色和深色背景下都清晰可读
- 预览卡片拖到 Finder：Quick Look 自动关闭；「拖出后关闭」开、关两种情况
- 录屏（麦克风 + 系统音频 + 摄像头），Studio 剪辑与导出（含运动模糊）
- 转写：中文、英文，短录音和 19 分钟录音；按文字剪辑的准确度
- 字幕清理：云端接口可用，设备端选项显示不可用原因
- 提词器自动滚动
- MCP：`transcribe`、`cut_words`、`tighten_narration`
- Sparkle：从 15 上检查更新，能收到新版本

**macOS 26 回归**：同一组清单再走一遍，确认外观和行为与改造前一致。

## 10. 实施顺序

每一步单独提交，并且每一步都要能在当前的部署目标（26.4）下编译通过。开发时用本文开头的命令覆盖部署目标来检查进度，最后一步再正式修改工程设置。

1. 界面退路：`glassSurface`、`GlassSurfaceContainer`、工具栏（第 3.1、3.2 节）——在 26 上不改变任何表现
2. 预览卡片拖拽的开始与结束（第 3.3 节）
3. 字幕清理的版本判断（第 4 节）
4. 语音识别权限：`Info.plist`、`AppPermission`、设置的权限列表（第 5.4 节）
5. 转写的 15 实现，含切块和长停顿后的分段归并（第 5 节）
6. 提词器的 15 实现（第 6 节）
7. 部署目标改为 15.0，检查脚本加 `-target`，发布工具读取最低系统版本，确认弱链接和 Metal（第 7 节）
8. 文档：AGENTS.md、README

粗略估计：第 1–4 步约 2 天，第 5–6 步约 2–3 天（主要花在转写质量和长录音的调试上），第 7–8 步半天，macOS 15 上的完整测试约 1 天，合计约 5–7 个工作日。

## 11. 已知取舍

- 15 上的转写使用旧一代识别模型，准确度，尤其是中文标点和逐词时间，会比 26 差，按文字剪辑的切点可能需要手动微调。
- 15 上能否转写取决于系统是否装了对应语言的设备端听写模型，App 无法主动下载。
- 字幕清理在 15 上只能用云端接口。
- 以后每用一个 macOS 26 及更新的 API，都要加版本判断，并考虑 15 上的退路。CI 只能拦下编译问题，拦不住运行时的行为差异。
