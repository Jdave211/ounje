-- Founder-facing subscription dashboard.
-- This is a read-only view over the existing entitlement + Apple event ledger.
-- It intentionally does not create another mutable source of truth.

CREATE OR REPLACE VIEW public.founder_subscription_dashboard
WITH (security_invoker = true)
AS
WITH latest_event AS (
  SELECT DISTINCT ON (events.user_id)
    events.user_id,
    events.notification_type AS latest_notification_type,
    events.subtype AS latest_notification_subtype,
    events.environment AS latest_environment,
    events.processed_at AS latest_event_at
  FROM public.app_store_notification_events events
  WHERE events.user_id IS NOT NULL
  ORDER BY events.user_id, events.processed_at DESC
),
event_rollup AS (
  SELECT
    events.user_id,
    COUNT(*)::INTEGER AS app_store_event_count,
    MIN(events.processed_at) FILTER (
      WHERE events.notification_type = 'SUBSCRIBED'
    ) AS first_subscribed_at,
    MIN(events.processed_at) FILTER (
      WHERE events.notification_type = 'SUBSCRIBED'
        AND lower(COALESCE(events.payload #>> '{entitlement_state,metadata,is_on_trial}', 'false')) IN ('true', '1', 'yes')
    ) AS first_trial_started_at,
    MIN(events.processed_at) FILTER (
      WHERE events.notification_type IN ('SUBSCRIBED', 'DID_RENEW')
        AND lower(COALESCE(events.payload #>> '{entitlement_state,metadata,is_on_trial}', 'false')) NOT IN ('true', '1', 'yes')
    ) AS first_paid_started_at,
    MAX(events.processed_at) FILTER (
      WHERE events.notification_type = 'DID_CHANGE_RENEWAL_STATUS'
        AND events.subtype = 'AUTO_RENEW_DISABLED'
    ) AS latest_auto_renew_disabled_at,
    MAX(events.processed_at) FILTER (
      WHERE events.notification_type = 'EXPIRED'
    ) AS latest_expired_at
  FROM public.app_store_notification_events events
  WHERE events.user_id IS NOT NULL
  GROUP BY events.user_id
),
entitlements AS (
  SELECT
    entitlement.user_id,
    entitlement.tier,
    entitlement.status,
    entitlement.source,
    entitlement.product_id,
    entitlement.transaction_id,
    entitlement.original_transaction_id,
    entitlement.expires_at,
    entitlement.metadata,
    entitlement.created_at,
    entitlement.updated_at,
    lower(COALESCE(entitlement.metadata->>'is_on_trial', 'false')) IN ('true', '1', 'yes') AS is_on_trial,
    CASE
      WHEN COALESCE(entitlement.metadata->>'auto_renew_status', '') ~ '^[0-9]+$'
        THEN (entitlement.metadata->>'auto_renew_status')::INTEGER
      ELSE NULL
    END AS auto_renew_status_code
  FROM public.app_user_entitlements entitlement
)
SELECT
  entitlements.user_id,
  profiles.email,
  profiles.display_name,
  entitlements.tier,
  entitlements.status,
  entitlements.source,
  entitlements.product_id,
  entitlements.expires_at,
  entitlements.is_on_trial,
  CASE
    WHEN entitlements.auto_renew_status_code = 1 THEN TRUE
    WHEN entitlements.auto_renew_status_code = 0 THEN FALSE
    ELSE NULL
  END AS auto_renew_enabled,
  CASE
    WHEN entitlements.source = 'app_store'
      AND entitlements.status = 'active'
      AND entitlements.tier <> 'free'
      AND entitlements.expires_at > timezone('utc', now())
      AND entitlements.is_on_trial
      THEN 'trial_active'
    WHEN entitlements.source = 'app_store'
      AND entitlements.status = 'active'
      AND entitlements.tier <> 'free'
      AND entitlements.expires_at > timezone('utc', now())
      AND NOT entitlements.is_on_trial
      AND entitlements.auto_renew_status_code = 0
      THEN 'paid_cancelled_access_remaining'
    WHEN entitlements.source = 'app_store'
      AND entitlements.status = 'active'
      AND entitlements.tier <> 'free'
      AND entitlements.expires_at > timezone('utc', now())
      AND NOT entitlements.is_on_trial
      THEN 'paid_active'
    WHEN entitlements.source = 'app_store'
      AND entitlements.status = 'active'
      AND entitlements.tier <> 'free'
      AND entitlements.expires_at <= timezone('utc', now())
      THEN 'expired'
    WHEN entitlements.status IN ('expired', 'revoked', 'inactive')
      THEN entitlements.status
    ELSE 'other'
  END AS founder_status,
  entitlements.transaction_id,
  entitlements.original_transaction_id,
  entitlements.metadata->>'app_store_environment' AS app_store_environment,
  entitlements.metadata->>'notification_type' AS entitlement_notification_type,
  entitlements.metadata->>'notification_subtype' AS entitlement_notification_subtype,
  event_rollup.first_subscribed_at,
  event_rollup.first_trial_started_at,
  event_rollup.first_paid_started_at,
  event_rollup.latest_auto_renew_disabled_at,
  event_rollup.latest_expired_at,
  latest_event.latest_notification_type,
  latest_event.latest_notification_subtype,
  latest_event.latest_environment,
  latest_event.latest_event_at,
  COALESCE(event_rollup.app_store_event_count, 0) AS app_store_event_count,
  entitlements.created_at AS entitlement_created_at,
  entitlements.updated_at AS entitlement_updated_at
FROM entitlements
LEFT JOIN public.profiles profiles ON profiles.id = entitlements.user_id
LEFT JOIN event_rollup ON event_rollup.user_id = entitlements.user_id
LEFT JOIN latest_event ON latest_event.user_id = entitlements.user_id
WHERE entitlements.source = 'app_store'
ORDER BY entitlements.updated_at DESC;

COMMENT ON VIEW public.founder_subscription_dashboard IS
  'Read-only founder dashboard for current App Store subscription state, joined with profile and latest Apple notification metadata.';

REVOKE ALL ON public.founder_subscription_dashboard FROM anon;
REVOKE ALL ON public.founder_subscription_dashboard FROM authenticated;
