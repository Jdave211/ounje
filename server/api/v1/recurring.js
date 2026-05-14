import express from "express";
import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";
import { getServiceRoleSupabase } from "../../lib/supabase-clients.js";

const router = express.Router();

function getSupabase() {
  return getServiceRoleSupabase();
}

function stripPostgrestOperator(value) {
  return String(value ?? "").trim().replace(/^eq\./, "");
}

function normalizeRecipePayload(input = {}) {
  const recipe = input.recipe && typeof input.recipe === "object" ? input.recipe : null;
  const recipeID = String(input.recipe_id ?? input.recipeID ?? recipe?.id ?? "").trim();
  const userID = String(input.user_id ?? input.userID ?? "").trim();
  const recipeTitle = String(input.recipe_title ?? input.recipeTitle ?? recipe?.title ?? "").trim();
  const isEnabled = Boolean(input.is_enabled ?? input.isEnabled ?? true);

  if (!userID || !recipeID || !recipe || !recipeTitle) {
    return null;
  }

  return {
    user_id: userID,
    recipe_id: recipeID,
    recipe,
    recipe_title: recipeTitle,
    is_enabled: isEnabled,
  };
}

router.get("/recurring", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);

    const supabase = getSupabase();
    const { data, error } = await supabase
      .from("prep_recurring_recipes")
      .select("user_id,recipe_id,recipe,recipe_title,is_enabled,created_at,updated_at")
      .eq("user_id", userID)
      .order("updated_at", { ascending: false });

    if (error) throw error;
    return res.json(data ?? []);
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "recurring/list");
    }
    console.error("[recurring/list] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

router.post("/recurring", async (req, res) => {
  try {
    const rawItems = Array.isArray(req.body) ? req.body : [req.body];
    const normalizedRows = rawItems.map(normalizeRecipePayload).filter(Boolean);
    if (normalizedRows.length === 0) {
      return res.status(400).json({ error: "Recurring recipe payload required" });
    }

    const { userID } = await resolveAuthorizedUserID(req);

    const supabase = getSupabase();
    const rows = normalizedRows.map((row) => ({ ...row, user_id: userID }));
    const { data, error } = await supabase
      .from("prep_recurring_recipes")
      .upsert(rows, { onConflict: "user_id,recipe_id" })
      .select("user_id,recipe_id,recipe,recipe_title,is_enabled,created_at,updated_at");

    if (error) throw error;
    return res.status(201).json(data ?? []);
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "recurring/create");
    }
    console.error("[recurring/create] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

router.delete("/recurring", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const recipeID = stripPostgrestOperator(req.body?.recipe_id ?? req.body?.recipeID ?? req.query.recipe_id ?? req.query.recipeID);

    if (!userID || !recipeID) {
      return res.status(400).json({ error: "User ID and recipe ID required" });
    }

    const supabase = getSupabase();
    const { error } = await supabase
      .from("prep_recurring_recipes")
      .delete()
      .eq("user_id", userID)
      .eq("recipe_id", recipeID);

    if (error) throw error;
    return res.json({ ok: true });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "recurring/delete");
    }
    console.error("[recurring/delete] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

export default router;
