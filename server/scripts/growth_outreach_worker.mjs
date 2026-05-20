#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const DEFAULT_IDLE_SLEEP_MS = 60_000;
const DEFAULT_LOCK_SECONDS = 1_800;
const DEFAULT_BATCH_SIZE = 1;

function parseArgs(argv) {
  const args = {
    once: false,
    batchSize: DEFAULT_BATCH_SIZE,
    idleSleepMs: DEFAULT_IDLE_SLEEP_MS,
    lockSeconds: DEFAULT_LOCK_SECONDS,
    workerID: null,
    autoEnqueueUserID: null,
    autoEnqueueMode: null,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--once") args.once = true;
    else if (token === "--batch-size") args.batchSize = Math.max(1, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_BATCH_SIZE), index += 1;
    else if (token === "--idle-sleep-ms") args.idleSleepMs = Math.max(5_000, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_IDLE_SLEEP_MS), index += 1;
    else if (token === "--lock-seconds") args.lockSeconds = Math.max(60, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_LOCK_SECONDS), index += 1;
    else if (token === "--worker-id") args.workerID = String(argv[index + 1] ?? "").trim() || null, index += 1;
    else if (token === "--auto-enqueue-user-id") args.autoEnqueueUserID = String(argv[index + 1] ?? "").trim() || null, index += 1;
    else if (token === "--auto-enqueue-mode") args.autoEnqueueMode = String(argv[index + 1] ?? "").trim() || null, index += 1;
  }

  return args;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeText(value) {
  return String(value ?? "").trim();
}

function normalizeMode(value) {
  const mode = normalizeText(value).toLowerCase();
  if (mode === "quora" || mode === "roundups" || mode === "both") return mode;
  return "both";
}

async function maybeEnqueueScheduledJob({ userID, mode, automationJobs, supabase }) {
  const normalizedUserID = normalizeText(userID);
  if (!normalizedUserID) return null;

  const intervalHours = Math.max(1, Number.parseInt(process.env.GROWTH_OUTREACH_INTERVAL_HOURS ?? "168", 10) || 168);
  const since = new Date(Date.now() - intervalHours * 60 * 60 * 1000).toISOString();
  const { data, error } = await supabase
    .from("automation_jobs")
    .select("id,status,created_at")
    .eq("user_id", normalizedUserID)
    .eq("kind", "growth_outreach_run")
    .in("status", ["queued", "running", "succeeded"])
    .gte("created_at", since)
    .limit(1);

  if (error) throw error;
  if (Array.isArray(data) && data.length > 0) return null;

  return automationJobs.createAutomationJob({
    userID: normalizedUserID,
    kind: "growth_outreach_run",
    payload: {
      mode: normalizeMode(mode),
      scheduled: true,
      intervalHours,
    },
    maxAttempts: 2,
  });
}

async function processJob(job, { workerID, lockSeconds, automationJobs, growthOutreachAgent }) {
  const {
    completeAutomationJob,
    failAutomationJob,
    heartbeatAutomationJob,
  } = automationJobs;
  const { executeGrowthOutreachJob } = growthOutreachAgent;

  const heartbeat = setInterval(() => {
    heartbeatAutomationJob({ jobID: job.id, workerID, lockSeconds }).catch((error) => {
      console.warn(`[growth-outreach-worker] heartbeat failed job=${job.id}: ${error.message}`);
    });
  }, Math.max(15_000, Math.floor(lockSeconds * 1000 * 0.4)));

  try {
    const result = await executeGrowthOutreachJob(job, { logger: console });
    await completeAutomationJob({ jobID: job.id, result });
    console.log(`[growth-outreach-worker] completed job=${job.id}`);
    return true;
  } catch (error) {
    console.error(`[growth-outreach-worker] failed job=${job.id}: ${error.message}`);
    await failAutomationJob({
      jobID: job.id,
      errorMessage: error.message,
      result: {
        error: error.message,
        failedAt: new Date().toISOString(),
      },
    }).catch((failError) => {
      console.error(`[growth-outreach-worker] failed to mark job failed=${job.id}: ${failError.message}`);
    });
    return false;
  } finally {
    clearInterval(heartbeat);
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const workerID = args.workerID ?? `growth_outreach_worker_${process.pid}`;
  const automationJobs = await import("../lib/automation-jobs.js");
  const growthOutreachAgent = await import("../lib/growth-outreach-agent.js");
  const { getServiceRoleSupabase } = await import("../lib/supabase-clients.js");
  const supabase = getServiceRoleSupabase();

  do {
    const autoEnqueueUserID = args.autoEnqueueUserID || process.env.GROWTH_OUTREACH_AUTO_ENQUEUE_USER_ID;
    const autoEnqueueMode = args.autoEnqueueMode || process.env.GROWTH_OUTREACH_AUTO_ENQUEUE_MODE || "both";
    const scheduled = await maybeEnqueueScheduledJob({
      userID: autoEnqueueUserID,
      mode: autoEnqueueMode,
      automationJobs,
      supabase,
    });
    if (scheduled) {
      console.log(`[growth-outreach-worker] scheduled job=${scheduled.id} user=${scheduled.userID}`);
    }

    const jobs = await automationJobs.claimAutomationJobs({
      workerID,
      kinds: ["growth_outreach_run"],
      batchSize: args.batchSize,
      lockSeconds: args.lockSeconds,
    });

    if (jobs.length === 0) {
      if (args.once) break;
      await sleep(args.idleSleepMs);
      continue;
    }

    for (const job of jobs) {
      await processJob(job, {
        workerID,
        lockSeconds: args.lockSeconds,
        automationJobs,
        growthOutreachAgent,
      });
    }

    if (args.once) break;
  } while (true);
}

main().catch((error) => {
  console.error("[growth-outreach-worker] fatal:", error.message);
  process.exit(1);
});
