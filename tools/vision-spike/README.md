# Later screenshot analysis service

This directory contains the Cloud Run service used by Later. Production analysis uses Gemini through Vertex AI. OpenAI remains available only as an optional local comparison provider.

The service processes image bytes in memory and returns structured JSON. It does not save screenshots.

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

After creating a GCP project with billing enabled and signing in with `gcloud auth login`, run:

```sh
./tools/vision-spike/deploy-gcp.sh YOUR_GCP_PROJECT_ID
```

The script:

- enables Cloud Run, Cloud Build, Artifact Registry, and Vertex AI;
- creates a service account that can invoke Vertex AI;
- deploys Gemini Flash Lite with zero minimum and two maximum instances;
- generates a request token;
- writes the Cloud Run URL and token to the ignored `Later/Configuration/CloudConfig.local.xcconfig` file.

No Gemini API key is used. Cloud Run authenticates to Vertex AI through its service account.

## Run locally

```sh
cd tools/vision-spike
npm start
```

The service uses Cloud Run's `PORT` variable, or port `8080` locally. `LATER_API_TOKEN` is optional locally and required by the deployment script. Send it as `Authorization: Bearer <token>`.
