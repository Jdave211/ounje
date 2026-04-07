import path from "path";
import dotenv from "dotenv";
import OpenAI from "openai";

dotenv.config({ path: path.resolve(path.dirname(new URL(import.meta.url).pathname), "../.env") });

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";

if (!OPENAI_API_KEY) {
  console.error("Missing OPENAI_API_KEY");
  process.exit(1);
}

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_ANON_KEY");
  process.exit(1);
}

const openai = new OpenAI({ apiKey: OPENAI_API_KEY });

const HEADERS = {
  apikey: SUPABASE_ANON_KEY,
  Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
  "Content-Type": "application/json",
};

function parseArgs(argv) {
  const args = {
    limit: 200,
    pageSize: 50,
    dryRun: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--limit") args.limit = Number.parseInt(argv[i + 1] ?? "200", 10) || 200;
    if (token === "--page-size") args.pageSize = Number.parseInt(argv[i + 1] ?? "50", 10) || 50;
    if (token === "--dry-run") args.dryRun = true;
  }

  args.limit = Math.max(1, Math.min(args.limit, 5000));
  args.pageSize = Math.max(1, Math.min(args.pageSize, 200));
  return args;
}

function normalizeText(value, maxChars = 4000) {
  return String(value ?? "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxChars);
}

function toVectorLiteral(values) {
  return `[${values.join(",")}]`;
}

function buildBasicInput(recipe) {
  return [
    `title: ${normalizeText(recipe.title, 240)}`,
    `description: ${normalizeText(recipe.description, 800)}`,
    `recipe_type: ${normalizeText(recipe.recipe_type, 80)}`,
    `category: ${normalizeText(recipe.category, 80)}`,
    `main_protein: ${normalizeText(recipe.main_protein, 80)}`,
    `cuisine_tags: ${(recipe.cuisine_tags ?? []).join(", ")}`,
    `dietary_tags: ${(recipe.dietary_tags ?? []).join(", ")}`,
    `flavor_tags: ${(recipe.flavor_tags ?? []).join(", ")}`,
    `occasion_tags: ${(recipe.occasion_tags ?? []).join(", ")}`,
    `ingredients: ${normalizeText(recipe.ingredients_text, 2000)}`,
  ].join("\n");
}

function buildRichInput(recipe) {
  return [
    buildBasicInput(recipe),
    `instructions: ${normalizeText(recipe.instructions_text, 5000)}`,
    `cook_time_text: ${normalizeText(recipe.cook_time_text, 120)}`,
    `skill_level: ${normalizeText(recipe.skill_level, 120)}`,
  ].join("\n");
}

async function fetchCandidates({ limit, pageSize }) {
  const rows = [];
  let offset = 0;

  while (rows.length < limit) {
    const remaining = limit - rows.length;
    const batchSize = Math.min(pageSize, remaining);
    const select = [
      "id",
      "title",
      "description",
      "recipe_type",
      "category",
      "main_protein",
      "cuisine_tags",
      "dietary_tags",
      "flavor_tags",
      "occasion_tags",
      "ingredients_text",
      "instructions_text",
      "cook_time_text",
      "skill_level",
      "embedding_basic",
      "embedding_rich",
      "created_at",
      "updated_at",
    ].join(",");

    const params = new URLSearchParams({
      select,
      or: "(embedding_basic.is.null,embedding_rich.is.null)",
      order: "created_at.desc.nullslast,updated_at.desc.nullslast,id.asc",
      limit: String(batchSize),
      offset: String(offset),
    });

    const response = await fetch(`${SUPABASE_URL}/rest/v1/recipes?${params.toString()}`, {
      headers: HEADERS,
    });
    const data = await response.json().catch(() => []);
    if (!response.ok) {
      throw new Error(data?.message ?? data?.error ?? "Failed to fetch candidate recipes");
    }

    const batch = Array.isArray(data) ? data : [];
    if (!batch.length) break;
    rows.push(...batch);
    offset += batch.length;
  }

  return rows;
}

async function patchRecipe(id, payload) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/recipes?id=eq.${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: {
      ...HEADERS,
      Prefer: "return=minimal",
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(data?.message ?? data?.error ?? `Failed to patch recipe ${id}`);
  }
}

async function buildEmbedding(input, model) {
  const response = await openai.embeddings.create({
    model,
    input,
  });
  return response.data?.[0]?.embedding ?? [];
}

async function processRecipe(recipe, { dryRun }) {
  const missingBasic = recipe.embedding_basic == null;
  const missingRich = recipe.embedding_rich == null;
  if (!missingBasic && !missingRich) {
    return { id: recipe.id, updated: false, reason: "already_complete" };
  }

  const payload = {};

  if (missingBasic) {
    const basic = await buildEmbedding(buildBasicInput(recipe), "text-embedding-3-small");
    if (!basic.length) throw new Error(`No basic embedding returned for ${recipe.id}`);
    payload.embedding_basic = toVectorLiteral(basic);
  }

  if (missingRich) {
    const rich = await buildEmbedding(buildRichInput(recipe), "text-embedding-3-large");
    if (!rich.length) throw new Error(`No rich embedding returned for ${recipe.id}`);
    payload.embedding_rich = toVectorLiteral(rich);
  }

  payload.embeddings_generated_at = new Date().toISOString();

  if (!dryRun) {
    await patchRecipe(recipe.id, payload);
  }

  return { id: recipe.id, updated: true, missingBasic, missingRich };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const candidates = await fetchCandidates(args);

  console.log(
    JSON.stringify(
      {
        stage: "start",
        total_candidates: candidates.length,
        limit: args.limit,
        dry_run: args.dryRun,
      },
      null,
      2
    )
  );

  let updated = 0;
  let failed = 0;
  const failures = [];

  for (let index = 0; index < candidates.length; index += 1) {
    const recipe = candidates[index];
    try {
      const result = await processRecipe(recipe, args);
      if (result.updated) {
        updated += 1;
      }
      if ((index + 1) % 10 === 0 || index + 1 === candidates.length) {
        console.log(
          JSON.stringify({
            stage: "progress",
            processed: index + 1,
            total: candidates.length,
            updated,
            failed,
          })
        );
      }
    } catch (error) {
      failed += 1;
      failures.push({
        id: recipe.id,
        title: recipe.title,
        error: error.message,
      });
      console.error(`[embeddings-backfill] ${recipe.id} ${recipe.title}: ${error.message}`);
    }
  }

  console.log(
    JSON.stringify(
      {
        stage: "complete",
        processed: candidates.length,
        updated,
        failed,
        failures,
      },
      null,
      2
    )
  );
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
