# Later repository guide

## What this app does

Later is a native iOS 18+ SwiftUI app that turns screenshots into useful, resurfaced items instead of leaving them buried in Photos.

- PhotoKit discovers screenshots. Onboarding processes up to 100; foreground, library-change, and background passes process up to 10 at a time.
- Apple Vision OCR runs on-device. A resized image is sent to the analysis service for structured understanding.
- The analysis result identifies intent, category/kind, dates, prices, places, links, contact actions, source surfaces/apps (for example Reddit or LinkedIn), and likely accidental screenshots.
- SwiftData stores screenshot records and `LaterItem` data locally. The backend is stateless and does not persist screenshots.
- The home experience groups actionable items, supports search, detail actions, marking items done, deletion, and a completed list.
- Cleanup surfaces old, expired, date-passed, duplicate, and likely accidental screenshots. Deleting a screenshot from Photos is reconciled back into the app when full or limited library access permits it.
- Notifications deliberately resurface eligible forgotten items, schedule date-sensitive reminders, and occasionally suggest cleanup. Completed, duplicate-copy, expired/date-passed, and otherwise ineligible items must not receive discovery reminders.
- The share extension imports screenshots shared directly to Later and uses the same analysis pipeline.

The main app code is under `Later/`, tests are under `LaterTests/`, and the Node analysis service is under `tools/vision-spike/`.

## Architecture and privacy boundaries

- iOS client: SwiftUI, SwiftData, PhotoKit, Vision, UserNotifications, and EventKit.
- Cloud service: a small Node HTTP service in `tools/vision-spike/server.mjs`.
- AI provider in production: Vertex AI using `gemini-2.5-flash-lite` by default.
- `POST /analyze` accepts JPEG, PNG, or WebP bytes (maximum 12 MB) and returns structured JSON.
- `GET /health` returns service/provider/model status.
- The deployed endpoint is publicly reachable at the Cloud Run network layer, but `/analyze` requires the app-level bearer token in `LATER_API_TOKEN`. `/health` does not require it.
- Image bytes are handled in memory. Do not add screenshot storage or request/response logging that could retain private user content.
- The Cloud Run service account authenticates to Vertex AI with IAM; there is no Gemini API key in the app or service.

## Local app configuration

`Later/Configuration/CloudConfig.xcconfig` contains safe committed defaults and optionally includes:

`Later/Configuration/CloudConfig.local.xcconfig`

The local file contains the real Cloud Run base URL and bearer token. It is intentionally ignored by Git. Both the main app and share extension receive these settings through their Info.plists.

Never print, commit, replace, or share the token. Preserve `.env.local` and `CloudConfig.local.xcconfig` when working in a dirty tree.

## Production Google Cloud deployment

Current production resources:

- Required authenticated GCP user account: `dhairya.lalwani2001@gmail.com`
- GCP project: `project-a5ac77cc-c119-47d6-bb4`
- GCP project number: `1075669514231` (Google-assigned numeric identifier for the same project; it is not an account or a separate project)
- Region: `us-central1`
- Cloud Run service: `later-analysis`
- Runtime service account: `later-analysis@project-a5ac77cc-c119-47d6-bb4.iam.gserviceaccount.com`
- Default model: `gemini-2.5-flash-lite`
- Desired script settings: zero minimum instances, two maximum instances, concurrency 10, 1 CPU, 512 MiB memory, and a 180-second timeout.

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

1. enables Vertex AI, Artifact Registry, Cloud Build, and Cloud Run APIs;
2. creates or reuses the `later-analysis` service account;
3. grants the runtime account `roles/aiplatform.user`;
4. grants the default build identity `roles/run.builder`;
5. builds from `tools/vision-spike/` and deploys the Cloud Run service;
6. reuses the token from `CloudConfig.local.xcconfig` when present, otherwise generates one;
7. writes the deployed URL and token back to the ignored local xcconfig.

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
- Do not bring back the old archive workflow. User-facing item lifecycle actions are Mark as Done, move back from Completed, and Delete.
- Do not schedule discovery reminders for completed, duplicate-copy, expired, date-passed, or likely accidental items. Accidental items belong in cleanup notifications.
- Treat the user's worktree as authoritative. Do not discard unrelated edits or ignored local configuration.

## TestFlight delivery

App Store Connect uses bundle ID `com.dhairyalalwani.Later`; the share extension uses `com.dhairyalalwani.Later.ShareExtension`. Release archives must include the ignored production cloud configuration, use automatic signing for team `X34H6AHCUU`, and have a monotonically increasing `CURRENT_PROJECT_VERSION`.

`TestFlightExportOptions.plist` contains the reusable automatic App Store Connect export settings but no credentials. Uploading a build is separate from deploying Cloud Run; do not redeploy the backend merely to produce a new iOS build.
