# Ounje Render Deploy

Render is the public API and control plane. The app should call Render plus Supabase realtime only; it should never call the VM directly.

This backend should run on Render as two services:

- `ounje-api` as the web service
- `ounje-recipe-ingestion` as the background worker

The repo root now includes [render.yaml](/Users/davejaga/Desktop/startups/ounje/render.yaml) so Render can sync both services from the same branch.

## Why two services

The API process should stay focused on request traffic. Recipe ingestion is long-running background work and should not live inside the web process.

Instacart/browser automation is not run synchronously on Render. `POST /v1/instacart/runs` validates the request, creates a Supabase `automation_jobs` row plus a grocery order/run log, and returns `202`. The private VM worker claims that job from Supabase and writes progress/results back.

## Health check

Render should use:

- `GET /healthz`

That endpoint verifies required env is present and that the API can make a lightweight Supabase query before Render marks the service healthy.

## Required secrets

Set these in both Render services:

- `OPENAI_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `KROGER_CLIENT_ID`
- `KROGER_CLIENT_SECRET`
- `BROWSER_USE_API_KEY`
- `LUMBOX_API_KEY`
- `AGENTSIM_API_KEY`
- `IFRAMELY_API_KEY`
- `TWO_CAPTCHA_API_KEY`
- `RECIPE_IMAGE_BUCKET`

## Supabase migration

Before or with the Render cutover, apply the pending migrations that add user-scoped realtime broadcasts and the durable automation queue:

- [supabase/migrations/2026042901_realtime_user_broadcasts.sql](/Users/davejaga/Desktop/startups/ounje/supabase/migrations/2026042901_realtime_user_broadcasts.sql)
- [supabase/migrations/2026043002_automation_jobs.sql](/Users/davejaga/Desktop/startups/ounje/supabase/migrations/2026043002_automation_jobs.sql)

That migration closes the current gap where:

- `entitlement.updated` is handled by the app but was never emitted
- meal prep mutations done directly in Supabase had no matching realtime broadcast back to the app

## Deploy flow

1. Sync the Blueprint in Render from `render.yaml`.
2. Apply the pending Supabase migration.
3. Deploy the web service.
4. Deploy the worker service.
5. Verify `GET /healthz` returns `200`.
6. Verify recipe generation, discover search, and Instacart enqueueing against the Render-hosted API.
7. Start the VM automation worker and verify queued Instacart jobs move from `queued` to `running`/`succeeded` or `failed` in Supabase.
