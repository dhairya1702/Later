#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
project_id="${1:-$(gcloud config get-value project 2>/dev/null)}"
required_account="${GCP_DEPLOY_ACCOUNT:-dhairya.lalwani2001@gmail.com}"
region="${GCP_REGION:-us-central1}"
service_name="${GCP_SERVICE_NAME:-later-analysis}"
model="${GEMINI_MODEL:-gemini-2.5-flash-lite}"
service_account_name="${GCP_SERVICE_ACCOUNT:-later-analysis}"
apns_secret_name="${APNS_SECRET_NAME:-later-apns-private-key}"
session_secret_name="${SESSION_SECRET_NAME:-later-session-signing-key}"
apns_key_id="${APNS_KEY_ID:-JUGJUPBAHM}"
apns_team_id="${APNS_TEAM_ID:-X34H6AHCUU}"
apns_topic="${APNS_TOPIC:-com.dhairyalalwani.Later}"
allow_legacy_token="${ALLOW_LEGACY_TOKEN:-true}"
analysis_daily_limit="${ANALYSIS_DAILY_LIMIT:-300}"
analysis_burst_limit="${ANALYSIS_BURST_LIMIT:-120}"
analysis_global_daily_limit="${ANALYSIS_GLOBAL_DAILY_LIMIT:-20000}"
legacy_global_daily_limit="${LEGACY_GLOBAL_DAILY_LIMIT:-5000}"
local_config="$repo_root/Later/Configuration/CloudConfig.local.xcconfig"

if [[ -z "$project_id" || "$project_id" == "(unset)" ]]; then
  echo "Usage: ./tools/vision-spike/deploy-gcp.sh YOUR_GCP_PROJECT_ID" >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud is required. Install the Google Cloud CLI and run: gcloud auth login" >&2
  exit 1
fi

active_account="$(gcloud config get-value account 2>/dev/null)"
if [[ "$active_account" != "$required_account" ]]; then
  echo "Refusing to deploy from GCP account: $active_account" >&2
  echo "Required account: $required_account" >&2
  echo "Run: gcloud config set account $required_account" >&2
  exit 1
fi

if [[ "$project_id" != "project-a5ac77cc-c119-47d6-bb4" ]]; then
  echo "Refusing to deploy to unexpected GCP project: $project_id" >&2
  exit 1
fi

existing_api_token=""
if [[ -f "$local_config" ]]; then
  existing_api_token="$(sed -n 's/^LATER_ANALYSIS_TOKEN = //p' "$local_config" | head -n 1)"
fi
api_token="${LATER_API_TOKEN:-${existing_api_token:-$(openssl rand -hex 32)}}"
service_account_email="${service_account_name}@${project_id}.iam.gserviceaccount.com"
project_number="$(gcloud projects describe "$project_id" --format='value(projectNumber)')"
build_service_account="${project_number}-compute@developer.gserviceaccount.com"

gcloud config set project "$project_id"
gcloud services enable \
  aiplatform.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  firestore.googleapis.com \
  secretmanager.googleapis.com \
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

gcloud projects add-iam-policy-binding "$project_id" \
  --member "serviceAccount:${service_account_email}" \
  --role roles/datastore.user \
  --condition=None \
  --quiet >/dev/null

if ! gcloud firestore databases describe --database='(default)' \
  --project "$project_id" >/dev/null 2>&1; then
  echo "Missing the default Firestore database." >&2
  echo "Create it deliberately in us-central1 before deploying:" >&2
  echo "gcloud firestore databases create --database='(default)' --location=us-central1 --type=firestore-native --project $project_id" >&2
  exit 1
fi

if ! gcloud secrets describe "$apns_secret_name" --project "$project_id" >/dev/null 2>&1; then
  echo "Missing Secret Manager secret: $apns_secret_name" >&2
  echo "Create it from the Apple APNs .p8 key before deploying." >&2
  exit 1
fi

gcloud secrets add-iam-policy-binding "$apns_secret_name" \
  --project "$project_id" \
  --member "serviceAccount:${service_account_email}" \
  --role roles/secretmanager.secretAccessor \
  --quiet >/dev/null

if ! gcloud secrets describe "$session_secret_name" --project "$project_id" >/dev/null 2>&1; then
  openssl rand -base64 48 | gcloud secrets create "$session_secret_name" \
    --project "$project_id" \
    --replication-policy automatic \
    --data-file=- >/dev/null
fi

gcloud secrets add-iam-policy-binding "$session_secret_name" \
  --project "$project_id" \
  --member "serviceAccount:${service_account_email}" \
  --role roles/secretmanager.secretAccessor \
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
  --min-instances 0 \
  --max-instances 2 \
  --concurrency 10 \
  --cpu 1 \
  --memory 512Mi \
  --timeout 180 \
  --port 8080 \
  --set-env-vars "AI_PROVIDER=vertex,GOOGLE_CLOUD_PROJECT=${project_id},VERTEX_LOCATION=${region},GEMINI_MODEL=${model},LATER_API_TOKEN=${api_token},APNS_KEY_ID=${apns_key_id},APNS_TEAM_ID=${apns_team_id},APNS_TOPIC=${apns_topic},APP_ATTEST_TEAM_ID=${apns_team_id},APP_ATTEST_BUNDLE_ID=${apns_topic},APP_ATTEST_ENVIRONMENT=production,ALLOW_LEGACY_TOKEN=${allow_legacy_token},ANALYSIS_DAILY_LIMIT=${analysis_daily_limit},ANALYSIS_BURST_LIMIT=${analysis_burst_limit},ANALYSIS_GLOBAL_DAILY_LIMIT=${analysis_global_daily_limit},LEGACY_GLOBAL_DAILY_LIMIT=${legacy_global_daily_limit}" \
  --set-secrets "APNS_PRIVATE_KEY=${apns_secret_name}:latest,LATER_SESSION_SECRET=${session_secret_name}:latest"

service_url="$(gcloud run services describe "$service_name" \
  --project "$project_id" \
  --region "$region" \
  --format='value(status.url)')"
service_host="${service_url#https://}"
umask 077
printf 'LATER_VISION_BASE_URL = https:/$()/%s\nLATER_ANALYSIS_TOKEN = %s\n' \
  "$service_host" "$api_token" > "$local_config"

echo
echo "Later analysis is live: $service_url"
echo "The ignored iPhone configuration was written to:"
echo "$local_config"
echo "Build the app normally; both the app and share extension will use Cloud Run."
