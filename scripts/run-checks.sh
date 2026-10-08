#!/bin/bash
# Compiles each standalone check in scripts/ against the production sources it
# exercises and runs it. Used by CI and before every release
# (cmd/framecho-release); runs locally the same way.
#
# Each check's output is kept in $out/logs. On GitHub Actions a table of
# results is added to the job summary.
set -euo pipefail

cd "$(dirname "$0")/.."
out="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/framecho-checks"
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
  Framecho/ProjectiveHomography.swift Framecho/RecordingClipTimeline.swift \
  Framecho/RecordingCardMotion.swift scripts/check-card-motion.swift

check editor-viewport \
  Framecho/AnnotationCanvasViewport.swift scripts/check-editor-viewport.swift

check screenshot-save \
  Framecho/ScreenshotEditFileTransaction.swift scripts/check-screenshot-save.swift

check recording-export-options -parse-as-library \
  Framecho/VideoCompressionModels.swift Framecho/RecordingExportTiming.swift \
  scripts/check-recording-export-options.swift

check editor-resources "${strict[@]}" \
  Framecho/BoundedCGImageCache.swift Framecho/AnnoRedactionPreviewCache.swift \
  Framecho/StudioScreenLayerCache.swift scripts/check-editor-resources.swift

check recording-pause "${strict[@]}" \
  Framecho/RecordingPauseTimeline.swift scripts/check-recording-pause.swift

check library-date-sections "${strict[@]}" \
  Framecho/CaptureLibraryDateSections.swift scripts/check-library-date-sections.swift

check cloud-image-transcode -default-isolation MainActor -parse-as-library \
  Framecho/CloudImageTranscoder.swift Framecho/CloudUploadOptions.swift \
  scripts/check-cloud-image-transcode.swift

check text-recognition -default-isolation MainActor -parse-as-library \
  Framecho/ImageTextRecognizer.swift scripts/check-text-recognition.swift

check pinned-geometry "${strict[@]}" \
  Framecho/PinnedScreenshotGeometry.swift scripts/check-pinned-geometry.swift

check app-permissions "${strict[@]}" \
  Framecho/AppPermission.swift scripts/check-app-permissions.swift

check onboarding-launch "${strict[@]}" \
  Framecho/OnboardingLaunch.swift scripts/check-onboarding-launch.swift

# The annotation engine without its AppKit drawing and text-editing views.
engine=(
  Framecho/Engine/AnnoEditor.swift Framecho/Engine/AnnoEditorInteraction.swift
  Framecho/Engine/ArrowShared.swift Framecho/Engine/ArrowTypes.swift Framecho/Engine/Arrowheads.swift
  Framecho/Engine/Box.swift Framecho/Engine/ColorTag.swift Framecho/Engine/CurvedArrow.swift Framecho/Engine/Document.swift
  Framecho/Engine/GeoPaths.swift Framecho/Engine/Geometry2d.swift Framecho/Engine/InkPath.swift
  Framecho/Engine/Intersect.swift Framecho/Engine/Measure.swift Framecho/Engine/Mat.swift Framecho/Engine/MathUtils.swift
  Framecho/Engine/PathBuilder.swift Framecho/Engine/PerfectDash.swift Framecho/Engine/Shape.swift
  Framecho/Engine/ShapeRenderer.swift Framecho/Engine/Shapes2d.swift Framecho/Engine/StraightArrow.swift
  Framecho/Engine/StrokeOptions.swift Framecho/Engine/StrokeOutline.swift Framecho/Engine/StrokePipeline.swift
  Framecho/Engine/TextMeasure.swift Framecho/Engine/Theme.swift Framecho/Engine/Vec.swift
  Framecho/AnnotationTool.swift Framecho/AnnotationSwatch.swift
)

check annotation-engine -default-isolation MainActor -parse-as-library \
  "${engine[@]}" Framecho/AnnotationColorSampler.swift Framecho/AnnotationMeasureScanner.swift \
  scripts/check-annotation-engine.swift

check annotation-document -default-isolation MainActor -parse-as-library \
  "${engine[@]}" Framecho/AnnotationDocument.swift Framecho/AnnotationBackground.swift \
  Framecho/AnnotationPresetStore.swift Framecho/AnnotationShadowStyle.swift Framecho/AnnotationMetrics.swift \
  scripts/check-annotation-document.swift

check history-metadata "${strict[@]}" \
  Framecho/ScreenshotHistoryItem.swift scripts/check-history-metadata.swift

check legacy-storage-migration "${strict[@]}" \
  Framecho/LegacyStorageMigration.swift scripts/check-legacy-storage-migration.swift

check hotkeys "${strict[@]}" \
  Framecho/CaptureHotkeys.swift scripts/check-hotkeys.swift

check background-layout -default-isolation MainActor -parse-as-library \
  Framecho/AnnotationBackgroundLayout.swift Framecho/AnnotationBackground.swift \
  Framecho/AnnotationShadowStyle.swift Framecho/AnnotationSwatch.swift scripts/check-background-layout.swift

check recording-timelines "${strict[@]}" \
  Framecho/RecordingViewportTimeline.swift Framecho/RecordingPointerTimeline.swift \
  Framecho/RecordingPointerStream.swift Framecho/RecordingMotionSpring.swift \
  Framecho/RecordingClipTimeline.swift Framecho/PointerCaptureFile.swift \
  Framecho/RecordingOverlayEffects.swift Framecho/RecordingCursorStyle.swift \
  scripts/check-recording-timelines.swift

echo "All checks passed."
