import { createClient } from "@supabase/supabase-js";
import { broadcastUserInvalidation } from "./realtime-invalidation.js";

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const AUTOMATION_JOBS_TABLE = "automation_jobs";

function getServiceSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Automation jobs require SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY");
  }
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

function normalizeText(value) {
  return String(value ?? "").trim();
}

function normalizeUUID(value) {
  const normalized = normalizeText(value);
  return normalized || null;
}

function normalizeJob(row) {
  if (!row) return null;
  return {
    id: row.id,
    userID: row.user_id,
    kind: row.kind,
    status: row.status,
    payload: row.payload ?? {},
    result: row.result ?? {},
    attemptCount: Number(row.attempt_count ?? 0),
    maxAttempts: Number(row.max_attempts ?? 0),
    lockedBy: row.locked_by ?? null,
    lockedUntil: row.locked_until ?? null,
    startedAt: row.started_at ?? null,
    completedAt: row.completed_at ?? null,
    errorMessage: row.error_message ?? null,
    runID: row.run_id ?? null,
    groceryOrderID: row.grocery_order_id ?? null,
    createdAt: row.created_at ?? null,
    updatedAt: row.updated_at ?? null,
  };
}

async function emitJobUpdate(row, event = "automation_job.updated") {
  if (!row?.user_id) return;
  await broadcastUserInvalidation(row.user_id, event, {
    job_id: row.id,
    kind: row.kind,
    status: row.status,
    run_id: row.run_id ?? null,
    grocery_order_id: row.grocery_order_id ?? null,
    error_message: row.error_message ?? null,
  }).catch(() => {});
}

export async function createAutomationJob({
  userID,
  kind,
  payload = {},
  runID = null,
  groceryOrderID = null,
  maxAttempts = 3,
} = {}) {
  const normalizedUserID = normalizeUUID(userID);
  const normalizedKind = normalizeText(kind);
  if (!normalizedUserID) throw new Error("automation job userID is required");
  if (!normalizedKind) throw new Error("automation job kind is required");

  const supabase = getServiceSupabase();
  const { data, error } = await supabase
    .from(AUTOMATION_JOBS_TABLE)
    .insert({
      user_id: normalizedUserID,
      kind: normalizedKind,
      status: "queued",
      payload: payload && typeof payload === "object" ? payload : {},
      result: {},
      max_attempts: Math.max(1, Number.parseInt(String(maxAttempts), 10) || 3),
      run_id: normalizeText(runID) || null,
      grocery_order_id: normalizeUUID(groceryOrderID),
    })
    .select("*")
    .single();

  if (error) throw error;
  await emitJobUpdate(data, "automation_job.created");
  return normalizeJob(data);
}

export async function claimAutomationJobs({
  workerID,
  kinds = ["instacart_run"],
  batchSize = 1,
  lockSeconds = 300,
} = {}) {
  const normalizedWorkerID = normalizeText(workerID) || `automation_worker_${process.pid}`;
  const supabase = getServiceSupabase();
  const { data, error } = await supabase.rpc("claim_automation_jobs", {
    p_worker_id: normalizedWorkerID,
    p_kinds: Array.isArray(kinds) && kinds.length ? kinds : null,
    p_batch_size: Math.max(1, Number.parseInt(String(batchSize), 10) || 1),
    p_lock_seconds: Math.max(30, Number.parseInt(String(lockSeconds), 10) || 300),
  });

  if (error) throw error;
  return (Array.isArray(data) ? data : []).map(normalizeJob).filter(Boolean);
}

export async function heartbeatAutomationJob({ jobID, workerID, lockSeconds = 300 } = {}) {
  const normalizedJobID = normalizeUUID(jobID);
  if (!normalizedJobID) return null;
  const supabase = getServiceSupabase();
  const { data, error } = await supabase
    .from(AUTOMATION_JOBS_TABLE)
    .update({
      locked_by: normalizeText(workerID) || null,
      locked_until: new Date(Date.now() + Math.max(30, Number(lockSeconds) || 300) * 1000).toISOString(),
    })
    .eq("id", normalizedJobID)
    .eq("status", "running")
    .select("*")
    .maybeSingle();

  if (error) throw error;
  return normalizeJob(data);
}

export async function completeAutomationJob({ jobID, result = {} } = {}) {
  const normalizedJobID = normalizeUUID(jobID);
  if (!normalizedJobID) return null;
  const supabase = getServiceSupabase();
  const { data, error } = await supabase
    .from(AUTOMATION_JOBS_TABLE)
    .update({
      status: "succeeded",
      result: result && typeof result === "object" ? result : {},
      locked_by: null,
      locked_until: null,
      completed_at: new Date().toISOString(),
      error_message: null,
    })
    .eq("id", normalizedJobID)
    .select("*")
    .single();

  if (error) throw error;
  await emitJobUpdate(data);
  return normalizeJob(data);
}

export async function failAutomationJob({ jobID, errorMessage, result = {} } = {}) {
  const normalizedJobID = normalizeUUID(jobID);
  if (!normalizedJobID) return null;
  const supabase = getServiceSupabase();
  const { data, error } = await supabase
    .from(AUTOMATION_JOBS_TABLE)
    .update({
      status: "failed",
      result: result && typeof result === "object" ? result : {},
      locked_by: null,
      locked_until: null,
      completed_at: new Date().toISOString(),
      error_message: normalizeText(errorMessage) || "Automation job failed",
    })
    .eq("id", normalizedJobID)
    .select("*")
    .single();

  if (error) throw error;
  await emitJobUpdate(data);
  return normalizeJob(data);
}
