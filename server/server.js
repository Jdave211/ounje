import express from "express";
import bodyParser from "body-parser";
import axios from "axios";
import dotenv from "dotenv";
import cors from "cors";

import api_router from "./api/index.js";
import { runRecipeIngestionWorkerBatch } from "./lib/recipe-ingestion.js";
import { startRecipeFineTunePolling } from "./lib/recipe-model-registry.js";

dotenv.config({ path: new URL("./.env", import.meta.url).pathname });

const app = express();
app.use(bodyParser.json({ limit: "50mb" }));
app.use(cors());

app.use(api_router);
app.get("/", (req, res) => {
  res.json({ message: "Hello from server" });
});
const PORT = process.env.PORT || 8080;
const HOST = process.env.HOST || "0.0.0.0";

const RECIPE_INGESTION_POLL_MS = Math.max(
  5_000,
  Number.parseInt(process.env.RECIPE_INGESTION_POLL_MS ?? "12000", 10) || 12_000
);
const RECIPE_INGESTION_BATCH_SIZE = Math.max(
  1,
  Number.parseInt(process.env.RECIPE_INGESTION_BATCH_SIZE ?? "3", 10) || 3
);

let recipeIngestionPollInFlight = false;

async function tickRecipeIngestionWorker() {
  if (recipeIngestionPollInFlight) {
    return;
  }

  recipeIngestionPollInFlight = true;
  try {
    const processed = await runRecipeIngestionWorkerBatch({
      workerID: `api_${process.pid}`,
      batchSize: RECIPE_INGESTION_BATCH_SIZE,
    });
    if (processed > 0) {
      console.log(`[recipe-ingestion] worker tick processed=${processed}`);
    }
  } catch (error) {
    console.warn("[recipe-ingestion] worker tick failed:", error.message);
  } finally {
    recipeIngestionPollInFlight = false;
  }
}

function startRecipeIngestionPolling() {
  void tickRecipeIngestionWorker();
  const interval = setInterval(() => {
    void tickRecipeIngestionWorker();
  }, RECIPE_INGESTION_POLL_MS);
  interval.unref?.();
}

startRecipeFineTunePolling();
startRecipeIngestionPolling();
app.listen(PORT, HOST, function () {
  console.log(`Server listening at http://${HOST}:${PORT}`);
});
