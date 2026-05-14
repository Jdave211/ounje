import express from "express";
import bodyParser from "body-parser";
import axios from "axios";
import dotenv from "dotenv";
import cors from "cors";
import { createClient } from "@supabase/supabase-js";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import api_router from "./api/index.js";
import { runRecipeIngestionWorkerBatch } from "./lib/recipe-ingestion.js";
import { startRecipeFineTunePolling } from "./lib/recipe-model-registry.js";
import { withAIUsageContext } from "./lib/openai-usage-logger.js";
import { checkRedisHealth } from "./lib/redis-cache.js";
import { renderRecipeSharePage, resolveRecipeShareLink } from "./lib/recipe-share-links.js";

dotenv.config({ path: new URL("./.env", import.meta.url).pathname });

const app = express();
const JSON_BODY_LIMIT = String(process.env.OUNJE_JSON_BODY_LIMIT ?? "18mb").trim() || "18mb";
app.use(bodyParser.json({ limit: JSON_BODY_LIMIT }));
app.use(cors());
app.use((req, _res, next) => {
  withAIUsageContext({
    service: "ounje-api",
    route: req.path,
    method: req.method,
    user_id: req.body?.user_id ?? req.body?.userID ?? req.query?.user_id ?? req.query?.userID ?? req.headers["x-user-id"],
    request_id: req.headers["x-request-id"] ?? req.headers["x-render-request-id"],
  }, next);
});
app.use((req, res, next) => {
  const startedAt = Date.now();
  const startedMemory = process.memoryUsage();

  res.on("finish", () => {
    const durationMs = Date.now() - startedAt;
    const endedMemory = process.memoryUsage();
    const routeKey = `${req.method} ${req.path}`;
    const isRecipeHeavyRoute = req.path.startsWith("/v1/recipe/discover")
      || req.path.startsWith("/v1/recipe/imports")
      || req.path.startsWith("/v1/recipe/adapt")
      || req.path.startsWith("/v1/recipe/prep-candidates");
    const heapDeltaMB = (endedMemory.heapUsed - startedMemory.heapUsed) / (1024 * 1024);

    if (isRecipeHeavyRoute || durationMs >= 1000 || heapDeltaMB >= 8) {
      const cacheStats = globalThis.__OUNJE_RECIPE_CACHE_STATS__?.();
      console.log("[api-route-metrics]", {
        route: routeKey,
        status: res.statusCode,
        duration_ms: durationMs,
        heap_used_mb: Number((endedMemory.heapUsed / (1024 * 1024)).toFixed(1)),
        rss_mb: Number((endedMemory.rss / (1024 * 1024)).toFixed(1)),
        heap_delta_mb: Number(heapDeltaMB.toFixed(1)),
        cache_stats: cacheStats ?? undefined,
      });
    }
  });

  next();
});

const serverDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(serverDir, "..");

const SUPABASE_URL = String(process.env.SUPABASE_URL ?? "").trim();
const SUPABASE_SERVICE_ROLE_KEY = String(process.env.SUPABASE_SERVICE_ROLE_KEY ?? "").trim();
const HEALTHZ_CACHE_TTL_MS = Math.max(
  5_000,
  Number.parseInt(String(process.env.OUNJE_HEALTHZ_CACHE_TTL_MS ?? ""), 10) || 30_000
);
const HEALTHZ_FAILURE_CACHE_TTL_MS = Math.max(
  2_000,
  Number.parseInt(String(process.env.OUNJE_HEALTHZ_FAILURE_CACHE_TTL_MS ?? ""), 10) || 10_000
);
let healthSupabaseClient = null;
let cachedHealthz = null;

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

app.get("/.well-known/apple-app-site-association", (_req, res) => {
  res.type("application/json").send({
    applinks: {
      apps: [],
      details: [
        {
          appIDs: ["U8FPZXV6X6.net.ounje"],
          components: [
            {
              "/": "/r/*",
              comment: "Open shared Ounje recipes in the app.",
            },
          ],
          paths: ["/r/*"],
        },
      ],
    },
  });
});

app.get("/r/:shareID", async (req, res) => {
  try {
    const link = await resolveRecipeShareLink(req.params.shareID);
    if (!link) {
      return res.status(404).type("html").send("<!doctype html><title>Recipe not found</title><p>Recipe link not found.</p>");
    }
    return res.type("html").send(renderRecipeSharePage(link));
  } catch (error) {
    console.error("[recipe-share-page] render failed:", error.message);
    return res.status(500).type("html").send("<!doctype html><title>Recipe unavailable</title><p>Recipe link is temporarily unavailable.</p>");
  }
});

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function renderLegalMarkdown(markdown) {
  const lines = String(markdown ?? "").split(/\r?\n/);
  const html = [];
  let inList = false;

  function closeList() {
    if (inList) {
      html.push("</ul>");
      inList = false;
    }
  }

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) {
      closeList();
      continue;
    }

    if (line.startsWith("# ")) {
      closeList();
      html.push(`<h1>${escapeHTML(line.slice(2))}</h1>`);
    } else if (line.startsWith("## ")) {
      closeList();
      html.push(`<h2>${escapeHTML(line.slice(3))}</h2>`);
    } else if (line.startsWith("### ")) {
      closeList();
      html.push(`<h3>${escapeHTML(line.slice(4))}</h3>`);
    } else if (line.startsWith("- ")) {
      if (!inList) {
        html.push("<ul>");
        inList = true;
      }
      html.push(`<li>${escapeHTML(line.slice(2))}</li>`);
    } else {
      closeList();
      html.push(`<p>${escapeHTML(line).replaceAll("  ", "<br>")}</p>`);
    }
  }

  closeList();
  return html.join("\n");
}

function sendLegalPage(res, title, markdownPath) {
  const fallback = `# ${title}\n\nContact thisisounje@gmail.com for support.`;
  const markdown = fs.existsSync(markdownPath)
    ? fs.readFileSync(markdownPath, "utf8")
    : fallback;

  res.type("html").send(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHTML(title)}</title>
  <style>
    :root { color-scheme: dark; background: #121212; color: #f6f2ec; }
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.58; }
    main { max-width: 760px; margin: 0 auto; padding: 40px 20px 72px; }
    h1 { font-size: 34px; line-height: 1.05; margin: 0 0 16px; }
    h2 { font-size: 21px; margin: 34px 0 10px; }
    h3 { font-size: 17px; margin: 24px 0 8px; }
    p, li { color: #d7d1c9; font-size: 15px; }
    ul { padding-left: 22px; }
    a { color: #63d471; }
  </style>
</head>
<body>
  <main>${renderLegalMarkdown(markdown)}</main>
</body>
</html>`);
}

app.get(["/privacy", "/privacy-policy"], (_req, res) => {
  sendLegalPage(res, "Ounje Privacy Policy", path.join(repoRoot, "docs/legal/privacy-policy.md"));
});

app.get(["/terms", "/terms-of-service"], (_req, res) => {
  sendLegalPage(res, "Ounje Terms of Service", path.join(repoRoot, "docs/legal/terms-of-service.md"));
});

app.get("/support", (_req, res) => {
  sendLegalPage(res, "Ounje Support", path.join(repoRoot, "docs/legal/support.md"));
});

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

  if (cachedHealthz && Date.now() < cachedHealthz.expiresAt) {
    return res.status(cachedHealthz.statusCode).json({
      ...cachedHealthz.payload,
      cached: true,
      servedAt: new Date().toISOString(),
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

    const redis = await checkRedisHealth();
    const responseStatus = redis.configured && redis.status !== "ok"
      ? "ready_degraded"
      : "ready";

    const payload = {
      ok: true,
      service: "ounje-api",
      status: responseStatus,
      dependencies: {
        supabase: "ok",
        redis: redis.status,
      },
      redis,
      checkedAt: new Date().toISOString(),
    };
    cachedHealthz = {
      statusCode: 200,
      payload,
      expiresAt: Date.now() + HEALTHZ_CACHE_TTL_MS,
    };
    return res.json(payload);
  } catch (error) {
    const payload = {
      ok: false,
      service: "ounje-api",
      status: "dependency_error",
      dependencies: {
        supabase: error.message,
      },
      checkedAt: new Date().toISOString(),
    };
    cachedHealthz = {
      statusCode: 503,
      payload,
      expiresAt: Date.now() + HEALTHZ_FAILURE_CACHE_TTL_MS,
    };
    return res.status(503).json(payload);
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
const RECIPE_INGESTION_WORKER_ID = String(
  process.env.RECIPE_INGESTION_WORKER_ID ?? `api_${process.pid}`
).trim();
const ENABLE_RECIPE_INGESTION_POLLING = ["1", "true", "yes", "on"].includes(
  String(process.env.OUNJE_ENABLE_RECIPE_INGESTION_POLLING ?? "").trim().toLowerCase()
);
const CAN_CLAIM_RECIPE_INGESTION_JOBS = RECIPE_INGESTION_WORKER_ID
  .toLowerCase()
  .startsWith("vm_recipe_ingest");

let recipeIngestionPollInFlight = false;

async function tickRecipeIngestionWorker() {
  if (recipeIngestionPollInFlight) {
    return;
  }

  recipeIngestionPollInFlight = true;
  try {
    const processed = await runRecipeIngestionWorkerBatch({
      workerID: RECIPE_INGESTION_WORKER_ID,
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

const ENABLE_RECIPE_FINE_TUNE_POLLING = ["1", "true", "yes", "on"].includes(
  String(process.env.OUNJE_ENABLE_RECIPE_FINE_TUNE_POLLING ?? "").trim().toLowerCase()
);

if (ENABLE_RECIPE_FINE_TUNE_POLLING) {
  startRecipeFineTunePolling();
} else {
  console.log("[recipe-model-registry] fine-tune polling disabled");
}
if (ENABLE_RECIPE_INGESTION_POLLING && CAN_CLAIM_RECIPE_INGESTION_JOBS) {
  console.log(`[recipe-ingestion] polling enabled worker=${RECIPE_INGESTION_WORKER_ID}`);
  startRecipeIngestionPolling();
} else if (ENABLE_RECIPE_INGESTION_POLLING) {
  console.log(
    `[recipe-ingestion] polling skipped: worker id ${RECIPE_INGESTION_WORKER_ID} is not allowed to claim jobs`
  );
} else {
  console.log("[recipe-ingestion] polling disabled by OUNJE_ENABLE_RECIPE_INGESTION_POLLING");
}
app.listen(PORT, HOST, function () {
  console.log(`Server listening at http://${HOST}:${PORT}`);
});
