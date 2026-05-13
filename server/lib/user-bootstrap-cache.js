import crypto from "node:crypto";
import { deleteRedisKey } from "./redis-cache.js";

export function normalizeText(value) {
  return String(value ?? "").trim();
}

export function userScopedCacheKey(namespace, userID) {
  const normalizedUserID = normalizeText(userID);
  if (!namespace || !normalizedUserID) return null;
  const digest = crypto.createHash("sha256").update(normalizedUserID).digest("hex");
  return `ounje:${namespace}:${digest}`;
}

export function userBootstrapCacheKey(userID) {
  return userScopedCacheKey("user-bootstrap", userID);
}

export function invalidateUserBootstrapCache(userID) {
  const key = userBootstrapCacheKey(userID);
  if (key) void deleteRedisKey(key);
}
