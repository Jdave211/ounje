-- Drop the orphaned landing_events table.
--
-- A grep over server/, client/ios/, ounje_website/, the root package.json, and
-- all scripts returned zero references. The table was never created via a
-- committed CREATE TABLE migration in this repo — only RLS hardening migrations
-- touched it. If the marketing site eventually needs to log landing events,
-- the schema should be recreated alongside the writer code so the policies
-- match the actual access pattern.

DROP TABLE IF EXISTS public.landing_events CASCADE;
