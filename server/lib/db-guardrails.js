const DEFAULT_SLOW_MS = 750;
const DEFAULT_RETRY_AFTER_SECONDS = 30;
const DEFAULT_EVENT_WINDOW_MS = 60_000;

const recentEvents = [];

function envFlag(name, defaultValue = false) {
  const raw = String(process.env[name] ?? "").trim().toLowerCase();
  if (!raw) return defaultValue;
  return ["1", "true", "yes", "on"].includes(raw);
}

function envInt(name, fallback, min = 0, max = Number.MAX_SAFE_INTEGER) {
  const parsed = Number.parseInt(String(process.env[name] ?? ""), 10);
  const value = Number.isFinite(parsed) ? parsed : fallback;
  return Math.max(min, Math.min(value, max));
}

export function guardrailConfig() {
  const enabled = envFlag("OUNJE_GUARDRAILS_ENABLED", true);
  const mode = String(process.env.OUNJE_CIRCUIT_BREAKER_MODE ?? "log").trim().toLowerCase();
  return {
    enabled,
    mode: mode === "enforce" ? "enforce" : "log",
    slowMs: envInt("OUNJE_DB_SLOW_MS", DEFAULT_SLOW_MS, 100),
    retryAfterSeconds: envInt("OUNJE_NONESSENTIAL_RETRY_AFTER_SECONDS", DEFAULT_RETRY_AFTER_SECONDS, 1, 300),
    windowMs: envInt("OUNJE_GUARDRAIL_EVENT_WINDOW_MS", DEFAULT_EVENT_WINDOW_MS, 10_000, 10 * 60_000),
    degradedSlowEvents: envInt("OUNJE_GUARDRAIL_DEGRADED_SLOW_EVENTS", 8, 1, 200),
    degradedErrorEvents: envInt("OUNJE_GUARDRAIL_DEGRADED_ERROR_EVENTS", 3, 1, 200),
  };
}

function pruneEvents(now = Date.now()) {
  const { windowMs } = guardrailConfig();
  while (recentEvents.length && now - recentEvents[0].at > windowMs) {
    recentEvents.shift();
  }
}

function safeErrorMessage(error) {
  const message = String(error?.message ?? error ?? "").trim();
  return message ? message.slice(0, 240) : null;
}

function pushEvent(event) {
  if (!guardrailConfig().enabled) return;
  const now = Date.now();
  pruneEvents(now);
  recentEvents.push({ ...event, at: now });
  if (recentEvents.length > 500) {
    recentEvents.splice(0, recentEvents.length - 500);
  }
}

export function recordDbOperation({ operation, method = "GET", path = null, durationMs = 0, ok = true, status = null, error = null } = {}) {
  const config = guardrailConfig();
  if (!config.enabled) return;

  const normalizedDuration = Math.max(0, Math.round(Number(durationMs) || 0));
  const isSlow = normalizedDuration >= config.slowMs;
  const isError = !ok || Boolean(error) || (Number.isFinite(Number(status)) && Number(status) >= 500);

  if (isSlow || isError) {
    const payload = {
      operation: operation ?? "supabase",
      method,
      path: path ? String(path).slice(0, 220) : null,
      status: status ?? null,
      duration_ms: normalizedDuration,
      error: safeErrorMessage(error),
    };
    console.warn("[db-guardrail] supabase_slow_or_error", payload);
    pushEvent({
      type: isError ? "db_error" : "db_slow",
      duration_ms: normalizedDuration,
      operation: payload.operation,
      status: payload.status,
    });
  }
}

export function recordApiRouteMetric({ method = "GET", path = "", status = 200, durationMs = 0 } = {}) {
  const config = guardrailConfig();
  if (!config.enabled) return;

  const normalizedDuration = Math.max(0, Math.round(Number(durationMs) || 0));
  if (Number(status) >= 500) {
    pushEvent({ type: "api_error", duration_ms: normalizedDuration, route: `${method} ${path}`, status });
  } else if (normalizedDuration >= Math.max(config.slowMs * 2, 1500)) {
    pushEvent({ type: "api_slow", duration_ms: normalizedDuration, route: `${method} ${path}`, status });
  }
}

export function getGuardrailState() {
  const config = guardrailConfig();
  pruneEvents();

  const counts = recentEvents.reduce((acc, event) => {
    acc[event.type] = (acc[event.type] ?? 0) + 1;
    return acc;
  }, {});

  const slowCount = (counts.db_slow ?? 0) + (counts.api_slow ?? 0);
  const errorCount = (counts.db_error ?? 0) + (counts.api_error ?? 0);
  const degraded = config.enabled
    && (slowCount >= config.degradedSlowEvents || errorCount >= config.degradedErrorEvents);

  return {
    enabled: config.enabled,
    mode: config.mode,
    degraded,
    retry_after_seconds: config.retryAfterSeconds,
    event_window_ms: config.windowMs,
    counts,
    reason: degraded
      ? (errorCount >= config.degradedErrorEvents ? "recent_errors" : "recent_slow_operations")
      : null,
  };
}

export function nonEssentialRoute(req) {
  const method = String(req?.method ?? "GET").toUpperCase();
  const path = String(req?.path ?? req?.originalUrl ?? "");
  if (method === "POST" && path === "/v1/recipe/discover") return true;
  if (method === "GET" && /^\/v1\/recipe\/detail\/[^/]+\/similar$/.test(path)) return true;
  if (method === "POST" && path === "/v1/recipe/similar") return true;
  if (method === "POST" && /^\/v1\/recipe\/[^/]+\/enrich-(macros|image)$/.test(path)) return true;
  return false;
}

export function maybeBlockNonEssentialDuringDegraded(req, res, next) {
  const state = getGuardrailState();
  if (!state.enabled || state.mode !== "enforce" || !state.degraded || !nonEssentialRoute(req)) {
    return next();
  }

  res.set("Retry-After", String(state.retry_after_seconds));
  return res.status(503).json({
    error: "Service is temporarily busy",
    code: "temporarily_degraded",
    degraded: true,
    retry_after_seconds: state.retry_after_seconds,
  });
}

export function importQueueBusyError(message = "Import queue is busy") {
  const error = new Error(message);
  error.statusCode = 429;
  error.code = "import_queue_busy";
  error.retryAfterSeconds = guardrailConfig().retryAfterSeconds;
  return error;
}
