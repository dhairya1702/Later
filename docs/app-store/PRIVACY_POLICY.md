# Later Privacy Policy

Public URL: https://later-screenshots.dhairya911.chatgpt.site/privacy

Effective September 29, 2026

Later helps you organize and resurface screenshots. This policy explains how Later handles information when you use the iOS app and its share extension.

## Information handled on your device

Later accesses only the photos you authorize through Apple's Photos permission. Apple Vision performs text recognition on your device. Screenshot records, recognized details, completion state, preferences, and working copies created by the share extension are stored locally on your device or in Later's private app-group container.

Later does not require an account and does not use advertising or cross-app tracking.

## Screenshot analysis

To understand a screenshot, Later sends a resized copy of the image over encrypted HTTPS to Later's analysis service. The service uses Google Cloud Vertex AI to produce structured details such as a title, category, useful dates, places, prices, and actions.

Screenshot bytes are processed in memory for the request. Later's backend does not save the screenshot, recognized text, title, or returned analysis result, and does not include that content in operational logs. Google processes the request as Later's cloud service provider under the applicable Google Cloud terms.

## Security and service information

Later uses Apple App Attest to verify legitimate app installations and protect the analysis service from abuse. The service retains security records including an App Attest public key or derived installation identifier, assertion counters, rate-limit counters, and related timestamps. These records are used only to provide and secure the service. They are not connected to an account or used for advertising or tracking.

When you send an image through the share extension, Later may send an APNs device token, the Apple push environment, and a random item identifier so Apple Push Notification service can deliver an analysis-completion notification. Later does not retain the APNs device token after servicing that request.

Operational infrastructure may process ordinary network information, such as an IP address, as needed to deliver and protect the service. Later does not use that information to build a profile or track you across apps or websites.

## Sharing

Later does not sell personal information. Information is shared only with service providers needed to operate the features you request:

- Google Cloud, including Cloud Run, Firestore, Vertex AI, and Secret Manager, for secure analysis and abuse prevention.
- Apple, including App Attest and APNs, for app verification and notification delivery.

## Retention and deletion

Screenshots and analysis results are not retained by Later's backend. Security and quota records are retained for as long as reasonably necessary to operate, protect, and enforce limits on the service.

You can delete an item and its locally stored details inside Later. When an item is linked to the Photos library, Later can also request deletion of the original; iOS asks you to confirm, and Photos manages its Recently Deleted retention. Deleting Later removes its local app data subject to normal iOS and backup behavior.

## Your choices

You can change Photos, Notifications, Calendars, and Reminders permissions at any time in iOS Settings. Later asks before creating a calendar event or reminder and uses those permissions only for the action you choose.

## Children

Later is a general-audience productivity app and is not directed to children under 13.

## Changes

This policy may be updated when Later's practices or features change. The effective date above will be updated when material changes are made.

## Contact

For privacy questions or support, email dhairya.lalwani@icloud.com. Support information is also available from Settings → Support in Later and from the Support URL on Later's App Store product page.
