# App Store Connect — App Privacy Answers

Use this as the source of truth when completing App Privacy in App Store Connect. Re-audit it whenever data handling changes.

These answers were entered and published in App Store Connect for the version 1.0 submission on September 29, 2026.

## Tracking

- Does this app use data for tracking? **No**
- Does this app or its third-party partners use data for third-party advertising? **No**

## Data collected

Declare **Identifiers → Device ID**:

- Purpose: **App Functionality**
- Linked to the user's identity: **No**
- Used for tracking: **No**

Reason: App Attest keys or derived installation identifiers, assertion counters, quota counters, and timestamps are retained in Firestore to authenticate installations, prevent replay, and enforce service limits. There is no Later account and these records are not used to identify the person.

## Data not declared as collected

Do not declare the categories below while the implementation and provider terms continue to satisfy Apple's exception for data transmitted only to service a request in real time and not retained longer than necessary:

- User Content → Photos or Videos: a resized screenshot is transmitted for analysis, processed in memory, and not retained by Later's backend.
- User Content → Other User Content: on-device OCR text and structured analysis are not stored by Later's backend.
- Identifiers → Device ID for APNs: the device token is used to send the requested completion notification and is not retained after the request.
- Diagnostics: Later does not operate analytics or crash-reporting SDKs and does not retain screenshot-derived operational logs.
- Contact Info, Financial Info, Location, Contacts, Browsing History, Search History, Purchases, Usage Data, Health & Fitness, and Sensitive Info: not collected.

If cloud logging, analytics, crash reporting, support intake, accounts, purchases, or provider retention changes, update both this answer sheet and the privacy policy before release.
