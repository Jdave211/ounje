# Ounje VM Deploy

The VM is private worker infrastructure. It should not serve the public API, terminate TLS, or receive traffic from the app. Render owns public HTTP requests; Supabase owns durable state and the automation queue.

## Process

- `ounje-automation-worker.service`: claims `automation_jobs` rows from Supabase and runs long browser/autonomous work such as Instacart cart building.

Recipe ingestion stays on the Render worker. The old VM API/nginx path is intentionally out of the production architecture.

## VM Setup

1. Install Node 22 LTS and clone the repo to `/opt/ounje`.
2. Create `/etc/ounje/ounje.env`.
3. Copy [deploy/systemd/ounje-automation-worker.service](/Users/davejaga/Desktop/startups/ounje/deploy/systemd/ounje-automation-worker.service) into `/etc/systemd/system/`.
4. Run `sudo systemctl daemon-reload`.
5. Run `sudo systemctl enable --now ounje-automation-worker`.

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
```

The worker also needs any provider/browser-session secrets used by the existing automation stack. It does not need `PORT`, `HOST`, nginx, or a public domain.

## Manual Check

```bash
cd /opt/ounje
npm install
node server/scripts/automation_worker.mjs --once --worker-id vm_manual_check
```

If no jobs are queued, the one-shot command exits cleanly after claiming nothing. To test the full path, enqueue an Instacart run through Render, then run the command above and watch the matching `automation_jobs`, `instacart_run_logs`, and `grocery_orders` rows update in Supabase.
