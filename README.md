# Later

Later is a native iOS app that recovers the intent behind screenshots. Screenshot metadata and app state remain on-device; screenshot understanding is performed by the stateless Cloud Run analysis service.

## Current checkpoint

This repository now proves the first local intent-recovery loop:

1. Request Photo Library access with context.
2. Fetch the latest 50 assets marked as screenshots by PhotoKit.
3. Send a resized screenshot to the stateless Gemini analysis service.
4. Extract prices, domains, dates, addresses, actionable entities, and meaningful text.
5. Persist processing state and structured results locally with SwiftData.
6. Show structured `LaterItem` objects in a category-first actionable list.
7. Route uncertain results to **Needs You** and expose classifier diagnostics in the screenshot debug view.

## Run on an iPhone

1. Open `Later.xcodeproj` in Xcode.
2. Select the `Later` target and choose your development team under Signing & Capabilities.
3. Connect an iPhone running iOS 18 or newer.
4. Build and run, then grant full Photos access when prompted.

The simulator can exercise permission and empty states, but a real photo library is required to validate the PhotoKit → Vision OCR path.
