import dotenv from "dotenv";
import { createClient } from "@supabase/supabase-js";

dotenv.config({ path: "server/.env" });

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.");
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const userIDArg = process.argv.find((arg) => arg.startsWith("--user-id="))?.split("=")[1]?.trim();
const recipeIDArg = process.argv.find((arg) => arg.startsWith("--recipe-id="))?.split("=")[1]?.trim();

async function fetchSmokeTarget() {
  let query = supabase
    .from("prep_recurring_recipes")
    .select("user_id,recipe_id,recipe,recipe_title,is_enabled,created_at,updated_at")
    .order("updated_at", { ascending: false })
    .limit(1);

  if (userIDArg) query = query.eq("user_id", userIDArg);
  if (recipeIDArg) query = query.eq("recipe_id", recipeIDArg);

  const { data, error } = await query;
  if (error) throw error;
  const row = data?.[0];
  if (!row) {
    throw new Error("No prep_recurring_recipes row found for smoke test. Pass --user-id and --recipe-id for an existing row.");
  }
  if (!row.recipe || typeof row.recipe !== "object") {
    throw new Error(`Recurring row ${row.user_id}/${row.recipe_id} has no recipe snapshot.`);
  }
  return row;
}

async function mealPrepSignature(userID) {
  const { data, error } = await supabase
    .from("meal_prep_cycles")
    .select("id,updated_at")
    .eq("user_id", userID)
    .order("updated_at", { ascending: false });
  if (error) throw error;
  return JSON.stringify((data ?? []).map((row) => [row.id, row.updated_at]));
}

async function fetchRows(userID, recipeID) {
  const { data, error } = await supabase
    .from("prep_recurring_recipes")
    .select("user_id,recipe_id,recipe_title,is_enabled,updated_at")
    .eq("user_id", userID)
    .eq("recipe_id", recipeID);
  if (error) throw error;
  return data ?? [];
}

async function setRecurring(row, isEnabled) {
  const payload = {
    user_id: row.user_id,
    recipe_id: row.recipe_id,
    recipe: row.recipe,
    recipe_title: row.recipe_title || row.recipe?.title || row.recipe_id,
    is_enabled: isEnabled,
  };
  const { error } = await supabase
    .from("prep_recurring_recipes")
    .upsert(payload, { onConflict: "user_id,recipe_id" });
  if (error) throw error;
}

const target = await fetchSmokeTarget();
const beforeMealPrepSignature = await mealPrepSignature(target.user_id);
const firstEnabledState = !Boolean(target.is_enabled);

await setRecurring(target, firstEnabledState);
let rows = await fetchRows(target.user_id, target.recipe_id);
if (rows.length !== 1) {
  throw new Error(`Expected exactly one recurring row after first toggle, found ${rows.length}.`);
}
if (rows[0].is_enabled !== firstEnabledState) {
  throw new Error(`Expected first toggle is_enabled=${firstEnabledState}, got ${rows[0].is_enabled}.`);
}

await setRecurring(target, Boolean(target.is_enabled));
rows = await fetchRows(target.user_id, target.recipe_id);
if (rows.length !== 1) {
  throw new Error(`Expected exactly one recurring row after restore, found ${rows.length}.`);
}
if (rows[0].is_enabled !== Boolean(target.is_enabled)) {
  throw new Error(`Expected restored is_enabled=${Boolean(target.is_enabled)}, got ${rows[0].is_enabled}.`);
}

const afterMealPrepSignature = await mealPrepSignature(target.user_id);
if (afterMealPrepSignature !== beforeMealPrepSignature) {
  throw new Error("Recurring toggle changed meal_prep_cycles; it should only touch prep_recurring_recipes.");
}

console.log(JSON.stringify({
  ok: true,
  user_id: target.user_id,
  recipe_id: target.recipe_id,
  recipe_title: target.recipe_title,
  restored_is_enabled: Boolean(target.is_enabled),
}, null, 2));
