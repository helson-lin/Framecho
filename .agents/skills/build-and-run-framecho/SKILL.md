---
name: build-and-run-framecho
description: "Build the Framecho macOS app with xcodebuild, kill any running instance (of any scheme), and launch the fresh build. Use this skill whenever the user asks to run, launch, relaunch, or try out the app, or says things like 'build and run' or 'restart the app'."
---

# Build and Run Framecho

Builds Framecho via `xcodebuild`, kills any running instance of the app
(whichever scheme launched it), then launches the new build. Run the commands
from the repository root.

## Steps

1. **Pick a scheme.** The shared schemes all build the same target:

   - `Framecho` - the Debug app, `Framecho.app`.
   - `Framecho Dev` - the `Debug Dev` configuration: a separate
     `Framecho Dev.app` with bundle ID `com.jarinhe.Framecho.dev`, so it can
     run beside an installed Framecho with its own settings and permissions.
   - `Framecho Demo` - the same `Framecho.app` as `Framecho`, launched with
     `--demo-mode`.

   Use `Framecho` unless the user named a scheme. Confirm the list with:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Framecho.xcodeproj -list 2>/dev/null | sed -n '/Schemes:/,$p' | tail -n +2
```

2. **Resolve build settings for the chosen scheme** - don't hardcode the
   configuration or output path, since they vary per scheme:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Framecho.xcodeproj \
  -scheme "<SCHEME_NAME>" -showBuildSettings 2>/dev/null \
  | grep -E "^\s*(CONFIGURATION|BUILT_PRODUCTS_DIR|FULL_PRODUCT_NAME|EXECUTABLE_NAME) "
```

Use `CONFIGURATION` for the `-configuration` flag in the build step, and
`BUILT_PRODUCTS_DIR` + `FULL_PRODUCT_NAME` to construct the `.app` path for
the run step.

3. **Build** the project with the resolved scheme/configuration:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Framecho.xcodeproj \
  -scheme "<SCHEME_NAME>" \
  -configuration "<CONFIGURATION>" \
  -destination "platform=macOS" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -20
```

If the output shows `BUILD FAILED`, stop here, read the `error:` lines, and
help the user fix them. Do not run a broken build. If the output is empty or
unclear, re-run without the grep filter to get full output for diagnosis.

4. **Kill every running instance of the app, across all schemes** - not just
   the one being launched. An old instance from another scheme leaves
   duplicate menu bar icons and competing hotkeys:

```bash
killall Framecho 2>/dev/null
killall "Framecho Dev" 2>/dev/null
```

(It's fine if these fail because that variant wasn't running. If a scheme with
a new `EXECUTABLE_NAME` is added, add its `killall` line here too.)

5. **Run** the freshly built app using the path resolved in step 2:

```bash
open "<BUILT_PRODUCTS_DIR>/<FULL_PRODUCT_NAME>"
```

For `Framecho Demo`, pass the demo launch argument yourself (the scheme sets
`--demo-mode`, but `open` doesn't pass it):

```bash
open "<BUILT_PRODUCTS_DIR>/Framecho.app" --args --demo-mode
```

## When to Use

- User says "run it", "build and run", "try it out", "relaunch the app"
- After making code changes, when the user wants to see the change live rather
  than just verify it compiles (for compile-only checks, use `build-framecho`
  instead)

## Notes

- DerivedData paths change between clean builds - always resolve
  `BUILT_PRODUCTS_DIR` via `-showBuildSettings` (step 2).
- Debug builds are signed with the maintainer's Apple Development certificate
  for team `64S5F787T9`, so screen recording and other privacy permissions
  survive rebuilds.
