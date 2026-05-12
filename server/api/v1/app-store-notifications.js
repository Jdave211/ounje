import express from "express";
import { createClient } from "@supabase/supabase-js";

import {
  processAppStoreNotification,
  verifyAppStoreNotificationPayload,
} from "../../lib/app-store-notifications.js";

const router = express.Router();

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

function getServiceSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Supabase not configured");
  }
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

router.post("/app-store/notifications", async (req, res) => {
  try {
    const signedPayload = req.body?.signedPayload;
    const decoded = await verifyAppStoreNotificationPayload(signedPayload);
    const result = await processAppStoreNotification({
      supabase: getServiceSupabase(),
      ...decoded,
    });

    return res.json(result);
  } catch (error) {
    const statusCode = Number(error?.statusCode) || 500;
    if (statusCode >= 500) {
      console.error("[app-store/notifications] error:", error.message);
    } else {
      console.warn("[app-store/notifications] rejected:", error.message);
    }

    return res.status(statusCode).json({
      ok: false,
      error: error.message,
      ledger: error?.ledger ?? undefined,
    });
  }
});

export default router;
