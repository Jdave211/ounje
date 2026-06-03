# Ounje VM Deploy

The VM is private worker infrastructure. It should not serve the public API, terminate TLS, or receive traffic from the app. Render owns public HTTP requests; Supabase owns durable state, recipe ingestion jobs, and automation queues.

## Process

- `ounje-automation-worker.service`: claims `automation_jobs` rows from Supabase and runs long browser/autonomous work such as Instacart cart building.
- `ounje-recipe-ingestion-worker.service`: wakes from Redis when Render enqueues a recipe import, claims `recipe_ingestion_jobs` rows from Supabase, and runs TikTok/IG/web media extraction, scraping, OpenAI extraction/completion, recipe persistence, artifacts, and AI usage logging.

The old VM API/nginx path is intentionally out of the production architecture. The app talks to Render only; the VM sleeps on Redis and only performs a sparse safety sweep when no wake event arrives.

## Auto-deploy (CI)

Unlike Render (which auto-deploys the API on push to `main`), the VM worker must be
re-deployed to pick up new ingestion code. This is automated by
[.github/workflows/deploy-vm-worker.yml](../.github/workflows/deploy-vm-worker.yml):
on every push to `main` that touches `server/**` or `package.json`, it **rsyncs**
`server/` + `package.json` to the droplet, runs `npm install`, and restarts the worker.

> The droplet's `/opt/ounje` is a plain file tree (NOT a git checkout), so deploy
> copies files with rsync rather than `git pull`. The live systemd unit is
> **`ounje-recipe-ingestion`** (runs as the `ounje` user) — note the name differs
> from the sample unit file in `deploy/systemd/`.

Current target (DigitalOcean droplet): `root@161.35.129.11`, NYC3, Ubuntu.

Add these repo secrets (**Settings → Secrets and variables → Actions**) to enable it —
until they exist the job no-ops cleanly instead of failing:

| Secret | Value |
| --- | --- |
| `VM_SSH_HOST` | droplet public IPv4 (`161.35.129.11`) |
| `VM_SSH_USER` | `root` |
| `VM_SSH_KEY` | the **private** half of a dedicated deploy key whose public half is in the droplet's `~/.ssh/authorized_keys` |
| `VM_SSH_PORT` | optional, defaults to `22` |

To mint a dedicated deploy key (recommended over reusing a personal key):

```bash
ssh-keygen -t ed25519 -N "" -C "ounje-vm-deploy@github-actions" -f ~/.ssh/ounje_vm_deploy
# add the .pub to the droplet (via DO Web Console or ssh-copy-id), then
# paste ~/.ssh/ounje_vm_deploy into the VM_SSH_KEY secret.
```

You can also trigger it manually from the Actions tab (**workflow_dispatch**). The manual
fallback (run locally with a key authorized on the droplet):

```bash
rsync -az --exclude '.sessions/' --exclude 'data/' --exclude 'node_modules/' \
  -e "ssh -i ~/.ssh/ounje_vm_deploy" server package.json root@161.35.129.11:/opt/ounje/
ssh -i ~/.ssh/ounje_vm_deploy root@161.35.129.11 \
  'cd /opt/ounje && chown -R ounje:ounje server package.json && YOUTUBE_DL_SKIP_DOWNLOAD=true npm install && systemctl restart ounje-recipe-ingestion'
```

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
REDIS_URL=...
OPENAI_API_KEY=...
BROWSER_USE_API_KEY=...
LUMBOX_API_KEY=...
AGENTSIM_API_KEY=...
TWO_CAPTCHA_API_KEY=...
RECIPE_IMAGE_BUCKET=...
OUNJE_ENABLE_AI_CALL_LOGGING=true
RECIPE_INGESTION_WORKER_CONCURRENCY=1
RECIPE_INGESTION_WORKER_WAKE_MODE=redis
RECIPE_INGESTION_WORKER_WAKE_TIMEOUT_MS=60000
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
