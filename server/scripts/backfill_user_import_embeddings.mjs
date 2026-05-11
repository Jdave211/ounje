#!/usr/bin/env node
/**
 * Backfill embedding_basic for existing user_import_recipes rows that have no embedding.
 *
 * Usage:
 *   node server/scripts/backfill_user_import_embeddings.mjs [--limit 500] [--page-size 50] [--dry-run]
 */
import path from "path";
import dotenv from "dotenv";
import OpenAI from "openai";

dotenv.config({ path: path.resolve(path.dirname(new URL(import.meta.url).pathname), "../.env") });

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

if (!OPENAI_API_KEY) { console.error("Missing OPENAI_API_KEY"); process.exit(1); }
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) { console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY"); process.exit(1); }

const openai = new OpenAI({ apiKey: OPENAI_API_KEY });

const HEADERS = {
  apikey: SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
  "Content-Type": "application/json",
};

function parseArgs(argv) {
  const args = { limit: 500, pageSize: 50, dryRun: false };
  for (let i = 2; i < argv.length; i++) {
    const token = argv[i];
    if (token === "--limit") args.limit = Number.parseInt(argv[i + 1] ?? "500", 10) || 500, i++;
    if (token === "--page-size") args.pageSize = Number.parseInt(argv[i + 1] ?? "50", 10) || 50, i++;
    if (token === "--dry-run") args.dryRun = true;
  }
  args.limit = Math.max(1, Math.min(args.limit, 10000));
  args.pageSize = Math.max(1, Math.min(args.pageSize, 200));
  return args;
}

function normalizeText(value, maxChars = 4000) {
  return String(value ?? "").replace(/\s+/g, " ").trim().slice(0, maxChars);
}

function toVectorLiteral(values) {
  return `[${values.join(",")}]`;
}

function buildEmbeddingInput(row) {
  return [
    `title: ${normalizeText(row.title ?? "", 240)}`,
    `description: ${normalizeText(row.description ?? "", 600)}`,
    `recipe_type: ${normalizeText(row.recipe_type ?? row.category ?? "", 80)}`,
    `main_protein: ${normalizeText(row.main_protein ?? "", 80)}`,
    `cuisine_tags: ${(row.cuisine_tags ?? []).join(", ")}`,
    `dietary_tags: ${(row.dietary_tags ?? []).join(", ")}`,
    `flavor_tags: ${(row.flavor_tags ?? []).join(", ")}`,
    `ingredients: ${normalizeText(row.ingredients_text ?? "", 1600)}`,
  ].join("\n");
}

async function fetchCandidates({ limit, pageSize }) {
  const rows = [];
  let offset = 0;
  const select = "id,title,description,recipe_type,category,main_protein,cuisine_tags,dietary_tags,flavor_tags,ingredients_text,embedding_basic";

  while (rows.length < limit) {
    const remaining = limit - rows.length;
    const batchSize = Math.min(pageSize, remaining);
    const params = new URLSearchParams({
      select,
      "embedding_basic": "is.null",
      order: "created_at.desc.nullslast",
      limit: String(batchSize),
      offset: String(offset),
    });

    const response = await fetch(`${SUPABASE_URL}/rest/v1/user_import_recipes?${params}`, { headers: HEADERS });
    const data = await response.json().catch(() => []);
    if (!response.ok) throw new Error(data?.message ?? data?.error ?? "Failed to fetch candidates");
    const batch = Array.isArray(data) ? data : [];
    if (!batch.length) break;
    rows.push(...batch);
    offset += batch.length;
  }
  return rows;
}

async function patchEmbedding(id, vector) {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/user_import_recipes?id=eq.${encodeURIComponent(id)}`,
    {
      method: "PATCH",
      headers: { ...HEADERS, Prefer: "return=minimal" },
      body: JSON.stringify({ embedding_basic: toVectorLiteral(vector) }),
    }
  );
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(data?.message ?? data?.error ?? `Failed to patch ${id}`);
  }
}

async function buildEmbedding(input) {
  const response = await openai.embeddings.create({ model: "text-embedding-3-small", input });
  return response.data?.[0]?.embedding ?? [];
}

async function main() {
  const args = parseArgs(process.argv);
  console.log(`[backfill] Starting — limit=${args.limit}, pageSize=${args.pageSize}, dryRun=${args.dryRun}`);

  const candidates = await fetchCandidates({ limit: args.limit, pageSize: args.pageSize });
  console.log(`[backfill] Found ${candidates.length} imported recipes missing embeddings`);

  let succeeded = 0;
  let failed = 0;

  for (const row of candidates) {
    const input = buildEmbeddingInput(row);
    try {
      const vector = await buildEmbedding(input);
      if (!vector.length) {
        console.warn(`[backfill] Empty embedding for ${row.id} — skipping`);
        failed++;
        continue;
      }
      if (!args.dryRun) {
        await patchEmbedding(row.id, vector);
      }
      console.log(`[backfill] ✓ ${row.id} "${(row.title ?? "").slice(0, 50)}"`);
      succeeded++;
    } catch (error) {
      console.error(`[backfill] ✗ ${row.id}: ${error.message}`);
      failed++;
    }
  }

  console.log(`[backfill] Done — succeeded=${succeeded}, failed=${failed}`);
}

main().catch((error) => {
  console.error("[backfill] fatal:", error.message);
  process.exit(1);
});
