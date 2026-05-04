import { AsyncLocalStorage } from "node:async_hooks";
import crypto from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import OpenAI from "openai";

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const NODE_ENV = process.env.NODE_ENV ?? "development";
const ENABLE_AI_CALL_LOGGING = !["0", "false", "off", "no"].includes(
  String(process.env.OUNJE_ENABLE_AI_CALL_LOGGING ?? "1").trim().toLowerCase()
);
const GLOBAL_DAILY_SPEND_LIMIT_USD = Number.parseFloat(process.env.OUNJE_AI_DAILY_SPEND_LIMIT_USD ?? "8");
const USER_DAILY_SPEND_LIMIT_USD = Number.parseFloat(process.env.OUNJE_AI_USER_DAILY_SPEND_LIMIT_USD ?? "3");
const BUDGET_FAIL_CLOSED = ["1", "true", "yes", "on"].includes(
  String(process.env.OUNJE_AI_BUDGET_FAIL_CLOSED ?? "").trim().toLowerCase()
);
const BUDGET_CACHE_TTL_MS = 60_000;

const aiUsageStorage = new AsyncLocalStorage();
let supabaseClient = null;
let warnedAboutLogging = false;
const budgetCache = new Map();

const MODEL_PRICING_PER_MILLION = {
  "gpt-5-mini": { input: 0.25, output: 2.00 },
  "gpt-5-mini-2025-08-07": { input: 0.25, output: 2.00 },
  "gpt-5-nano": { input: 0.05, output: 0.40 },
  "gpt-5.4-nano": { input: 0.05, output: 0.40 },
  "gpt-4o-mini": { input: 0.15, output: 0.60 },
  "gpt-4o-mini-transcribe": { input: 0, output: 0 },
  "text-embedding-3-small": { input: 0.02, output: 0 },
  "text-embedding-3-large": { input: 0.13, output: 0 },
};

function getSupabaseClient() {
  if (!ENABLE_AI_CALL_LOGGING || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) return null;
  if (!supabaseClient) {
    supabaseClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });
  }
  return supabaseClient;
}

export function verifyAIUsageLoggingConfiguration({ service = "server" } = {}) {
  const ok = Boolean(ENABLE_AI_CALL_LOGGING && SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY);
  if (!ok && ENABLE_AI_CALL_LOGGING && !warnedAboutLogging) {
    warnedAboutLogging = true;
    console.warn(`[ai-call-logs] ${service}: Supabase service role not configured; OpenAI usage logging disabled.`);
  }
  return ok;
}

function normalizeText(value, limit = 220) {
  const text = String(value ?? "").trim();
  if (text.length <= limit) return text || null;
  return `${text.slice(0, limit - 1).trimEnd()}…`;
}

function byteLength(value) {
  if (value === undefined || value === null) return 0;
  try {
    return Buffer.byteLength(typeof value === "string" ? value : JSON.stringify(value), "utf8");
  } catch {
    return 0;
  }
}

function hashInput(value) {
  if (value === undefined || value === null) return null;
  try {
    const payload = typeof value === "string" ? value : JSON.stringify(value);
    return crypto.createHash("sha256").update(payload).digest("hex");
  } catch {
    return null;
  }
}

function extractUsage(response) {
  const usage = response?.usage ?? {};
  const inputTokens = usage.prompt_tokens ?? usage.input_tokens ?? null;
  const outputTokens = usage.completion_tokens ?? usage.output_tokens ?? null;
  const totalTokens = usage.total_tokens
    ?? (Number.isFinite(inputTokens) || Number.isFinite(outputTokens)
      ? Number(inputTokens ?? 0) + Number(outputTokens ?? 0)
      : null);

  return {
    inputTokens: Number.isFinite(Number(inputTokens)) ? Number(inputTokens) : null,
    outputTokens: Number.isFinite(Number(outputTokens)) ? Number(outputTokens) : null,
    totalTokens: Number.isFinite(Number(totalTokens)) ? Number(totalTokens) : null,
  };
}

function extractModel(response, requestPayload) {
  return normalizeText(response?.model ?? requestPayload?.model ?? requestPayload?.engine ?? null, 120);
}

function estimateCostUSD(model, inputTokens, outputTokens) {
  const normalizedModel = String(model ?? "").trim();
  if (!normalizedModel) return null;
  const pricing = MODEL_PRICING_PER_MILLION[normalizedModel]
    ?? MODEL_PRICING_PER_MILLION[normalizedModel.replace(/-\d{4}-\d{2}-\d{2}$/, "")]
    ?? null;
  if (!pricing) return null;
  const inputCost = (Number(inputTokens ?? 0) / 1_000_000) * pricing.input;
  const outputCost = (Number(outputTokens ?? 0) / 1_000_000) * pricing.output;
  const total = inputCost + outputCost;
  return Number.isFinite(total) ? Number(total.toFixed(6)) : null;
}

function currentContext() {
  return aiUsageStorage.getStore() ?? {};
}

export function withAIUsageContext(context, fn) {
  const parent = currentContext();
  const merged = {
    ...parent,
    ...Object.fromEntries(
      Object.entries(context ?? {}).filter(([, value]) => value !== undefined && value !== null && value !== "")
    ),
  };
  return aiUsageStorage.run(merged, fn);
}

export function annotateAIUsageContext(context) {
  const store = aiUsageStorage.getStore();
  if (!store || !context || typeof context !== "object") return;
  for (const [key, value] of Object.entries(context)) {
    if (value !== undefined && value !== null && value !== "") {
      store[key] = value;
    }
  }
}

async function recordAICall(row) {
  const supabase = getSupabaseClient();
  if (!supabase) {
    verifyAIUsageLoggingConfiguration({ service: row?.service ?? "server" });
    return;
  }

  try {
    const { error } = await supabase.from("ai_call_logs").insert(row);
    if (error && !warnedAboutLogging) {
      warnedAboutLogging = true;
      console.warn("[ai-call-logs] insert failed:", error.message);
    }
  } catch (error) {
    if (!warnedAboutLogging) {
      warnedAboutLogging = true;
      console.warn("[ai-call-logs] insert failed:", error.message);
    }
  }
}

function utcDayStartIso() {
  const date = new Date();
  date.setUTCHours(0, 0, 0, 0);
  return date.toISOString();
}

function validLimit(value) {
  return Number.isFinite(value) && value > 0 ? value : null;
}

async function readEstimatedSpend({ userID = null } = {}) {
  const supabase = getSupabaseClient();
  if (!supabase) return 0;

  const cacheKey = `${userID || "global"}:${utcDayStartIso()}`;
  const cached = budgetCache.get(cacheKey);
  if (cached && Date.now() - cached.checkedAt < BUDGET_CACHE_TTL_MS) {
    return cached.spend;
  }

  let query = supabase
    .from("ai_call_logs")
    .select("estimated_cost_usd")
    .gte("created_at", utcDayStartIso())
    .eq("status", "succeeded")
    .not("estimated_cost_usd", "is", null)
    .limit(10000);

  if (userID) {
    query = query.eq("user_id", userID);
  }

  const { data, error } = await query;
  if (error) {
    if (BUDGET_FAIL_CLOSED) throw error;
    return 0;
  }

  const spend = (data ?? []).reduce((sum, row) => sum + Number(row.estimated_cost_usd ?? 0), 0);
  budgetCache.set(cacheKey, { checkedAt: Date.now(), spend });
  return spend;
}

async function assertAIBudgetAvailable() {
  const globalLimit = validLimit(GLOBAL_DAILY_SPEND_LIMIT_USD);
  const userLimit = validLimit(USER_DAILY_SPEND_LIMIT_USD);
  if (!globalLimit && !userLimit) return;

  const context = currentContext();
  const userID = normalizeText(context.user_id ?? context.userID, 120);

  if (globalLimit) {
    const globalSpend = await readEstimatedSpend();
    if (globalSpend >= globalLimit) {
      const error = new Error(`OpenAI daily spend gate reached: $${globalSpend.toFixed(2)} >= $${globalLimit.toFixed(2)}.`);
      error.code = "OUNJE_AI_BUDGET_GATE";
      throw error;
    }
  }

  if (userLimit && userID) {
    const userSpend = await readEstimatedSpend({ userID });
    if (userSpend >= userLimit) {
      const error = new Error(`OpenAI user daily spend gate reached: $${userSpend.toFixed(2)} >= $${userLimit.toFixed(2)}.`);
      error.code = "OUNJE_AI_USER_BUDGET_GATE";
      throw error;
    }
  }
}

function buildLogRow({
  apiType,
  service,
  requestPayload,
  response = null,
  status,
  durationMS,
  error = null,
}) {
  const context = currentContext();
  const usage = extractUsage(response);
  const model = extractModel(response, requestPayload);
  const promptLikePayload = requestPayload?.messages
    ?? requestPayload?.input
    ?? requestPayload?.prompt
    ?? requestPayload?.file
    ?? null;
  const outputPayload = response?.choices
    ?? response?.output
    ?? response?.data
    ?? response?.text
    ?? null;

  return {
    environment: normalizeText(process.env.RENDER_SERVICE_NAME ?? NODE_ENV, 80),
    service: normalizeText(context.service ?? service, 120),
    route: normalizeText(context.route, 180),
    method: normalizeText(context.method, 12),
    operation: normalizeText(context.operation, 160) ?? `openai.${apiType}`,
    provider: "openai",
    api_type: normalizeText(apiType, 80),
    status,
    user_id: normalizeText(context.user_id ?? context.userID, 120),
    job_id: normalizeText(context.job_id ?? context.jobID, 160),
    request_id: normalizeText(context.request_id ?? context.requestID, 160),
    model,
    duration_ms: Number.isFinite(durationMS) ? Math.max(0, Math.round(durationMS)) : null,
    input_tokens: usage.inputTokens,
    output_tokens: usage.outputTokens,
    total_tokens: usage.totalTokens,
    estimated_cost_usd: estimateCostUSD(model, usage.inputTokens, usage.outputTokens),
    input_bytes: byteLength(promptLikePayload) || null,
    output_bytes: byteLength(outputPayload) || null,
    prompt_hash: hashInput(promptLikePayload),
    metadata: {
      ...(context.metadata && typeof context.metadata === "object" ? context.metadata : {}),
      request_model: normalizeText(requestPayload?.model, 120),
      response_id: normalizeText(response?.id, 120),
    },
    error_message: error ? normalizeText(error.message ?? error, 500) : null,
  };
}

function patchCreateMethod(target, methodName, apiType, service) {
  if (!target || typeof target[methodName] !== "function") return;
  const original = target[methodName].bind(target);
  target[methodName] = async (...args) => {
    const requestPayload = args[0] ?? {};
    const startedAt = Date.now();
    try {
      await assertAIBudgetAvailable();
      const response = await original(...args);
      void recordAICall(buildLogRow({
        apiType,
        service,
        requestPayload,
        response,
        status: "succeeded",
        durationMS: Date.now() - startedAt,
      }));
      return response;
    } catch (error) {
      void recordAICall(buildLogRow({
        apiType,
        service,
        requestPayload,
        status: "failed",
        durationMS: Date.now() - startedAt,
        error,
      }));
      throw error;
    }
  };
}

export function createLoggedOpenAI({ apiKey, service = "server" } = {}) {
  const client = new OpenAI({ apiKey });
  patchCreateMethod(client.chat?.completions, "create", "chat.completions", service);
  patchCreateMethod(client.embeddings, "create", "embeddings", service);
  patchCreateMethod(client.responses, "create", "responses", service);
  patchCreateMethod(client.images, "edit", "images.edit", service);
  patchCreateMethod(client.audio?.transcriptions, "create", "audio.transcriptions", service);
  return client;
}

export function isOpenAIQuotaError(error) {
  const status = Number(error?.status ?? error?.code ?? 0);
  const message = String(error?.message ?? "").toLowerCase();
  return status === 429 || message.includes("quota") || message.includes("rate limit");
}
