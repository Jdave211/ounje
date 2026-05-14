// Per-process + per-cluster single-flight helper.
//
// Use when an endpoint does expensive compute on a cache miss (e.g. discover
// search, embedding generation, image fetch fan-out). Without this, when a
// hot key expires N concurrent requests all do the same expensive work in
// parallel ("cache stampede").
//
// In-process: we de-dupe via a Map<string, Promise>.
// Across the cluster: we use a Redis NX lock so only one Node instance does
// the heavy work; the others poll Redis for the filled cache entry.
//
// Failure mode: if Redis is unreachable or the lock can't be acquired
// quickly, we fall back to doing the work locally rather than serving stale.
// That preserves correctness at the cost of occasional duplicated work.

import { readRedisJSON, writeRedisJSON, acquireRedisLock, releaseRedisLock } from "./redis-cache.js";

const inFlightLocal = new Map();

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * @typedef {Object} SingleFlightOptions
 * @property {string} cacheKey                 Redis key holding the cached JSON payload.
 * @property {number} ttlSeconds               TTL applied to the cache entry on fill.
 * @property {() => Promise<any>} compute      Async function that produces the value when cache misses.
 * @property {string} [lockKey]                Optional Redis lock key; defaults to `${cacheKey}:lock`.
 * @property {number} [lockSeconds=15]         How long the cluster lock should live.
 * @property {number} [waitMs=2000]            Max time non-leaders wait for the leader to fill the cache.
 * @property {number} [pollMs=120]             Poll interval while waiting.
 */

/**
 * Single-flight wrapper. Returns the cached value if present; otherwise only
 * one caller (per process + per cluster) executes `compute()` and writes the
 * result; concurrent callers wait briefly for that fill and read it.
 *
 * @template T
 * @param {SingleFlightOptions} options
 * @returns {Promise<{ value: T, hit: "memory" | "redis" | "computed" | "waited" }>}
 */
export async function withSingleFlight(options) {
  const {
    cacheKey,
    ttlSeconds,
    compute,
    lockKey,
    lockSeconds = 15,
    waitMs = 2_000,
    pollMs = 120,
  } = options;

  if (!cacheKey) throw new Error("withSingleFlight requires a cacheKey");
  if (typeof compute !== "function") throw new Error("withSingleFlight requires a compute() function");

  const cached = await readRedisJSON(cacheKey);
  if (cached !== null && cached !== undefined) {
    return { value: cached, hit: "redis" };
  }

  const inflight = inFlightLocal.get(cacheKey);
  if (inflight) {
    const value = await inflight;
    return { value, hit: "memory" };
  }

  const computation = (async () => {
    const resolvedLockKey = lockKey || `${cacheKey}:lock`;
    const leaderToken = await acquireRedisLock(resolvedLockKey, lockSeconds);

    if (!leaderToken) {
      // Another node is filling. Poll the cache for up to `waitMs` then fall
      // back to local compute if we're still empty.
      const deadline = Date.now() + waitMs;
      while (Date.now() < deadline) {
        await sleep(pollMs);
        const filled = await readRedisJSON(cacheKey);
        if (filled !== null && filled !== undefined) {
          return { value: filled, hit: "waited" };
        }
      }
    }

    try {
      const value = await compute();
      if (value !== null && value !== undefined && Number.isFinite(ttlSeconds) && ttlSeconds > 0) {
        await writeRedisJSON(cacheKey, value, ttlSeconds);
      }
      return { value, hit: "computed" };
    } finally {
      if (leaderToken) {
        await releaseRedisLock(resolvedLockKey, leaderToken).catch(() => null);
      }
    }
  })();

  // De-dupe concurrent in-process callers on the unwrapped value, not the
  // {value, hit} tuple — they all share the same effective result.
  const unwrapped = computation.then((result) => result.value);
  inFlightLocal.set(cacheKey, unwrapped);
  try {
    return await computation;
  } finally {
    inFlightLocal.delete(cacheKey);
  }
}
