import express from "express";
import { createClient } from "@supabase/supabase-js";
import { resolveAuthenticatedUserID } from "../../lib/instacart-run-logs.js";
import { broadcastUserInvalidation } from "../../lib/realtime-invalidation.js";

const router = express.Router();
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

function extractBearerToken(authorizationHeader) {
  const value = String(authorizationHeader ?? "").trim();
  if (!value) return null;
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match?.[1]?.trim() || null;
}

function getServiceSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Account deactivation requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY");
  }
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
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
    const accessToken = extractBearerToken(req.headers.authorization);
    if (!accessToken) {
      return res.status(401).json({ error: "Authorization required" });
    }

    const userID = await resolveAuthenticatedUserID(accessToken);
    if (!userID) {
      return res.status(401).json({ error: "Could not resolve authenticated user" });
    }

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
        .select("id", { count: "exact", head: true }),
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
        .select("id", { count: "exact", head: true }),
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
        .select("id", { count: "exact", head: true }),
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
        .select("user_id", { count: "exact", head: true }),
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
        .select("id", { count: "exact", head: true }),
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
        .select("run_id", { count: "exact", head: true }),
      "instacart_run_logs"
    );

    await broadcastUserInvalidation(userID, "account.deactivated", {
      status: "deactivated",
      deactivated_at: now,
    }).catch(() => {});

    return res.json({
      ok: true,
      status: "deactivated",
      deactivatedAt: now,
      counts,
    });
  } catch (error) {
    console.error("[account/deactivate] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

export default router;
