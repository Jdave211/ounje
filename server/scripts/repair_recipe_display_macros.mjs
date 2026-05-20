import { config as loadEnv } from "dotenv";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  guaranteeRecipeDisplayMacros,
  hasCompleteDisplayMacros,
} from "../lib/recipe-ingestion.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
loadEnv({ path: path.resolve(__dirname, "../.env") });

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

const args = new Set(process.argv.slice(2));
const apply = args.has("--apply");
const tableArg = process.argv.find((arg) => arg.startsWith("--table="))?.split("=").slice(1).join("=") ?? "both";
const limitArg = Number(process.argv.find((arg) => arg.startsWith("--limit="))?.split("=")[1] ?? 500);
const limit = Number.isFinite(limitArg) && limitArg > 0 ? Math.min(Math.floor(limitArg), 2000) : 500;

const TABLES = tableArg === "both"
  ? ["user_import_recipes", "recipes"]
  : [tableArg].filter((table) => ["user_import_recipes", "recipes"].includes(table));

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.");
  process.exit(1);
}

if (!TABLES.length) {
  console.error("Use --table=user_import_recipes, --table=recipes, or --table=both.");
  process.exit(1);
}

function authHeaders(extra = {}) {
  return {
    apikey: SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    ...extra,
  };
}

function selectColumns() {
  return [
    "id",
    "title",
    "description",
    "source",
    "source_platform",
    "category",
    "subcategory",
    "recipe_type",
    "main_protein",
    "cook_method",
    "servings_text",
    "serving_size_text",
    "est_calories_text",
    "calories_kcal",
    "protein_g",
    "carbs_g",
    "fat_g",
    "prep_time_minutes",
    "cook_time_minutes",
    "cook_time_text",
    "ingredients_json",
    "steps_json",
    "servings_count",
    "updated_at",
  ].join(",");
}

function isFiniteMacro(value) {
  return value !== null
    && value !== undefined
    && String(value).trim() !== ""
    && Number.isFinite(Number(value));
}

function patchFromCompleted(row, completed) {
  const patch = {};
  for (const field of ["calories_kcal", "protein_g", "carbs_g", "fat_g"]) {
    if (!isFiniteMacro(row[field]) && isFiniteMacro(completed[field])) {
      patch[field] = Number(completed[field]);
    }
  }
  if (
    String(completed.est_calories_text ?? "").trim()
    && (
      !String(row.est_calories_text ?? "").trim()
      || Object.prototype.hasOwnProperty.call(patch, "calories_kcal")
    )
  ) {
    patch.est_calories_text = String(completed.est_calories_text).trim();
  }
  return patch;
}

function detailFromRow(row) {
  return {
    ...row,
    ingredients: Array.isArray(row.ingredients_json) ? row.ingredients_json : [],
    steps: Array.isArray(row.steps_json) ? row.steps_json : [],
  };
}

async function fetchRows(table) {
  const url = new URL(`${SUPABASE_URL.replace(/\/+$/, "")}/rest/v1/${table}`);
  url.searchParams.set("select", selectColumns());
  url.searchParams.set("or", "(calories_kcal.is.null,protein_g.is.null,carbs_g.is.null,fat_g.is.null)");
  url.searchParams.set("order", "updated_at.desc.nullslast");
  url.searchParams.set("limit", String(limit));

  const response = await fetch(url, { headers: authHeaders() });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`Fetch ${table} failed (${response.status}): ${body.slice(0, 300)}`);
  }
  return JSON.parse(body);
}

async function patchRow(table, id, patch) {
  const url = new URL(`${SUPABASE_URL.replace(/\/+$/, "")}/rest/v1/${table}`);
  url.searchParams.set("id", `eq.${id}`);
  const response = await fetch(url, {
    method: "PATCH",
    headers: authHeaders({
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    }),
    body: JSON.stringify(patch),
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`Patch ${table}/${id} failed (${response.status}): ${body.slice(0, 300)}`);
  }
}

const summary = {
  apply,
  limit,
  tables: {},
};

for (const table of TABLES) {
  const rows = await fetchRows(table);
  const repairs = [];

  for (const row of rows) {
    const completed = await guaranteeRecipeDisplayMacros(detailFromRow(row));
    if (!hasCompleteDisplayMacros(completed)) continue;

    const patch = patchFromCompleted(row, completed);
    if (!Object.keys(patch).length) continue;

    repairs.push({
      id: row.id,
      title: row.title,
      patch,
    });

    if (apply) {
      await patchRow(table, row.id, patch);
    }
  }

  summary.tables[table] = {
    scanned: rows.length,
    repairable: repairs.length,
    repaired: apply ? repairs.length : 0,
    sample: repairs.slice(0, 10),
  };
}

console.log(JSON.stringify(summary, null, 2));
