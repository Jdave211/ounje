-- App notifications + grocery delivery tracking

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'app_notification_kind'
  ) THEN
    CREATE TYPE app_notification_kind AS ENUM (
      'meal_prep_ready',
      'cart_review_required',
      'checkout_approval_required',
      'grocery_cart_ready',
      'grocery_order_confirmed',
      'grocery_delivery_update',
      'grocery_delivery_arrived',
      'grocery_issue',
      'recipe_nudge',
      'trending_recipe_nudge'
    );
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS app_notification_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  kind app_notification_kind NOT NULL,
  dedupe_key TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  subtitle TEXT,
  image_url TEXT,
  action_url TEXT,
  action_label TEXT,
  order_id UUID REFERENCES grocery_orders(id) ON DELETE SET NULL,
  plan_id UUID,
  recipe_id TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  scheduled_for TIMESTAMPTZ NOT NULL DEFAULT now(),
  delivered_at TIMESTAMPTZ,
  seen_at TIMESTAMPTZ,
  opened_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, dedupe_key)
);

CREATE INDEX IF NOT EXISTS idx_app_notification_events_user_created
  ON app_notification_events(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_app_notification_events_user_schedule
  ON app_notification_events(user_id, scheduled_for DESC);

CREATE INDEX IF NOT EXISTS idx_app_notification_events_user_unread
  ON app_notification_events(user_id, seen_at, delivered_at);

ALTER TABLE app_notification_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own app notifications" ON app_notification_events;
CREATE POLICY "Users can view own app notifications"
  ON app_notification_events FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own app notifications" ON app_notification_events;
CREATE POLICY "Users can insert own app notifications"
  ON app_notification_events FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own app notifications" ON app_notification_events;
CREATE POLICY "Users can update own app notifications"
  ON app_notification_events FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

ALTER TABLE grocery_orders
  ADD COLUMN IF NOT EXISTS provider_tracking_url TEXT,
  ADD COLUMN IF NOT EXISTS tracking_status TEXT NOT NULL DEFAULT 'unknown',
  ADD COLUMN IF NOT EXISTS tracking_title TEXT,
  ADD COLUMN IF NOT EXISTS tracking_detail TEXT,
  ADD COLUMN IF NOT EXISTS tracking_eta_text TEXT,
  ADD COLUMN IF NOT EXISTS tracking_image_url TEXT,
  ADD COLUMN IF NOT EXISTS tracking_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS tracking_started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_tracked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_grocery_orders_user_tracking
  ON grocery_orders(user_id, tracking_status, created_at DESC);

CREATE OR REPLACE FUNCTION update_app_notification_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS app_notification_events_updated_at ON app_notification_events;
CREATE TRIGGER app_notification_events_updated_at
  BEFORE UPDATE ON app_notification_events
  FOR EACH ROW
  EXECUTE FUNCTION update_app_notification_timestamp();

COMMENT ON TABLE app_notification_events IS 'User-scoped in-app and local notification events emitted by meal prep, grocery, and delivery workflows.';
COMMENT ON COLUMN grocery_orders.provider_tracking_url IS 'Provider order-tracking page for post-checkout delivery updates.';
COMMENT ON COLUMN grocery_orders.tracking_status IS 'Latest scraper-derived delivery status such as shopping, out_for_delivery, delivered, or issue.';
