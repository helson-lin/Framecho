---
name: release-framecho
description: "Release the Framecho macOS app to GitHub using the framecho-release CLI tool. Use this skill whenever the user wants to publish a new version, create a release, ship an update, cut a build, push a release to GitHub, or update the appcast. Also use when they mention archiving, notarization, DMG creation, Sparkle signing, bumping the version/build, or anything related to building and distributing a new Framecho version."
---

# Release Framecho

Framecho is released with a Go CLI in `cmd/framecho-release`. It runs **fully
non-interactively**, so a release can be run end to end from a chat session.
Run every command below from the repository root.

There are two modes:

- **Full auto (`-build`)** - run the checks, then archive, export (Developer
  ID), notarize, staple, package, sign and publish. Nothing in Xcode's GUI is
  required.
- **Package-only** (no `-build`) - assumes a notarized
  `~/Downloads/Framecho.app` was already exported from Xcode, then packages and
  publishes it.

Prefer **full auto** unless the user says they've already exported the app.

## Prerequisites

Always required:

1. Tools installed: `create-dmg` (brew), `gh` (GitHub CLI, authenticated), `git`, `plutil`, `go`.
2. The Sparkle EdDSA private key in the login keychain under the account
   `com.jarinhe.Framecho`. Without it, installed copies can't be updated.
3. The Sparkle `sign_update` binary, found in `build/release` or the
   `Framecho-*` DerivedData folder (building or archiving the project creates it).

For **full auto (`-build`)** additionally:

4. `xcodebuild`, `xcrun`, `ditto` (all part of Xcode).
5. The Developer ID Application certificate for team `64S5F787T9`.
6. A notarytool keychain profile named `framecho-notary`, created once with:
   ```bash
   xcrun notarytool store-credentials framecho-notary --apple-id <apple-id> --team-id 64S5F787T9
   ```
   If notarization fails with a credentials error, the profile is missing or
   wrong - ask the user to re-run `store-credentials`.

## Flags

- `-build` - run the archive → export → notarize → staple phase first.
- `-set-version <x.y.z>` - set `MARKETING_VERSION` before archiving (and commit it). Used with `-build`.
- `-set-build <n>` - set `CURRENT_PROJECT_VERSION` before archiving (and commit it). Used with `-build`.
- `-scheme <name>` - Xcode scheme to archive (default `Framecho`).
- `-notes "<text>"` - release notes, one bullet per line (markdown `- ` prefixes are stripped). Skips the interactive prompt.
- `-notes-file <path>` - read release notes from a file instead.
- `-notary-profile <name>` - notarytool keychain profile (default `framecho-notary`).
- `-yes` / `-y` - assume "yes" for all confirmation prompts.
- `-skip-checks` - release without running the checks or consulting CI. Emergencies only.

## Running a full release

1. **Decide the version and build number.** The build number
   (`CURRENT_PROJECT_VERSION`) **must increase** every release or Sparkle won't
   offer the update. Check the current values:
   ```bash
   grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" Framecho.xcodeproj/project.pbxproj | sort -u
   ```
   Pick the next `MARKETING_VERSION` (dotted semver like `0.40.1`, never
   regressing) and `CURRENT_PROJECT_VERSION` = current + 1.
2. **Make sure code changes are committed and pushed** to `main` first, so the
   release tag points at the released source. If CI failed for that commit,
   the tool stops.
3. **Run it:**
   ```bash
   go run ./cmd/framecho-release -build -yes \
     -set-version <x.y.z> -set-build <n> \
     -notes "First note
   Second note"
   ```
   Notarization blocks for a few minutes - this is expected, not a hang. Use a
   generous tool timeout (~10 min).

Package-only, with the app already exported:

```bash
go run ./cmd/framecho-release -yes -notes "Your notes here"
```

## What it does (in order)

1. **Checks** - `scripts/run-checks.sh`, `go vet` and `go test`, plus the CI result for the commit.
2. With `-build`: **set version/build** (commits the pbxproj), **archive** the `Framecho` scheme, **export** with Developer ID, **notarize** with `notarytool submit --wait`, **staple**, and place the app at `~/Downloads/Framecho.app`.
3. **Validate** the app's version, build and Sparkle keys.
4. **Collect release notes** (from `-notes`/`-notes-file`, else stdin).
5. **Create** `~/Downloads/Framecho.dmg` with `create-dmg` and **sign** it with Sparkle's `sign_update`.
6. **Push commits** (e.g. the version bump) to `main`.
7. **GitHub release** - `gh release create vX.Y.Z` on `helson-lin/Framecho` with the DMG attached.
8. **Update and push `appcast.xml`** - prepend the new `<item>` (replacing any entry for the same build).

The release is created **before** the appcast is pushed, so a published
appcast never points at a missing release. Network operations are retried with
backoff, and re-running is safe: an existing release gets the DMG re-uploaded
and the appcast entry for that build is replaced, not duplicated.

## Configuration

- GitHub repo: `helson-lin/Framecho` · branch: `main` · team: `64S5F787T9` · bundle ID: `com.jarinhe.Framecho`.
- Sparkle feed: `https://raw.githubusercontent.com/helson-lin/Framecho/main/appcast.xml` (`SUFeedURL` in `Framecho/Info.plist`, alongside `SUPublicEDKey`).
- Repo auto-detected from the working directory (override with `FRAMECHO_REPO`).
- DMG volume: `Framecho` · minimum macOS: `26.4`.

## After releasing

```bash
gh release view v<x.y.z> --repo helson-lin/Framecho --json tagName,assets -q '{tag: .tagName, assets: [.assets[].name]}'
```

The CLI pushes the appcast commit itself, so run `git pull --ff-only origin main`
afterwards to sync the local `main`.

## Troubleshooting

- **Partial failure / network error mid-release** - re-run the exact same command; the pipeline is idempotent.
- **notarytool credentials error** - the `framecho-notary` profile is missing or invalid; have the user re-run `store-credentials`.
- **Notarization "Invalid"** - inspect with `xcrun notarytool log <submission-id> --keychain-profile framecho-notary` (usually a signing or entitlements issue).
- **`xcodebuild archive` fails** - the CLI prints the last lines of output and points `DEVELOPER_DIR` at Xcode. Confirm the scheme is `Framecho`, not `Framecho Dev`.
- **Framecho.app not found** (package-only mode) - export from Xcode first, or use `-build`.
- **sign_update not found** - build or archive the project once so the Sparkle artifacts exist.
- **gh auth** - run `gh auth login`.
- **Build already in appcast** - re-running is safe, but a *new* release needs a higher build number; bump `-set-build`.
