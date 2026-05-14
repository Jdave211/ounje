import express from "express";
import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";
import { broadcastUserInvalidation } from "../../lib/realtime-invalidation.js";
import { invalidateUserBootstrapCache } from "../../lib/user-bootstrap-cache.js";
import { getServiceRoleSupabase } from "../../lib/supabase-clients.js";

const router = express.Router();

function getServiceSupabase() {
  return getServiceRoleSupabase();
}

async function updateOrThrow(query, label) {
  const { error, count } = await query;
  if (error) {
    error.message = `${label}: ${error.message}`;
    throw error;
  }
  return count ?? 0;
}

router.post("/account/deactivate", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);

    const supabase = getServiceSupabase();
    const now = new Date().toISOString();

    const counts = {};

    counts.profiles = await updateOrThrow(
      supabase
        .from("profiles")
        .update({
          account_status: "deactivated",
          deactivated_at: now,
          updated_at: now,
        })
        .eq("id", userID)
        .select("id", { count: "estimated", head: true }),
      "profiles"
    );

    counts.automationJobs = await updateOrThrow(
      supabase
        .from("automation_jobs")
        .update({
          status: "cancelled",
          locked_by: null,
          locked_until: null,
          completed_at: now,
          error_message: "Account deactivated",
        })
        .eq("user_id", userID)
        .in("status", ["queued", "running"])
        .select("id", { count: "estimated", head: true }),
      "automation_jobs"
    );

    counts.providerAccounts = await updateOrThrow(
      supabase
        .from("user_provider_accounts")
        .update({
          is_active: false,
          session_cookies: null,
          login_status: "deactivated",
          updated_at: now,
        })
        .eq("user_id", userID)
        .select("id", { count: "estimated", head: true }),
      "user_provider_accounts"
    );

    counts.automationState = await updateOrThrow(
      supabase
        .from("meal_prep_automation_state")
        .update({
          last_cart_sync_for_delivery_at: null,
          last_cart_sync_plan_id: null,
          last_cart_signature: null,
          last_instacart_run_status: "deactivated",
          updated_at: now,
        })
        .eq("user_id", userID)
        .select("user_id", { count: "estimated", head: true }),
      "meal_prep_automation_state"
    );

    counts.groceryOrders = await updateOrThrow(
      supabase
        .from("grocery_orders")
        .update({
          status: "cancelled",
          status_message: "Account deactivated",
          error_message: "Account deactivated",
          browser_live_url: null,
          updated_at: now,
        })
        .eq("user_id", userID)
        .in("status", ["pending", "session_started", "building_cart", "cart_ready", "selecting_slot", "awaiting_review", "user_approved", "checkout_started"])
        .select("id", { count: "estimated", head: true }),
      "grocery_orders"
    );

    counts.instacartRunLogs = await updateOrThrow(
      supabase
        .from("instacart_run_logs")
        .update({
          status_kind: "cancelled",
          success: false,
          partial_success: false,
          progress: 0,
          top_issue: "Account deactivated",
          completed_at: now,
          updated_at: now,
        })
        .eq("user_id", userID)
        .in("status_kind", ["queued", "running", "partial"])
        .select("run_id", { count: "estimated", head: true }),
      "instacart_run_logs"
    );

    await broadcastUserInvalidation(userID, "account.deactivated", {
      status: "deactivated",
      deactivated_at: now,
    }).catch(() => {});
    invalidateUserBootstrapCache(userID);

    return res.json({
      ok: true,
      status: "deactivated",
      deactivatedAt: now,
      counts,
    });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "account/deactivate");
    }
    console.error("[account/deactivate] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

export default router;
