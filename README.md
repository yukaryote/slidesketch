# SlideSketch

A native iPad presentation editor with Apple Pencil drawing, movable text and media, and editable PowerPoint export. An independent project, not affiliated with Procreate.

## Build and run

Open `handwritten-slides.xcodeproj` in Xcode 26.2 or later and select the `handwritten-slides` scheme. Choose an iPad Simulator and run, or select your own signing team in Signing & Capabilities before running on a physical iPad.

The display name is **SlideSketch**. The existing project name and bundle identifier (`iyu.handwritten-slides`) are retained so updates keep the same on-device documents.

```sh
xcodebuild -project handwritten-slides.xcodeproj \
  -scheme handwritten-slides -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Editor

- Draw and erase on user-created transparent layers with blending modes.
- Adjust brush size, bookmarked sizes, stabilization, pressure response, color, and pencil tilt shading.
- Double-tap the side of a supported Apple Pencil to switch between brush and eraser. Turn on Double Tap in iPad Settings → Apple Pencil. The app respects the system Off setting and preserves separate brush and eraser settings.
- Pinch to zoom, pan with two fingers, undo with a two-finger tap, and open Copy & Paste with a three-finger downward swipe.
- Move, resize, rotate, reorder, and edit text, images, animated GIFs, and video. Raster drawings support manual pixel lasso selection.
- Use ColorDrop and reference drawing layers for fills.
- Change every slide's dimensions through Actions → Presentation size. The default is 1600 × 900 pixels; presets and custom sizes fit existing content proportionally and can be undone.
- Export editable deck files or `.pptx` files for PowerPoint/Keynote. Text and media export as separate editable objects; drawings export as raster artwork.

## Brushes and storage

The bundled COFE brush pack and rake regression fixture were supplied for this private project and remain subject to their creators' terms. Importing a `.brush` or `.brushset` preserves available tip/grain assets and supported dynamics. Several COFE presets reference built-in Procreate textures that are absent from the archive; these use labeled approximations. Dual-brush/wet mixing is not reproduced exactly, and the Finger Smudge preset supplies a tip rather than a smudge engine.

Decks and media are saved in the app's Documents container. Brush assets use `Documents/BrushLibrary`; an older `Documents/Brushes` library is migrated without removing the original. Device backups, signing keys, provisioning profiles, and Xcode user state are not stored in this repository.

## Checks

Boot an iPad Simulator, then run:

```sh
Tests/run-editor-checks.sh booted
```

You may substitute a Simulator UUID and optionally pass a local performance-deck directory as the second argument. The script builds an isolated test app, exercises drawing/input, storage migration, layers, transforms, fill, media playback data, dimensions, and PPTX packaging, and prints a path to the results. Apple Pencil hardware double-tap and physical tilt must also be checked on an iPad with a compatible Pencil.

## Signing lifetime

A free Apple Personal Team provisioning profile expires seven days after issuance. Rebuilding and reinstalling over the existing app preserves its documents; uninstalling the app removes its local data. App code cannot extend Apple's signing lifetime. Paid membership enables other signing/distribution options, but development builds still require renewal.

See [Apple's developer-account signing limits](https://developer.apple.com/help/account/basics/about-your-developer-account/) and [developer program enrollment](https://developer.apple.com/help/account/membership/program-enrollment/).
