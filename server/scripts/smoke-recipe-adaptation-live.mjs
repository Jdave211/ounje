import assert from "node:assert/strict";

const baseURL = process.env.OUNJE_API_BASE_URL ?? "http://127.0.0.1:3000";
const recipeID = process.env.OUNJE_ADAPT_SMOKE_RECIPE_ID;
const userID = process.env.OUNJE_ADAPT_SMOKE_USER_ID;

if (!recipeID || !userID) {
  console.log("Skipping live adaptation smoke: set OUNJE_ADAPT_SMOKE_RECIPE_ID and OUNJE_ADAPT_SMOKE_USER_ID to run.");
  process.exit(0);
}

const response = await fetch(`${baseURL.replace(/\/$/, "")}/v1/recipe/adapt`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    recipe_id: recipeID,
    user_id: userID,
    intent_key: "vegetarian",
    intent_label: "Make it vegetarian",
    adaptation_prompt: "Make this vegetarian. Remove meat, seafood, gelatin, meat stock, and fish sauce; add a satisfying plant-forward protein or base; update quantities, steps, and tags.",
    reroll_nonce: `smoke-${Date.now()}`,
    strict_edit_validation: true,
  }),
});

const payload = await response.json().catch(() => ({}));
assert.equal(response.ok, true, JSON.stringify(payload));
assert(payload.recipe_id, "expected a persisted adapted recipe id");
assert(
  ["structural_passed", "structural_repaired", "passed", "repaired"].includes(payload.validation_status),
  "expected validation to pass or repair"
);

const haystack = JSON.stringify([
  payload.recipe_detail?.ingredients,
  payload.recipe_detail?.steps,
]).toLowerCase();
assert(!/\bchicken\b/.test(haystack), "vegetarian smoke must not leave chicken in ingredients or steps");

console.log(JSON.stringify({
  ok: true,
  recipe_id: payload.recipe_id,
  validation_status: payload.validation_status,
  title: payload.recipe_detail?.title,
}, null, 2));
