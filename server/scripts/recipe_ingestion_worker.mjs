#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { RECIPE_IMPORT_WAKE_CHANNEL, runRecipeIngestionWorkerBatch } from "../lib/recipe-ingestion.js";
import { getRedisClient, redisConfigStatus } from "../lib/redis-cache.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const DEFAULT_BATCH_SIZE = 3;
const DEFAULT_IDLE_SLEEP_MS = 20_000;
const DEFAULT_WAKE_TIMEOUT_MS = 15 * 60 * 1000;
const MAX_EMPTY_QUEUE_SLEEP_MS = 10 * 60 * 1000;

function parseArgs(argv) {
  const args = {
    once: false,
    batchSize: DEFAULT_BATCH_SIZE,
    idleSleepMs: DEFAULT_IDLE_SLEEP_MS,
    wakeMode: String(process.env.RECIPE_INGESTION_WORKER_WAKE_MODE ?? "poll").trim().toLowerCase(),
    wakeTimeoutMs: Math.max(
      60_000,
      Number.parseInt(process.env.RECIPE_INGESTION_WORKER_WAKE_TIMEOUT_MS ?? "", 10) || DEFAULT_WAKE_TIMEOUT_MS
    ),
    workerID: null,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--once") args.once = true;
    else if (token === "--batch-size") args.batchSize = Math.max(1, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_BATCH_SIZE), index += 1;
    else if (token === "--idle-sleep-ms") args.idleSleepMs = Math.max(1_000, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_IDLE_SLEEP_MS), index += 1;
    else if (token === "--wake-mode") args.wakeMode = String(argv[index + 1] ?? "poll").trim().toLowerCase(), index += 1;
    else if (token === "--wake-timeout-ms") args.wakeTimeoutMs = Math.max(60_000, Number.parseInt(argv[index + 1] ?? "", 10) || DEFAULT_WAKE_TIMEOUT_MS), index += 1;
    else if (token === "--worker-id") args.workerID = String(argv[index + 1] ?? "").trim() || null, index += 1;
  }

  return args;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForRedisWake(channel, timeoutMs) {
  const status = redisConfigStatus();
  if (!status.configured) {
    await sleep(timeoutMs);
    return { woke: false, reason: "redis_not_configured" };
  }

  let subscriber = null;
  let settled = false;
  return new Promise(async (resolve) => {
    const finish = async (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        if (subscriber?.isOpen) await subscriber.unsubscribe(channel);
      } catch (_) { /* noop */ }
      try {
        if (subscriber?.isOpen) await subscriber.quit();
      } catch (_) { /* noop */ }
      resolve(result);
    };

    const timer = setTimeout(() => {
      void finish({ woke: false, reason: "safety_sweep" });
    }, timeoutMs);

    try {
      const client = await getRedisClient();
      if (!client) {
        await finish({ woke: false, reason: "redis_unavailable" });
        return;
      }

      subscriber = client.duplicate();
      subscriber.on("error", () => {
        void finish({ woke: false, reason: "redis_error" });
      });
      await subscriber.connect();
      await subscriber.subscribe(channel, () => {
        void finish({ woke: true, reason: "redis_wake" });
      });
    } catch {
      await finish({ woke: false, reason: "redis_subscribe_failed" });
    }
  });
}

async function main() {
  const args = parseArgs(process.argv);
  const workerID = args.workerID ?? `vm_recipe_ingest_${process.pid}`;
  let emptyQueueSleepMs = args.idleSleepMs;
  const wakeMode = args.wakeMode === "redis" ? "redis" : "poll";
  console.log(`[recipe-ingestion-worker] started worker=${workerID} wakeMode=${wakeMode}`);

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
      if (wakeMode === "redis") {
        const wake = await waitForRedisWake(RECIPE_IMPORT_WAKE_CHANNEL, args.wakeTimeoutMs);
        console.log(`[recipe-ingestion-worker] idle wake=${wake.reason} worker=${workerID}`);
      } else {
        await sleep(emptyQueueSleepMs);
        emptyQueueSleepMs = Math.min(
          MAX_EMPTY_QUEUE_SLEEP_MS,
          Math.max(args.idleSleepMs, emptyQueueSleepMs * 2),
        );
      }
    } else {
      emptyQueueSleepMs = args.idleSleepMs;
    }
  } while (true);
}

main().catch((error) => {
  console.error("[recipe-ingestion-worker] fatal:", error.message);
  process.exit(1);
});
