#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const DEFAULT_IDLE_SLEEP_MS = 15_000;
const DEFAULT_LOCK_SECONDS = 600;
const DEFAULT_BATCH_SIZE = 1;

function parseArgs(argv) {
  const args = {
    once: false,
    batchSize: DEFAULT_BATCH_SIZE,
    idleSleepMs: DEFAULT_IDLE_SLEEP_MS,
    lockSeconds: DEFAULT_LOCK_SECONDS,
    workerID: null,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--once") args.once = true;
    else if (token === "--batch-size") args.batchSize = Math.max(1, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_BATCH_SIZE), index += 1;
    else if (token === "--idle-sleep-ms") args.idleSleepMs = Math.max(1_000, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_IDLE_SLEEP_MS), index += 1;
    else if (token === "--lock-seconds") args.lockSeconds = Math.max(30, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_LOCK_SECONDS), index += 1;
    else if (token === "--worker-id") args.workerID = String(argv[index + 1] ?? "").trim() || null, index += 1;
  }

  return args;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function processJob(job, { workerID, lockSeconds, automationJobs, instacartRunner }) {
  const {
    completeAutomationJob,
    failAutomationJob,
    heartbeatAutomationJob,
  } = automationJobs;
  const { executeInstacartAutomationJob } = instacartRunner;

  const heartbeat = setInterval(() => {
    heartbeatAutomationJob({ jobID: job.id, workerID, lockSeconds }).catch((error) => {
      console.warn(`[automation-worker] heartbeat failed job=${job.id}: ${error.message}`);
    });
  }, Math.max(15_000, Math.floor(lockSeconds * 1000 * 0.4)));

  try {
    let result;
    if (job.kind === "instacart_run") {
      result = await executeInstacartAutomationJob(job, { logger: console });
    } else {
      throw new Error(`Unsupported automation job kind: ${job.kind}`);
    }

    await completeAutomationJob({ jobID: job.id, result });
    console.log(`[automation-worker] completed job=${job.id} kind=${job.kind}`);
    return true;
  } catch (error) {
    console.error(`[automation-worker] failed job=${job.id} kind=${job.kind}: ${error.message}`);
    await failAutomationJob({
      jobID: job.id,
      errorMessage: error.message,
      result: {
        error: error.message,
        failedAt: new Date().toISOString(),
      },
    }).catch((failError) => {
      console.error(`[automation-worker] failed to mark job failed=${job.id}: ${failError.message}`);
    });
    return false;
  } finally {
    clearInterval(heartbeat);
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const workerID = args.workerID ?? `vm_automation_worker_${process.pid}`;
  const automationJobs = await import("../lib/automation-jobs.js");
  const instacartRunner = await import("../api/v1/instacart.js");

  do {
    const jobs = await automationJobs.claimAutomationJobs({
      workerID,
      kinds: ["instacart_run"],
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
        instacartRunner,
      });
    }

    if (args.once) break;
  } while (true);
}

main().catch((error) => {
  console.error("[automation-worker] fatal:", error.message);
  process.exit(1);
});
