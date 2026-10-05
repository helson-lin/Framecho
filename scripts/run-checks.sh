#!/bin/bash
# Compiles each standalone check in scripts/ against the production sources it
# exercises and runs it. Used by CI; runs locally the same way.
#
# check-editor-cancellation.swift is left out: it needs a movie fixture from
# the motion-blur benchmark (see docs/editor-performance.md).
set -euo pipefail

cd "$(dirname "$0")/.."
out="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/screendrop-checks"
mkdir -p "$out"

strict=(-swift-version 6 -strict-concurrency=complete -default-isolation MainActor -parse-as-library)

check() {
  local name="$1"; shift
  echo "==> $name"
  xcrun swiftc -O -module-cache-path "$out/module-cache" "$@" -o "$out/$name"
  "$out/$name"
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

echo "All checks passed."
