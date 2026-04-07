#!/usr/bin/env node

import { chromium } from "playwright";
import { loadPreferredProviderSession } from "../lib/provider-session-store.js";

function toPlaywrightCookies(cookies) {
  return (cookies ?? []).map((cookie) => ({
    name: cookie.name,
    value: cookie.value,
    domain: cookie.domain,
    path: cookie.path ?? "/",
    expires: typeof cookie.expires === "number" ? cookie.expires : undefined,
    secure: Boolean(cookie.secure),
    httpOnly: Boolean(cookie.httpOnly),
    sameSite: cookie.sameSite,
  }));
}

async function dumpRelevantButtons(page, label) {
  const buttons = await page.locator("button").evaluateAll((nodes, needle) =>
    nodes
      .map((node, index) => {
        const text = (node.innerText || "").replace(/\s+/g, " ").trim();
        const aria = node.getAttribute("aria-label") || "";
        const parent = (node.parentElement?.innerText || "").replace(/\s+/g, " ").trim();
        return {
          index,
          text,
          aria,
          parent: parent.slice(0, 280),
        };
      })
      .filter((entry) => {
        const haystack = `${entry.text} ${entry.aria} ${entry.parent}`;
        return new RegExp(needle, "i").test(haystack) || /increase|remove|view cart|\+|−|-/.test(haystack);
      }),
  label);

  console.log(JSON.stringify(buttons, null, 2));
}

async function main() {
  const session = await loadPreferredProviderSession("instacart");
  if (!session?.cookies?.length) {
    throw new Error("No saved Instacart session available");
  }

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1100 },
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
  });
  await context.addCookies(toPlaywrightCookies(session.cookies));
  const page = await context.newPage();

  try {
    await page.goto("https://www.instacart.ca/store/metro/s?k=chicken", {
      waitUntil: "domcontentloaded",
      timeout: 30000,
    });
    await page.waitForTimeout(3000);

    const addButton = page
      .locator('button[aria-label*="Boneless Skinless Chicken Breast"], button[aria-label*="Chicken Breast"]')
      .filter({ hasText: /Add/i })
      .first();

    const addCount = await addButton.count().catch(() => 0);
    console.log(`addButtonCount=${addCount}`);
    if (addCount) {
      const label = await addButton.getAttribute("aria-label").catch(() => "") ?? "";
      console.log(`clicking=${label}`);
      await addButton.click({ timeout: 5000 });
      await page.waitForTimeout(3000);
    }

    console.log("searchPageButtons");
    await dumpRelevantButtons(page, "Boneless Skinless Chicken Breast|Chicken Breast|View Cart");

    const cartButton = page
      .locator('button[aria-label*="View Cart"], button:has-text("View Cart"), a[aria-label*="View Cart"]')
      .first();
    const cartCount = await cartButton.count().catch(() => 0);
    console.log(`viewCartButtonCount=${cartCount}`);
    if (cartCount) {
      await cartButton.click({ timeout: 5000 }).catch(() => {});
      await page.waitForTimeout(3000);
      console.log(`afterCartClickUrl=${page.url()}`);
      console.log("cartSurfaceButtons");
      await dumpRelevantButtons(page, "Boneless Skinless Chicken Breast|Chicken Breast|View Cart");
      const bodyText = await page.locator("body").innerText().catch(() => "");
      const lines = String(bodyText)
        .split(/\n+/)
        .map((line) => line.trim())
        .filter(Boolean);
      const idx = lines.findIndex((line) => /Boneless Skinless Chicken Breast/i.test(line));
      console.log("cartLines");
      console.log(lines.slice(Math.max(0, idx - 5), idx + 15));
    }
  } finally {
    await browser.close().catch(() => {});
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
