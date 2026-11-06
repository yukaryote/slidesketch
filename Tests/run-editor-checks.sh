#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR%/}/handwritten-checks.XXXXXX")"
device_id="${1:-booted}"
bundle_id="local.handwritten.editor-checks"
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
app_dir="$check_dir/EditorChecks.app"
mkdir -p "$app_dir"
cat > "$app_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.handwritten.editor-checks</string>
<key>CFBundleExecutable</key><string>EditorChecks</string>
<key>CFBundleName</key><string>EditorChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>26.2</string>
<key>UIDeviceFamily</key><array><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
SDKROOT="$sdk_path" xcrun swiftc -sdk "$sdk_path" -target "$(uname -m)-apple-ios26.2-simulator" -module-cache-path "$check_dir/ModuleCache" -parse-as-library \
 "$project_dir/Tests/EditorRegression.swift" \
 "$project_dir/handwritten-slides/SlideModel.swift" \
 "$project_dir/handwritten-slides/SlideArtwork.swift" \
 "$project_dir/handwritten-slides/CanvasEditing.swift" \
 "$project_dir/handwritten-slides/PressureCurve.swift" \
 "$project_dir/handwritten-slides/Layers.swift" \
 "$project_dir/handwritten-slides/Eraser.swift" \
 "$project_dir/handwritten-slides/DrawingCanvas.swift" \
 "$project_dir/handwritten-slides/StudioPanels.swift" \
 "$project_dir/handwritten-slides/BrushSizeBookmarks.swift" \
 "$project_dir/handwritten-slides/ColorDrop.swift" \
 "$project_dir/handwritten-slides/AnimatedImage.swift" \
 "$project_dir/handwritten-slides/TextEditing.swift" \
 "$project_dir/handwritten-slides/Clipboard.swift" \
 "$project_dir/handwritten-slides/VideoOptions.swift" \
 "$project_dir/handwritten-slides/CanvasViewport.swift" \
 "$project_dir/handwritten-slides/RasterDrawing.swift" \
 "$project_dir/handwritten-slides/PixelSelection.swift" \
 "$project_dir/handwritten-slides/LayerGestures.swift" \
 "$project_dir/handwritten-slides/KeynoteExport.swift" \
 "$project_dir/handwritten-slides/ImportedBrush.swift" \
 "$project_dir/handwritten-slides/EditorPerformance.swift" \
 "$project_dir/handwritten-slides/GraphiteBrush.swift" \
 "$project_dir/handwritten-slides/PresentationDimensions.swift" \
 -O -o "$app_dir/EditorChecks"
cp "$project_dir/handwritten-slides/MotionStudy.mp4" "$app_dir/MotionStudy.mp4"
cp "$project_dir/handwritten-slides/ExportTheme.xml" "$app_dir/ExportTheme.xml"
cp "$project_dir/handwritten-slides/COFEPencils.brushset" "$app_dir/COFEPencils.brushset"
cp "$project_dir/Tests/Fixtures/Rake_Brushpack.brushset" "$app_dir/Rake_Brushpack.brushset"
if [[ -n "${2:-}" ]]; then cp -R "$2" "$app_dir/PerformanceDeck"; fi
xcrun simctl install "$device_id" "$app_dir"
trap 'xcrun simctl terminate "$device_id" "$bundle_id" >/dev/null 2>&1 || true; xcrun simctl uninstall "$device_id" "$bundle_id" >/dev/null 2>&1 || true' EXIT
container_dir="$(xcrun simctl get_app_container "$device_id" "$bundle_id" data)"
xcrun simctl launch "$device_id" "$bundle_id"
for attempt in {1..60}; do
 if [ -f "$container_dir/Documents/Failure.txt" ]; then
  cp "$container_dir/Documents/Failure.txt" "$check_dir/Failure.txt"
  cat "$check_dir/Failure.txt"
  exit 1
 fi
 if [ -f "$container_dir/Documents/results.json" ]; then
  cp "$container_dir/Documents/results.json" "$check_dir/results.json"
  cp "$container_dir/Documents/Graphite-quality-check.png" "$check_dir/Graphite-quality-check.png"
  cp "$container_dir/Documents/Playback-check.gif" "$check_dir/Playback-check.gif"
  cp "$container_dir/Documents/Media-export-check.pptx" "$check_dir/Media-export-check.pptx"
  cp -R "$container_dir/Documents/ImportedBrushTest/BrushLibrary" "$check_dir/Brushes"
  cat "$check_dir/results.json"
  printf '\nReport: %s\n' "$check_dir/results.json"
  exit 0
 fi
 sleep 1
done
printf 'Editor checks failed or timed out. Inspect the simulator crash log.\n' >&2
exit 1
