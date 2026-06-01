import express from "express";
import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";
import { broadcastUserInvalidation } from "../../lib/realtime-invalidation.js";
import { invalidateUserBootstrapCache } from "../../lib/user-bootstrap-cache.js";
import { getServiceRoleSupabase } from "../../lib/supabase-clients.js";
import { sendFounderSlackMessage } from "../../lib/founder-slack.js";

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

// Fired by the client right after a user finishes onboarding. Posts a founder Slack
// ping. Idempotent: the founder_onboarding_notified_at stamp is set atomically and
// the row is only returned when it was previously null, so retries / double-calls
// (or two devices) never produce duplicate pings.
router.post("/account/onboarding-complete", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const supabase = getServiceSupabase();
    const now = new Date().toISOString();

    const { data: rows, error } = await supabase
      .from("profiles")
      .update({ founder_onboarding_notified_at: now })
      .eq("id", userID)
      .is("founder_onboarding_notified_at", null)
      .select("email,display_name,preferred_name,cadence,food_persona,created_at");
    if (error) throw error;

    if (!Array.isArray(rows) || !rows.length) {
      // Already notified (or no profile row) — nothing to do.
      return res.json({ ok: true, notified: false });
    }

    const profile = rows[0];
    const name = profile.preferred_name || profile.display_name || "(no name)";
    const result = await sendFounderSlackMessage({
      heading: ":tada: *New user finished onboarding*",
      fields: [
        { label: "Name", value: name },
        { label: "Email", value: profile.email || "(no email)" },
        { label: "Cadence", value: profile.cadence },
        { label: "Persona", value: profile.food_persona },
        { label: "User", value: userID },
      ],
      context: profile.created_at ? `Joined ${profile.created_at}` : null,
    });

    if (!result.sent) {
      console.warn("[account/onboarding-complete] slack not sent:", result.reason);
    }
    return res.json({ ok: true, notified: result.sent, reason: result.reason ?? null });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "account/onboarding-complete");
    }
    console.error("[account/onboarding-complete] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

export default router;
