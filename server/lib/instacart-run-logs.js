import { createClient } from "@supabase/supabase-js";
import { broadcastUserInvalidation } from "./realtime-invalidation.js";
import { invalidateUserBootstrapCache } from "./user-bootstrap-cache.js";

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const INSTACART_RUN_LOGS_TABLE = "instacart_run_logs";
const INSTACART_RUN_LOG_TRACES_TABLE = "instacart_run_log_traces";

function normalizeText(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function isLikelyStoreName(storeName) {
  const trimmed = String(storeName ?? "").trim();
  if (!trimmed) return null;

  const lower = trimmed.toLowerCase();
  const allowlistedHints = [
    "metro",
    "no frills",
    "freshco",
    "food basics",
    "sobeys",
    "loblaws",
    "walmart",
    "costco",
    "real canadian superstore",
    "shoppers drug mart",
    "giant tiger",
    "adonis",
    "save on foods",
    "whole foods market",
  ];
  if (allowlistedHints.includes(lower)) {
    return trimmed;
  }

  const storeishTerms = [
    "store",
    "market",
    "mart",
    "grocery",
    "grocer",
    "grocers",
    "foods",
    "superstore",
    "supermarket",
    "drug",
    "pharmacy",
    "wholesale",
    "express",
    "centre",
    "center",
  ];
  if (storeishTerms.some((term) => lower.includes(term))) {
    return trimmed;
  }

  const productishTerms = [
    "all purpose flour",
    "flour",
    "garlic",
    "onion",
    "chicken",
    "beef",
    "pork",
    "shrimp",
    "salmon",
    "tuna",
    "bread",
    "oil",
    "sauce",
    "salt",
    "pepper",
    "sugar",
    "honey",
    "rice",
    "pasta",
    "miso",
    "juice",
    "stock",
    "broth",
    "butter",
    "milk",
    "cheese",
    "cream",
    "yogurt",
    "lettuce",
    "cilantro",
    "parsley",
    "basil",
    "ginger",
    "cucumber",
    "potato",
    "tomato",
    "jalapeno",
    "chili",
    "paprika",
    "seasoning",
    "spice",
    "vanilla",
    "cinnamon",
  ];
  if (productishTerms.some((term) => lower.includes(term))) {
    return null;
  }

  if (["true", "false", "null", "none", "undefined"].includes(lower)) {
    return null;
  }

  if (lower.startsWith("delivery by") || lower.startsWith("pickup by") || lower.startsWith("current price") || lower.startsWith("add ")) {
    return null;
  }

  return /\p{L}/u.test(trimmed) ? trimmed : null;
}

function parseInteger(value, fallback, { min = Number.NEGATIVE_INFINITY, max = Number.POSITIVE_INFINITY } = {}) {
  const parsed = Number.parseInt(String(value ?? "").trim(), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(Math.max(parsed, min), max);
}

function safeDate(value) {
  const date = value ? new Date(value) : null;
  return date && !Number.isNaN(date.getTime()) ? date : null;
}

function createSupabaseClient(accessToken = null, userID = null, { admin = false } = {}) {
  if (!SUPABASE_URL) return null;

  const key = admin
    ? SUPABASE_SERVICE_ROLE_KEY || SUPABASE_ANON_KEY
    : accessToken
      ? SUPABASE_ANON_KEY || SUPABASE_SERVICE_ROLE_KEY
      : SUPABASE_SERVICE_ROLE_KEY || SUPABASE_ANON_KEY;
  if (!key) return null;

  const headers = {};
  if (accessToken && !admin) {
    headers.Authorization = `Bearer ${accessToken}`;
  }
  const normalizedUserID = String(userID ?? "").trim();
  if (normalizedUserID) {
    headers["x-user-id"] = normalizedUserID;
  }

  const options = Object.keys(headers).length > 0
    ? {
        global: {
          headers,
        },
      }
    : undefined;

  return createClient(SUPABASE_URL, key, options);
}

export async function resolveAuthenticatedUserID(accessToken = null) {
  const token = String(accessToken ?? "").trim();
  if (!token) return null;

  const client = createSupabaseClient(token);
  if (!client?.auth?.getUser) return null;

  const { data, error } = await client.auth.getUser(token);
  if (error) {
    throw error;
  }

  return data?.user?.id ?? null;
}

function statusKind(trace) {
  if (!trace?.completedAt) return "running";
  if (trace?.success) return "completed";
  if (trace?.partialSuccess) return "partial";
  return "failed";
}

function isMissingRelationError(error) {
  const code = String(error?.code ?? "").trim();
  if (code === "42P01") return true;
  const message = String(error?.message ?? error?.details ?? "").toLowerCase();
  return message.includes("does not exist")
    || (message.includes("relation") && message.includes("does not exist"))
    || (message.includes("schema cache") && message.includes("could not find the table"));
}

function itemStatus(item) {
  return normalizeText(item?.finalStatus?.status ?? item?.finalStatus?.decision ?? "");
}

function summarizeItems(items = []) {
  let resolvedCount = 0;
  let unresolvedCount = 0;
  let shortfallCount = 0;
  let attemptCount = 0;
  let firstIssue = null;

  for (const item of items) {
    const status = itemStatus(item);
    const quantityAdded = Number(item?.finalStatus?.quantityAdded ?? 0);
    const shortfall = Number(item?.finalStatus?.shortfall ?? 0);
    const attempts = Array.isArray(item?.attempts) ? item.attempts.length : 0;
    attemptCount += attempts;

    const isResolved = ["exact", "substituted", "saved", "done", "completed"].includes(status) || quantityAdded > 0;
    const isUnresolved = ["unresolved", "failed", "error", "cancelled", "missing"].includes(status) || quantityAdded <= 0;

    if (isResolved) resolvedCount += 1;
    if (isUnresolved) unresolvedCount += 1;
    if (shortfall > 0) shortfallCount += shortfall;

    if (!firstIssue && (isUnresolved || shortfall > 0)) {
      const requested = String(item?.requested ?? item?.canonicalName ?? "item").trim();
      const finalStatus = String(item?.finalStatus?.status ?? "").trim();
      const reason = String(item?.attempts?.[0]?.reason ?? "").trim();
      firstIssue = [requested, finalStatus || null, reason || null].filter(Boolean).join(" • ");
    }
  }

  return {
    resolvedCount,
    unresolvedCount,
    shortfallCount,
    attemptCount,
    firstIssue,
  };
}

function collectMatches(rawText, query, limit = 5) {
  const normalizedQuery = normalizeText(query);
  if (!normalizedQuery) return [];

  const lines = String(rawText ?? "").split(/\r?\n/);
  const queryTokens = normalizedQuery.split(" ").filter(Boolean);
  const matches = [];
  const seen = new Set();

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const normalizedLine = normalizeText(line);
    if (!normalizedLine) continue;

    const exactHit = normalizedLine.includes(normalizedQuery);
    const tokenHit = queryTokens.length > 0 && queryTokens.every((token) => normalizedLine.includes(token));
    if (!exactHit && !tokenHit) continue;

    const start = Math.max(0, index - 1);
    const end = Math.min(lines.length, index + 2);
    const snippet = lines.slice(start, end).map((entry) => entry.trim()).filter(Boolean).join("  ");
    if (!snippet || seen.has(snippet)) continue;

    seen.add(snippet);
    matches.push(snippet);
    if (matches.length >= limit) break;
  }

  return matches;
}

function summarizeTrace(trace, rawText, { query = "" } = {}) {
  const items = Array.isArray(trace?.items) ? trace.items : [];
  const finalizer = trace?.finalizer ?? null;
  const warden = trace?.warden ?? null;
  const {
    resolvedCount,
    unresolvedCount,
    shortfallCount,
    attemptCount,
    firstIssue,
  } = summarizeItems(items);

  const plannedItemCount = Number(trace?.cartSummary?.totalItems ?? items.length);
  const totalItems = Number.isFinite(plannedItemCount) && plannedItemCount > 0
    ? plannedItemCount
    : items.length;
  const completionProgress = totalItems > 0 ? resolvedCount / totalItems : 0;
  const matches = collectMatches(rawText, query);
  const selectedStore = isLikelyStoreName(trace?.selectedStore) ?? isLikelyStoreName(trace?.preferredStore);
  const preferredStore = isLikelyStoreName(trace?.preferredStore);
  const strictStore = isLikelyStoreName(trace?.strictStore);
  const selectedStoreLogoURL = String(trace?.selectedStoreLogoURL ?? "").trim() || null;
  const selectedStoreReason = String(trace?.selectedStoreReason ?? "").trim() || null;
  const latestEvent = trace?.latestEvent && typeof trace.latestEvent === "object" ? trace.latestEvent : null;
  const latestEventKind = String(latestEvent?.kind ?? "").trim() || null;
  const latestEventTitle = String(latestEvent?.title ?? "").trim() || null;
  const latestEventBody = String(latestEvent?.body ?? "").trim() || null;
  const latestEventAt = String(trace?.latestEventAt ?? latestEvent?.at ?? "").trim() || null;
  const shoppingPreview = items
    .map((item) => {
      const label = String(item?.requested ?? item?.canonicalName ?? item?.normalizedQuery ?? "").trim();
      if (!label) return null;

      const status = String(item?.finalStatus?.status ?? item?.finalStatus?.decision ?? "").trim().toLowerCase();
      if (!status) return label;
      if (["exact", "substituted", "saved", "done", "completed"].includes(status)) {
        return label;
      }
      if (["unresolved", "failed", "error", "cancelled", "missing"].includes(status)) {
        return `${label} (needs attention)`;
      }
      return `${label} (shopping)`;
    })
    .filter(Boolean)
    .slice(0, 3);
  const startedAt = safeDate(trace?.startedAt);
  const completedAt = safeDate(trace?.completedAt);
  const durationSeconds = startedAt && completedAt
    ? Math.max(0, Math.round((completedAt.getTime() - startedAt.getTime()) / 1000))
    : null;
  const finalizerIssueCount = summarizeArrayCount(finalizer?.missingItems)
    + summarizeArrayCount(finalizer?.mismatchedItems)
    + summarizeArrayCount(finalizer?.extraItems)
    + summarizeArrayCount(finalizer?.duplicateItems)
    + summarizeArrayCount(finalizer?.unresolvedItems);

  return {
    runId: String(trace?.runId ?? "").trim(),
    userId: String(trace?.userId ?? "").trim() || null,
    startedAt: trace?.startedAt ?? null,
    completedAt: trace?.completedAt ?? null,
    selectedStore,
    selectedStoreLogoURL,
    selectedStoreReason,
    latestEventKind,
    latestEventTitle,
    latestEventBody,
    latestEventAt,
    shoppingPreview,
    preferredStore,
    strictStore,
    sessionSource: String(trace?.sessionSource ?? "").trim() || null,
    mealPlanID: String(trace?.mealPlanID ?? "").trim() || null,
    groceryOrderID: String(trace?.groceryOrderID ?? "").trim() || null,
    runKind: String(trace?.runKind ?? "").trim() || "primary",
    rootRunID: String(trace?.rootRunID ?? "").trim() || null,
    retryAttempt: Number.isFinite(Number(trace?.retryAttempt)) ? Number(trace.retryAttempt) : null,
    retryState: String(trace?.retryState ?? "").trim() || null,
    retryQueuedAt: String(trace?.retryQueuedAt ?? "").trim() || null,
    retryStartedAt: String(trace?.retryStartedAt ?? "").trim() || null,
    retryCompletedAt: String(trace?.retryCompletedAt ?? "").trim() || null,
    retryRunID: String(trace?.retryRunID ?? "").trim() || null,
    retryItemCount: Number.isFinite(Number(trace?.retryItemCount)) ? Number(trace.retryItemCount) : null,
    success: Boolean(trace?.success),
    partialSuccess: Boolean(trace?.partialSuccess),
    statusKind: statusKind(trace),
    itemCount: totalItems,
    resolvedCount,
    unresolvedCount,
    shortfallCount,
    attemptCount,
    durationSeconds,
    progress: Number.isFinite(completionProgress) ? Number(completionProgress.toFixed(3)) : 0,
    topIssue: firstIssue,
    finalizerStatus: String(finalizer?.status ?? "").trim() || null,
    finalizerSummary: String(finalizer?.summary ?? "").trim() || null,
    finalizerTopIssue: String(finalizer?.topIssue ?? "").trim() || null,
    finalizerIssueCount,
    wardenStatus: String(warden?.status ?? "").trim() || null,
    wardenSummary: String(warden?.overallSummary ?? "").trim() || null,
    wardenMappingScore: Number.isFinite(Number(warden?.mappingScore)) ? Number(warden?.mappingScore) : null,
    wardenRetryRecommendation: String(warden?.retryRecommendation ?? "").trim() || null,
    cartResetCleared: Boolean(trace?.cartReset?.cleared),
    cartResetBeforeCount: Number.isFinite(Number(trace?.cartReset?.beforeCount)) ? Number(trace?.cartReset?.beforeCount) : null,
    cartResetAfterCount: Number.isFinite(Number(trace?.cartReset?.afterCount)) ? Number(trace?.cartReset?.afterCount) : null,
    cartResetError: String(trace?.cartReset?.error ?? "").trim() || null,
    searchPreview: matches[0] ?? firstIssue ?? null,
    matches,
    shoppingPreview,
    cartUrl: String(trace?.cartUrl ?? "").trim() || null,
  };
}

function summarizeArrayCount(value) {
  return Array.isArray(value) ? value.length : 0;
}

function buildRunSearchText(trace, rawText) {
  const segments = [
    trace?.runId,
    trace?.userId,
    trace?.mealPlanID,
    trace?.selectedStore,
    trace?.preferredStore,
    trace?.strictStore,
    trace?.sessionSource,
    trace?.cartUrl,
    trace?.error,
    trace?.topIssue,
    trace?.cartReset?.error,
    trace?.finalizer?.status,
    trace?.finalizer?.summary,
    trace?.finalizer?.topIssue,
    trace?.finalizer?.nextAction,
    trace?.warden?.status,
    trace?.warden?.overallSummary,
    trace?.warden?.retryRecommendation,
    rawText,
  ];

  for (const item of Array.isArray(trace?.items) ? trace.items : []) {
    segments.push(item?.requested, item?.canonicalName, item?.normalizedQuery);
    segments.push(item?.finalStatus?.status, item?.finalStatus?.decision, item?.finalStatus?.reason);
    for (const attempt of Array.isArray(item?.attempts) ? item.attempts : []) {
      segments.push(attempt?.store, attempt?.query, attempt?.matchedLabel, attempt?.decision, attempt?.matchType, attempt?.reason);
    }
  }

  for (const item of Array.isArray(trace?.finalizer?.missingItems) ? trace.finalizer.missingItems : []) {
    segments.push(item?.name, item?.issue, item?.reason, item?.severity);
  }
  for (const item of Array.isArray(trace?.finalizer?.mismatchedItems) ? trace.finalizer.mismatchedItems : []) {
    segments.push(item?.name, item?.issue, item?.reason, item?.severity, item?.expected, item?.observed);
  }
  for (const item of Array.isArray(trace?.finalizer?.extraItems) ? trace.finalizer.extraItems : []) {
    segments.push(item?.name, item?.reason, item?.severity);
  }
  for (const item of Array.isArray(trace?.finalizer?.duplicateItems) ? trace.finalizer.duplicateItems : []) {
    segments.push(item?.name, item?.reason, item?.severity);
  }
  for (const item of Array.isArray(trace?.finalizer?.unresolvedItems) ? trace.finalizer.unresolvedItems : []) {
    segments.push(item?.name, item?.reason, item?.severity);
  }
  for (const item of Array.isArray(trace?.finalizer?.outOfStockItems) ? trace.finalizer.outOfStockItems : []) {
    segments.push(item?.name, item?.reason, item?.severity);
  }

  segments.push(
    trace?.cartReset?.beforeCount,
    trace?.cartReset?.afterCount,
    trace?.cartReset?.cleared ? "cart_reset_cleared" : "cart_reset_pending",
  );

  return segments
    .map((value) => String(value ?? "").trim())
    .filter(Boolean)
    .join("\n");
}

function summarizeStoredRow(row, { query = "" } = {}) {
  const summary = row?.summary_json ?? {};
  const normalizedQuery = String(query ?? "").trim();
  const rawText = normalizedQuery ? String(row?.search_text ?? "").trim() : "";
  const matches = normalizedQuery ? collectMatches(rawText, normalizedQuery) : [];
  return {
    ...summary,
    runId: String(row?.run_id ?? summary?.runId ?? "").trim(),
    userId: String(row?.user_id ?? summary?.userId ?? "").trim() || null,
    startedAt: summary?.startedAt ?? null,
    completedAt: summary?.completedAt ?? null,
    selectedStore: isLikelyStoreName(summary?.selectedStore) ?? isLikelyStoreName(summary?.preferredStore),
    selectedStoreLogoURL: String(summary?.selectedStoreLogoURL ?? "").trim() || null,
    selectedStoreReason: String(summary?.selectedStoreReason ?? "").trim() || null,
    latestEventKind: String(summary?.latestEventKind ?? "").trim() || null,
    latestEventTitle: String(summary?.latestEventTitle ?? "").trim() || null,
    latestEventBody: String(summary?.latestEventBody ?? "").trim() || null,
    latestEventAt: String(summary?.latestEventAt ?? "").trim() || null,
    preferredStore: isLikelyStoreName(summary?.preferredStore),
    strictStore: isLikelyStoreName(summary?.strictStore),
    sessionSource: summary?.sessionSource ?? null,
    mealPlanID: summary?.mealPlanID ?? null,
    groceryOrderID: String(summary?.groceryOrderID ?? "").trim() || null,
    runKind: String(summary?.runKind ?? "").trim() || "primary",
    rootRunID: String(summary?.rootRunID ?? "").trim() || null,
    retryAttempt: Number.isFinite(Number(summary?.retryAttempt)) ? Number(summary.retryAttempt) : null,
    retryState: String(summary?.retryState ?? "").trim() || null,
    retryQueuedAt: String(summary?.retryQueuedAt ?? "").trim() || null,
    retryStartedAt: String(summary?.retryStartedAt ?? "").trim() || null,
    retryCompletedAt: String(summary?.retryCompletedAt ?? "").trim() || null,
    retryRunID: String(summary?.retryRunID ?? "").trim() || null,
    retryItemCount: Number.isFinite(Number(summary?.retryItemCount)) ? Number(summary.retryItemCount) : null,
    success: Boolean(summary?.success),
    partialSuccess: Boolean(summary?.partialSuccess),
    statusKind: String(summary?.statusKind ?? row?.status_kind ?? "failed"),
    itemCount: Number(summary?.itemCount ?? 0),
    resolvedCount: Number(summary?.resolvedCount ?? 0),
    unresolvedCount: Number(summary?.unresolvedCount ?? 0),
    shortfallCount: Number(summary?.shortfallCount ?? 0),
    attemptCount: Number(summary?.attemptCount ?? 0),
    durationSeconds: summary?.durationSeconds ?? null,
    progress: Number.isFinite(Number(summary?.progress)) ? Number(summary?.progress) : Number(row?.progress ?? 0),
    topIssue: summary?.topIssue ?? null,
    searchPreview: matches[0] ?? summary?.searchPreview ?? summary?.topIssue ?? null,
    matches,
    cartUrl: summary?.cartUrl ?? null,
  };
}

function buildRunLogRecord(trace) {
  const rawText = JSON.stringify(trace, null, 2);
  const summary = summarizeTrace(trace, rawText, { query: "" });
  return {
    run_id: summary.runId,
    user_id: summary.userId,
    status_kind: summary.statusKind,
    success: summary.success,
    partial_success: summary.partialSuccess,
    started_at: summary.startedAt,
    completed_at: summary.completedAt,
    selected_store: summary.selectedStore,
    preferred_store: summary.preferredStore,
    strict_store: summary.strictStore,
    session_source: summary.sessionSource,
    item_count: summary.itemCount,
    resolved_count: summary.resolvedCount,
    unresolved_count: summary.unresolvedCount,
    shortfall_count: summary.shortfallCount,
    attempt_count: summary.attemptCount,
    duration_seconds: summary.durationSeconds,
    progress: summary.progress ?? 0,
    top_issue: summary.topIssue,
    search_preview: summary.searchPreview,
    matches: Array.isArray(summary.matches) ? summary.matches : [],
    shopping_preview: Array.isArray(summary.shoppingPreview) ? summary.shoppingPreview : [],
    cart_url: summary.cartUrl,
    summary_json: {
      ...summary,
      matches: [],
    },
    trace_json: {},
    search_text: buildRunSearchText(trace, rawText),
  };
}

function buildRunTraceRecord(trace) {
  if (!trace?.runId || !trace?.userId) {
    return null;
  }

  return {
    run_id: String(trace.runId).trim(),
    user_id: String(trace.userId).trim(),
    trace_json: trace,
  };
}

async function persistInstacartRunLog(trace, { accessToken = null } = {}) {
  if (!trace?.runId || !trace?.userId) {
    return null;
  }

  const record = buildRunLogRecord(trace);
  const traceRecord = buildRunTraceRecord(trace);
  const client = createSupabaseClient(accessToken, record.user_id, { admin: true });
  if (!client) {
    throw new Error("Instacart run log persistence is unavailable (missing SUPABASE_URL or Supabase API key in environment)");
  }

  if (accessToken) {
    let authenticatedUserID = null;
    try {
      authenticatedUserID = await resolveAuthenticatedUserID(accessToken);
    } catch {
      authenticatedUserID = null;
    }

    if (authenticatedUserID && authenticatedUserID !== record.user_id) {
      throw new Error("Authenticated user does not match Instacart run log owner");
    }
  }

  const { error } = await client
    .from(INSTACART_RUN_LOGS_TABLE)
    .upsert(record, { onConflict: "run_id" });

  if (error) {
    throw error;
  }

  if (traceRecord) {
    const traceWrite = await client
      .from(INSTACART_RUN_LOG_TRACES_TABLE)
      .upsert(traceRecord, { onConflict: "run_id" });

    if (traceWrite?.error) {
      if (!isMissingRelationError(traceWrite.error)) {
        throw traceWrite.error;
      }

      const legacyTraceWrite = await client
        .from(INSTACART_RUN_LOGS_TABLE)
        .update({ trace_json: traceRecord.trace_json })
        .eq("run_id", traceRecord.run_id);

      if (legacyTraceWrite?.error && !isMissingRelationError(legacyTraceWrite.error)) {
        throw legacyTraceWrite.error;
      }
    }
  }

  await broadcastUserInvalidation(record.user_id, "instacart_run.updated", {
    run_id: record.run_id,
    status_kind: record.status_kind,
    progress: record.progress ?? null,
    meal_plan_id: trace?.mealPlanId ?? trace?.meal_plan_id ?? null,
    grocery_order_id: trace?.groceryOrderID ?? trace?.grocery_order_id ?? null,
  });
  invalidateUserBootstrapCache(record.user_id);

  return record.run_id;
}

export async function listInstacartRunLogs({ userID = null, accessToken = null, status = "all", query = "", limit = 24, offset = 0, includeCount = false } = {}) {
  const normalizedUserID = String(userID ?? "").trim();
  const normalizedStatus = normalizeText(status);
  const normalizedQuery = String(query ?? "").trim();
  const safeLimit = parseInteger(limit, 24, { min: 1, max: 100 });
  const safeOffset = parseInteger(offset, 0, { min: 0, max: 100_000 });
  const resolvedUserID = !normalizedUserID && accessToken ? await resolveAuthenticatedUserID(accessToken).catch(() => null) : null;
  const effectiveUserID = normalizedUserID || resolvedUserID;

  const storedRows = await listStoredInstacartRunLogs({
    userID: effectiveUserID,
    accessToken,
    status: normalizedStatus,
    query: normalizedQuery,
    limit: safeLimit,
    offset: safeOffset,
    includeCount,
  });
  if (!storedRows) {
    throw new Error("Unable to read Instacart run logs from Supabase");
  }

  return {
    ...storedRows,
    userID: storedRows.userID ?? effectiveUserID ?? null,
  };
}

async function listStoredInstacartRunLogs({ userID = null, accessToken = null, status = "all", query = "", limit = 24, offset = 0, includeCount = false } = {}) {
  const normalizedUserID = String(userID ?? "").trim();
  const normalizedStatus = normalizeText(status);
  const normalizedQuery = String(query ?? "").trim();
  const safeLimit = parseInteger(limit, 24, { min: 1, max: 100 });
  const safeOffset = parseInteger(offset, 0, { min: 0, max: 100_000 });
  const authUserID = !normalizedUserID && accessToken ? await resolveAuthenticatedUserID(accessToken).catch(() => null) : null;
  const effectiveUserID = normalizedUserID || authUserID;
  const client = createSupabaseClient(normalizedUserID ? null : accessToken, effectiveUserID, { admin: true });
  if (!client) return null;

  const selectColumns = normalizedQuery
    ? "run_id,user_id,status_kind,success,partial_success,started_at,completed_at,selected_store,preferred_store,strict_store,session_source,item_count,resolved_count,unresolved_count,shortfall_count,attempt_count,duration_seconds,progress,top_issue,search_preview,matches,cart_url,summary_json,search_text"
    : "run_id,user_id,status_kind,success,partial_success,started_at,completed_at,selected_store,preferred_store,strict_store,session_source,item_count,resolved_count,unresolved_count,shortfall_count,attempt_count,duration_seconds,progress,top_issue,search_preview,matches,cart_url,summary_json";

  const table = client
    .from(INSTACART_RUN_LOGS_TABLE);
  let builder = (includeCount ? table.select(selectColumns, { count: "exact" }) : table.select(selectColumns))
    .order("completed_at", { ascending: false, nullsFirst: true })
    .order("started_at", { ascending: false, nullsFirst: false });

  if (effectiveUserID) {
    builder = builder.eq("user_id", effectiveUserID);
  }
  if (normalizedStatus === "current") {
    builder = builder.in("status_kind", ["running", "queued", "completed", "partial"]);
  } else if (normalizedStatus === "historic") {
    builder = builder.in("status_kind", ["completed", "partial", "failed"]);
  } else if (normalizedStatus === "partial") {
    builder = builder.in("status_kind", ["partial", "running"]);
  } else if (normalizedStatus !== "all") {
    builder = builder.eq("status_kind", normalizedStatus);
  }
  if (normalizedQuery) {
    builder = builder.ilike("search_text", `%${normalizedQuery}%`);
  }

  const { data, count, error } = await builder.range(safeOffset, safeOffset + safeLimit - 1);
  if (error) {
    throw error;
  }

  if (!Array.isArray(data)) {
    return null;
  }

  const items = data.map((row) => summarizeStoredRow(row, { query: normalizedQuery }));
  const inferredTotal = safeOffset + items.length + (items.length === safeLimit ? 1 : 0);
  return {
    items,
    total: Number.isFinite(Number(count)) ? Number(count) : inferredTotal,
    offset: safeOffset,
    limit: safeLimit,
    hasMore: Number.isFinite(Number(count))
      ? safeOffset + safeLimit < Number(count)
      : data.length === safeLimit,
    userID: effectiveUserID || null,
  };
}

export async function getCurrentInstacartRunLogSummary({ userID = null, accessToken = null, mealPlanID = null } = {}) {
  const normalizedUserID = String(userID ?? "").trim();
  const authUserID = !normalizedUserID && accessToken ? await resolveAuthenticatedUserID(accessToken).catch(() => null) : null;
  const effectiveUserID = normalizedUserID || authUserID;
  const normalizedMealPlanID = String(mealPlanID ?? "").trim().toLowerCase();
  if (!effectiveUserID) return null;
  const client = createSupabaseClient(normalizedUserID ? null : accessToken, effectiveUserID, { admin: true });
  if (!client) return null;

  const { data, error } = await client
    .from(INSTACART_RUN_LOGS_TABLE)
    .select("run_id,user_id,status_kind,success,partial_success,started_at,completed_at,selected_store,preferred_store,strict_store,session_source,item_count,resolved_count,unresolved_count,shortfall_count,attempt_count,duration_seconds,progress,top_issue,search_preview,matches,cart_url,summary_json")
    .order("completed_at", { ascending: false, nullsFirst: true })
    .order("started_at", { ascending: false, nullsFirst: false })
    .in("status_kind", ["running", "queued", "completed", "partial"])
    .eq("user_id", effectiveUserID)
    .limit(normalizedMealPlanID ? 10 : 6);

  if (error) {
    throw error;
  }
  if (!Array.isArray(data) || data.length === 0) {
    return null;
  }

  const summaries = data
    .map((row) => summarizeStoredRow(row))
    .filter((summary) => {
      const title = String(summary?.latestEventTitle ?? "").trim().toLowerCase();
      const kind = String(summary?.latestEventKind ?? "").trim().toLowerCase();
      return summary?.statusKind !== "superseded"
        && kind !== "run_superseded"
        && title !== "run superseded";
    });

  if (normalizedMealPlanID) {
    const planMatch = summaries.find((summary) => String(summary?.mealPlanID ?? "").trim().toLowerCase() === normalizedMealPlanID);
    if (planMatch) return planMatch;
  }

  return summaries[0] ?? null;
}

export async function getInstacartRunLog(runId, { userID = null, accessToken = null } = {}) {
  const [summary, trace] = await Promise.all([
    getInstacartRunLogSummary(runId, { userID, accessToken }),
    getInstacartRunLogTrace(runId, { userID, accessToken }),
  ]);
  if (!summary && !trace) {
    return null;
  }
  return {
    summary,
    trace,
  };
}

export async function getInstacartRunLogSummary(runId, { userID = null, accessToken = null } = {}) {
  const normalizedRunID = String(runId ?? "").trim();
  if (!normalizedRunID) {
    return null;
  }
  const normalizedUserID = String(userID ?? "").trim();
  const resolvedUserID = !normalizedUserID && accessToken ? await resolveAuthenticatedUserID(accessToken).catch(() => null) : null;
  const effectiveUserID = normalizedUserID || resolvedUserID;

  const client = createSupabaseClient(normalizedUserID ? null : accessToken, effectiveUserID, { admin: true });
  if (!client) {
    throw new Error("Unable to read Instacart run log from Supabase");
  }

  const { data, error } = await client
    .from(INSTACART_RUN_LOGS_TABLE)
    .select("run_id,user_id,summary_json")
    .eq("run_id", normalizedRunID)
    .maybeSingle();

  if (error) {
    throw error;
  }

  if (!data) {
    return null;
  }

  if (effectiveUserID && String(data.user_id ?? "").trim() !== effectiveUserID) {
    return null;
  }

  return {
    ...summarizeStoredRow({
      run_id: data.run_id,
      user_id: data.user_id,
      summary_json: data.summary_json,
    }),
  };
}

export async function getInstacartRunLogTrace(runId, { userID = null, accessToken = null } = {}) {
  const normalizedRunID = String(runId ?? "").trim();
  if (!normalizedRunID) {
    return null;
  }
  const normalizedUserID = String(userID ?? "").trim();
  const resolvedUserID = !normalizedUserID && accessToken ? await resolveAuthenticatedUserID(accessToken).catch(() => null) : null;
  const effectiveUserID = normalizedUserID || resolvedUserID;

  const client = createSupabaseClient(normalizedUserID ? null : accessToken, effectiveUserID, { admin: true });
  if (!client) {
    throw new Error("Unable to read Instacart run trace from Supabase");
  }

  const traceTableResult = await client
    .from(INSTACART_RUN_LOG_TRACES_TABLE)
    .select("run_id,user_id,trace_json")
    .eq("run_id", normalizedRunID)
    .maybeSingle();

  if (traceTableResult.error && !isMissingRelationError(traceTableResult.error)) {
    throw traceTableResult.error;
  }

  if (traceTableResult.data) {
    if (effectiveUserID && String(traceTableResult.data.user_id ?? "").trim() !== effectiveUserID) {
      return null;
    }

    return {
      runId: String(traceTableResult.data.run_id ?? normalizedRunID).trim(),
      userId: String(traceTableResult.data.user_id ?? "").trim() || null,
      trace: traceTableResult.data.trace_json ?? {},
    };
  }

  const legacyResult = await client
    .from(INSTACART_RUN_LOGS_TABLE)
    .select("run_id,user_id,trace_json")
    .eq("run_id", normalizedRunID)
    .maybeSingle();

  if (legacyResult.error) {
    throw legacyResult.error;
  }

  if (!legacyResult.data) {
    return null;
  }

  if (effectiveUserID && String(legacyResult.data.user_id ?? "").trim() !== effectiveUserID) {
    return null;
  }

  return {
    runId: String(legacyResult.data.run_id ?? normalizedRunID).trim(),
    userId: String(legacyResult.data.user_id ?? "").trim() || null,
    trace: legacyResult.data.trace_json ?? {},
  };
}

export { persistInstacartRunLog };
