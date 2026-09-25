# Local vision spike

This tool sends screenshots directly from your Mac to the OpenAI Responses API and saves structured Later classification results locally. It does not modify or run the iOS app.

## Setup

1. Copy `.env.example` at the repository root to `.env.local`.
2. Put your OpenAI project API key in `.env.local`. Never commit or share that file.
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

Set `OPENAI_MODEL` in `.env.local` to compare another image-capable model.
Set `OPENAI_BASE_URL` when using an OpenAI-compatible proxy or load balancer.

## Local iPhone bridge

Run the LAN bridge while testing the app on an iPhone:

```sh
node tools/vision-spike/server.mjs
```

The bridge listens on port `8787`, keeps the API key on the Mac, and forwards image analysis to the configured `OPENAI_BASE_URL`.
