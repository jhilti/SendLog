# SendLog

Offline-first iOS app for spray wall boulders.

## What this build includes
- Import a wall photo from your library.
- Auto-detect likely holds on device using Vision contours.
- Tap holds to select a boulder problem.
- Save problems with name, fixed grade picker (`6a` to `8a`), notes, and selected holds.
- Browse walls and saved problems fully offline.
- Browse a global problems library with search and grade filter.
- Optional manual hold editing: remove wrong holds and add holds by tapping the wall image.
- Export/import a full JSON backup of walls, holds, problems, and wall images.

## Project setup (VS Code + Xcode)
1. Install full Xcode from the App Store.
2. Install XcodeGen:
   ```bash
   brew install xcodegen
   ```
3. Generate the project:
   ```bash
   xcodegen generate
   ```
4. Open `SendLog.xcodeproj` in Xcode:
   ```bash
   open SendLog.xcodeproj
   ```
5. Pick an iOS Simulator and run.

## Why Xcode is still required
You can edit Swift files in VS Code, but iOS Simulator builds/signing rely on the iOS SDK tooling bundled with full Xcode.
