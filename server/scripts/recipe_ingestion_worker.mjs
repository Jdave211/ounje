#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { runRecipeIngestionWorkerBatch } from "../lib/recipe-ingestion.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const DEFAULT_BATCH_SIZE = 3;
const DEFAULT_IDLE_SLEEP_MS = 20_000;
const MAX_EMPTY_QUEUE_SLEEP_MS = 30_000;

function parseArgs(argv) {
  const args = {
    once: false,
    batchSize: DEFAULT_BATCH_SIZE,
    idleSleepMs: DEFAULT_IDLE_SLEEP_MS,
    workerID: null,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--once") args.once = true;
    else if (token === "--batch-size") args.batchSize = Math.max(1, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_BATCH_SIZE), index += 1;
    else if (token === "--idle-sleep-ms") args.idleSleepMs = Math.max(1_000, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_IDLE_SLEEP_MS), index += 1;
    else if (token === "--worker-id") args.workerID = String(argv[index + 1] ?? "").trim() || null, index += 1;
  }

  return args;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const args = parseArgs(process.argv);
  const workerID = args.workerID ?? `vm_recipe_ingest_${process.pid}`;
  let emptyQueueSleepMs = args.idleSleepMs;

  do {
    const processed = await runRecipeIngestionWorkerBatch({
      workerID,
      batchSize: args.batchSize,
    });

    console.log(`[recipe-ingestion-worker] processed=${processed} worker=${workerID}`);

    if (args.once) {
      break;
    }

    if (processed === 0) {
      await sleep(emptyQueueSleepMs);
      emptyQueueSleepMs = Math.min(
        MAX_EMPTY_QUEUE_SLEEP_MS,
        Math.max(args.idleSleepMs, emptyQueueSleepMs * 2),
      );
    } else {
      emptyQueueSleepMs = args.idleSleepMs;
    }
  } while (true);
}

main().catch((error) => {
  console.error("[recipe-ingestion-worker] fatal:", error.message);
  process.exit(1);
});
