-- Idempotency stamp for the founder "new user finished onboarding" Slack ping.
-- The /v1/account/onboarding-complete endpoint sets this atomically and only notifies
-- when it was previously null, so retries / multiple devices never double-ping.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS founder_onboarding_notified_at timestamptz;
