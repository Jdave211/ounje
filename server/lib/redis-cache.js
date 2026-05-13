import { createClient } from "redis";

let redisClient = null;
let redisClientPromise = null;
let lastRedisError = null;

function redisURL() {
  return String(process.env.REDIS_URL ?? "").trim();
}

function redisDisabled() {
  return ["1", "true", "yes", "on"].includes(
    String(process.env.REDIS_DISABLED ?? "").trim().toLowerCase()
  );
}

function redisConnectTimeoutMs() {
  return Math.max(250, Number.parseInt(String(process.env.REDIS_CONNECT_TIMEOUT_MS ?? "800"), 10) || 800);
}

function redisOperationTimeoutMs() {
  return Math.max(100, Number.parseInt(String(process.env.REDIS_OPERATION_TIMEOUT_MS ?? "350"), 10) || 350);
}

function redactedRedisEndpoint() {
  const urlString = redisURL();
  if (!urlString) return null;
  try {
    const url = new URL(urlString);
    return {
      protocol: url.protocol.replace(":", ""),
      host: url.hostname,
      port: url.port || (url.protocol === "rediss:" ? "6380" : "6379"),
    };
  } catch {
    return { protocol: "unknown", host: "invalid_url", port: null };
  }
}

export function redisConfigStatus() {
  const disabled = redisDisabled();
  return {
    configured: Boolean(redisURL()) && !disabled,
    disabled,
    endpoint: redactedRedisEndpoint(),
  };
}

export async function getRedisClient() {
  const url = redisURL();
  if (!url || redisDisabled()) return null;
  if (redisClient?.isOpen) return redisClient;
  if (redisClientPromise) return redisClientPromise;

  redisClient = createClient({
    url,
    socket: {
      connectTimeout: redisConnectTimeoutMs(),
      reconnectStrategy: false,
    },
  });

  redisClient.on("error", (error) => {
    lastRedisError = error;
  });

  redisClientPromise = redisClient.connect()
    .then(() => redisClient)
    .catch((error) => {
      lastRedisError = error;
      redisClientPromise = null;
      redisClient = null;
      throw error;
    });

  return redisClientPromise;
}

function withTimeout(promise, timeoutMs, label) {
  let timeoutID;
  const timeout = new Promise((_, reject) => {
    timeoutID = setTimeout(() => reject(new Error(`${label}_timeout`)), timeoutMs);
  });

  return Promise.race([promise, timeout])
    .finally(() => clearTimeout(timeoutID));
}

export async function checkRedisHealth({ timeoutMs = 1_500 } = {}) {
  const startedAt = Date.now();
  const config = redisConfigStatus();
  if (!config.configured) {
    return {
      ...config,
      status: config.disabled ? "disabled" : "not_configured",
      latency_ms: 0,
      last_error: lastRedisError?.message ?? null,
    };
  }

  try {
    const client = await withTimeout(getRedisClient(), timeoutMs, "redis_connect");
    const pong = await withTimeout(client.ping(), timeoutMs, "redis_ping");
    return {
      ...config,
      status: pong === "PONG" ? "ok" : "unexpected_response",
      latency_ms: Date.now() - startedAt,
      last_error: null,
    };
  } catch (error) {
    lastRedisError = error;
    return {
      ...config,
      status: "error",
      latency_ms: Date.now() - startedAt,
      last_error: error.message,
    };
  }
}

export async function readRedisJSON(key) {
  if (!key) return null;
  try {
    const client = await getRedisClient();
    if (!client) return null;
    const raw = await withTimeout(client.get(key), redisOperationTimeoutMs(), "redis_get");
    if (!raw) return null;
    return JSON.parse(raw);
  } catch (error) {
    lastRedisError = error;
    return null;
  }
}

export async function writeRedisJSON(key, value, ttlSeconds) {
  if (!key || value == null) return false;
  const seconds = Math.max(1, Number.parseInt(String(ttlSeconds ?? ""), 10) || 1);
  try {
    const client = await getRedisClient();
    if (!client) return false;
    await withTimeout(client.set(key, JSON.stringify(value), { EX: seconds }), redisOperationTimeoutMs(), "redis_set");
    return true;
  } catch (error) {
    lastRedisError = error;
    return false;
  }
}
