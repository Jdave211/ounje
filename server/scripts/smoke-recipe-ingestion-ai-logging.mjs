import { createClient } from "@supabase/supabase-js";
import {
  fetchRecipeIngestionJob,
  processRecipeIngestionJob,
  queueRecipeIngestion,
} from "../lib/recipe-ingestion.js";

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const SOURCE_URL = process.env.RECIPE_IMPORT_SMOKE_URL ?? "";
const USER_ID = process.env.RECIPE_IMPORT_SMOKE_USER_ID ?? null;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY before running this smoke test.");
}

if (!SOURCE_URL) {
  throw new Error("Set RECIPE_IMPORT_SMOKE_URL to a TikTok/IG/web recipe URL.");
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
  },
});

async function waitForAICallLogs(jobID, { timeoutMS = 20_000 } = {}) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMS) {
    const { data, error } = await supabase
      .from("ai_call_logs")
      .select("id,operation,model,status,input_tokens,output_tokens,total_tokens,estimated_cost_usd")
      .eq("job_id", jobID)
      .order("created_at", { ascending: false })
      .limit(20);

    if (error) throw error;
    if (Array.isArray(data) && data.length) return data;
    await new Promise((resolve) => setTimeout(resolve, 750));
  }
  return [];
}

const queued = await queueRecipeIngestion({
  user_id: USER_ID,
  source_url: SOURCE_URL,
  target_state: "saved",
});

const jobID = queued?.job?.id;
if (!jobID) {
  throw new Error(`Queue response did not include a job id: ${JSON.stringify(queued)}`);
}

if (queued.processing_mode !== "queued") {
  throw new Error(`Expected queued processing mode, received ${queued.processing_mode ?? "missing"}.`);
}

console.log(`[smoke] queued recipe import job=${jobID}`);
await processRecipeIngestionJob(jobID, { workerID: "smoke_recipe_ingestion_ai_logging" });

const finalJob = await fetchRecipeIngestionJob(jobID);
const status = finalJob?.job?.status ?? "unknown";
if (!["saved", "needs_review", "draft", "failed"].includes(status)) {
  throw new Error(`Unexpected final job status: ${status}`);
}

const logs = await waitForAICallLogs(jobID);
if (!logs.length) {
  throw new Error(`No ai_call_logs rows found for job ${jobID}. Check Render/local SUPABASE_SERVICE_ROLE_KEY and OUNJE_ENABLE_AI_CALL_LOGGING.`);
}

console.log(JSON.stringify({
  job_id: jobID,
  status,
  ai_call_log_count: logs.length,
  operations: [...new Set(logs.map((row) => row.operation).filter(Boolean))],
  estimated_cost_usd: logs.reduce((sum, row) => sum + Number(row.estimated_cost_usd ?? 0), 0),
}, null, 2));
