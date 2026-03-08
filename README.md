# SendLog

Offline-first iOS app for spray wall boulders.

## What this build includes
- Import a wall photo from your library.
- Auto-detect likely holds on device using Vision contours.
- Optional remote hold detection endpoint with automatic fallback to on-device detection.
- Tap holds to select a boulder problem.
- Save problems with name, fixed grade picker (`6a` to `8a`), notes, and selected holds.
- Browse walls and saved problems fully offline.
- Browse a global problems library with search and grade filter.
- Optional manual hold editing: remove wrong holds and add holds by tapping the wall image.
- Tap-to-segment manual hold mode: tapping a hold first tries point-based segmentation, then falls back to a ring marker.
- Optional wall mask import per wall: provide a static black/white mask image to limit detection/segmentation to the wall area.
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

## Optional remote hold detection
Set `SENDLOG_HOLD_DETECTION_URL` to enable remote detection.

Ways to set it:
- Xcode scheme environment variable: `SENDLOG_HOLD_DETECTION_URL=https://your-server/detect-holds`
- `Info.plist` string key: `SENDLOG_HOLD_DETECTION_URL`

If the remote call fails or is not configured, the app falls back to local Vision detection automatically.

Starter backend code is in `tools/hold_detection_server`.

### Remote endpoint contract
Request (`POST`, JSON):
```json
{
  "image_base64": "<base64-jpeg>",
  "image_width": 1536,
  "image_height": 2048
}
```

Response (`200`, JSON):
```json
{
  "holds": [
    {
      "rect": { "x": 0.12, "y": 0.42, "width": 0.07, "height": 0.06 },
      "contour": [
        { "x": 0.13, "y": 0.43 },
        { "x": 0.18, "y": 0.43 },
        { "x": 0.17, "y": 0.48 }
      ],
      "confidence": 0.94
    }
  ]
}
```

All coordinates are normalized to `[0, 1]` in image space.

### Point segmentation contract (optional)
Request (`POST /segment-hold`, JSON):
```json
{
  "image_base64": "<base64-jpeg>",
  "image_width": 1536,
  "image_height": 2048,
  "point": { "x": 0.51, "y": 0.74 }
}
```

Response (`200`, JSON):
```json
{
  "hold": {
    "rect": { "x": 0.47, "y": 0.71, "width": 0.08, "height": 0.07 },
    "contour": [
      { "x": 0.48, "y": 0.72 },
      { "x": 0.55, "y": 0.73 },
      { "x": 0.54, "y": 0.78 }
    ],
    "confidence": 0.93
  },
  "provider": "sam"
}
```
