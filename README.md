# SendLog

SendLog is an offline-first iOS companion for home boards, spray walls, and training resets. Import a wall photo, let the bundled Core ML model find the holds, clean up anything by hand, then build and log boulders directly on the image.

It is designed for the messy, useful reality of board climbing: multiple resets, tiny tweaks to hold boxes, project notes, attempts, ticks, search, grade filters, and backups that keep your wall data portable.

## Screenshots

<p>
  <img src="docs/screenshots/sendlog-library.png" alt="SendLog wall library" width="260">
  <img src="docs/screenshots/sendlog-wall-detail.png" alt="SendLog wall detail with detected holds and saved problems" width="260">
  <img src="docs/screenshots/sendlog-problems.png" alt="SendLog global problems library" width="260">
</p>

## Features

- Import wall photos and organize them by wall and reset.
- Detect holds fully offline with the bundled FastSAM/Core ML model.
- Manually add, remove, move, and resize hold boxes when the model needs a spot.
- Draw wall areas and keep hold detection focused on the climbable surface.
- Tap holds to compose boulder problems with grades, notes, starts, finishes, and selected footholds.
- Track attempts, ticks, and session time without leaving the app.
- Browse all walls, problems, and log entries with search, sorting, and grade filters.
- Export and import a full JSON backup of walls, holds, problems, session logs, and wall images.

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
