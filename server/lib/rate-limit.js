// Lightweight Redis-backed rate limiter for the most expensive endpoints.
//
// Why it exists: the API process previously had NO request-rate controls. A
// single misbehaving client (or a network glitch causing the iOS app to
// retry in a tight loop) could trivially fan out into OpenAI + Supabase
// fan-out work and starve other users.
//
// Implementation: fixed-window counter per (key, window). Cheap, easy to
// reason about, and lossy in the right direction (we err on the side of
// allowing slightly more than the limit at window boundaries rather than
// blocking legitimate traffic). If Redis is unavailable we fail OPEN so that
// a Redis outage cannot take down the whole API.
//
// Usage:
//   import { createRateLimit } from "../../lib/rate-limit.js";
//   router.use(createRateLimit({ name: "recipe-discover", windowSeconds: 60, max: 30 }));

import crypto from "node:crypto";

import { getRedisClient } from "./redis-cache.js";
import { resolveAuthorizedUserID } from "./auth.js";

const DEFAULT_OPERATION_TIMEOUT_MS = Number.parseInt(
  String(process.env.REDIS_OPERATION_TIMEOUT_MS ?? "350"),
  10
) || 350;

function withTimeout(promise, timeoutMs, label) {
  let timeoutID;
  const timeout = new Promise((_, reject) => {
    timeoutID = setTimeout(() => reject(new Error(`${label}_timeout`)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timeoutID));
}

function clientIPHash(req) {
  const candidate = String(
    req.headers["cf-connecting-ip"]
      ?? req.headers["x-forwarded-for"]?.split(",")[0]?.trim()
      ?? req.headers["x-real-ip"]
      ?? req.ip
      ?? ""
  ).trim();

  if (!candidate) return "unknown";
  return crypto.createHash("sha1").update(candidate).digest("hex").slice(0, 16);
}

function userIDFromHeaders(req) {
  return String(req.headers["x-user-id"] ?? "").trim();
}

/**
 * Build an express middleware that enforces a per-key rate limit.
 *
 * @param {Object} options
 * @param {string} options.name             A short identifier baked into the Redis key + 429 response.
 * @param {number} options.windowSeconds    Window size for the fixed-window counter.
 * @param {number} options.max              Max requests per window per key.
 * @param {(req: import("express").Request) => string} [options.keyFn] Optional
 *   custom key extractor. Defaults to authenticated user id (via x-user-id
 *   header — already populated by withAIUsageContext at the top of server.js)
 *   with a fallback to a hashed client IP.
 * @param {boolean} [options.skipIfDisabled=true] When true, the middleware no-ops
 *   if RATE_LIMIT_DISABLED=1 in env. Useful as a deploy-time killswitch.
 */
export function createRateLimit({ name, windowSeconds, max, keyFn, skipIfDisabled = true }) {
  if (!name) throw new Error("createRateLimit requires a `name`");
  if (!Number.isFinite(windowSeconds) || windowSeconds <= 0) {
    throw new Error("createRateLimit requires positive `windowSeconds`");
  }
  if (!Number.isFinite(max) || max <= 0) {
    throw new Error("createRateLimit requires positive `max`");
  }

  return async function rateLimitMiddleware(req, res, next) {
    if (skipIfDisabled && String(process.env.RATE_LIMIT_DISABLED ?? "").trim() === "1") {
      return next();
    }

    let key = null;
    try {
      if (typeof keyFn === "function") {
        key = String(keyFn(req) ?? "").trim();
      } else {
        key = userIDFromHeaders(req) || `ip:${clientIPHash(req)}`;
      }
    } catch {
      key = `ip:${clientIPHash(req)}`;
    }

    if (!key) key = `ip:${clientIPHash(req)}`;

    const bucket = Math.floor(Date.now() / 1000 / windowSeconds);
    const redisKey = `ratelimit:${name}:${bucket}:${key}`;

    try {
      const client = await getRedisClient();
      if (!client) return next();

      const current = await withTimeout(client.incr(redisKey), DEFAULT_OPERATION_TIMEOUT_MS, "ratelimit_incr");
      if (current === 1) {
        // Best-effort TTL; if EXPIRE fails the key just lingers until next IDLE.
        void withTimeout(
          client.expire(redisKey, windowSeconds),
          DEFAULT_OPERATION_TIMEOUT_MS,
          "ratelimit_expire"
        ).catch(() => null);
      }

      if (current > max) {
        const retryAfter = windowSeconds - (Math.floor(Date.now() / 1000) % windowSeconds);
        res.set("Retry-After", String(Math.max(1, retryAfter)));
        res.set("X-RateLimit-Limit", String(max));
        res.set("X-RateLimit-Remaining", "0");
        return res.status(429).json({
          error: "Too many requests",
          limit: name,
          window_seconds: windowSeconds,
          retry_after_seconds: retryAfter,
        });
      }

      res.set("X-RateLimit-Limit", String(max));
      res.set("X-RateLimit-Remaining", String(Math.max(0, max - current)));
      return next();
    } catch {
      // Fail open on Redis trouble — never block real users because the
      // limiter itself is sick.
      return next();
    }
  };
}

/**
 * Authenticated rate limit: resolves the bearer token, fails 401 if missing/
 * invalid, then rate-limits by user_id (consistent across IPs / devices).
 * Use on endpoints where anonymous traffic should be hard-rejected.
 */
export function createAuthenticatedRateLimit({ name, windowSeconds, max }) {
  return async function authenticatedRateLimitMiddleware(req, res, next) {
    try {
      const { userID } = await resolveAuthorizedUserID(req);
      const inner = createRateLimit({
        name,
        windowSeconds,
        max,
        keyFn: () => `uid:${userID}`,
      });
      return inner(req, res, next);
    } catch (error) {
      const statusCode = Number(error?.statusCode) || 401;
      return res.status(statusCode).json({ error: error?.message ?? "Authorization required" });
    }
  };
}
