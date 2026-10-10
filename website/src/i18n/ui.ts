// Page copy for each locale. Keys ending in `Html` hold trusted markup (line breaks, <kbd>, <code>)
// and are rendered with `set:html`; everything else is plain text.

const mark = (word: string) => `<span class="mark vf"><span class="vf-b"></span>${word}</span>`;

const zh = {
  htmlLang: 'zh-CN',
  meta: {
    title: 'Framecho — 原生 macOS 截图、录屏与编辑工具',
    description:
      'Framecho 是原生 macOS 截图、录屏与编辑工具：本地素材库、非破坏性编辑、Studio 视频剪辑、3D 运镜，以及部署在你自己 Cloudflare 账号上的云端分享。',
  },
  nav: {
    editor: '图片编辑',
    studio: 'Studio',
    library: '素材库',
    agents: 'AI 助手',
    privacy: '隐私',
    download: '下载',
    language: '切换语言',
  },
  shot: {
    light: '浅色',
    dark: '深色',
    appearance: '切换截图外观',
    language: '切换界面语言',
  },
  hero: {
    release: 'Studio 现在居中近全屏打开，项目在后台加载',
    titleHtml: `一键截下，<br>把${mark('重点')}讲清楚。`,
    lede: 'Framecho 是原生 macOS 截图、录屏与编辑工具。标注、美化、剪辑、加字幕都在本地完成，原图永远不被改动。',
    download: '下载 Framecho.dmg',
    explore: '看看能做什么 ↓',
    facts: (macOS: string) => ['免费 · CC0 开源', `macOS ${macOS}+ · Apple Silicon 与 Intel`, 'Developer ID 签名并经 Apple 公证'],
    alt: {
      light: 'Framecho 图片编辑器（浅色外观）：一篇网页文章截图上有取色标注、编号、矩形框、手绘圈注、像素化、模糊和测量，并套用了壁纸背景',
      dark: 'Framecho 图片编辑器（深色外观）：一篇网页文章截图上有取色标注、编号、矩形框、手绘圈注、像素化、模糊和测量，并套用了壁纸背景',
    },
    tags: ['取色标注直接指向原像素', '编号 · 矩形 · 手绘圈注', '壁纸背景 · 圆角 · 阴影'],
  },
  rail: {
    kicker: '随手可达',
    note: '八个全局快捷键，都可在设置中修改',
    keys: ['全屏截图', '窗口截图', '区域截图', '录屏', '识别并复制文字', '倒计时截图', '截图并置顶', '置顶最近一张'],
  },
  flow: {
    kicker: '一条完整的流程',
    titleHtml: '从按下快捷键，<br>到发出链接。',
    steps: [
      { title: '截取', bodyHtml: '全屏、窗口、区域或录屏。区域选择时按空格切到窗口截图。' },
      { title: '标注', bodyHtml: '悬浮工具条，每个工具一个单键快捷键，画完 <kbd>⌘</kbd><kbd>C</kbd> 即可拷贝。' },
      { title: '美化', bodyHtml: '背景、圆角、阴影、3D 透视，一套预设复用到每一张图。' },
      { title: '分享', bodyHtml: '保存、拷贝，或上传到你自己的 Cloudflare，链接自动进剪贴板。' },
    ],
  },
  editor: {
    kicker: '图片编辑器',
    titleHtml: '标注要快，<br>成图要好看。',
    ledeHtml: '工具都在画布上方的悬浮工具条里，每个都有单键快捷键，手不用离开键盘。编辑记录保存在 <code>.framecho</code> 文件里，随时回来再改。',
    annotationsAlt:
      '用 Framecho 标注的一篇网页文章截图：取色标注指向两处颜色值，两个编号，矩形框和手绘圈注标出重点，一处文字被像素化遮挡，一行标题被模糊，底部测量出一个区块为 716 × 94 px',
    legendLabel: '图中用到的标注工具',
    tools: ['取色', '编号', '矩形', '手绘', '像素化', '模糊', '测量'],
    splitTitleHtml: '一套预设，<br>每张图都好看。',
    features: [
      { key: '背景', valueHtml: '纯色、渐变、壁纸包，留白、圆角、阴影、边框、水印' },
      { key: '效果', valueHtml: '3D 透视（镜头角度、取景、卡片旋转）与渐进模糊' },
      { key: '预设', valueHtml: '保存成 <code>.framechopreset</code>，导入导出，团队共用' },
      { key: '双语', valueHtml: '完整的简体中文与英文界面，跟随系统语言' },
      { key: '非破坏', valueHtml: '裁剪、撤销、重做，原图始终保留' },
    ],
    splitAlt: {
      light: '英文界面的图片编辑器（浅色外观）：侧边栏显示背景壁纸、截图圆角与阴影、3D 透视的镜头角度和取景设置',
      dark: '英文界面的图片编辑器（深色外观）：侧边栏显示自动遮挡、构图、背景壁纸和截图设置',
    },
  },
  studio: {
    kicker: 'Studio 视频编辑',
    titleHtml: '录完就剪，<br>剪完就像成片。',
    lede: '自动缩放跟着鼠标走，3D 运镜在时间线上拖出一段就能加。屏幕和摄像头轨道分开保存，随时重新构图。',
    formats: '导出画幅',
    alt: {
      zhLight: 'Studio 视频编辑器（浅色外观）：预览区是套用壁纸背景的录屏画面，下方时间线有视频、音乐、缩放和三段 3D 运镜',
      zhDark: 'Studio 视频编辑器（深色外观）：预览区是套用壁纸背景的录屏画面，下方时间线有视频、音乐、缩放和三段 3D 运镜',
      enLight: '英文界面的 Studio 视频编辑器（浅色外观）：时间线有视频、音乐、缩放和三段 3D 运镜',
      enDark: '英文界面的 Studio 视频编辑器（深色外观）：时间线有视频、音乐、缩放和三段 3D 运镜',
    },
    features: [
      { title: '自动缩放', body: '鼠标跟随、重建光标、点按高亮，小操作也看得清。' },
      { title: '3D 运镜', body: '画布上用旋转球调姿态，带进入 / 退出过渡，导出含 Metal 运动模糊。' },
      { title: '逐词字幕', body: '设备端转写，逐词高亮；删掉文字就剪掉对应的视频。' },
      { title: '时间线剪辑', body: '分割、裁剪、删除片段，按段调速。' },
      { title: '摄像头与按键', body: '画中画位置、大小、圆角可调；按键字幕自动生成。' },
      { title: '导出', body: '横屏、竖屏、方形，30 / 60 fps，可随时取消。' },
    ],
  },
  library: {
    kicker: '还有这些',
    titleHtml: '每一张截图，<br>都有地方放。',
    library: {
      title: '素材库',
      body: '截图、视频和录屏项目统一管理。智能分组、按日期排列、网格 / 列表切换，批量操作。',
      alt: {
        light: '素材库窗口（浅色外观）：侧边栏选中「录制」，右侧按今天、过去 7 天分组显示三段录屏',
        dark: '素材库窗口（深色外观）：侧边栏选中「录制」，右侧按今天、过去 7 天分组显示三段录屏',
      },
    },
    pin: { title: '置顶截图', body: '把参考图钉在屏幕上，直接在上面标注，滚轮调透明度。', cards: ['设计稿 v2', '接口返回字段'] },
    ocr: { title: '框选即识字', body: '本地 OCR，不用保存截图，排版原样复制。', lines: ['错误码 E1042：令牌已过期，', '请重新登录后再试。'], copied: '已拷贝 ✓' },
    cjk: { title: '为中文而做', body: '完整简体中文界面；OCR 与自动遮挡能读出中英混排。' },
    redact: {
      title: '自动遮挡',
      body: '找出截图里的邮箱、密钥、手机号，一键打码。',
      rows: [
        { key: 'email', value: 'jane.doe@example.com', kind: 'blur', label: '模糊' },
        { key: 'token', value: 'sk_live_9fa2c1e8', kind: 'pixel', label: '像素化' },
        { key: '手机', value: '138 0013 8000', kind: 'pixel', label: '像素化' },
      ],
    },
  },
  agents: {
    kicker: '给 AI 助手用',
    titleHtml: '让 Agent<br>帮你剪视频。',
    ledeHtml:
      '在设置中开启 AI 访问后，Framecho 通过 MCP 把 Studio 的编辑能力交给 Claude 等助手：剪掉口误、加缩放、写片头。所有修改都是非破坏的，在 Studio 里 <kbd>⌘</kbd><kbd>Z</kbd> 就能撤回。',
    terminalLabel: '与 AI 助手的对话示例',
    example: '示例',
    terminalHtml: `<span class="c"># 默认关闭 · 仅本机用户可连接的 Unix socket</span>
<span class="u">你 ›</span> 把昨天那段演示剪干净，口误和停顿都去掉，
    点「部署」的时候放大一下，最后导出竖屏。

<span class="t">→ list_recordings</span>      <span class="c">找到 “录制 · 10月9日 16:42”</span>
<span class="t">→ tighten_narration</span>    <span class="c">移除 14 处停顿，−0:23</span>
<span class="t">→ cut_words</span>            <span class="c">删除 “呃，那个” ×6</span>
<span class="t">→ get_frame</span> <span class="s">t=31.2</span>     <span class="c">定位「部署」按钮</span>
<span class="t">→ add_zoom</span> <span class="s">2.0× · 30.8s</span>
<span class="t">→ export</span> <span class="s">9:16 · 1080p · 60fps</span>

<span class="u">完成 ›</span> 1:48 → 1:19，已保存到 ~/Pictures/Framecho`,
  },
  privacy: {
    kicker: '隐私',
    titleHtml: '你的素材，<br>只在你的地方。',
    tiles: [
      { big: '本地', small: '优先', title: '默认不出 Mac', body: '截图、录屏轨道、编辑项目都保存在本地；备份只需复制一个文件夹。' },
      { big: '设备端', small: '转写', title: '语音不上传', body: '字幕、提词器跟随都在设备端完成。摄像头、麦克风权限只在用到时才请求。' },
      { big: '自托管', small: '分享', title: '没有公共服务器', body: '分享部署在你自己的 Cloudflare 账号上，视频页带播放器、可搜索转写和评论。' },
    ],
  },
  final: {
    iconAlt: 'Framecho 应用图标',
    titleHtml: '下一张截图，<br>用 Framecho。',
    lede: '免费、开源，通过 Sparkle 自动更新。',
    download: '下载 Framecho.dmg',
    releases: '发布记录',
    meta: (version: string, macOS: string) => `v${version} · macOS ${macOS} 或更高版本`,
  },
  footer: {
    creditHtml: (screendrop: string) => `Framecho · CC0 1.0 · 基于 <a href="${screendrop}">Screendrop</a> 开发，由 helson-lin 独立维护`,
    issues: '反馈问题',
    worker: '分享服务',
  },
};

export type UI = typeof zh;

const en: UI = {
  htmlLang: 'en',
  meta: {
    title: 'Framecho — Native screenshots, screen recording and editing for macOS',
    description:
      'Framecho is a native macOS tool for screenshots, screen recordings and editing: a local library, non-destructive edits, a video Studio with 3D camera moves, and sharing that runs on your own Cloudflare account.',
  },
  nav: {
    editor: 'Editor',
    studio: 'Studio',
    library: 'Library',
    agents: 'AI agents',
    privacy: 'Privacy',
    download: 'Download',
    language: 'Change language',
  },
  shot: {
    light: 'Light',
    dark: 'Dark',
    appearance: 'Screenshot appearance',
    language: 'Interface language',
  },
  hero: {
    release: 'Studio now opens centered and nearly full screen, loading projects in the background',
    titleHtml: `Capture it.<br>Make the ${mark('point')} clear.`,
    lede: 'Framecho is a native macOS app for screenshots, screen recordings and editing. Annotate, polish, cut and caption on your Mac — the original is never touched.',
    download: 'Download Framecho.dmg',
    explore: 'See what it does ↓',
    facts: (macOS: string) => ['Free · CC0 open source', `macOS ${macOS}+ · Apple silicon and Intel`, 'Developer ID signed, notarized by Apple'],
    alt: {
      light: 'The Framecho image editor in English (light appearance), with an annotated screenshot of the Chinese editor on a wallpaper background',
      dark: 'The Framecho image editor in English (dark appearance), with an annotated screenshot of the Chinese editor on a wallpaper background',
    },
    tags: ['Color values point at the exact pixel', 'Numbers · boxes · freehand', 'Wallpaper · corners · shadow'],
  },
  rail: {
    kicker: 'Always at hand',
    note: 'Eight global shortcuts, all changeable in Settings',
    keys: ['Full screen', 'Window', 'Area', 'Record screen', 'Copy text on screen', 'Timed capture', 'Capture area & pin', 'Pin latest capture'],
  },
  flow: {
    kicker: 'One complete flow',
    titleHtml: 'From a keystroke<br>to a shared link.',
    steps: [
      { title: 'Capture', bodyHtml: 'Full screen, window, area or video. Press Space while selecting an area to switch to a window.' },
      { title: 'Annotate', bodyHtml: 'A floating toolbar with a single-key shortcut for every tool. Press <kbd>⌘</kbd><kbd>C</kbd> and it’s copied.' },
      { title: 'Polish', bodyHtml: 'Backgrounds, corners, shadows and 3D perspective — save it once as a preset, reuse it everywhere.' },
      { title: 'Share', bodyHtml: 'Save, copy, or upload to your own Cloudflare with the link already on your clipboard.' },
    ],
  },
  editor: {
    kicker: 'Image editor',
    titleHtml: 'Fast to mark up,<br>good to look at.',
    ledeHtml: 'Every tool sits in a floating toolbar above the canvas with its own single-key shortcut, so your hands stay on the keyboard. Edits live in a <code>.framecho</code> file beside the image — come back and change them any time.',
    annotationsAlt:
      'A web article annotated in Framecho: color values sampled from two pixels, two numbered markers, a box and a freehand loop around key lines, one phrase pixelated, one heading blurred, and a block measured at 716 × 94 px',
    legendLabel: 'Annotation tools used in this image',
    tools: ['Color value', 'Number', 'Rectangle', 'Freehand', 'Pixelate', 'Blur', 'Measure'],
    splitTitleHtml: 'One preset,<br>every image looks right.',
    features: [
      { key: 'Background', valueHtml: 'Color, gradient or wallpaper packs, with padding, corners, shadow, border and watermark' },
      { key: 'Effects', valueHtml: '3D perspective (camera angle, framing, card rotation) and progressive blur' },
      { key: 'Presets', valueHtml: 'Saved as <code>.framechopreset</code> to import, export and share with your team' },
      { key: 'Bilingual', valueHtml: 'A complete English and Simplified Chinese interface that follows your system language' },
      { key: 'Lossless', valueHtml: 'Crop, undo and redo freely — the original is always kept' },
    ],
    splitAlt: {
      light: 'The image editor in Simplified Chinese (light appearance), with the wallpaper, corner and shadow settings in the sidebar',
      dark: 'The image editor in Simplified Chinese (dark appearance), with the wallpaper, corner and shadow settings in the sidebar',
    },
  },
  studio: {
    kicker: 'Studio video editor',
    titleHtml: 'Record it, cut it,<br>ship it polished.',
    lede: 'Auto-zoom follows your cursor, and a 3D camera move is one drag on the timeline. Screen and camera are kept as separate tracks, so you can reframe whenever you like.',
    formats: 'Export formats',
    alt: {
      zhLight: 'Studio in Simplified Chinese (light appearance): a wallpaper-framed recording above a timeline with video, music, zoom and three 3D moves',
      zhDark: 'Studio in Simplified Chinese (dark appearance): a wallpaper-framed recording above a timeline with video, music, zoom and three 3D moves',
      enLight: 'Studio in English (light appearance): a wallpaper-framed recording above a timeline with video, music, zoom and three 3D moves',
      enDark: 'Studio in English (dark appearance): a wallpaper-framed recording above a timeline with video, music, zoom and three 3D moves',
    },
    features: [
      { title: 'Auto zoom', body: 'Follows the pointer, rebuilds the cursor and highlights clicks, so small actions read clearly.' },
      { title: '3D camera moves', body: 'Pose the card with an on-canvas trackball, ease in and out, export with Metal motion blur.' },
      { title: 'Word-level captions', body: 'On-device transcription with word highlighting — delete words to cut the video under them.' },
      { title: 'Timeline editing', body: 'Split, trim and delete clips, and change speed per segment.' },
      { title: 'Camera & keystrokes', body: 'Position, size and round the camera bubble; keystroke captions are generated for you.' },
      { title: 'Export', body: 'Landscape, portrait or square at 30 or 60 fps, cancellable at any time.' },
    ],
  },
  library: {
    kicker: 'And there’s more',
    titleHtml: 'Every capture<br>has a place.',
    library: {
      title: 'Library',
      body: 'Screenshots, videos and recording projects in one window — smart groups, date sections, grid or list, batch actions.',
      alt: {
        light: 'The library in Simplified Chinese (light appearance), showing three recordings grouped under Today and Last 7 Days',
        dark: 'The library in Simplified Chinese (dark appearance), showing three recordings grouped under Today and Last 7 Days',
      },
    },
    pin: { title: 'Pinned screenshots', body: 'Float a reference on screen, annotate it in place, scroll to change its opacity.', cards: ['Design v2', 'API response fields'] },
    ocr: { title: 'Select to copy text', body: 'On-device OCR — no screenshot saved, layout preserved.', lines: ['Error E1042: your token expired.', 'Sign in again and retry.'], copied: 'Copied ✓' },
    cjk: { title: 'Fluent in Chinese', body: 'A full Simplified Chinese interface, with OCR and redaction that read mixed Chinese and English.' },
    redact: {
      title: 'Auto redact',
      body: 'Finds emails, keys and phone numbers in a screenshot and covers them in one click.',
      rows: [
        { key: 'email', value: 'jane.doe@example.com', kind: 'blur', label: 'Blur' },
        { key: 'token', value: 'sk_live_9fa2c1e8', kind: 'pixel', label: 'Pixelate' },
        { key: 'phone', value: '+1 415 555 0132', kind: 'pixel', label: 'Pixelate' },
      ],
    },
  },
  agents: {
    kicker: 'For AI agents',
    titleHtml: 'Let an agent<br>edit your video.',
    ledeHtml:
      'Turn on AI access in Settings and Framecho hands Studio’s editing tools to assistants like Claude over MCP: cut the flubs, add zooms, write an intro card. Every edit is non-destructive — press <kbd>⌘</kbd><kbd>Z</kbd> in Studio to undo it.',
    terminalLabel: 'An example conversation with an AI agent',
    example: 'Example',
    terminalHtml: `<span class="c"># Off by default · a Unix socket only your user can reach</span>
<span class="u">You ›</span> Clean up yesterday’s demo — cut the flubs and pauses,
      zoom in when I click “Deploy”, then export it vertical.

<span class="t">→ list_recordings</span>      <span class="c">found “Recording · Oct 9 at 16:42”</span>
<span class="t">→ tighten_narration</span>    <span class="c">removed 14 pauses, −0:23</span>
<span class="t">→ cut_words</span>            <span class="c">deleted “um, so” ×6</span>
<span class="t">→ get_frame</span> <span class="s">t=31.2</span>     <span class="c">found the Deploy button</span>
<span class="t">→ add_zoom</span> <span class="s">2.0× · 30.8s</span>
<span class="t">→ export</span> <span class="s">9:16 · 1080p · 60fps</span>

<span class="u">Done ›</span> 1:48 → 1:19, saved to ~/Pictures/Framecho`,
  },
  privacy: {
    kicker: 'Privacy',
    titleHtml: 'Your captures<br>stay yours.',
    tiles: [
      { big: 'Local', small: 'first', title: 'Nothing leaves your Mac', body: 'Screenshots, recording tracks and projects are stored locally; back up by copying one folder.' },
      { big: 'On-device', small: 'speech', title: 'Your voice isn’t uploaded', body: 'Captions and teleprompter tracking run on device. Camera and microphone are only requested when used.' },
      { big: 'Self-hosted', small: 'sharing', title: 'No public server', body: 'Sharing runs on your own Cloudflare account, with a player, searchable transcript and comments.' },
    ],
  },
  final: {
    iconAlt: 'Framecho app icon',
    titleHtml: 'Make your next<br>screenshot in Framecho.',
    lede: 'Free, open source, and kept up to date with Sparkle.',
    download: 'Download Framecho.dmg',
    releases: 'Release notes',
    meta: (version: string, macOS: string) => `v${version} · macOS ${macOS} or later`,
  },
  footer: {
    creditHtml: (screendrop: string) => `Framecho · CC0 1.0 · Built on <a href="${screendrop}">Screendrop</a>, maintained independently by helson-lin`,
    issues: 'Report an issue',
    worker: 'Sharing service',
  },
};

export const ui = { zh, en } as const;
export type Locale = keyof typeof ui;
