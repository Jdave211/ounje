import crypto from "node:crypto";
import dotenv from "dotenv";

dotenv.config({ path: new URL("../.env", import.meta.url).pathname });

const SUPABASE_URL = String(process.env.SUPABASE_URL ?? "").trim();
const SUPABASE_SERVICE_ROLE_KEY = String(process.env.SUPABASE_SERVICE_ROLE_KEY ?? "").trim();
const PUBLIC_BASE_URL = String(process.env.OUNJE_PUBLIC_BASE_URL ?? "https://ounje-recipe.vercel.app").replace(/\/+$/, "");

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

function creatorLabel(value) {
  const source = readableSource(value);
  if (!source) return "";
  return `@${source.replace(/^@+/, "")}`;
}

function positiveNumber(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function metricValue(primary, fallback = null, suffix = "") {
  const numeric = positiveNumber(primary);
  if (numeric != null) {
    const rounded = Math.round(numeric * 10) / 10;
    return `${rounded}${suffix}`;
  }
  const text = String(fallback ?? "").trim();
  return text || "&mdash;";
}

function ingredientMonogram(value) {
  const words = String(value ?? "")
    .split(/[^A-Za-z0-9]+/)
    .filter((word) => word.length > 1);
  if (words.length >= 2) return `${words[0][0]}${words[1][0]}`.toUpperCase();
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
  return "OU";
}

function safeJSONForHTML(value) {
  return JSON.stringify(value).replaceAll("<", "\\u003c");
}

export function renderRecipeSharePage(link) {
  const snapshot = link?.snapshot_json ?? {};
  const detail = snapshot.recipe_detail ?? {};
  const card = snapshot.recipe_card ?? {};
  const title = String(detail.title ?? card.title ?? "Ounje recipe").trim();
  const description = String(detail.description ?? card.description ?? "").trim();
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
  const creator = [
    detail.author_handle,
    detail.author_name,
    card.author_handle,
    card.author_name,
  ].map(creatorLabel).find(Boolean) ?? "@ounje";
  const originalURL = [
    detail.original_recipe_url,
    detail.recipe_url,
    card.recipe_url,
  ].map(absoluteURL).find(Boolean) ?? "";

  const servingsCount = positiveNumber(detail.servings_count);
  const servings = servingsCount
    ? String(Math.round(servingsCount))
    : String(detail.servings_text ?? "").trim();
  const metrics = [
    { label: "Cooktime", value: String(detail.cook_time_text ?? "").trim() || "&mdash;" },
    { label: "Serving", value: servings || "&mdash;" },
    { label: "Calories", value: metricValue(detail.calories_kcal, detail.est_calories_text, " kcal") },
    { label: "Protein", value: metricValue(detail.protein_g, detail.protein_text, "g") },
    { label: "Carbs", value: metricValue(detail.carbs_g, detail.carbs_text, "g") },
    { label: "Fats", value: metricValue(detail.fat_g, detail.fats_text, "g") },
    { label: "Type", value: String(detail.recipe_type ?? detail.category ?? detail.subcategory ?? "").trim() || "&mdash;" },
    { label: "Cuisine", value: String(detail.cuisine_tags?.[0] ?? detail.category ?? detail.subcategory ?? "").trim() || "&mdash;" },
    { label: "Source", value: String(detail.source_platform ?? detail.source ?? "Ounje").trim() || "Ounje" },
  ];

  const metricHTML = metrics.map((metric) => `
    <div class="metric">
      <span>${escapeHTML(metric.label)}</span>
      <strong>${metric.value === "&mdash;" ? metric.value : escapeHTML(metric.value)}</strong>
    </div>`).join("");

  const ingredientHTML = ingredients.map((ingredient) => {
    const name = ingredient.display_name ?? ingredient.name ?? "";
    const quantity = ingredient.quantity_text ?? "";
    const ingredientImageURL = absoluteURL(ingredient.image_url ?? ingredient.imageURL ?? "");
    return `<li class="ingredient">
      <div class="ingredient-image">
        <span aria-hidden="true">${escapeHTML(ingredientMonogram(name))}</span>
        ${ingredientImageURL ? `<img src="${escapeHTML(ingredientImageURL)}" alt="" loading="lazy" decoding="async" onerror="this.remove()">` : ""}
      </div>
      <strong>${escapeHTML(name)}</strong>
      ${quantity ? `<small>${escapeHTML(quantity)}</small>` : ""}
    </li>`;
  }).join("");
  const stepHTML = steps.map((step, index) => {
    const text = step.text ?? step.instruction_text ?? "";
    const number = positiveNumber(step.number ?? step.step_number) ?? index + 1;
    const tip = String(step.tip_text ?? step.tipText ?? "").trim();
    return `<li class="step">
      <span class="step-number">${String(Math.round(number)).padStart(2, "0")}</span>
      <div><p>${escapeHTML(text)}</p>${tip ? `<small>${escapeHTML(tip)}</small>` : ""}</div>
    </li>`;
  }).join("");

  const recipeSchema = {
    "@context": "https://schema.org",
    "@type": "Recipe",
    name: title,
    description,
    image: imageURL || undefined,
    author: creator ? { "@type": "Person", name: creator } : undefined,
    recipeYield: servings || undefined,
    recipeIngredient: ingredients.map((ingredient) => {
      const name = ingredient.display_name ?? ingredient.name ?? "";
      const quantity = ingredient.quantity_text ?? "";
      return [quantity, name].filter(Boolean).join(" ");
    }),
    recipeInstructions: steps.map((step, index) => ({
      "@type": "HowToStep",
      position: index + 1,
      text: step.text ?? step.instruction_text ?? "",
    })),
    url: webURL || undefined,
  };

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
  <link rel="icon" href="/favicon.ico">
  <link rel="apple-touch-icon" href="/favicon.ico">
  <link rel="canonical" href="${escapeHTML(webURL)}">
  <script type="application/ld+json">${safeJSONForHTML(recipeSchema)}</script>
  <style>
    @font-face {
      font-family: "Ounje Hand";
      src: url("/recipe-assets/slee-handwriting.otf") format("opentype");
      font-display: swap;
    }
    :root {
      color-scheme: dark;
      background: #121212;
      color: #fff;
      --background: #121212;
      --panel: #1e1e1e;
      --surface: #2e2e2e;
      --cream: #e9e0d2;
      --muted: #8a8a8a;
      --stroke: rgba(255,255,255,.08);
      --accent: #1e5a3e;
    }
    * { box-sizing: border-box; }
    html { background: var(--background); }
    body {
      margin: 0;
      background: var(--background);
      color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
      letter-spacing: 0;
    }
    a { color: inherit; }
    .topbar {
      width: min(100% - 32px, 820px);
      height: 74px;
      margin: 0 auto;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .wordmark {
      font-family: "Ounje Hand", cursive;
      color: var(--cream);
      font-size: 34px;
      line-height: 1;
    }
    .open-app {
      min-height: 40px;
      display: inline-flex;
      align-items: center;
      padding: 0 14px;
      border: 1px solid var(--stroke);
      border-radius: 7px;
      background: var(--panel);
      font-size: 13px;
      font-weight: 700;
      text-decoration: none;
    }
    main {
      width: min(100% - 28px, 820px);
      margin: 0 auto;
      padding-bottom: 80px;
    }
    .hero {
      height: 340px;
      position: relative;
      overflow: hidden;
    }
    .hero-image {
      position: absolute;
      width: 410px;
      height: 410px;
      top: -78px;
      right: -12px;
      border-radius: 50%;
      overflow: hidden;
      background: var(--panel);
      box-shadow: 0 14px 34px rgba(0,0,0,.24);
    }
    .hero-image img { width: 100%; height: 100%; display: block; object-fit: cover; }
    .hero-fallback {
      width: 100%; height: 100%; display: grid; place-items: center;
      color: var(--muted); font-family: "Ounje Hand", cursive; font-size: 34px;
    }
    .intro { max-width: 720px; padding-top: 12px; }
    h1 {
      margin: 0;
      max-width: 760px;
      font-family: "Ounje Hand", cursive;
      font-size: clamp(44px, 9vw, 72px);
      font-weight: 400;
      line-height: .96;
      overflow-wrap: anywhere;
      text-wrap: balance;
    }
    .byline { margin-top: 14px; display: flex; align-items: center; flex-wrap: wrap; gap: 7px; }
    .creator { color: var(--muted); font-size: 15px; font-weight: 500; }
    .original { color: var(--cream); font-size: 15px; text-underline-offset: 3px; }
    .separator { color: var(--muted); }
    .summary { color: var(--muted); font-size: 14px; font-weight: 500; line-height: 1.55; margin: 18px 0 0; max-width: 700px; }
    .section { margin-top: 52px; }
    .section-title {
      color: var(--cream);
      font-family: ui-serif, Georgia, serif;
      font-size: 28px;
      font-weight: 400;
      line-height: 1.15;
      margin: 0 0 18px;
    }
    .metrics {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      border: 1px solid var(--stroke);
    }
    .metric {
      min-height: 94px;
      padding: 16px;
      display: flex;
      flex-direction: column;
      gap: 9px;
      border-right: 1px solid var(--stroke);
      border-bottom: 1px solid var(--stroke);
    }
    .metric:nth-child(3n) { border-right: 0; }
    .metric:nth-last-child(-n + 3) { border-bottom: 0; }
    .metric span { color: var(--muted); font-size: 14px; font-weight: 500; }
    .metric strong { color: #fff; font-size: 16px; font-weight: 600; overflow-wrap: anywhere; }
    .ingredients {
      list-style: none;
      padding: 0;
      margin: 0;
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 28px 18px;
    }
    .ingredient { min-width: 0; }
    .ingredient-image {
      position: relative;
      aspect-ratio: 1;
      overflow: hidden;
      border-radius: 8px;
      background: var(--panel);
      display: grid;
      place-items: center;
      color: var(--cream);
      font-family: "Ounje Hand", cursive;
      font-size: 24px;
    }
    .ingredient-image img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
    .ingredient > strong {
      display: block;
      margin-top: 10px;
      font-family: "Ounje Hand", cursive;
      font-size: 19px;
      font-weight: 400;
      line-height: 1.05;
      overflow-wrap: anywhere;
    }
    .ingredient > small { display: block; color: var(--muted); font-size: 12px; font-weight: 500; line-height: 1.3; margin-top: 5px; }
    .steps { list-style: none; margin: 0; padding: 0; }
    .step {
      display: grid;
      grid-template-columns: 48px minmax(0, 1fr);
      gap: 20px;
      padding: 24px 0;
      border-top: 1px solid var(--stroke);
    }
    .step-number { color: var(--cream); font-family: "Ounje Hand", cursive; font-size: 34px; line-height: 1; }
    .step p { margin: 0; font-size: 18px; line-height: 1.55; }
    .step small { display: block; color: var(--muted); font-size: 14px; font-weight: 500; line-height: 1.45; margin-top: 10px; }
    footer { padding-top: 58px; text-align: center; color: var(--muted); font-size: 12px; }
    @media (max-width: 640px) {
      .topbar { width: calc(100% - 28px); height: 68px; }
      .wordmark { font-size: 30px; }
      .open-app { min-height: 38px; }
      .hero { height: 248px; }
      .hero-image { width: 310px; height: 310px; top: -62px; right: -38px; }
      .intro { padding-top: 8px; }
      h1 { font-size: clamp(42px, 14vw, 62px); line-height: .94; }
      .section { margin-top: 46px; }
      .ingredients { grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 24px 12px; }
      .ingredient > strong { font-size: 16px; }
      .step { grid-template-columns: 42px minmax(0, 1fr); gap: 12px; }
      .step p { font-size: 17px; }
    }
    @media (max-width: 380px) {
      .ingredients { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    }
  </style>
</head>
<body>
  <header class="topbar">
    <span class="wordmark">ounje</span>
    <a class="open-app" href="${escapeHTML(appURL)}">Open in Ounje</a>
  </header>
  <main>
    <div class="hero" aria-hidden="true">
      <div class="hero-image">
        ${imageURL ? `<img src="${escapeHTML(imageURL)}" alt="">` : `<div class="hero-fallback">ounje</div>`}
      </div>
    </div>

    <article>
      <div class="intro">
        <h1>${escapeHTML(title)}</h1>
        <div class="byline">
          <span class="creator">${escapeHTML(creator)}</span>
          ${originalURL ? `<span class="separator">&bull;</span><a class="original" href="${escapeHTML(originalURL)}" rel="noopener noreferrer">See original link</a>` : ""}
        </div>
        ${description ? `<p class="summary">${escapeHTML(description)}</p>` : ""}
      </div>

      <section class="section" aria-labelledby="details-heading">
        <h2 class="section-title" id="details-heading">Details</h2>
        <div class="metrics">${metricHTML}</div>
      </section>

      ${ingredientHTML ? `<section class="section" aria-labelledby="ingredients-heading">
        <h2 class="section-title" id="ingredients-heading">Ingredients</h2>
        <ul class="ingredients">${ingredientHTML}</ul>
      </section>` : ""}

      ${stepHTML ? `<section class="section" aria-labelledby="steps-heading">
        <h2 class="section-title" id="steps-heading">Cooking Steps</h2>
        <ol class="steps">${stepHTML}</ol>
      </section>` : ""}
    </article>

    <footer>Shared from Ounje</footer>
  </main>
</body>
</html>`;
}
