# Later

Later is a native iOS 18+ app that turns buried screenshots into useful, resurfaced items. Screenshot metadata, imported images, and app state remain on-device; screenshot understanding is performed by a Cloud Run service using Gemini through Vertex AI. The analysis path does not retain screenshots or analysis results; Firestore holds only App Attest and quota metadata.

Version 1.0 (build `2026092901`) was submitted to App Review on September 29, 2026 after TestFlight and physical-device QA. Automatic release is enabled for approval.

Public links:

- Website: https://later-screenshots.dhairya911.chatgpt.site
- Support: https://later-screenshots.dhairya911.chatgpt.site/support
- Privacy Policy: https://later-screenshots.dhairya911.chatgpt.site/privacy
- Support email: dhairya.lalwani@icloud.com

## What works today

1. PhotoKit discovers screenshots and Apple Vision performs OCR on-device.
2. A resized image is sent over HTTPS to the authenticated analysis service, which extracts intent, dates, prices, places, links, contact actions, source apps, and likely accidental captures.
3. SwiftData stores structured items locally and presents them in searchable, actionable groups.
4. Notifications resurface forgotten items, schedule date-sensitive reminders, and suggest cleanup without notifying for completed, expired, duplicate-copy, or accidental items.
5. Cleanup finds old, expired, date-passed, duplicate, and likely accidental screenshots and reconciles deletions with Photos.
6. Items can be marked done, restored from Completed, or deleted, with contextual actions such as opening links, calling, emailing, adding reminders, and creating calendar events.

## Share to Later

Sharing a screenshot to Later does not hold the share sheet open while Gemini works:

1. The share extension saves the image in Later's private app-group inbox.
2. An iOS background `URLSession` uploads it and the share sheet dismisses.
3. Cloud Run analyzes the image in memory and sends an APNs notification when it is ready.
4. iOS delivers the result to Later, which imports it into the local library. If the background transfer fails, Later keeps the queued image and retries when the app opens.

The backend does not persist screenshots or analysis results.

## Backend protection

Later uses Apple App Attest to enroll genuine iOS installations and issue renewable, rate-limited credentials that the main app shares with its extension. Firestore stores only cryptographic public keys, replay counters, quota counters, and timestamps—never screenshots, OCR, titles, or analysis results. Per-install, burst, legacy, and global limits provide layered protection against an extracted token or a compromised installation running up AI costs.

The implementation is backward-compatible while TestFlight users are on an older build. The legacy embedded token must remain enabled until a protected build has migrated, after which it can be rotated and disabled.

## Run on an iPhone

1. Open `Later.xcodeproj` in Xcode.
2. Select the `Later` target and choose your development team under Signing & Capabilities.
3. Connect an iPhone running iOS 18 or newer.
4. Build and run, then complete onboarding and grant Photos and notification access when prompted.

The simulator can exercise permission and empty states, but a physical iPhone is required to validate the full PhotoKit, background-upload, APNs, and share-extension flow.

## Development

The main app is under `Later/`, tests are under `LaterTests/`, the share extension is under `LaterShareExtension/`, and the Node service is under `tools/vision-spike/`.

The production URL and temporary migration bearer token belong only in ignored `Later/Configuration/CloudConfig.local.xcconfig`. Never commit or print that file. See `AGENTS.md` for the exact production account, App Attest rollout, deployment safeguards, testing commands, and TestFlight process.

The app uses Apple-provided HTTPS/TLS and operating-system data protection. It does not implement proprietary or custom encryption algorithms.

## Privacy and release documentation

App Store privacy answers, review notes, the policy source, support copy, and the release checklist are under `docs/app-store/`. The public-site source is under `public-site/`; when data handling or support details change, update the repository documents and the hosted pages together.

The current App Store privacy disclosure is Device ID only, used for App Functionality, not linked to identity, and not used for tracking. Resized screenshots are processed transiently to service an analysis request and are not retained by Later's backend.
