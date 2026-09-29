# App Store Compliance Checklist

## Completed in the repository

- Privacy manifests are included in both the app and share-extension targets.
- `UserDefaults` use declares required-reason code `CA92.1` for app and app-group preferences.
- The manifests disclose a device identifier used for app functionality/security, not linked to identity and not used for tracking.
- `ITSAppUsesNonExemptEncryption` is `false`; Later uses Apple-provided HTTPS/TLS and no custom or non-exempt encryption.
- Privacy and Support pages are accessible inside Settings.
- The public Privacy and Support pages are published at stable HTTPS URLs and linked from the app.
- Production service logs do not include screenshot-derived category, kind, content, title, OCR, or analysis results.
- Production revision `later-analysis-00010-z4m` is live with App Attest enabled and the approved scaling limits.
- Version 1.0 build `2026092901` was uploaded successfully to App Store Connect on September 29, 2026.
- Build `2026092901` passed final TestFlight and physical-iPhone smoke testing.
- App Privacy was published as Device ID used for App Functionality, not linked to identity, and not used for tracking.
- The Privacy Policy, Support, and Marketing URLs were entered in App Store Connect.
- Required iPhone (`1284 × 2778`) and 13-inch iPad (`2064 × 2752`) screenshots were uploaded.
- The listing uses `Later: Visual Memory`, subtitle `Your screenshot organizer`, primary category Productivity, price Free, and age rating 4+ with no override.
- App Review contact information, review notes, content-rights information, and export compliance are complete.
- Version 1.0 build `2026092901` was submitted to App Review on September 29, 2026 with automatic release enabled.
- Publish-ready privacy policy, support copy, App Privacy answers, and App Review notes are maintained in this directory.

## While App Review is pending

- Monitor App Store Connect and `dhairya.lalwani@icloud.com` for review questions or rejection details.
- Do not change the submitted privacy answers or hosted policy independently of the implementation.
- Do not disable legacy-token access while an older distributed build remains usable.
- Preserve the exact App Review message before changing code, metadata, or the binary.

## After approval and automatic release

- Verify the live App Store product page, screenshots, Support URL, and Privacy Policy URL.
- Install the public App Store build and smoke-test analysis, sharing, APNs completion, Settings links, and Cleanup.
- Verify Cloud Run health and sanitized logs without using a private production screenshot.
- Record the approval and public release date in `AGENTS.md` and this checklist.
