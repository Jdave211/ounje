import crypto from "node:crypto";

const TOKEN_VERSION = "v1";
const TOKEN_SCOPE = "recipe_import:create";
const DEFAULT_TTL_SECONDS = 180 * 24 * 60 * 60;

function normalizeText(value) {
  return String(value ?? "").trim();
}

function signingSecret(explicitSecret = null) {
  const source = normalizeText(
    explicitSecret
      ?? process.env.OUNJE_SHARE_IMPORT_AUTH_SECRET
      ?? process.env.SUPABASE_SERVICE_ROLE_KEY
  );
  if (!source) {
    const error = new Error("Share import authorization is not configured");
    error.statusCode = 503;
    throw error;
  }
  return crypto.createHash("sha256").update(`ounje:${TOKEN_SCOPE}:${source}`).digest();
}

function encodeJSON(value) {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

function decodeJSON(value) {
  return JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
}

function signatureFor(encodedPayload, explicitSecret = null) {
  return crypto
    .createHmac("sha256", signingSecret(explicitSecret))
    .update(`${TOKEN_VERSION}.${encodedPayload}`)
    .digest("base64url");
}

function signaturesMatch(actual, expected) {
  const actualBuffer = Buffer.from(normalizeText(actual));
  const expectedBuffer = Buffer.from(normalizeText(expected));
  return actualBuffer.length === expectedBuffer.length
    && crypto.timingSafeEqual(actualBuffer, expectedBuffer);
}

export function createShareImportAuthorization(userID, {
  now = Date.now(),
  ttlSeconds = DEFAULT_TTL_SECONDS,
  secret = null,
} = {}) {
  const subject = normalizeText(userID);
  if (!subject) {
    const error = new Error("User ID is required");
    error.statusCode = 400;
    throw error;
  }

  const issuedAt = Math.floor(Number(now) / 1000);
  const lifetime = Math.max(60, Math.floor(Number(ttlSeconds) || DEFAULT_TTL_SECONDS));
  const payload = {
    sub: subject,
    scope: TOKEN_SCOPE,
    iat: issuedAt,
    exp: issuedAt + lifetime,
    jti: crypto.randomBytes(12).toString("base64url"),
  };
  const encodedPayload = encodeJSON(payload);
  return {
    token: `${TOKEN_VERSION}.${encodedPayload}.${signatureFor(encodedPayload, secret)}`,
    expiresAt: new Date(payload.exp * 1000).toISOString(),
  };
}

export function verifyShareImportAuthorization(token, {
  now = Date.now(),
  secret = null,
} = {}) {
  const [version, encodedPayload, signature, ...extra] = normalizeText(token).split(".");
  if (version !== TOKEN_VERSION || !encodedPayload || !signature || extra.length > 0) {
    throwInvalidAuthorization();
  }

  const expectedSignature = signatureFor(encodedPayload, secret);
  if (!signaturesMatch(signature, expectedSignature)) {
    throwInvalidAuthorization();
  }

  let payload;
  try {
    payload = decodeJSON(encodedPayload);
  } catch {
    throwInvalidAuthorization();
  }

  const currentTime = Math.floor(Number(now) / 1000);
  const subject = normalizeText(payload?.sub);
  if (
    !subject
    || payload?.scope !== TOKEN_SCOPE
    || !Number.isInteger(payload?.iat)
    || !Number.isInteger(payload?.exp)
    || payload.exp <= currentTime
    || payload.iat > currentTime + 60
  ) {
    throwInvalidAuthorization();
  }

  return {
    userID: subject,
    scope: TOKEN_SCOPE,
    expiresAt: new Date(payload.exp * 1000).toISOString(),
  };
}

export function isShareImportCreateRequest(req) {
  if (normalizeText(req?.method).toUpperCase() !== "POST") return false;
  const path = normalizeText(req?.originalUrl ?? req?.url).split("?", 1)[0].replace(/\/+$/, "");
  return path === "/v1/recipe/imports" || path === "/recipe/imports";
}

function throwInvalidAuthorization() {
  const error = new Error("Share import authorization expired or invalid");
  error.statusCode = 401;
  throw error;
}

