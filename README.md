# Later

Later is a native iOS app that recovers the intent behind screenshots. All screenshot recognition and persistence happen on-device.

## Current checkpoint

This repository now proves the first local intent-recovery loop:

1. Request Photo Library access with context.
2. Fetch the latest 50 assets marked as screenshots by PhotoKit.
3. Run accurate Vision OCR locally and persist processing state with SwiftData.
4. Extract prices, domains, date/address language, and meaningful text chunks.
5. Classify with deterministic rules plus Apple sentence embeddings when the runtime provides them.
6. Fall back to calibrated rules-only scoring when system embeddings are unavailable.
7. Persist structured `LaterItem` objects and show them in a category-first actionable list.
8. Route uncertain results to **Needs You** and expose classifier diagnostics in the screenshot debug view.

## Run on an iPhone

1. Open `Later.xcodeproj` in Xcode.
2. Select the `Later` target and choose your development team under Signing & Capabilities.
3. Connect an iPhone running iOS 18 or newer.
4. Build and run, then grant full Photos access when prompted.

The simulator can exercise permission and empty states, but a real photo library is required to validate the PhotoKit → Vision OCR path.
