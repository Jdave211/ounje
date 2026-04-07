import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_ROUTES = [
  "https://withjulienne.com/discover",
  "https://withjulienne.com/discover/breakfast",
  "https://withjulienne.com/discover/lunch",
  "https://withjulienne.com/discover/dinner",
  "https://withjulienne.com/discover/dessert",
  "https://withjulienne.com/discover/soup",
  "https://withjulienne.com/discover/pasta",
  "https://withjulienne.com/discover/salad",
  "https://withjulienne.com/discover/sandwich",
  "https://withjulienne.com/discover/chicken",
  "https://withjulienne.com/discover/steak",
  "https://withjulienne.com/discover/fish",
  "https://withjulienne.com/discover/vegetarian",
  "https://withjulienne.com/discover/vegan",
];

function normalizeText(value) {
  return String(value ?? "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeKey(value) {
  return normalizeText(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

async function loadPlaywright() {
  const localPath = "/Users/davejaga/.openclaw/skills/playwright-scraper-skill/node_modules/playwright/index.js";
  try {
    const module = await import(localPath);
    return module.default ?? module;
  } catch {
    const module = await import("playwright");
    return module.default ?? module;
  }
}

async function createBrowserContext({ headless = true } = {}) {
  const playwright = await loadPlaywright();
  const browser = await playwright.chromium.launch({ headless });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1600 },
    locale: "en-US",
    userAgent:
      process.env.USER_AGENT ||
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
  });
  await context.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
  });
  return { browser, context };
}

async function findCardByTitle(page, title) {
  const target = normalizeKey(title);
  if (!target) return null;

  return page.evaluate((needle) => {
    const normalize = (value) =>
      String(value ?? "")
        .replace(/\s+/g, " ")
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, " ")
        .replace(/\s+/g, " ")
        .trim();

    const anchors = Array.from(document.querySelectorAll("a[href]"));
    const scored = anchors
      .map((anchor) => {
        const href = anchor.href || anchor.getAttribute("href") || "";
        if (!/\/recipes\//i.test(href)) return null;

        const text = normalize(anchor.innerText || anchor.textContent || "");
        if (!text) return null;

        let score = 0;
        if (text === needle) score += 1_000_000;
        if (text.includes(needle)) score += 500_000;
        if (needle.includes(text)) score += 250_000;

        const rect = anchor.getBoundingClientRect();
        const visible = rect.bottom > 0 && rect.top < window.innerHeight && rect.width > 0 && rect.height > 0;
        if (visible) score += 10_000;
        score += Math.min(Math.round(rect.width * rect.height), 50_000);

        return { href, text, score };
      })
      .filter(Boolean)
      .sort((a, b) => b.score - a.score);

    return scored[0] ?? null;
  }, target);
}

async function tryClickLoadMore(page) {
  return page.evaluate(() => {
    const buttons = Array.from(document.querySelectorAll("button"));
    const target = buttons.find((button) => /load more/i.test(button.textContent || ""));
    if (!target) return false;
    target.scrollIntoView({ block: "center" });
    target.click();
    return true;
  });
}

async function clickTargetCardByPath(page, recipePath) {
  return page.evaluate((pathToClick) => {
    const normalizePath = (value) => {
      try {
        return new URL(String(value || ""), window.location.origin).pathname;
      } catch {
        return String(value || "");
      }
    };

    const anchors = Array.from(document.querySelectorAll("a[href]"));
    const scored = anchors
      .map((anchor) => {
        const href = anchor.getAttribute("href") || "";
        const pathname = normalizePath(anchor.href || href);
        if (pathname !== pathToClick && href !== pathToClick && !href.endsWith(pathToClick)) return null;

        const rect = anchor.getBoundingClientRect();
        const area = Math.round(rect.width) * Math.round(rect.height);
        const inViewport = rect.bottom > 0 && rect.top < window.innerHeight;
        const isRendered =
          area > 0 &&
          anchor.getClientRects().length > 0 &&
          getComputedStyle(anchor).visibility !== "hidden" &&
          getComputedStyle(anchor).display !== "none";

        return {
          anchor,
          rank: (isRendered ? 1_000_000 : 0) + (inViewport ? 100_000 : 0) + Math.min(area, 99_999),
        };
      })
      .filter(Boolean)
      .sort((a, b) => b.rank - a.rank);

    const chosen = scored[0]?.anchor;
    if (!chosen) return false;
    chosen.scrollIntoView({ block: "center" });
    chosen.click();
    return true;
  }, recipePath);
}

async function searchRoutesForPath(page, recipePath, routes = DEFAULT_ROUTES) {
  for (const route of routes) {
    try {
      await page.goto(route, { waitUntil: "domcontentloaded" });
      await page.waitForTimeout(5000);
    } catch {
      continue;
    }

    for (let i = 0; i < 40; i += 1) {
      const clicked = await clickTargetCardByPath(page, recipePath);
      if (clicked) return true;

      const moreClicked = await tryClickLoadMore(page);
      if (moreClicked) {
        await page.waitForTimeout(2000);
        continue;
      }

      await page.evaluate(() => window.scrollBy({ top: Math.floor(window.innerHeight * 0.85), behavior: "instant" }));
      await page.waitForTimeout(800);
    }
  }

  return false;
}

async function searchRoutesForTitle(page, title, routes = DEFAULT_ROUTES) {
  for (const route of routes) {
    try {
      await page.goto(route, { waitUntil: "domcontentloaded" });
      await page.waitForTimeout(5000);
    } catch {
      continue;
    }

    for (let i = 0; i < 40; i += 1) {
      const matched = await findCardByTitle(page, title);
      if (matched?.href) {
        await page.goto(matched.href, { waitUntil: "domcontentloaded" });
        return true;
      }

      const clicked = await tryClickLoadMore(page);
      if (clicked) {
        await page.waitForTimeout(2000);
        continue;
      }

      await page.evaluate(() => window.scrollBy({ top: Math.floor(window.innerHeight * 0.85), behavior: "instant" }));
      await page.waitForTimeout(800);
    }
  }

  return false;
}

function parseBreadcrumbs() {
  const scripts = Array.from(document.querySelectorAll('script[type="application/ld+json"]'));
  for (const script of scripts) {
    try {
      const parsed = JSON.parse(script.textContent);
      const items = Array.isArray(parsed) ? parsed : [parsed];
      for (const item of items) {
        if (item?.["@type"] !== "BreadcrumbList") continue;
        return (item.itemListElement || []).map((entry) => ({
          position: entry.position || null,
          label: normalizeText(entry.name),
          url: entry.item || null,
        }));
      }
    } catch {
      continue;
    }
  }

  return [];
}

function extractSectionByHeading(headingText) {
  const heading = Array.from(document.querySelectorAll("h2")).find(
    (node) => normalizeText(node.textContent) === headingText
  );
  return heading ? heading.parentElement?.parentElement || heading.parentElement : null;
}

function extractIngredients() {
  const section = extractSectionByHeading("Ingredients");
  const grid = section?.querySelector("div.grid");
  if (!grid) return [];

  return Array.from(grid.children)
    .map((card, index) => {
      const lines = card.innerText
        .split("\n")
        .map((line) => normalizeText(line))
        .filter(Boolean);
      const image = card.querySelector("img");

      return {
        sortOrder: index + 1,
        displayName: lines[0] || null,
        quantityText: lines[1] || null,
        imageUrl: image?.getAttribute("src") || null,
        imageAlt: image?.getAttribute("alt") || null,
      };
    })
    .filter((ingredient) => ingredient.displayName);
}

function extractSteps() {
  const section = extractSectionByHeading("Cooking Steps");
  if (!section) return [];

  const blocks = Array.from(section.children).slice(1);
  const steps = [];

  for (const block of blocks) {
    const instruction = normalizeText(block.querySelector("p")?.textContent);
    if (!instruction) continue;

    const stepNumberText =
      normalizeText(
        Array.from(block.querySelectorAll("div"))
          .map((node) => normalizeText(node.textContent))
          .find((text) => /^\d{1,3}$/.test(text))
      ) || null;

    const tipText =
      Array.from(block.querySelectorAll("p"))
        .map((node) => normalizeText(node.textContent))
        .find((text) => text.startsWith("Tip:")) || null;

    const ingredientRefs = Array.from(block.querySelectorAll("div.flex.flex-wrap > span")).map((chip, index) => {
      const lines = chip.innerText
        .split("\n")
        .map((line) => normalizeText(line))
        .filter(Boolean);
      return {
        sortOrder: index + 1,
        displayName: lines[0] || null,
        quantityText: lines[1] || null,
      };
    });

    steps.push({
      stepNumber: stepNumberText ? parseInt(stepNumberText, 10) : steps.length + 1,
      instructionText: instruction,
      tipText: tipText ? tipText.replace(/^Tip:\s*/i, "") : null,
      ingredientRefs: ingredientRefs.filter((item) => item.displayName),
    });
  }

  return steps;
}

function extractRecipePageData() {
  const normalize = (value) =>
    String(value ?? "")
      .replace(/\s+/g, " ")
      .trim();

  const parseBreadcrumbs = () => {
    const scripts = Array.from(document.querySelectorAll('script[type="application/ld+json"]'));
    for (const script of scripts) {
      try {
        const parsed = JSON.parse(script.textContent);
        const items = Array.isArray(parsed) ? parsed : [parsed];
        for (const item of items) {
          if (item?.["@type"] !== "BreadcrumbList") continue;
          return (item.itemListElement || []).map((entry) => ({
            position: entry.position || null,
            label: normalize(entry.name),
            url: entry.item || null,
          }));
        }
      } catch {
        continue;
      }
    }
    return [];
  };

  const extractSectionByHeading = (headingText) => {
    const heading = Array.from(document.querySelectorAll("h2")).find(
      (node) => normalize(node.textContent) === headingText
    );
    return heading ? heading.parentElement?.parentElement || heading.parentElement : null;
  };

  const extractIngredients = () => {
    const section = extractSectionByHeading("Ingredients");
    const grid = section?.querySelector("div.grid");
    if (!grid) return [];

    return Array.from(grid.children)
      .map((card, index) => {
        const lines = card.innerText
          .split("\n")
          .map((line) => normalize(line))
          .filter(Boolean);
        const image = card.querySelector("img");

        return {
          sortOrder: index + 1,
          displayName: lines[0] || null,
          quantityText: lines[1] || null,
          imageUrl: image?.getAttribute("src") || null,
          imageAlt: image?.getAttribute("alt") || null,
        };
      })
      .filter((ingredient) => ingredient.displayName);
  };

  const extractSteps = () => {
    const section = extractSectionByHeading("Cooking Steps");
    if (!section) return [];

    const blocks = Array.from(section.children).slice(1);
    const steps = [];

    for (const block of blocks) {
      const instruction = normalize(block.querySelector("p")?.textContent);
      if (!instruction) continue;

      const stepNumberText =
        normalize(
          Array.from(block.querySelectorAll("div"))
            .map((node) => normalize(node.textContent))
            .find((text) => /^\d{1,3}$/.test(text))
        ) || null;

      const tipText =
        Array.from(block.querySelectorAll("p"))
          .map((node) => normalize(node.textContent))
          .find((text) => text.startsWith("Tip:")) || null;

      const ingredientRefs = Array.from(block.querySelectorAll("div.flex.flex-wrap > span")).map((chip, index) => {
        const lines = chip.innerText
          .split("\n")
          .map((line) => normalize(line))
          .filter(Boolean);
        return {
          sortOrder: index + 1,
          displayName: lines[0] || null,
          quantityText: lines[1] || null,
        };
      });

      steps.push({
        stepNumber: stepNumberText ? parseInt(stepNumberText, 10) : steps.length + 1,
        instructionText: instruction,
        tipText: tipText ? tipText.replace(/^Tip:\s*/i, "") : null,
        ingredientRefs: ingredientRefs.filter((item) => item.displayName),
      });
    }

    return steps;
  };

  const title = normalize(document.querySelector("h1")?.textContent);
  const authorAnchor = Array.from(document.querySelectorAll("a")).find((node) => normalize(node.textContent).startsWith("@"));
  const originalRecipeAnchor = Array.from(document.querySelectorAll("a")).find(
    (node) => normalize(node.textContent) === "Original Recipe Link"
  );
  const breadcrumbs = parseBreadcrumbs();
  const leafBreadcrumb = breadcrumbs[breadcrumbs.length - 1] || null;
  const heroImage =
    document.querySelector(`img[alt="${CSS.escape(title)}"]`) ||
    Array.from(document.querySelectorAll("img")).find((img) => normalize(img.getAttribute("alt")) === title);
  const originalRecipeUrl = originalRecipeAnchor?.href || null;

  return {
    source: "withjulienne",
    sourceUrl: window.location.href,
    canonicalUrl: originalRecipeUrl || window.location.href,
    siteName: "Julienne",
    authorName: normalize(authorAnchor?.textContent) || null,
    authorHandle: normalize(authorAnchor?.textContent) || null,
    language: "en",
    recipeType: leafBreadcrumb?.label ? leafBreadcrumb.label.replace(/\s+recipes$/i, "").trim() || null : null,
    category: leafBreadcrumb?.label || null,
    subcategory: breadcrumbs[breadcrumbs.length - 2]?.label || null,
    title,
    heroImageUrl: heroImage?.getAttribute("src") || null,
    originalRecipeUrl,
    attachedVideoUrl:
      originalRecipeUrl && /(instagram\.com|tiktok\.com|youtube\.com|youtu\.be|reel|video|shorts)/i.test(originalRecipeUrl)
        ? originalRecipeUrl
        : null,
    breadcrumbs,
    ingredients: extractIngredients(),
    steps: extractSteps(),
  };
}

export async function scrapeJulienneRecipe({ title, recipeUrl = null, headless = true, routes = DEFAULT_ROUTES } = {}) {
  const { browser, context } = await createBrowserContext({ headless });
  const page = await context.newPage();
  page.setDefaultTimeout(45000);
  page.setDefaultNavigationTimeout(60000);

  try {
    const directUrl = recipeUrl && /withjulienne\.com\/.*\/recipes\//i.test(recipeUrl) ? recipeUrl : null;
    const directPath = directUrl ? new URL(directUrl).pathname : null;
    let opened = false;

    if (directPath) {
      opened = await searchRoutesForPath(page, directPath, routes);
    }

    if (!opened) {
      opened = await searchRoutesForTitle(page, title, routes);
    }

    if (!opened) {
      if (!directUrl) {
        throw new Error(`Could not locate Julienne recipe for "${title}"`);
      }
      await page.goto(directUrl, { waitUntil: "domcontentloaded" });
    }

    await page.waitForFunction(() => {
      const h1 = document.querySelector("h1");
      return Boolean(h1 && document.body.innerText.includes("Ingredients"));
    }, { timeout: 30000 });
    await page.waitForTimeout(3000);

    return await page.evaluate(extractRecipePageData);
  } finally {
    await page.close().catch(() => {});
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
  }
}

export { DEFAULT_ROUTES, normalizeKey, normalizeText };
