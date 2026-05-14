import express from "express";

import {
  processAppStoreNotification,
  verifyAppStoreNotificationPayload,
} from "../../lib/app-store-notifications.js";
import { getServiceRoleSupabase } from "../../lib/supabase-clients.js";

const router = express.Router();

function getServiceSupabase() {
  return getServiceRoleSupabase();
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
