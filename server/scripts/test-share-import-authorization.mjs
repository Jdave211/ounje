import assert from "node:assert/strict";

import {
  createShareImportAuthorization,
  isShareImportCreateRequest,
  verifyShareImportAuthorization,
} from "../lib/share-import-authorization.js";
import { resolveAuthorizedUserID } from "../lib/auth.js";

const secret = "test-only-share-import-secret";
const now = Date.parse("2026-08-22T12:00:00.000Z");
const authorization = createShareImportAuthorization("user-123", {
  now,
  ttlSeconds: 3600,
  secret,
});

assert.equal(
  verifyShareImportAuthorization(authorization.token, { now: now + 1000, secret }).userID,
  "user-123"
);
assert.throws(
  () => verifyShareImportAuthorization(`${authorization.token.slice(0, -1)}x`, { now, secret }),
  /expired or invalid/
);
assert.throws(
  () => verifyShareImportAuthorization(authorization.token, { now: now + 3_601_000, secret }),
  /expired or invalid/
);
assert.equal(isShareImportCreateRequest({ method: "POST", originalUrl: "/v1/recipe/imports" }), true);
assert.equal(isShareImportCreateRequest({ method: "GET", originalUrl: "/v1/recipe/imports" }), false);
assert.equal(isShareImportCreateRequest({ method: "POST", originalUrl: "/v1/recipe/imports/completed" }), false);

process.env.OUNJE_SHARE_IMPORT_AUTH_SECRET = secret;
const liveAuthorization = createShareImportAuthorization("user-123");
const scopedAuth = await resolveAuthorizedUserID({
  method: "POST",
  originalUrl: "/v1/recipe/imports",
  headers: {
    "x-ounje-share-authorization": liveAuthorization.token,
    "x-user-id": "user-123",
  },
  body: { user_id: "user-123" },
});
assert.deepEqual(scopedAuth, { userID: "user-123", accessToken: null });
await assert.rejects(
  resolveAuthorizedUserID({
    method: "GET",
    originalUrl: "/v1/recipe/imports/completed",
    headers: { "x-ounje-share-authorization": liveAuthorization.token },
  }),
  /not valid for this request/
);

console.log("share import authorization tests passed");
