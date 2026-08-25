import express from "express";

import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";
import { createShareImportAuthorization } from "../../lib/share-import-authorization.js";

const share_import_authorization_router = express.Router();

share_import_authorization_router.post("/recipe/imports/share-authorization", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req, { allowBodyAccessToken: true });
    const authorization = createShareImportAuthorization(userID);
    return res.status(201).json({
      token: authorization.token,
      expires_at: authorization.expiresAt,
    });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "recipe/imports/share-authorization");
    }
    console.error("[recipe/imports/share-authorization] failed:", error?.message ?? error);
    return res.status(Number(error?.statusCode) || 500).json({
      error: error?.message ?? "Share import authorization failed",
    });
  }
});

export default share_import_authorization_router;
