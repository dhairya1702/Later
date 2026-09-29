# Later screenshot analysis service

This directory contains the Cloud Run service used by Later. Production analysis uses Gemini through Vertex AI. OpenAI remains available only as an optional local comparison provider.

Production was last verified on September 29, 2026 at revision `later-analysis-00010-z4m`: Vertex AI, `gemini-2.5-flash-lite`, App Attest enabled, zero minimum instances, two maximum instances, concurrency 10, 1 CPU, 512 MiB memory, and a 180-second timeout. Version 1.0 build `2026092901`, which uses this service, is submitted to App Review. Keep legacy-token access enabled during the migration window.

The service processes image bytes in memory and returns structured JSON. It does not save screenshots or analysis results. For background share-extension requests, it can also notify the user's device through APNs after analysis completes.

## HTTP API

- `GET /health` returns the configured provider and model.
- `POST /analyze` accepts JPEG, PNG, or WebP image bytes up to 12 MB. Protected builds use a renewable `AppAttest` authorization session; the old bearer token is accepted only during migration.
- Background share requests also provide an item UUID, APNs device token, and APNs environment in request headers. A successful response includes the analysis envelope and an `X-Later-Push-Sent` header so the app can avoid a duplicate local notification.
- `POST /auth/challenge`, `/auth/attest`, and `/auth/assert` enroll genuine Later installations and issue renewable App Attest sessions.

## App Attest and quotas

The service validates Apple's App Attestation certificate chain against the pinned Apple root, verifies the Later app identity and nonce, stores only the installation public key and assertion counter, and rejects replayed assertions. Analysis sessions last seven days and are renewed with a hardware-backed assertion when the app opens.

Firestore stores authentication and quota metadata only. Default limits are 300 analyses per installation per UTC day, 120 per five minutes, 20,000 total per day, and 5,000 total legacy-token requests per day during migration. All limits are configurable through environment variables. `ALLOW_LEGACY_TOKEN=false` disables older builds only after users have migrated.

## Setup

1. Run `npm install` in this directory.
2. For local OpenAI comparisons, copy `.env.example` at the repository root to `.env.local` and add the API key. Never commit or share that file.
3. Put a few `.png`, `.jpg`, `.jpeg`, or `.webp` screenshots in `tools/vision-spike/screenshots/`.
4. Confirm configuration:

   ```sh
   node tools/vision-spike/analyze.mjs --check
   ```

5. Analyze every screenshot in the folder:

   ```sh
   node tools/vision-spike/analyze.mjs
   ```

You can also analyze one image at any location:

```sh
node tools/vision-spike/analyze.mjs /absolute/path/to/screenshot.png
```

Results are written to `tools/vision-spike/results/`. Both screenshots and results are ignored by Git because they may contain private information.

For local Vertex AI testing, set `AI_PROVIDER=vertex`, `GOOGLE_CLOUD_PROJECT`, `VERTEX_LOCATION`, and `GEMINI_MODEL`, then run `gcloud auth application-default login`.

## Deploy to Google Cloud

Production deployment must use Google account `dhairya.lalwani2001@gmail.com` and project `project-a5ac77cc-c119-47d6-bb4`. Verify both before running:

```sh
gcloud config set account dhairya.lalwani2001@gmail.com
gcloud config set project project-a5ac77cc-c119-47d6-bb4
gcloud config list --format='text(core.account,core.project)'
./tools/vision-spike/deploy-gcp.sh project-a5ac77cc-c119-47d6-bb4
```

The script:

- enables Cloud Run, Cloud Build, Artifact Registry, Vertex AI, Firestore, and Secret Manager;
- creates a service account that can invoke Vertex AI and access Firestore;
- requires the existing `later-apns-private-key` Secret Manager secret, grants the service account access, and mounts its latest version as `APNS_PRIVATE_KEY`;
- requires an explicitly created default Firestore Native database in `us-central1`;
- creates or reuses the `later-session-signing-key` Secret Manager secret and mounts it as `LATER_SESSION_SECRET`;
- deploys Gemini Flash Lite with zero minimum and two maximum instances;
- reuses the request token from the ignored local xcconfig when available, otherwise generates one;
- writes the Cloud Run URL and token to the ignored `Later/Configuration/CloudConfig.local.xcconfig` file.

No Gemini API key is used. Cloud Run authenticates to Vertex AI through its service account. The APNs `.p8` key must remain in Secret Manager—never commit it, print it, or place it in an xcconfig file. Do not deploy without the existing production API token unless intentional token rotation is acceptable, because replacing it breaks analysis for distributed builds.

Firestore's location is effectively permanent, so the deployment script will not create the database automatically. Before the first security rollout, create it deliberately:

```sh
gcloud firestore databases create \
  --database='(default)' \
  --location=us-central1 \
  --type=firestore-native \
  --project=project-a5ac77cc-c119-47d6-bb4
```

Keep `ALLOW_LEGACY_TOKEN=true` for the initial backward-compatible deployment. After the protected iOS build has migrated, rotate `LATER_API_TOKEN`, set `ALLOW_LEGACY_TOKEN=false`, deploy again, and only then remove the token from a future app build.

## Run locally

```sh
cd tools/vision-spike
npm start
```

The service uses Cloud Run's `PORT` variable, or port `8080` locally. `LATER_API_TOKEN` is optional locally and required by the deployment script. Send it as `Authorization: Bearer <token>`.

APNs is optional for local service development. Push delivery is enabled only when `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, and `APNS_PRIVATE_KEY` are all configured. Keep the private key out of `.env.local` whenever possible and never commit it.

Run the service checks with:

```sh
cd tools/vision-spike
npm test
npm run check
```
