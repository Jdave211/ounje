-- Remove remaining anon grants from user-owned tables that already rely on RLS.

ALTER TABLE public.saved_recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_prep_automation_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grocery_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grocery_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_provider_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_verification_inboxes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_notification_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.saved_recipes FROM anon, authenticated;
REVOKE ALL ON public.meal_prep_automation_state FROM anon, authenticated;
REVOKE ALL ON public.grocery_orders FROM anon, authenticated;
REVOKE ALL ON public.grocery_order_items FROM anon, authenticated;
REVOKE ALL ON public.user_provider_accounts FROM anon, authenticated;
REVOKE ALL ON public.user_verification_inboxes FROM anon, authenticated;
REVOKE ALL ON public.app_notification_events FROM anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.saved_recipes TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.meal_prep_automation_state TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.grocery_orders TO authenticated;
GRANT SELECT ON public.grocery_order_items TO authenticated;
GRANT SELECT ON public.user_provider_accounts TO authenticated;
GRANT SELECT ON public.user_verification_inboxes TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.app_notification_events TO authenticated;

DROP POLICY IF EXISTS "saved_recipes_own_all" ON public.saved_recipes;
CREATE POLICY "saved_recipes_own_all"
  ON public.saved_recipes
  FOR ALL
  TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "meal_prep_automation_state_own_all" ON public.meal_prep_automation_state;
CREATE POLICY "meal_prep_automation_state_own_all"
  ON public.meal_prep_automation_state
  FOR ALL
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "grocery_orders_own_all" ON public.grocery_orders;
CREATE POLICY "grocery_orders_own_all"
  ON public.grocery_orders
  FOR ALL
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "grocery_order_items_select_own" ON public.grocery_order_items;
CREATE POLICY "grocery_order_items_select_own"
  ON public.grocery_order_items
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.grocery_orders orders
      WHERE orders.id = order_id
        AND orders.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "user_provider_accounts_select_own" ON public.user_provider_accounts;
CREATE POLICY "user_provider_accounts_select_own"
  ON public.user_provider_accounts
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "user_verification_inboxes_select_own" ON public.user_verification_inboxes;
CREATE POLICY "user_verification_inboxes_select_own"
  ON public.user_verification_inboxes
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "app_notification_events_own_all" ON public.app_notification_events;
CREATE POLICY "app_notification_events_own_all"
  ON public.app_notification_events
  FOR ALL
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
