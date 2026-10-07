# AGENTS.md

## Project overview

Framecho is a native macOS screenshot and screen recording tool. Its Library window opens on normal launch; login launches remain in the menu bar (`LSUIElement = YES`). `AppActivationPolicy` uses `.regular` while Library, Settings, or editor windows are open, and returns to `.accessory` when they close. Built with SwiftUI + AppKit and no Xcode test target.

**Deployment target:** macOS 26.4, built with Xcode 27.1 (macOS 27 SDK).
**Bundle ID:** `com.jarinhe.Framecho`
**Origin:** started as a fork of [Screendrop](https://github.com/fayazara/screendrop) and is now maintained independently; upstream changes are no longer merged. The GitHub repository was renamed from `helson-lin/Screendrop` to `helson-lin/Framecho` on 2026-10-07. Copies installed before then poll the old `raw.githubusercontent.com/helson-lin/Screendrop` feed URL and older appcast entries link to old release URLs; both rely on GitHub's rename redirects, so never create a new repository named `helson-lin/Screendrop`.

## Build

Use `xcodebuild` from the command line. The project requires Xcode 27.1, the toolchain releases and CI use. If the build reports a missing Metal toolchain (needed for `StudioMotionBlur.metal`), run `xcodebuild -downloadComponent MetalToolchain` once:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Framecho.xcodeproj \
  -scheme Framecho \
  -configuration Debug \
  -destination "platform=macOS" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -20
```

There are three shared schemes, all building the same target: `Framecho`, `Framecho Dev` (runs the `Debug Dev` configuration: a separate `Framecho Dev` app with bundle ID `com.jarinhe.Framecho.dev`) and `Framecho Demo` (launches with `--demo-mode`). Use `Framecho` unless told otherwise.

No Xcode test target exists. Automated verification is:

- **Build success** (add `CODE_SIGNING_ALLOWED=NO` to build without the maintainer's signing identity).
- **`scripts/run-checks.sh`** - compiles each standalone check in `scripts/` against the production sources it exercises and runs it. Add new checks there: the script fails if a `scripts/check-*.swift` isn't run by it or listed in its `not_run` (where `check-editor-cancellation.swift` sits, as it needs a fixture from the motion-blur benchmark). To make code checkable, keep its logic in files that compile without the app (see the `nonisolated` geometry, permission and timeline files the checks use).
- **`go test ./cmd/...`** for the release tool.

CI (`.github/workflows/ci.yml`) runs all three on pull requests and pushes to `main`, using Xcode 27.1 on GitHub's `xcode-27` runner image (beta), and can be started by hand on any branch. Pushes touching only `appcast.xml`, docs or Markdown are skipped. Each check's result appears in the job summary; on failure the logs are uploaded as `check-logs`.

## Swift concurrency settings

The project uses **strict concurrency** settings that are easy to violate:

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` - every type is implicitly `@MainActor` unless explicitly opted out.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` - imports in one file do not leak to other files.

When adding new types, assume `@MainActor` isolation by default. If a type must be `Sendable` or `nonisolated`, mark it explicitly.

## Architecture

App source is in `Framecho/`, flat except for `Engine/` (the annotation engine). Key flow:

1. **App entry** - `FramechoApp.swift`: `@main` App struct. Creates a `MenuBarExtra`, a Settings window, and an annotation editor `WindowGroup`.
2. **Hotkeys** - `HotkeyManager.swift`: Registers global Carbon hotkeys (Option+1/2/3) at launch via `AppDelegate`.
3. **Capture** - `CaptureCoordinator.swift` → `ScreenshotManager.swift`: Fullscreen uses `ScreenCaptureKit`; window/area use `/usr/sbin/screencapture` CLI.
4. **Preview** - `PreviewPanelPresenter.swift` + `PreviewWindowView.swift`: Borderless floating `NSPanel` showing a screenshot stack. Uses `ScreenshotPreviewStack` (an `@Observable` model).
5. **Annotation** - `AnnotationEditorWindow.swift` + `AnnotationEditorModel.swift` + `AnnotationCanvas.swift`: Full annotation editor with tools (rectangle, ellipse, arrow, freehand, text, numbered circles, pixelate, blur). All coordinates are normalized (0..1) relative to the image.
6. **Rendering** - `AnnotationRenderer.swift`: Composites annotations onto the source image at full pixel resolution using Core Graphics.
7. **Preferences** - `FramechoPreferences.swift` + `SettingsView.swift`: `UserDefaults`-backed settings (auto-save, auto-copy, auto-compress, export directory).
8. **Library** - `CaptureLibraryView.swift` + `CaptureLibraryModel.swift`: Single native sidebar/detail/inspector scene. `CaptureLibraryCollection.swift` reuses AppKit cells for grid/list layouts; `CaptureLibraryThumbnails.swift` bounds decoded image memory and concurrency. The model merges History metadata with recording packages by standardized package path. Existing capture storage and editable sidecars remain authoritative. `CaptureLibraryActions.swift` handles batch operations and prevents trashing captures while their editors are open.

### Singletons

Most managers are `static let shared` singletons: `ScreenshotManager`, `CaptureCoordinator`, `HotkeyManager`, `PreviewPanelPresenter`, `ScreenshotPreviewStack`, `PreviewWindowPlacement`, `PreviewWindowCaptureExclusion`. Follow this pattern for new services.

### Annotation coordinate system

All annotation positions/sizes are normalized to `[0, 1]` relative to the source image dimensions. Pixel conversion happens only in `AnnotationRenderer` at export time and in the canvas view for display. Do not use pixel coordinates in the model layer.

## Conventions

- **Minimal dependencies.** Apart from Apple frameworks, the only Swift packages are Sparkle (updates) and DockProgress. Don't add packages without a strong reason.
- **`@Observable` macro** (Observation framework) is used for state - not `ObservableObject`/`@Published`.
- **App sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`) - the app needs screen capture permissions and direct filesystem access.
- Screenshots are saved as lossless PNG to `NSTemporaryDirectory()` first, then optionally compressed to JPEG on export.
- **Persisted formats** live in `~/Library/Application Support/Framecho`: `<image>.framecho` edit sidecars beside History images, `.framechorec` recording packages, and `history.json`. Exported presets are `.framechopreset` (`com.jarinhe.framecho.preset`). Files from before the rename (`.screendrop`, `.screendroprec`, `.screendroppreset`) are migrated at launch by `LegacyStorageMigration` or still read; keep that path working and never rename a persisted key or format without a migration.

## Commits

Make atomic commits. Each commit should represent exactly one logical change (e.g. one feature, one bug fix, one refactor). Do not bundle unrelated changes into a single commit. If a task touches multiple concerns, split it into separate commits. Verify the build passes before committing.

## Entitlements / permissions

- Screen recording permission (`NSScreenCaptureUsageDescription` in Info.plist) is required.
- Hardened runtime is enabled.
- No App Sandbox - do not add sandbox entitlements.

## Releasing Framecho

Updates are served by Sparkle from `appcast.xml` on `main` of `helson-lin/Framecho`, with DMGs attached to GitHub releases. The EdDSA private key lives in the login keychain under the account `com.jarinhe.Framecho`; its public key is `SUPublicEDKey` in `Info.plist`. Back the key up (`generate_keys --account com.jarinhe.Framecho -x <file>`); without it, installed copies can't be updated.

Builds are signed for team `64S5F787T9`: Debug with the Apple Development certificate, Release with Developer ID Application (hardened runtime on). Because the signature is tied to the team rather than the binary, privacy permissions survive rebuilds and updates.

To release, run `go run ./cmd/framecho-release -build -set-version <x.y.z> -set-build <n>`. It first runs the same checks as CI (`scripts/run-checks.sh`, `go vet`, `go test`) and stops if any fail or if CI failed for the commit; `-skip-checks` bypasses that, for emergencies only. Then it archives, exports with Developer ID, notarizes, staples, builds and Sparkle-signs the DMG, prepends `appcast.xml`, pushes it, and creates the GitHub release. Notarization reads the `framecho-notary` keychain profile; create it once with:

```bash
xcrun notarytool store-credentials framecho-notary --apple-id <apple-id> --team-id 64S5F787T9
```
