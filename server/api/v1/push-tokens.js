import express from "express";
import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";
import { registerDeviceToken, unregisterDeviceToken, pushTestNotificationToLatestDevice } from "../../lib/push-tokens.js";

const router = express.Router();

router.post("/push-tokens/register", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const token = String(req.body?.token ?? "").trim();
    if (!token) {
      return res.status(400).json({ error: "token is required" });
    }
    const row = await registerDeviceToken({
      userId: userID,
      token,
      environment: req.body?.environment,
      platform: req.body?.platform,
      appVersion: req.body?.app_version,
      deviceModel: req.body?.device_model,
      osVersion: req.body?.os_version,
    });
    return res.status(201).json({ ok: true, device: row });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "push-tokens/register");
    }
    console.error("[push-tokens/register] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

router.post("/push-tokens/unregister", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const token = String(req.body?.token ?? "").trim();
    if (!token) return res.status(400).json({ error: "token is required" });
    await unregisterDeviceToken({ userId: userID, token });
    return res.json({ ok: true });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "push-tokens/unregister");
    }
    console.error("[push-tokens/unregister] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

router.post("/push-tokens/test", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const testId = String(req.body?.test_id ?? req.body?.testId ?? "").trim();
    const deviceToken = String(req.body?.token ?? req.body?.device_token ?? req.body?.deviceToken ?? "").trim();
    const results = await pushTestNotificationToLatestDevice({ userId: userID, testId, deviceToken });
    const ok = results.some((result) => result.ok);
    const reasons = [...new Set(results.map((result) => result.reason).filter(Boolean))];
    const message = ok
      ? "Server APNs test push accepted."
      : results.length === 0
        ? deviceToken
          ? "This app's current APNs token is not registered for this account yet. Reopen Ounje once with notifications allowed, then try again."
          : "No APNs device token is registered for this account yet. Open Ounje once with notifications allowed, then try again."
        : `Server APNs test push failed${reasons.length ? `: ${reasons.join(", ")}` : "."}`;
    return res.json({ ok, message, results });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "push-tokens/test");
    }
    console.error("[push-tokens/test] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

export default router;
