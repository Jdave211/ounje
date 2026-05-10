-- Remove duplicate permissive policies created during iterative hardening.
-- Grants still restrict the allowed client actions; service-role backend writes bypass RLS.

DROP POLICY IF EXISTS "Users can insert own app notifications" ON public.app_notification_events;
DROP POLICY IF EXISTS "Users can update own app notifications" ON public.app_notification_events;
DROP POLICY IF EXISTS "Users can view own app notifications" ON public.app_notification_events;

DROP POLICY IF EXISTS "Users cannot mutate entitlements directly" ON public.app_user_entitlements;

DROP POLICY IF EXISTS "Users can view own order items" ON public.grocery_order_items;

DROP POLICY IF EXISTS "Users can create own orders" ON public.grocery_orders;
DROP POLICY IF EXISTS "Users can update own orders" ON public.grocery_orders;
DROP POLICY IF EXISTS "Users can view own orders" ON public.grocery_orders;

DROP POLICY IF EXISTS "Users can insert own meal prep automation state" ON public.meal_prep_automation_state;
DROP POLICY IF EXISTS "Users can update own meal prep automation state" ON public.meal_prep_automation_state;
DROP POLICY IF EXISTS "Users can view own meal prep automation state" ON public.meal_prep_automation_state;

DROP POLICY IF EXISTS "Users can manage own provider accounts" ON public.user_provider_accounts;
DROP POLICY IF EXISTS "Users can view own provider accounts" ON public.user_provider_accounts;

DROP POLICY IF EXISTS "Users can view own verification inboxes" ON public.user_verification_inboxes;

-- Pin search_path on app-owned public functions so invocation cannot depend on
-- caller-controlled role search paths.

ALTER FUNCTION public.prevent_profile_onboarding_downgrade() SET search_path = public, extensions;
ALTER FUNCTION public.set_main_shop_items_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.set_meal_prep_automation_state_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.set_prep_recipe_overrides_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.claim_automation_jobs(text, text[], integer, integer) SET search_path = public, extensions;
ALTER FUNCTION public.set_app_user_entitlements_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.set_base_cart_items_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.update_app_notification_timestamp() SET search_path = public, extensions;
ALTER FUNCTION public.match_recipes_hybrid(vector, text, integer, integer, text, text, text, integer, integer) SET search_path = public, extensions;
ALTER FUNCTION public.set_automation_jobs_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.set_instacart_run_logs_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.instacart_run_logs_actor_user_id() SET search_path = public, extensions;
ALTER FUNCTION public.set_profiles_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.set_provider_connect_sessions_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.set_prep_recurring_recipes_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.set_user_import_recipes_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.claim_recipe_ingestion_jobs(text, integer, timestamp with time zone) SET search_path = public, extensions;
ALTER FUNCTION public.set_meal_prep_cycle_completions_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.set_instacart_run_log_traces_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.set_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.update_grocery_order_timestamp() SET search_path = public, extensions;
ALTER FUNCTION public.set_meal_prep_cycles_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.match_recipes_rich(vector, integer, text, text, text, integer, integer) SET search_path = public, extensions;
ALTER FUNCTION public.set_recipe_ingestion_jobs_updated_at() SET search_path = public, extensions;
ALTER FUNCTION public.match_recipes_basic(vector, integer, text, text, text, integer, integer) SET search_path = public, extensions;
ALTER FUNCTION public.set_recipe_share_links_updated_at() SET search_path = public, extensions;
