import crypto from "node:crypto";
import dotenv from "dotenv";

dotenv.config({ path: new URL("../.env", import.meta.url).pathname });

const SUPABASE_URL = String(process.env.SUPABASE_URL ?? "").trim();
const SUPABASE_SERVICE_ROLE_KEY = String(process.env.SUPABASE_SERVICE_ROLE_KEY ?? "").trim();
const PUBLIC_BASE_URL = String(process.env.OUNJE_PUBLIC_BASE_URL ?? "https://ounje-idbl.onrender.com").replace(/\/+$/, "");
const APP_DOWNLOAD_URL = String(process.env.OUNJE_APP_DOWNLOAD_URL ?? PUBLIC_BASE_URL).trim();

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

function readableSource(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return "";
  const compact = raw.replace(/^@+/, "").replace(/[^A-Za-z0-9]/g, "");
  if (compact && /^\d{8,}$/.test(compact)) return "";
  return raw;
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
  const downloadURL = absoluteURL(APP_DOWNLOAD_URL) || PUBLIC_BASE_URL;
  const source = [
    detail.author_handle,
    detail.author_name,
    card.author_handle,
    card.author_name,
    detail.source_platform,
    detail.source,
  ].map(readableSource).find(Boolean) ?? "";
  const metaPills = [
    detail.cook_time_text,
    detail.servings_text,
    Number.isFinite(Number(detail.calories_kcal)) ? `${Math.round(Number(detail.calories_kcal))} kcal` : null,
  ].filter(Boolean);

  const pillHTML = metaPills.map((pill) => `<span>${escapeHTML(pill)}</span>`).join("");
  const ingredientHTML = ingredients.slice(0, 14).map((ingredient) => {
    const name = ingredient.display_name ?? ingredient.name ?? "";
    const quantity = ingredient.quantity_text ?? "";
    return `<li><span>${escapeHTML(name)}</span>${quantity ? `<small>${escapeHTML(quantity)}</small>` : ""}</li>`;
  }).join("");
  const stepHTML = steps.slice(0, 5).map((step, index) => {
    const text = step.text ?? step.instruction_text ?? "";
    return `<li><span>${index + 1}</span><p>${escapeHTML(text)}</p></li>`;
  }).join("");
  const ingredientOverflow = ingredients.length > 14 ? `<p class="overflow">+${ingredients.length - 14} more ingredients in the app</p>` : "";
  const stepOverflow = steps.length > 5 ? `<p class="overflow">Open in Ounje for the full cook mode.</p>` : "";

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
    :root { color-scheme: dark; background: #080b09; color: #f7f3ec; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: ui-rounded, "SF Pro Rounded", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at 18% 0%, rgba(43, 116, 74, .42), transparent 30%),
        radial-gradient(circle at 95% 10%, rgba(244, 178, 91, .18), transparent 26%),
        #080b09;
      color: #f7f3ec;
    }
    main { width: min(100%, 1040px); margin: 0 auto; padding: 24px 16px 54px; }
    .shell {
      min-height: calc(100svh - 48px);
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(300px, 390px);
      gap: 18px;
      align-items: stretch;
    }
    .card, .panel {
      border: 1px solid rgba(255,255,255,.11);
      background: linear-gradient(180deg, rgba(30,32,30,.96), rgba(13,15,13,.98));
      box-shadow: 0 28px 80px rgba(0,0,0,.38);
    }
    .card { position: relative; overflow: hidden; border-radius: 34px; min-height: 640px; }
    .media { position: absolute; inset: 0; background: #1d1f1d; }
    .media img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .media:after {
      content: "";
      position: absolute;
      inset: 0;
      background: linear-gradient(180deg, rgba(0,0,0,.06), rgba(0,0,0,.18) 36%, rgba(0,0,0,.86));
    }
    .card-copy { position: absolute; inset: auto 22px 22px; }
    .brand { display: inline-flex; align-items: center; gap: 8px; color: #dff6df; font-weight: 900; letter-spacing: .01em; margin-bottom: 14px; }
    .brand:before { content: ""; width: 10px; height: 10px; border-radius: 999px; background: #62d276; box-shadow: 0 0 22px rgba(98,210,118,.95); }
    h1 { margin: 0; font-size: clamp(42px, 9vw, 86px); line-height: .9; letter-spacing: -.055em; text-wrap: balance; }
    .summary { color: #e4ded4; font-size: 17px; line-height: 1.48; max-width: 620px; margin: 14px 0 0; }
    .source { color: #9d988f; margin-top: 14px; font-size: 14px; font-weight: 700; }
    .pills { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 18px; }
    .pills span { border: 1px solid rgba(255,255,255,.14); background: rgba(255,255,255,.1); border-radius: 999px; padding: 8px 11px; color: #f4efe6; font-size: 13px; font-weight: 800; }
    .panel { border-radius: 28px; padding: 20px; align-self: stretch; display: flex; flex-direction: column; }
    .panel h2 { font-size: 22px; margin: 0 0 14px; letter-spacing: -.02em; }
    .panel-copy { color: #aaa49b; line-height: 1.45; margin: 0 0 18px; }
    .actions { display: grid; gap: 10px; margin-bottom: 20px; }
    .cta {
      display: flex; align-items: center; justify-content: center; min-height: 54px; padding: 0 18px;
      border-radius: 18px; color: white; text-decoration: none; font-weight: 900;
    }
    .cta.primary { background: #1f6b46; }
    .cta.secondary { background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.12); }
    section { margin-top: 18px; }
    h3 { font-size: 16px; margin: 0 0 8px; color: #f6f0e8; }
    ul, ol { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
    li { border-top: 1px solid rgba(255,255,255,.08); padding: 10px 0; color: #ede8df; }
    li small { display: block; color: #948f88; margin-top: 3px; }
    ol li { display: grid; grid-template-columns: 28px 1fr; gap: 10px; }
    ol span { color: #63d471; font-weight: 900; }
    ol p { margin: 0; color: #d9d3cb; line-height: 1.42; }
    .overflow { color: #8d877d; font-size: 13px; margin: 10px 0 0; }
    footer { margin-top: auto; padding-top: 18px; color: #77726b; font-size: 12px; }
    @media (max-width: 820px) {
      main { padding: 12px 12px 38px; }
      .shell { grid-template-columns: 1fr; }
      .card { min-height: 72svh; border-radius: 30px; }
      .panel { border-radius: 26px; }
    }
  </style>
</head>
<body>
  <main>
    <div class="shell">
      <article class="card">
        ${imageURL ? `<div class="media"><img src="${escapeHTML(imageURL)}" alt="${escapeHTML(title)}"></div>` : `<div class="media"></div>`}
        <div class="card-copy">
          <div class="brand">Ounje recipe card</div>
          <h1>${escapeHTML(title)}</h1>
          ${description ? `<p class="summary">${escapeHTML(description)}</p>` : ""}
          ${source ? `<div class="source">From ${escapeHTML(source)}</div>` : ""}
          ${pillHTML ? `<div class="pills">${pillHTML}</div>` : ""}
        </div>
      </article>
      <aside class="panel">
        <h2>Cook this in Ounje</h2>
        <p class="panel-copy">Open the recipe in the app for cook mode, prep planning, grocery sync, and AI edits.</p>
        <div class="actions">
          <a class="cta primary" href="${escapeHTML(appURL)}">Open recipe</a>
          <a class="cta secondary" href="${escapeHTML(downloadURL)}">Download Ounje</a>
        </div>
        ${ingredientHTML ? `<section><h3>Ingredients</h3><ul>${ingredientHTML}</ul>${ingredientOverflow}</section>` : ""}
        ${stepHTML ? `<section><h3>Preview steps</h3><ol>${stepHTML}</ol>${stepOverflow}</section>` : ""}
        <footer>Shared from Ounje. Install the app to save or adapt this recipe.</footer>
      </aside>
    </div>
  </main>
</body>
</html>`;
}
