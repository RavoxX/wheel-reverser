<img src="ScrollReverser/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="">

# Scroll Reverser

A small menu bar app that reverses the scroll direction of your mouse and trackpad independently.
Requires macOS 13 or later.

## Install

1. Download the DMG from the [latest release](https://github.com/RavoxX/wheel-reverser/releases/latest) and drag the app to Applications.
2. The app is not notarized. On first launch, go to System Settings > Privacy & Security and click "Open Anyway".
3. Allow Scroll Reverser under Accessibility when asked. macOS requires this to change scroll events.

Updates can be installed from the menu. Every download is checked against the SHA3-256 checksum published with the release.

## Build

Open `ScrollReverser.xcodeproj` in Xcode and run, or build a release DMG:

```bash
scripts/release.sh
```

`scripts/release.sh --publish` also creates the GitHub release for the current version.

