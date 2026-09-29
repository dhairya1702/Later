# Later repository guide

## What this app does

Later is a native iOS 18+ SwiftUI app that turns screenshots into useful, resurfaced items instead of leaving them buried in Photos.

- PhotoKit discovers screenshots. Onboarding processes up to 100; foreground, library-change, and background passes process up to 10 at a time.
- Apple Vision OCR runs on-device. A resized image is sent to the analysis service for structured understanding.
- The analysis result identifies intent, category/kind, dates, prices, places, links, contact actions, source surfaces/apps (for example Reddit or LinkedIn), and likely accidental screenshots.
- SwiftData stores screenshot records and `LaterItem` data locally. The analysis backend does not persist screenshots or analysis results. The hardened authentication layer uses Firestore only for App Attest public keys, replay counters, rate-limit counters, and timestamps.
- The home experience groups actionable items, supports search, detail actions, marking items done, deletion, and a completed list.
- Cleanup surfaces old, expired, date-passed, duplicate, and likely accidental screenshots. Deleting a screenshot from Photos is reconciled back into the app when full or limited library access permits it.
- Notifications deliberately resurface eligible forgotten items, schedule date-sensitive reminders, and occasionally suggest cleanup. Completed, duplicate-copy, expired/date-passed, and otherwise ineligible items must not receive discovery reminders.
- The share extension saves a shared image to the app-group inbox, starts a system background upload, and dismisses without waiting for analysis. Cloud Run sends an APNs completion notification, and the main app imports the saved analysis when iOS delivers the background-session result. If the upload fails after the image is queued, the main app retries it when opened.

The main app code is under `Later/`, tests are under `LaterTests/`, and the Node analysis service is under `tools/vision-spike/`.

## Architecture and privacy boundaries

- iOS client: SwiftUI, SwiftData, PhotoKit, Vision, UserNotifications, and EventKit.
- Cloud service: a small Node HTTP service in `tools/vision-spike/server.mjs`.
- AI provider in production: Vertex AI using `gemini-2.5-flash-lite` by default.
- `POST /analyze` accepts JPEG, PNG, or WebP bytes (maximum 12 MB) and returns structured JSON.
- A share-extension request may include an item UUID, APNs device token, and sandbox/production environment in headers. When APNs is configured, the service sends a `Saved to Later` notification after analysis and reports whether it was sent in `X-Later-Push-Sent`.
- `GET /health` returns service/provider/model status.
- The deployed endpoint is publicly reachable at the Cloud Run network layer, but `/analyze` requires the app-level bearer token in `LATER_API_TOKEN`. `/health` does not require it.
- Image bytes are handled in memory. Do not add screenshot storage or request/response logging that could retain private user content.
- The Cloud Run service account authenticates to Vertex AI with IAM; there is no Gemini API key in the app or service.
- The APNs `.p8` private key is stored in Google Secret Manager as `later-apns-private-key` and mounted into Cloud Run. Never store it in the repository, an xcconfig file, or a normal environment file.
- App Attest enrollment validates Apple's certificate chain, the app identity, nonce, environment, credential ID, and public key. Later then uses a renewable seven-day installation session. Assertion counters and per-install quotas are durable in Firestore; no screenshot content, OCR, titles, or analysis is stored there.
- The default limits are 300 analyses per installation per UTC day, 120 per five minutes, 20,000 total per day, and a temporary 5,000-per-day ceiling for all legacy-token traffic. Keep `ALLOW_LEGACY_TOKEN=true` while an older distributed build is active, then rotate the embedded token and set it to `false` after migration.
- The iOS app does not implement custom or proprietary encryption algorithms. It relies on Apple-provided HTTPS/TLS and operating-system data protection; the App Store Connect encryption questionnaire answer is therefore `None of the algorithms mentioned above` for the current app.

## Local app configuration

`Later/Configuration/CloudConfig.xcconfig` contains safe committed defaults and optionally includes:

`Later/Configuration/CloudConfig.local.xcconfig`

The local file contains the real Cloud Run base URL and bearer token. It is intentionally ignored by Git. Both the main app and share extension receive these settings through their Info.plists.

Never print, commit, replace, or share the token. Preserve `.env.local` and `CloudConfig.local.xcconfig` when working in a dirty tree.

## Public website and App Store privacy

Later's public website is live on ChatGPT Sites. Do not assume Firebase hosts it:

- Landing page: `https://later-screenshots.dhairya911.chatgpt.site`
- Support: `https://later-screenshots.dhairya911.chatgpt.site/support`
- Privacy Policy: `https://later-screenshots.dhairya911.chatgpt.site/privacy`
- Public support email: `dhairya.lalwani@icloud.com`

The site source is under `public-site/`, which intentionally has its own nested Git repository and `.openai/hosting.json`. It contains the landing, support, and privacy pages. The site is public and live; review and update both the source and hosted copy when policy or support details change.

`Later/Resources/Info.plist` defines `LaterSupportURL` and `LaterPrivacyURL`, and Settings links to those URLs. Repository privacy/compliance work currently includes privacy manifests for the app and share extension, the `UserDefaults` required-reason declaration, a non-tracking App Attest device-identifier disclosure, `ITSAppUsesNonExemptEncryption = false`, Settings privacy/support surfaces, sanitized production-service logging, and the App Store materials under `docs/app-store/`.

The sanitized backend and App Attest rollout is deployed and verified. App Store Connect has the live Support and Privacy Policy URLs, the Device ID privacy disclosure from `docs/app-store/APP_PRIVACY_ANSWERS.md`, and the completed version 1.0 listing. Version 1.0 is submitted for review with automatic release enabled. Do not change the public policy, privacy answers, listing metadata, or submitted binary while review is pending unless the submission is deliberately withdrawn and the documentation is updated with it.

An abandoned Firebase Hosting attempt enabled `firebase.googleapis.com`, `firebasehosting.googleapis.com`, and `cloudresourcemanager.googleapis.com` on the production GCP project. No Firebase project registration, Hosting site, URL reservation, or deployment succeeded. Do not treat Firebase as the website host or create Firebase resources unless explicitly requested.

## Production Google Cloud deployment

Current production resources:

- Required authenticated GCP user account: `dhairya.lalwani2001@gmail.com`
- GCP project: `project-a5ac77cc-c119-47d6-bb4`
- GCP project number: `1075669514231` (Google-assigned numeric identifier for the same project; it is not an account or a separate project)
- Region: `us-central1`
- Cloud Run service: `later-analysis`
- Runtime service account: `later-analysis@project-a5ac77cc-c119-47d6-bb4.iam.gserviceaccount.com`
- Default model: `gemini-2.5-flash-lite`
- APNs Secret Manager secret: `later-apns-private-key`
- App Attest session-signing secret: `later-session-signing-key`
- APNs topic: `com.dhairyalalwani.Later`
- Desired script settings: zero minimum instances, two maximum instances, concurrency 10, 1 CPU, 512 MiB memory, and a 180-second timeout.

Last verified on September 29, 2026: revision `later-analysis-00010-z4m` was healthy with Vertex AI, `gemini-2.5-flash-lite`, and App Attest enabled. It served 100% of traffic with zero minimum instances, two maximum instances, concurrency 10, 1 CPU, 512 MiB memory, and a 180-second timeout. Legacy-token access remained enabled for the migration window.

The live service can drift from the script settings after manual changes, so inspect it before assuming its current scaling configuration.

Before every production deployment, verify both `core.account` and `core.project`. Do not deploy unless the active account is exactly `dhairya.lalwani2001@gmail.com` and the active project is exactly `project-a5ac77cc-c119-47d6-bb4`.

### Deploy or update Cloud Run

Prerequisites: Google Cloud CLI, billing enabled, and an authenticated account with permission to enable APIs, manage IAM, build, and deploy Cloud Run.

```sh
gcloud auth login
gcloud config set account dhairya.lalwani2001@gmail.com
gcloud config set project project-a5ac77cc-c119-47d6-bb4
gcloud config list --format='text(core.account,core.project)'
./tools/vision-spike/deploy-gcp.sh project-a5ac77cc-c119-47d6-bb4
```

The deployment script:

1. enables Vertex AI, Artifact Registry, Cloud Build, Firestore, Secret Manager, and Cloud Run APIs;
2. creates or reuses the `later-analysis` service account;
3. grants the runtime account `roles/aiplatform.user` and `roles/datastore.user`;
4. requires the existing `later-apns-private-key` secret, grants the runtime account access to it, and exposes it to the service as `APNS_PRIVATE_KEY`;
5. requires a default Firestore Native database, creates `later-session-signing-key` if absent, and grants the runtime account access;
6. grants the default build identity `roles/run.builder`;
7. builds from `tools/vision-spike/` and deploys the Cloud Run service with APNs, App Attest, and quota configuration;
8. reuses the token from `CloudConfig.local.xcconfig` when present, otherwise generates one;
9. writes the deployed URL and token back to the ignored local xcconfig.

Critical: do not deploy from a fresh machine or checkout without the existing production token unless token rotation is intentional. A newly generated token immediately makes already distributed iOS builds unable to analyze screenshots. If the local config is unavailable, supply the existing token explicitly as `LATER_API_TOKEN` rather than generating a replacement.

Optional deployment overrides are environment variables:

```sh
GCP_REGION=us-central1 \
GCP_SERVICE_NAME=later-analysis \
GCP_SERVICE_ACCOUNT=later-analysis \
GEMINI_MODEL=gemini-2.5-flash-lite \
LATER_API_TOKEN='<existing token>' \
./tools/vision-spike/deploy-gcp.sh project-a5ac77cc-c119-47d6-bb4
```

Never paste a real token into committed files, shell history, logs, issues, or chat output.
Never print, copy into source control, or replace the production APNs private key during a routine deployment. Rotating the Apple key requires updating the Secret Manager secret before deploying.
The deployment script deliberately refuses to create Firestore because its database location is effectively permanent. Create the default Firestore Native database in `us-central1` only as an explicit rollout step.

### Verify and inspect the deployment

```sh
gcloud run services describe later-analysis \
  --project project-a5ac77cc-c119-47d6-bb4 \
  --region us-central1

curl -sS https://later-analysis-cojbflnaka-uc.a.run.app/health

gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="later-analysis"' \
  --project project-a5ac77cc-c119-47d6-bb4 \
  --limit 50
```

The health response should report `ok: true`, provider `vertex`, and the configured Gemini model. Do not use production screenshots for ad hoc endpoint tests.

## Run and test locally

Install and test the analysis service:

```sh
cd tools/vision-spike
npm install
npm test
npm run check
npm start
```

`npm start` listens on `PORT` or 8080. Local Vertex testing requires `AI_PROVIDER=vertex`, `GOOGLE_CLOUD_PROJECT`, `VERTEX_LOCATION`, and `GEMINI_MODEL`, plus Application Default Credentials from `gcloud auth application-default login`.

Open `Later.xcodeproj` to run the iOS app. Use an iOS 18+ simulator for unit tests and a physical iPhone for realistic PhotoKit, notification, share-extension, and action testing. A normal command-line test invocation is:

```sh
xcodebuild test \
  -project Later.xcodeproj \
  -scheme Later \
  -destination 'platform=iOS Simulator,name=<installed simulator name>'
```

Before shipping changes that affect analysis, run both the Swift tests and `npm test` because the iOS decoder and backend response contract must stay aligned.

## Implementation guardrails

- Preserve the current detail action hit-testing behavior when changing the screenshot preview; action buttons must remain above the preview hit region.
- Keep screenshot detail imagery aspect-fit, centered, with visible edges and a blurred fill behind it.
- `ClassificationConfig.classifierVersion` controls re-analysis. Increment it only when existing records genuinely need to be classified again; doing so can generate substantial cloud traffic.
- Keep the app and backend enums/schema compatible. Update Swift decoding/tests and Node tests together.
- Classification uses a closed app-owned taxonomy. Do not display model-invented categories or kinds. Unknown results must fall back to the existing Miscellaneous/Junk presentation; `inspiration` is not a supported category. The internal `boardingPass` kind is intentionally presented to users as the broader `Travel` label.
- Preserve the asynchronous share contract: queue the image before dismissing, use the background URL session, persist its returned analysis in the shared inbox, and avoid sending a duplicate local notification when APNs already delivered one.
- Preserve the App Attest migration path. The main app enrolls or refreshes on launch, stores its short-lived session in the app group for the share extension, and silently falls back to the legacy bearer token until production explicitly disables it. Never disable legacy access while an older TestFlight/App Store build is still in use.
- Do not bring back the old archive workflow. User-facing item lifecycle actions are Mark as Done, move back from Completed, and Delete.
- Do not schedule discovery reminders for completed, duplicate-copy, expired, date-passed, or likely accidental items. Accidental items belong in cleanup notifications.
- Treat the user's worktree as authoritative. Do not discard unrelated edits or ignored local configuration.

## TestFlight delivery

App Store Connect uses bundle ID `com.dhairyalalwani.Later`; the share extension uses `com.dhairyalalwani.Later.ShareExtension`. Release archives must include the ignored production cloud configuration, use automatic signing for team `X34H6AHCUU`, and have a monotonically increasing `CURRENT_PROJECT_VERSION`.

`TestFlightExportOptions.plist` contains the reusable automatic App Store Connect export settings but no credentials. Uploading a build is separate from deploying Cloud Run; do not redeploy the backend merely to produce a new iOS build.

Build `2026092901` (version `1.0`) was uploaded successfully on September 29, 2026. Its export created an App Store provisioning profile with production APNs, App Attest support, and `get-task-allow` disabled. It was installed from TestFlight and passed final physical-device smoke testing, including Settings links, analysis, share-extension upload, completion notification, and Cleanup. Any later upload must use a build number greater than `2026092901`; confirm the latest App Store Connect build before choosing it.

## App Store submission status

Version 1.0, build `2026092901`, was submitted to App Review on September 29, 2026. Automatic release is enabled, so an approval will make the app available without a separate manual-release action.

Submitted listing and compliance values:

- Name: `Later: Visual Memory`
- Subtitle: `Your screenshot organizer`
- Primary category: Productivity
- Price: Free
- Age rating: 4+ with no override (`Not Applicable`)
- Content rights: the app does not contain, show, or access a developer-supplied catalog of third-party content
- Encryption: `ITSAppUsesNonExemptEncryption = false`; no documentation upload is required
- App Privacy: Device ID only, used for App Functionality, not linked to identity, and not used for tracking
- Privacy Policy: `https://later-screenshots.dhairya911.chatgpt.site/privacy`
- Support: `https://later-screenshots.dhairya911.chatgpt.site/support`
- Marketing: `https://later-screenshots.dhairya911.chatgpt.site`
- Support email: `dhairya.lalwani@icloud.com`
- Release mode: automatic after approval

The submitted iPhone screenshots were prepared at `1284 × 2778`; the submitted 13-inch iPad screenshots were captured at `2064 × 2752`. Local working copies are under `app-store-screenshots/` and may contain user-provided images or extracted details. Treat that directory as private release material and do not commit or publish it without an explicit content review.

While review is pending, watch App Store Connect and the support email for App Review questions. Preserve the exact rejection or information-request text before changing code or metadata. After approval, verify the live App Store product page, public URLs, download/install flow, and production analysis health; then record the release date here.
