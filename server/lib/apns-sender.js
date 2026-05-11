// Apple Push Notification Service sender.
//
// Uses HTTP/2 + token-based authentication (.p8 key → ES256 JWT) so we can
// reuse a single key for all environments and don't have to roll certificates.
// Implemented with Node's built-in `http2` + `crypto` to avoid pulling in an
// external APNs dependency.
//
// Required env vars:
//   APNS_KEY_ID         – 10-character Key ID from Apple Developer.
//   APNS_TEAM_ID        – 10-character Team ID from Apple Developer.
//   APNS_BUNDLE_ID      – iOS bundle id (e.g. "net.ounje"). Used as the APNs
//                         topic header.
//   APNS_KEY_BASE64     – Contents of the AuthKey_<KEY_ID>.p8 file, base64
//                         encoded so it survives env var transport. The raw
//                         PEM is recovered before signing.
//
// Optional:
//   APNS_PRODUCTION     – truthy → default to production gateway. Per-call
//                         `environment` overrides this.
//
// Designed to fail SOFT: missing config logs a warning and the send is a
// no-op. We never want a push failure to break the upstream notification
// pipeline (Supabase row + realtime invalidation still happen).

import crypto from "node:crypto";
import http2 from "node:http2";

const APNS_KEY_ID = process.env.APNS_KEY_ID ?? "";
const APNS_TEAM_ID = process.env.APNS_TEAM_ID ?? "";
const APNS_BUNDLE_ID = process.env.APNS_BUNDLE_ID ?? "";
const APNS_KEY_BASE64 = process.env.APNS_KEY_BASE64 ?? "";

const PRODUCTION_HOST = "api.push.apple.com";
const SANDBOX_HOST = "api.development.push.apple.com";
const APNS_PORT = 443;

// JWTs for APNs must be regenerated at most once per hour and at least once
// per 20 minutes (Apple's docs). We cache the most recent JWT and recycle.
let cachedJwt = null;
let cachedJwtMintedAt = 0;
const JWT_REFRESH_MS = 50 * 60 * 1000;

function isApnsConfigured() {
  return (
    APNS_KEY_ID.length > 0
    && APNS_TEAM_ID.length > 0
    && APNS_BUNDLE_ID.length > 0
    && APNS_KEY_BASE64.length > 0
  );
}

function decodePrivateKeyPem() {
  try {
    const raw = Buffer.from(APNS_KEY_BASE64, "base64").toString("utf8");
    // Two acceptable formats: the original .p8 PEM or the bare base64 body.
    // Wrap the body if needed so crypto.createPrivateKey can parse it.
    if (raw.includes("BEGIN PRIVATE KEY")) return raw;
    const trimmed = raw.replace(/\s+/g, "");
    return `-----BEGIN PRIVATE KEY-----\n${trimmed}\n-----END PRIVATE KEY-----\n`;
  } catch (cause) {
    console.warn("[apns] failed to decode APNS_KEY_BASE64:", cause.message);
    return null;
  }
}

function base64UrlEncode(buffer) {
  return Buffer.from(buffer)
    .toString("base64")
    .replace(/=+$/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function mintJwt() {
  if (cachedJwt && Date.now() - cachedJwtMintedAt < JWT_REFRESH_MS) {
    return cachedJwt;
  }
  const pem = decodePrivateKeyPem();
  if (!pem) return null;

  const header = { alg: "ES256", kid: APNS_KEY_ID };
  const payload = {
    iss: APNS_TEAM_ID,
    iat: Math.floor(Date.now() / 1000),
  };
  const headerB64 = base64UrlEncode(JSON.stringify(header));
  const payloadB64 = base64UrlEncode(JSON.stringify(payload));
  const signingInput = `${headerB64}.${payloadB64}`;

  try {
    const signer = crypto.createSign("SHA256");
    signer.update(signingInput);
    signer.end();
    // The .p8 is an ES256 key; sign returns DER-encoded ECDSA. APNs wants
    // raw P1363 (r||s) format. Convert below.
    const derSignature = signer.sign({
      key: pem,
      dsaEncoding: "ieee-p1363",
    });
    const signatureB64 = base64UrlEncode(derSignature);
    cachedJwt = `${signingInput}.${signatureB64}`;
    cachedJwtMintedAt = Date.now();
    return cachedJwt;
  } catch (cause) {
    console.warn("[apns] failed to sign JWT:", cause.message);
    return null;
  }
}

/**
 * Sends an APNs push to a single device token.
 *
 * @param {object} options
 * @param {string} options.token         APNs device token (hex string).
 * @param {string} [options.environment] "sandbox" | "production" (default
 *                                       picks production unless DEBUG env).
 * @param {string} options.title         Notification title.
 * @param {string} options.body          Notification body.
 * @param {string} [options.subtitle]
 * @param {object} [options.userInfo]    Custom payload merged into the aps
 *                                       payload at the top level (e.g.
 *                                       { event_id, kind, deep_link }).
 * @returns {Promise<{ok: boolean, status?: number, reason?: string}>}
 */
export async function sendApnsNotification({
  token,
  environment = "production",
  title,
  body,
  subtitle,
  userInfo = {},
}) {
  if (!isApnsConfigured()) {
    return { ok: false, reason: "apns_not_configured" };
  }
  if (!token || !title || !body) {
    return { ok: false, reason: "missing_parameters" };
  }

  const jwt = mintJwt();
  if (!jwt) return { ok: false, reason: "jwt_failed" };

  const host = environment === "sandbox" ? SANDBOX_HOST : PRODUCTION_HOST;
  const path = `/3/device/${token}`;
  const payload = JSON.stringify({
    aps: {
      alert: subtitle ? { title, subtitle, body } : { title, body },
      sound: "default",
      "content-available": 1,
    },
    ...userInfo,
  });

  return new Promise((resolve) => {
    const client = http2.connect(`https://${host}:${APNS_PORT}`);
    let settled = false;
    const safeResolve = (value) => {
      if (settled) return;
      settled = true;
      try { client.close(); } catch (_) { /* noop */ }
      resolve(value);
    };

    client.on("error", (err) => {
      safeResolve({ ok: false, reason: `http2_error:${err.message}` });
    });

    const request = client.request({
      ":method": "POST",
      ":path": path,
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
      "content-length": Buffer.byteLength(payload).toString(),
    });

    let status = 0;
    let responseBody = "";

    request.on("response", (headers) => {
      status = Number(headers[":status"]) || 0;
    });
    request.on("data", (chunk) => { responseBody += chunk.toString(); });
    request.on("end", () => {
      if (status >= 200 && status < 300) {
        safeResolve({ ok: true, status });
      } else {
        let reason = `apns_${status}`;
        try {
          const parsed = JSON.parse(responseBody);
          if (parsed?.reason) reason = parsed.reason;
        } catch (_) { /* keep generic reason */ }
        safeResolve({ ok: false, status, reason });
      }
    });
    request.on("error", (err) => {
      safeResolve({ ok: false, reason: `req_error:${err.message}` });
    });

    request.end(payload);
  });
}
