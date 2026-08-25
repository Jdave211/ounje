# Ounje Render Deploy

Render is Ounje's public API and private worker platform. The app talks to Render and Supabase Realtime only; it never calls a worker directly.

## Services

- `ounje-api`: validates requests, enqueues work, and serves the app API.
- `ounje-recipe-ingestion`: claims recipe imports and performs social/media extraction, OCR, transcription, OpenAI processing, and recipe persistence.
- `ounje-recipe-ingestion-health`: checks the durable queue every minute and fails when jobs are stale or invalid workers can claim them.

The recipe worker uses the shared Docker image in [Dockerfile](/Users/davejaga/Desktop/startups/ounje/Dockerfile). It contains Chromium, `yt-dlp`, FFmpeg, and OCR dependencies. Recipe imports use caption and page evidence first; when that evidence already contains ingredients and preparation, the worker skips downloading the video. Set `RECIPE_INGESTION_SOCIAL_VIDEO_EAGER=true` only to force video evidence for every social import.

Grocery automation is intentionally held and has no continuous Render worker. Its worker implementation remains available for a later explicit rollout.

Growth outreach is intentionally not deployed as a continuous service. Run its explicit script or schedule a separate job when it is needed.

## Required Secrets

The Blueprint in [render.yaml](/Users/davejaga/Desktop/startups/ounje/render.yaml) lists every environment variable for each service. Configure the Supabase, OpenAI, recipe-media, grocery-provider, and browser-provider secrets on the worker that consumes them. Redis is intentionally disabled; Supabase is the durable queue. Keep `OUNJE_ENABLE_RECIPE_INGESTION_POLLING=false` on `ounje-api` so it remains enqueue-only.

## Deployment

1. Apply all pending Supabase migrations. Only `render_recipe_ingest*` identities may claim recipe work.
2. Sync the Blueprint and deploy `ounje-api`, `ounje-recipe-ingestion`, and the health cron.
3. Verify `GET /healthz`, then queue TikTok, Instagram, web, photo, and duplicate-link imports. Confirm the recipe worker claims them and each reaches `saved` or `failed` with artifacts and AI logs.
4. Verify the health cron stays green and a deliberately stale import becomes `retryable` within 15 minutes.
