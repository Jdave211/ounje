# Ounje VM Deploy

The VM is private worker infrastructure. It should not serve the public API, terminate TLS, or receive traffic from the app. Render owns public HTTP requests; Supabase owns durable state, recipe ingestion jobs, and automation queues.

## Process

- `ounje-automation-worker.service`: claims `automation_jobs` rows from Supabase and runs long browser/autonomous work such as Instacart cart building.
- `ounje-recipe-ingestion-worker.service`: claims `recipe_ingestion_jobs` rows from Supabase and runs TikTok/IG/web media extraction, scraping, OpenAI extraction/completion, recipe persistence, artifacts, and AI usage logging.

The old VM API/nginx path is intentionally out of the production architecture. The app talks to Render only; the VM polls Supabase privately.

## VM Setup

1. Install Node 22 LTS and clone the repo to `/opt/ounje`.
2. Install system media/browser dependencies:
   ```bash
   sudo apt-get update
   sudo apt-get install -y ffmpeg tesseract-ocr python3 python3-pip
   sudo python3 -m pip install --break-system-packages -U yt-dlp
   cd /opt/ounje
   YOUTUBE_DL_SKIP_DOWNLOAD=true npm install
   npx playwright install --with-deps chromium
   ```
3. Create `/etc/ounje/ounje.env`.
4. Copy both files in [deploy/systemd](/Users/davejaga/Desktop/startups/ounje/deploy/systemd) into `/etc/systemd/system/`.
5. Run `sudo systemctl daemon-reload`.
6. Run `sudo systemctl enable --now ounje-automation-worker ounje-recipe-ingestion-worker`.

## Required Env

Add these to `/etc/ounje/ounje.env`:

```bash
SUPABASE_URL=...
SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...
OPENAI_API_KEY=...
BROWSER_USE_API_KEY=...
LUMBOX_API_KEY=...
AGENTSIM_API_KEY=...
TWO_CAPTCHA_API_KEY=...
RECIPE_IMAGE_BUCKET=...
OUNJE_ENABLE_AI_CALL_LOGGING=true
RECIPE_INGESTION_WORKER_CONCURRENCY=1
YOUTUBE_DL_BINARY=/usr/local/bin/yt-dlp
```

The worker also needs any provider/browser-session secrets used by the existing automation stack. It does not need `PORT`, `HOST`, nginx, or a public domain.

## Manual Check

```bash
cd /opt/ounje
YOUTUBE_DL_SKIP_DOWNLOAD=true npm install
node server/scripts/automation_worker.mjs --once --worker-id vm_manual_check
node server/scripts/recipe_ingestion_worker.mjs --once --worker-id vm_recipe_ingest_manual_check
# or keep it running manually:
npm run recipes:ingestion-worker:vm
```

If no jobs are queued, the one-shot command exits cleanly after claiming nothing. To test the full path, enqueue an Instacart run through Render, then run the command above and watch the matching `automation_jobs`, `instacart_run_logs`, and `grocery_orders` rows update in Supabase.

For recipe ingestion, enqueue a TikTok/IG URL through Render, then watch the matching `recipe_ingestion_jobs` row move from `queued` to `processing`, `fetching`, `parsing`, `normalized`, and finally `saved` or `failed`. Confirm `worker_id` starts with `vm_recipe_ingest`, `recipe_ingestion_artifacts` has rows for the job, and `ai_call_logs.job_id` contains the OpenAI calls.
