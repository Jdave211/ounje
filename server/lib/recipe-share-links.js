import crypto from "node:crypto";
import dotenv from "dotenv";

dotenv.config({ path: new URL("../.env", import.meta.url).pathname });

const SUPABASE_URL = String(process.env.SUPABASE_URL ?? "").trim();
const SUPABASE_SERVICE_ROLE_KEY = String(process.env.SUPABASE_SERVICE_ROLE_KEY ?? "").trim();
const PUBLIC_BASE_URL = String(process.env.OUNJE_PUBLIC_BASE_URL ?? "https://ounje-idbl.onrender.com").replace(/\/+$/, "");

function requireShareLinkConfig() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Recipe share links require Supabase service role configuration.");
  }
}

async function supabaseRequest(pathname, { method = "GET", body = null, headers = {} } = {}) {
  requireShareLinkConfig();
  const response = await fetch(`${SUPABASE_URL}${pathname}`, {
    method,
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      ...headers,
    },
    body: body == null ? undefined : JSON.stringify(body),
  });

  const data = await response.json().catch(() => null);
  if (!response.ok) {
    const message = data?.message ?? data?.error ?? `Supabase request failed (${response.status})`;
    throw new Error(message);
  }
  return data;
}

function stableJSONString(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableJSONString).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJSONString(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function snapshotHash(snapshot) {
  return crypto.createHash("sha256").update(stableJSONString(snapshot)).digest("hex");
}

function generateShareID() {
  return crypto.randomBytes(9).toString("base64url");
}

function shareURLs(shareID) {
  const webURL = `${PUBLIC_BASE_URL}/r/${encodeURIComponent(shareID)}`;
  return {
    url: webURL,
    web_url: webURL,
    app_url: `net.ounje://r/${encodeURIComponent(shareID)}`,
  };
}

async function findReusableShareLink({ recipeID, snapshotHashValue, userID }) {
  const filters = [
    `recipe_id=eq.${encodeURIComponent(recipeID)}`,
    `snapshot_hash=eq.${encodeURIComponent(snapshotHashValue)}`,
    "status=eq.active",
    userID ? `created_by_user_id=eq.${encodeURIComponent(userID)}` : "created_by_user_id=is.null",
    "order=updated_at.desc",
    "limit=1",
  ];
  const rows = await supabaseRequest(
    `/rest/v1/recipe_share_links?select=share_id,recipe_id,recipe_kind,created_by_user_id,snapshot_json,status,created_at,updated_at,snapshot_hash&${filters.join("&")}`
  );
  return Array.isArray(rows) ? rows[0] ?? null : null;
}

async function insertShareLink({ recipeID, recipeKind, userID, snapshot, snapshotHashValue }) {
  const shareID = generateShareID();
  const [row] = await supabaseRequest("/rest/v1/recipe_share_links", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: [{
      share_id: shareID,
      recipe_id: recipeID,
      recipe_kind: recipeKind,
      created_by_user_id: userID || null,
      snapshot_json: snapshot,
      snapshot_hash: snapshotHashValue,
      status: "active",
    }],
  });
  return row;
}

export async function createOrReuseRecipeShareLink({ recipeID, recipeKind, userID = null, snapshot }) {
  const normalizedRecipeID = String(recipeID ?? "").trim();
  if (!normalizedRecipeID) {
    throw new Error("recipe_id is required.");
  }
  const normalizedUserID = String(userID ?? "").trim() || null;
  const normalizedKind = recipeKind === "user_import" ? "user_import" : "public";
  const normalizedSnapshot = snapshot && typeof snapshot === "object" ? snapshot : {};
  const hash = snapshotHash(normalizedSnapshot);

  const reusable = await findReusableShareLink({
    recipeID: normalizedRecipeID,
    snapshotHashValue: hash,
    userID: normalizedUserID,
  });
  const row = reusable ?? await insertShareLink({
    recipeID: normalizedRecipeID,
    recipeKind: normalizedKind,
    userID: normalizedUserID,
    snapshot: normalizedSnapshot,
    snapshotHashValue: hash,
  });

  return {
    share_id: row.share_id,
    recipe_id: row.recipe_id,
    recipe_kind: row.recipe_kind,
    snapshot_json: row.snapshot_json,
    ...shareURLs(row.share_id),
  };
}

export async function resolveRecipeShareLink(shareID) {
  const normalizedID = String(shareID ?? "").trim();
  if (!normalizedID) {
    throw new Error("share_id is required.");
  }
  const rows = await supabaseRequest(
    `/rest/v1/recipe_share_links?select=share_id,recipe_id,recipe_kind,created_by_user_id,snapshot_json,status,created_at,updated_at,snapshot_hash&share_id=eq.${encodeURIComponent(normalizedID)}&status=eq.active&limit=1`
  );
  const row = Array.isArray(rows) ? rows[0] ?? null : null;
  if (!row) {
    return null;
  }
  return {
    ...row,
    ...shareURLs(row.share_id),
  };
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function absoluteURL(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return "";
  try {
    return new URL(raw).toString();
  } catch {
    return "";
  }
}

export function renderRecipeSharePage(link) {
  const snapshot = link?.snapshot_json ?? {};
  const detail = snapshot.recipe_detail ?? {};
  const card = snapshot.recipe_card ?? {};
  const title = String(detail.title ?? card.title ?? "Ounje recipe").trim();
  const description = String(detail.description ?? card.description ?? "Open this recipe in Ounje.").trim();
  const imageURL = absoluteURL(
    detail.hero_image_url
      ?? detail.discover_card_image_url
      ?? card.hero_image_url
      ?? card.discover_card_image_url
  );
  const ingredients = Array.isArray(detail.ingredients) ? detail.ingredients : [];
  const steps = Array.isArray(detail.steps) ? detail.steps : [];
  const appURL = link?.app_url ?? "";
  const webURL = link?.web_url ?? "";

  const ingredientHTML = ingredients.slice(0, 48).map((ingredient) => {
    const name = ingredient.display_name ?? ingredient.name ?? "";
    const quantity = ingredient.quantity_text ?? "";
    return `<li><span>${escapeHTML(name)}</span>${quantity ? `<small>${escapeHTML(quantity)}</small>` : ""}</li>`;
  }).join("");
  const stepHTML = steps.slice(0, 24).map((step, index) => {
    const text = step.text ?? step.instruction_text ?? "";
    return `<li><span>${index + 1}</span><p>${escapeHTML(text)}</p></li>`;
  }).join("");

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHTML(title)} | Ounje</title>
  <meta name="description" content="${escapeHTML(description)}">
  <meta property="og:title" content="${escapeHTML(title)}">
  <meta property="og:description" content="${escapeHTML(description)}">
  <meta property="og:type" content="article">
  <meta property="og:url" content="${escapeHTML(webURL)}">
  ${imageURL ? `<meta property="og:image" content="${escapeHTML(imageURL)}">` : ""}
  <meta name="twitter:card" content="summary_large_image">
  <style>
    :root { color-scheme: dark; background: #101111; color: #f7f3ec; }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #101111; color: #f7f3ec; }
    main { max-width: 860px; margin: 0 auto; padding: 34px 18px 72px; }
    .brand { color: #63d471; font-weight: 800; letter-spacing: .02em; margin-bottom: 22px; }
    .hero { display: grid; gap: 22px; }
    h1 { margin: 0; font-size: clamp(38px, 8vw, 72px); line-height: .92; letter-spacing: -.03em; }
    .summary { color: #b9b4ad; font-size: 17px; line-height: 1.48; max-width: 660px; }
    .media { width: 100%; aspect-ratio: 1.15; border-radius: 22px; overflow: hidden; background: #1f201f; border: 1px solid rgba(255,255,255,.08); }
    .media img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .cta { display: inline-flex; align-items: center; justify-content: center; margin: 26px 0 10px; min-height: 52px; padding: 0 22px; border-radius: 17px; background: #1f6b46; color: white; text-decoration: none; font-weight: 800; }
    section { margin-top: 36px; }
    h2 { font-size: 25px; margin: 0 0 14px; }
    ul, ol { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
    li { border-top: 1px solid rgba(255,255,255,.08); padding: 13px 0; color: #ede8df; }
    li small { display: block; color: #948f88; margin-top: 4px; }
    ol li { display: grid; grid-template-columns: 34px 1fr; gap: 12px; }
    ol span { color: #63d471; font-weight: 800; }
    ol p { margin: 0; color: #d9d3cb; line-height: 1.5; }
    footer { margin-top: 42px; color: #85817b; font-size: 13px; }
  </style>
</head>
<body>
  <main>
    <div class="brand">Ounje</div>
    <div class="hero">
      ${imageURL ? `<div class="media"><img src="${escapeHTML(imageURL)}" alt="${escapeHTML(title)}"></div>` : ""}
      <div>
        <h1>${escapeHTML(title)}</h1>
        ${description ? `<p class="summary">${escapeHTML(description)}</p>` : ""}
        <a class="cta" href="${escapeHTML(appURL)}">Open in Ounje</a>
      </div>
    </div>
    ${ingredientHTML ? `<section><h2>Ingredients</h2><ul>${ingredientHTML}</ul></section>` : ""}
    ${stepHTML ? `<section><h2>Steps</h2><ol>${stepHTML}</ol></section>` : ""}
    <footer>Shared from Ounje.</footer>
  </main>
</body>
</html>`;
}
