#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
project_id="${1:-$(gcloud config get-value project 2>/dev/null)}"
region="${GCP_REGION:-us-central1}"
service_name="${GCP_SERVICE_NAME:-later-analysis}"
model="${GEMINI_MODEL:-gemini-2.5-flash-lite}"
service_account_name="${GCP_SERVICE_ACCOUNT:-later-analysis}"

if [[ -z "$project_id" || "$project_id" == "(unset)" ]]; then
  echo "Usage: ./tools/vision-spike/deploy-gcp.sh YOUR_GCP_PROJECT_ID" >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud is required. Install the Google Cloud CLI and run: gcloud auth login" >&2
  exit 1
fi

api_token="${LATER_API_TOKEN:-$(openssl rand -hex 32)}"
service_account_email="${service_account_name}@${project_id}.iam.gserviceaccount.com"
project_number="$(gcloud projects describe "$project_id" --format='value(projectNumber)')"
build_service_account="${project_number}-compute@developer.gserviceaccount.com"

gcloud config set project "$project_id"
gcloud services enable \
  aiplatform.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  --project "$project_id"

if ! gcloud iam service-accounts describe "$service_account_email" \
  --project "$project_id" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$service_account_name" \
    --display-name "Later screenshot analysis" \
    --project "$project_id"
fi

gcloud projects add-iam-policy-binding "$project_id" \
  --member "serviceAccount:${service_account_email}" \
  --role roles/aiplatform.user \
  --condition=None \
  --quiet >/dev/null

# New GCP projects no longer grant the default source-build identity broad
# permissions. Give it only the documented role needed to build Cloud Run.
gcloud projects add-iam-policy-binding "$project_id" \
  --member "serviceAccount:${build_service_account}" \
  --role roles/run.builder \
  --condition=None \
  --quiet >/dev/null

gcloud run deploy "$service_name" \
  --source "$script_dir" \
  --project "$project_id" \
  --region "$region" \
  --service-account "$service_account_email" \
  --allow-unauthenticated \
  --min 0 \
  --max 2 \
  --concurrency 10 \
  --cpu 1 \
  --memory 512Mi \
  --timeout 180 \
  --port 8080 \
  --set-env-vars "AI_PROVIDER=vertex,GOOGLE_CLOUD_PROJECT=${project_id},VERTEX_LOCATION=${region},GEMINI_MODEL=${model},LATER_API_TOKEN=${api_token}"

service_url="$(gcloud run services describe "$service_name" \
  --project "$project_id" \
  --region "$region" \
  --format='value(status.url)')"
service_host="${service_url#https://}"
local_config="$repo_root/Later/Configuration/CloudConfig.local.xcconfig"

umask 077
printf 'LATER_VISION_BASE_URL = https:/$()/%s\nLATER_ANALYSIS_TOKEN = %s\n' \
  "$service_host" "$api_token" > "$local_config"

echo
echo "Later analysis is live: $service_url"
echo "The ignored iPhone configuration was written to:"
echo "$local_config"
echo "Build the app normally; both the app and share extension will use Cloud Run."
