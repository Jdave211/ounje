# Ounje VM Retirement

The rented Ubuntu VM is no longer part of Ounje's production architecture. Render owns the public API and the managed recipe-ingestion and automation workers; Supabase owns durable job state; Redis wakes recipe workers. Migration `20260822030626_retire_vm_recipe_ingestion_claims.sql` prevents legacy VM identities from claiming recipe work.

## Before Shutdown

1. Apply the Render worker claim migration and deploy the services described in [render-deploy.md](/Users/davejaga/Desktop/startups/ounje/docs/render-deploy.md).
2. Confirm a Render worker has completed controlled TikTok, Instagram, web, photo, and duplicate imports.
3. Confirm the Render automation worker has completed an Instacart job.
4. Inspect Supabase and wait until no live `recipe_ingestion_jobs` row (`processing`, `fetching`, `parsing`, or `normalized`) has a `worker_id` beginning with `vm_recipe_ingest`, and no `automation_jobs.locked_by` begins with `vm_automation`.
5. Confirm the Render import-health cron reports a healthy queue.

## Shutdown

1. Stop and disable `ounje-recipe-ingestion-worker`, `ounje-automation-worker`, and `ounje-growth-outreach-worker` on Ubuntu.
2. Keep the VM powered off for the agreed observation window; do not delete it yet.
3. If imports or automation regress, repair the managed worker. The retired `vm_recipe_ingest*` identity is no longer eligible to claim jobs.
4. After the observation window, cancel the VM and revoke its Supabase, Redis, OpenAI, browser-provider, and SSH credentials.

## Final Cleanup

The VM claim allowance was removed by `20260822030626_retire_vm_recipe_ingestion_claims.sql`. After the machine is cancelled, revoke its Supabase, Redis, OpenAI, browser-provider, and SSH credentials, then remove the legacy VM scripts and systemd units.
