#!/usr/bin/env node
import fs from "fs";
import { chromium } from "playwright";

const sessionStorePath = "/Users/davejaga/Desktop/startups/ounje/server/.sessions/provider-accounts.json";
const store = JSON.parse(fs.readFileSync(sessionStorePath, "utf8"));
const record = [...(store.records ?? [])].reverse().find((r) => r.provider === "instacart" && r.sessionCookies);

if (!record) {
  throw new Error("No saved Instacart session found");
}

const cookies = JSON.parse(record.sessionCookies);
const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const context = await browser.newContext({ viewport: { width: 1440, height: 1600 } });

await context.addCookies(
  cookies.map((cookie) => ({
    name: cookie.name,
    value: cookie.value,
    domain: cookie.domain,
    path: cookie.path ?? "/",
    expires: typeof cookie.expires === "number" ? cookie.expires : undefined,
    secure: Boolean(cookie.secure),
    httpOnly: Boolean(cookie.httpOnly),
    sameSite: cookie.sameSite,
  }))
);

const page = await context.newPage();

const INITIAL_URLS = [
  "https://www.instacart.ca/store/cart",
  "https://www.instacart.ca/store",
];

function normalizeStorefrontUrl(raw) {
  if (!raw) return null;
  try {
    const url = new URL(raw, "https://www.instacart.ca");
    if (!/instacart\.ca$/i.test(url.hostname)) return null;
    const match = url.pathname.match(/^\/store\/([^/?#]+)(?:\/storefront)?/i);
    if (!match) return null;
    return `https://www.instacart.ca/store/${match[1]}/storefront`;
  } catch {
    return null;
  }
}

async function extractStorefrontUrls() {
  return await page.evaluate(() => {
    return [...document.querySelectorAll("a[href]")]
      .map((anchor) => anchor.getAttribute("href"))
      .filter(Boolean);
  }).then((hrefs) => {
    return [...new Set(hrefs.map(normalizeStorefrontUrl).filter(Boolean))];
  }).catch(() => []);
}

async function openVisibleCart() {
  const alreadyOpen = await page.evaluate(() => {
    return /Personal .* Cart/i.test(document.body?.innerText || "");
  }).catch(() => false);
  if (alreadyOpen) return true;

  const clickedViaDom = await page.evaluate(() => {
    const buttons = [...document.querySelectorAll("button")];
    const byPriority = [
      (button) => /View Cart/i.test(button.getAttribute("aria-label") ?? ""),
      (button) => /Go to checkout/i.test(button.getAttribute("aria-label") ?? ""),
      (button) => /Checkout/i.test((button.innerText || "").trim()),
    ];

    for (const matcher of byPriority) {
      const match = buttons.find((button) => matcher(button));
      if (match) {
        match.click();
        return true;
      }
    }

    return false;
  }).catch(() => false);

  if (clickedViaDom) {
    await page.waitForTimeout(1800);
    const opened = await page.evaluate(() => /Personal .* Cart/i.test(document.body?.innerText || "")).catch(() => false);
    if (opened) return true;
  }

  const candidates = [
    page.getByRole("button", { name: /View Cart/i }).first(),
    page.getByRole("button", { name: /Go to checkout/i }).first(),
    page.getByText(/Personal .* Cart/i).first(),
  ];

  for (const locator of candidates) {
    if (await locator.count().catch(() => 0)) {
      await locator.click({ timeout: 5000 }).catch(() => {});
      await page.waitForTimeout(1800);
      const opened = await page.evaluate(() => /Personal .* Cart/i.test(document.body?.innerText || "")).catch(() => false);
      if (opened) return true;
    }
  }

  return await page.evaluate(() => /Personal .* Cart/i.test(document.body?.innerText || "")).catch(() => false);
}

async function readCartSnapshot() {
  const finalCartLabel = await page.getByRole("button", { name: /View Cart/i }).first().getAttribute("aria-label").catch(() => null);
  const bodyText = await page.locator("body").innerText({ timeout: 10000 }).catch(() => "");
  const cartTitles = [
    ...new Set(
      bodyText
        .split(/\r?\n+/)
        .map((line) => line.trim())
        .filter((line) => /cart/i.test(line) && line.length < 160)
      .slice(0, 12)
    ),
  ];

  const activeStoreCart = bodyText
    .split(/\r?\n+/)
    .map((line) => line.trim())
    .find((line) => /^Personal .* Cart$/i.test(line)) ?? null;

  const zeroSubtotal = /Item subtotal\s*\n?\$0\.00/i.test(bodyText) || /Item subtotal\s+\$0\.00/i.test(bodyText);

  const removableButtons = await page.evaluate(() => {
    const isVisible = (element) => {
      const style = window.getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
    };

    return [...document.querySelectorAll("button")]
      .filter((button) => isVisible(button) && !button.disabled)
      .map((button) => ({
        aria: button.getAttribute("aria-label") ?? "",
        title: button.getAttribute("title") ?? "",
        text: (button.innerText || "").replace(/\s+/g, " ").trim(),
      }))
      .filter((entry) =>
        /^Remove /i.test(entry.aria) ||
        /^Delete /i.test(entry.aria) ||
        /^Decrement quantity/i.test(entry.aria) ||
        /^Decrease quantity/i.test(entry.aria) ||
        /^Remove /i.test(entry.title) ||
        /^Delete /i.test(entry.title) ||
        entry.text === "−" ||
        entry.text === "-"
      )
      .slice(0, 40);
  }).catch(() => []);

  return {
    url: page.url(),
    finalCartLabel,
    bodyText,
    cartTitles,
    activeStoreCart,
    zeroSubtotal,
    removableButtons,
  };
}

async function removeCartItemsBurst(limit = 10) {
  return await page.evaluate((burstLimit) => {
    const isVisible = (element) => {
      const style = window.getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
    };

    const scored = [...document.querySelectorAll("button")]
      .filter((button) => isVisible(button) && !button.disabled)
      .map((button) => {
        const aria = button.getAttribute("aria-label") ?? "";
        const title = button.getAttribute("title") ?? "";
        const text = (button.innerText || "").replace(/\s+/g, " ").trim();
        let score = -1;

        if (/^Remove /i.test(aria) || /^Delete /i.test(aria) || /^Remove /i.test(title) || /^Delete /i.test(title)) score = 100;
        else if (/^Decrement quantity/i.test(aria) || /^Decrease quantity/i.test(aria)) score = 90;
        else if (text === "−" || text === "-") score = 60;

        return { button, score, aria, title, text };
      })
      .filter((entry) => entry.score >= 0)
      .sort((a, b) => b.score - a.score);

    const chosen = scored.slice(0, burstLimit);
    const labels = [];

    chosen.forEach((target) => {
      const label = target.aria || target.title || target.text || "unnamed-button";
      target.button.click();
      labels.push(label);
    });

    return labels;
  }, limit);
}

async function clearCurrentSurface(label) {
  const rounds = [];

  for (let round = 0; round < 80; round += 1) {
    const snapshot = await readCartSnapshot();
    const clicked = await removeCartItemsBurst();
    rounds.push({
      round,
      label,
      url: snapshot.url,
      finalCartLabel: snapshot.finalCartLabel,
      cartTitles: snapshot.cartTitles,
      activeStoreCart: snapshot.activeStoreCart,
      zeroSubtotal: snapshot.zeroSubtotal,
      removableButtons: snapshot.removableButtons.length,
      clicked: clicked.length ? clicked : ["none"],
    });
    console.log(`surface=${label} round=${round} cart=${snapshot.finalCartLabel} active=${snapshot.activeStoreCart ?? "none"} subtotal0=${snapshot.zeroSubtotal} titles=${snapshot.cartTitles.join(" | ") || "none"} controls=${snapshot.removableButtons.length} clicked=${clicked.length ? clicked.join(" || ") : "none"}`);
    if (!clicked.length) break;
    await page.waitForTimeout(1800);
    await page.reload({ waitUntil: "domcontentloaded", timeout: 30000 }).catch(() => {});
    await page.waitForTimeout(1800);
    await openVisibleCart();
  }

  return rounds;
}

const discoveredUrls = new Set();
const queue = [...INITIAL_URLS];
const visited = [];
const clearLog = [];

try {
  while (queue.length > 0 && discoveredUrls.size < 25) {
    const nextUrl = queue.shift();
    const normalizedUrl = nextUrl.startsWith("http") ? nextUrl : normalizeStorefrontUrl(nextUrl) ?? nextUrl;
    if (!normalizedUrl || discoveredUrls.has(normalizedUrl)) continue;
    discoveredUrls.add(normalizedUrl);

    console.log(`discover visiting=${normalizedUrl}`);
    await page.goto(normalizedUrl, { waitUntil: "domcontentloaded", timeout: 30000 }).catch(() => {});
    await page.waitForTimeout(2500);
    console.log(`discover landed=${page.url()}`);
    await openVisibleCart();

    const snapshot = await readCartSnapshot();
    const storefrontUrls = await extractStorefrontUrls();
    console.log(`discover snapshot url=${snapshot.url} titles=${snapshot.cartTitles.join(" | ") || "none"} controls=${snapshot.removableButtons.length} discovered=${storefrontUrls.length}`);
    storefrontUrls.forEach((url) => {
      if (!discoveredUrls.has(url) && !queue.includes(url)) queue.push(url);
    });

    visited.push({
      url: page.url(),
      requestedUrl: normalizedUrl,
      cartTitles: snapshot.cartTitles,
      activeStoreCart: snapshot.activeStoreCart,
      zeroSubtotal: snapshot.zeroSubtotal,
      finalCartLabel: snapshot.finalCartLabel,
      removableButtons: snapshot.removableButtons.length,
      discoveredStorefronts: storefrontUrls,
    });

    if (snapshot.removableButtons.length > 0) {
      const label = snapshot.cartTitles[0] || normalizedUrl;
      const rounds = await clearCurrentSurface(label);
      clearLog.push(...rounds);
    }
  }

  await page.goto("https://www.instacart.ca/store/cart", { waitUntil: "domcontentloaded", timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(2000);
  console.log(`final-check landed=${page.url()}`);
  await openVisibleCart();
  const finalSnapshot = await readCartSnapshot();

  console.log(JSON.stringify({
    success:
      /Items in cart: 0/i.test(finalSnapshot.finalCartLabel ?? "") ||
      /Your cart is empty/i.test(finalSnapshot.bodyText) ||
      finalSnapshot.zeroSubtotal ||
      finalSnapshot.removableButtons.length === 0,
    finalCartLabel: finalSnapshot.finalCartLabel,
    finalCartTitles: finalSnapshot.cartTitles,
    finalZeroSubtotal: finalSnapshot.zeroSubtotal,
    finalRemovableButtons: finalSnapshot.removableButtons,
    visited,
    clearLog,
    sessionSource: record?.loginStatus ?? null,
  }, null, 2));
} finally {
  await browser.close().catch(() => {});
}
