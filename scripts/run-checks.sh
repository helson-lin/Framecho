#!/bin/bash
# Compiles each standalone check in scripts/ against the production sources it
# exercises and runs it. Used by CI and before every release
# (cmd/screendrop-release); runs locally the same way.
#
# Each check's output is kept in $out/logs. On GitHub Actions a table of
# results is added to the job summary.
set -euo pipefail

cd "$(dirname "$0")/.."
out="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/screendrop-checks"
mkdir -p "$out/logs"

# Checks that can't run here, with the reason. Anything else in scripts/
# named check-*.swift must be run below, so a new check can't be forgotten.
not_run=(
  # Needs a movie fixture from the motion-blur benchmark (docs/editor-performance.md).
  scripts/check-editor-cancellation.swift
)
for file in scripts/check-*.swift; do
  if [[ " ${not_run[*]} " != *" $file "* ]] && ! grep -q "$file" "$0"; then
    echo "error: $file isn't run by scripts/run-checks.sh. Add a check line for it, or list it in not_run." >&2
    exit 1
  fi
done

strict=(-swift-version 6 -strict-concurrency=complete -default-isolation MainActor -parse-as-library)

summary="${GITHUB_STEP_SUMMARY:-}"
if [[ -n "$summary" ]]; then
  printf '### Standalone checks\n\n| Check | Result |\n| --- | --- |\n' >> "$summary"
fi

report() {
  [[ -n "$summary" ]] && printf '| %s | %s |\n' "$1" "$2" >> "$summary"
  return 0
}

check() {
  local name="$1"; shift
  local log="$out/logs/$name.log"
  echo "==> $name"
  # Optimised, but keeping precondition messages: a plain -O build drops
  # them, and a failing check would only say it trapped.
  if ! xcrun swiftc -O -assert-config Debug -module-cache-path "$out/module-cache" "$@" -o "$out/$name" 2>&1 | tee "$log"; then
    report "$name" "❌ doesn't compile"
    exit 1
  fi
  if ! "$out/$name" 2>&1 | tee -a "$log"; then
    report "$name" "❌ $(grep -m1 -E 'Precondition failed|Fatal error|FAIL' "$log" | sed 's/|/\\|/g' || echo 'failed')"
    exit 1
  fi
  report "$name" "✅ $(tail -n 1 "$log" | sed 's/|/\\|/g')"
}

check card-motion \
  Screendrop/ProjectiveHomography.swift Screendrop/RecordingClipTimeline.swift \
  Screendrop/RecordingCardMotion.swift scripts/check-card-motion.swift

check editor-viewport \
  Screendrop/AnnotationCanvasViewport.swift scripts/check-editor-viewport.swift

check screenshot-save \
  Screendrop/ScreenshotEditFileTransaction.swift scripts/check-screenshot-save.swift

check recording-export-options -parse-as-library \
  Screendrop/VideoCompressionModels.swift Screendrop/RecordingExportTiming.swift \
  scripts/check-recording-export-options.swift

check editor-resources "${strict[@]}" \
  Screendrop/BoundedCGImageCache.swift Screendrop/AnnoRedactionPreviewCache.swift \
  Screendrop/StudioScreenLayerCache.swift scripts/check-editor-resources.swift

check recording-pause "${strict[@]}" \
  Screendrop/RecordingPauseTimeline.swift scripts/check-recording-pause.swift

check cloud-image-transcode -default-isolation MainActor -parse-as-library \
  Screendrop/CloudImageTranscoder.swift Screendrop/CloudUploadOptions.swift \
  scripts/check-cloud-image-transcode.swift

check text-recognition -default-isolation MainActor -parse-as-library \
  Screendrop/ImageTextRecognizer.swift scripts/check-text-recognition.swift

check pinned-geometry "${strict[@]}" \
  Screendrop/PinnedScreenshotGeometry.swift scripts/check-pinned-geometry.swift

check app-permissions "${strict[@]}" \
  Screendrop/AppPermission.swift scripts/check-app-permissions.swift

check onboarding-launch "${strict[@]}" \
  Screendrop/OnboardingLaunch.swift scripts/check-onboarding-launch.swift

# The annotation engine without its AppKit drawing and text-editing views.
engine=(
  Screendrop/Engine/AnnoEditor.swift Screendrop/Engine/AnnoEditorInteraction.swift
  Screendrop/Engine/ArrowShared.swift Screendrop/Engine/ArrowTypes.swift Screendrop/Engine/Arrowheads.swift
  Screendrop/Engine/Box.swift Screendrop/Engine/CurvedArrow.swift Screendrop/Engine/Document.swift
  Screendrop/Engine/GeoPaths.swift Screendrop/Engine/Geometry2d.swift Screendrop/Engine/InkPath.swift
  Screendrop/Engine/Intersect.swift Screendrop/Engine/Mat.swift Screendrop/Engine/MathUtils.swift
  Screendrop/Engine/PathBuilder.swift Screendrop/Engine/PerfectDash.swift Screendrop/Engine/Shape.swift
  Screendrop/Engine/ShapeRenderer.swift Screendrop/Engine/Shapes2d.swift Screendrop/Engine/StraightArrow.swift
  Screendrop/Engine/StrokeOptions.swift Screendrop/Engine/StrokeOutline.swift Screendrop/Engine/StrokePipeline.swift
  Screendrop/Engine/TextMeasure.swift Screendrop/Engine/Theme.swift Screendrop/Engine/Vec.swift
  Screendrop/AnnotationTool.swift Screendrop/AnnotationSwatch.swift
)

check annotation-engine -default-isolation MainActor -parse-as-library \
  "${engine[@]}" scripts/check-annotation-engine.swift

check annotation-document -default-isolation MainActor -parse-as-library \
  "${engine[@]}" Screendrop/AnnotationDocument.swift Screendrop/AnnotationBackground.swift \
  Screendrop/AnnotationPresetStore.swift Screendrop/AnnotationShadowStyle.swift Screendrop/AnnotationMetrics.swift \
  scripts/check-annotation-document.swift

check history-metadata "${strict[@]}" \
  Screendrop/ScreenshotHistoryItem.swift scripts/check-history-metadata.swift

check hotkeys "${strict[@]}" \
  Screendrop/CaptureHotkeys.swift scripts/check-hotkeys.swift

check background-layout -default-isolation MainActor -parse-as-library \
  Screendrop/AnnotationBackgroundLayout.swift Screendrop/AnnotationBackground.swift \
  Screendrop/AnnotationShadowStyle.swift Screendrop/AnnotationSwatch.swift scripts/check-background-layout.swift

check recording-timelines "${strict[@]}" \
  Screendrop/RecordingViewportTimeline.swift Screendrop/RecordingPointerTimeline.swift \
  Screendrop/RecordingPointerStream.swift Screendrop/RecordingMotionSpring.swift \
  Screendrop/RecordingClipTimeline.swift Screendrop/PointerCaptureFile.swift \
  Screendrop/RecordingOverlayEffects.swift scripts/check-recording-timelines.swift

echo "All checks passed."
