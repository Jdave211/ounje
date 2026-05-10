-- Fix landing_events RLS: anon role has INSERT grant but no matching policy.
-- Add anon INSERT policy so anonymous event tracking actually works.

DROP POLICY IF EXISTS "anon_insert_landing_events" ON public.landing_events;
CREATE POLICY "anon_insert_landing_events"
  ON public.landing_events
  FOR INSERT
  TO anon
  WITH CHECK (true);
