---
name: build-framecho
description: "Build the Framecho macOS app using xcodebuild. Use this skill whenever the user asks to build, compile, or check if the Framecho project compiles successfully. Also use it when the user asks to fix build errors, verify changes compile, or run a debug build."
---

# Build Framecho

Run from the repository root:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Framecho.xcodeproj \
  -scheme Framecho \
  -configuration Debug \
  -destination "platform=macOS" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -20
```

Add `CODE_SIGNING_ALLOWED=NO` when the maintainer's signing identity (team
`64S5F787T9`) isn't available. If the build reports a missing Metal toolchain,
run `xcodebuild -downloadComponent MetalToolchain` once.

## Interpreting Results

- **BUILD SUCCEEDED** -- the build passed, report success to the user.
- **BUILD FAILED** with `error:` lines -- read each error, identify the source file and line, and help the user fix them. After fixing, re-run the build to verify.
- If the output is empty or unclear, re-run without the grep filter to get full output for diagnosis.

A passing build isn't the whole verification: `scripts/run-checks.sh` runs the
standalone checks, and `go test ./cmd/...` tests the release tool.

## When to Build

- After making code changes, if the user asks to verify they compile
- When the user explicitly says "build", "compile", or "check if it builds"
- After fixing build errors, to confirm the fix worked
