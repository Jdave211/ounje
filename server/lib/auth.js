import { resolveAuthenticatedUserID } from "./instacart-run-logs.js";

function normalizeText(value) {
  return String(value ?? "").trim();
}

export function extractBearerToken(authorizationHeader) {
  const value = normalizeText(authorizationHeader);
  if (!value) return null;
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match?.[1]?.trim() || null;
}

function addCandidate(candidates, value) {
  const normalized = normalizeText(value);
  if (normalized) candidates.add(normalized);
}

export function collectRequestedUserIDs(req, extraValues = []) {
  const candidates = new Set();
  addCandidate(candidates, req?.headers?.["x-user-id"]);
  addCandidate(candidates, req?.query?.user_id);
  addCandidate(candidates, req?.query?.userID);
  addCandidate(candidates, req?.body?.user_id);
  addCandidate(candidates, req?.body?.userID);

  const event = req?.body?.event && typeof req.body.event === "object" ? req.body.event : null;
  addCandidate(candidates, event?.user_id);
  addCandidate(candidates, event?.userID);

  for (const value of extraValues) {
    addCandidate(candidates, value);
  }

  return [...candidates];
}

export async function resolveAuthorizedUserID(req, { extraUserIDValues = [] } = {}) {
  const accessToken = extractBearerToken(req?.headers?.authorization);
  if (!accessToken) {
    const error = new Error("Authorization required");
    error.statusCode = 401;
    throw error;
  }

  let authenticatedUserID = null;
  try {
    authenticatedUserID = await resolveAuthenticatedUserID(accessToken);
  } catch (cause) {
    const error = new Error("Authorization expired or invalid");
    error.statusCode = 401;
    error.cause = cause;
    throw error;
  }

  if (!authenticatedUserID) {
    const error = new Error("Authorization expired or invalid");
    error.statusCode = 401;
    throw error;
  }

  const requestedUserIDs = collectRequestedUserIDs(req, extraUserIDValues);
  const mismatchedUserID = requestedUserIDs.find((candidate) => candidate !== authenticatedUserID);
  if (mismatchedUserID) {
    const error = new Error("User mismatch");
    error.statusCode = 403;
    throw error;
  }

  return { userID: authenticatedUserID, accessToken };
}

export function sendAuthError(res, error, label = "auth") {
  const statusCode = Number(error?.statusCode) || 500;
  if (statusCode >= 500) {
    console.error(`[${label}] auth error:`, error?.message ?? error);
  }
  return res.status(statusCode).json({ error: error?.message ?? "Authorization failed" });
}
