import express from "express";
import bodyParser from "body-parser";
import axios from "axios";
import dotenv from "dotenv";
import cors from "cors";
import { createClient } from "@supabase/supabase-js";

import api_router from "./api/index.js";
import { runRecipeIngestionWorkerBatch } from "./lib/recipe-ingestion.js";
import { startRecipeFineTunePolling } from "./lib/recipe-model-registry.js";

dotenv.config({ path: new URL("./.env", import.meta.url).pathname });

const app = express();
app.use(bodyParser.json({ limit: "50mb" }));
app.use(cors());

const SUPABASE_URL = String(process.env.SUPABASE_URL ?? "").trim();
const SUPABASE_SERVICE_ROLE_KEY = String(process.env.SUPABASE_SERVICE_ROLE_KEY ?? "").trim();
let healthSupabaseClient = null;

function getHealthSupabaseClient() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return null;
  }

  if (!healthSupabaseClient) {
    healthSupabaseClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });
  }

  return healthSupabaseClient;
}

app.use(api_router);
app.get("/", (req, res) => {
  res.json({ message: "Hello from server" });
});
app.get("/healthz", async (req, res) => {
  const missingEnv = [
    "OPENAI_API_KEY",
    "SUPABASE_URL",
    "SUPABASE_ANON_KEY",
    "SUPABASE_SERVICE_ROLE_KEY",
  ].filter((key) => !String(process.env[key] ?? "").trim());

  if (missingEnv.length > 0) {
    return res.status(503).json({
      ok: false,
      service: "ounje-api",
      status: "missing_env",
      missingEnv,
      checkedAt: new Date().toISOString(),
    });
  }

  const supabase = getHealthSupabaseClient();
  if (!supabase) {
    return res.status(503).json({
      ok: false,
      service: "ounje-api",
      status: "supabase_unavailable",
      checkedAt: new Date().toISOString(),
    });
  }

  try {
    const { error } = await supabase
      .from("profiles")
      .select("id", { head: true, count: "estimated" })
      .limit(1);

    if (error) {
      throw error;
    }

    return res.json({
      ok: true,
      service: "ounje-api",
      status: "ready",
      dependencies: {
        supabase: "ok",
      },
      checkedAt: new Date().toISOString(),
    });
  } catch (error) {
    return res.status(503).json({
      ok: false,
      service: "ounje-api",
      status: "dependency_error",
      dependencies: {
        supabase: error.message,
      },
      checkedAt: new Date().toISOString(),
    });
  }
});
const PORT = process.env.PORT || 8080;
const HOST = process.env.HOST || "0.0.0.0";

const RECIPE_INGESTION_POLL_MS = Math.max(
  2_000,
  Number.parseInt(process.env.RECIPE_INGESTION_POLL_MS ?? "4000", 10) || 4_000
);
const RECIPE_INGESTION_BATCH_SIZE = Math.max(
  1,
  Number.parseInt(process.env.RECIPE_INGESTION_BATCH_SIZE ?? "4", 10) || 4
);
const ENABLE_RECIPE_INGESTION_POLLING = ["1", "true", "yes", "on"].includes(
  String(process.env.OUNJE_ENABLE_RECIPE_INGESTION_POLLING ?? "").trim().toLowerCase()
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
if (ENABLE_RECIPE_INGESTION_POLLING) {
  console.log("[recipe-ingestion] polling enabled");
  startRecipeIngestionPolling();
} else {
  console.log("[recipe-ingestion] polling disabled by OUNJE_ENABLE_RECIPE_INGESTION_POLLING");
}
app.listen(PORT, HOST, function () {
  console.log(`Server listening at http://${HOST}:${PORT}`);
});
