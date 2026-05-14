import { chromium } from "playwright";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { loadProviderSession } from "./provider-session-store.js";
import { buildPlaywrightLaunchOptions } from "./playwright-runtime.js";
import { installCaptchaHooksScript, maybeSolveCaptcha } from "./twocaptcha.js";
import { createNotificationEvent } from "./notification-events.js";
import { createLoggedOpenAI } from "./openai-usage-logger.js";
import { getServiceRoleSupabase } from "./supabase-clients.js";

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const INSTACART_TRACKER_MODEL = process.env.INSTACART_TRACKER_MODEL ?? "gpt-5-nano";
const INSTACART_TRACKING_ARTIFACT_DIR = process.env.INSTACART_TRACKING_ARTIFACT_DIR
  ?? path.resolve(process.cwd(), "server/logs/instacart-tracking");

const openai = OPENAI_API_KEY ? createLoggedOpenAI({ apiKey: OPENAI_API_KEY, service: "instacart-order-tracker" }) : null;

function getSupabase() {
  return getServiceRoleSupabase();
}

function normalizeText(value) {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

function toPlaywrightCookies(cookies = []) {
  return cookies
    .map((cookie) => {
      const domain = normalizeText(cookie.domain || cookie.host || ".instacart.ca");
      const pathValue = normalizeText(cookie.path || "/") || "/";
      const name = normalizeText(cookie.name);
      const value = String(cookie.value ?? "");
      if (!name || !domain) return null;
      const expires = Number(cookie.expirationDate ?? cookie.expires ?? 0);
      return {
        name,
        value,
        domain,
        path: pathValue,
        expires: Number.isFinite(expires) && expires > 0 ? expires : -1,
        httpOnly: Boolean(cookie.httpOnly),
        secure: cookie.secure !== false,
        sameSite: "Lax",
      };
    })
    .filter(Boolean);
}

function buildTrackingURLs(order) {
  const directURLs = [
    order?.provider_tracking_url,
    order?.provider_checkout_url,
    order?.provider_cart_url,
    "https://www.instacart.ca/store/account/orders",
    "https://www.instacart.ca/store/orders",
    "https://www.instacart.ca/accounts/orders",
  ]
    .map((value) => normalizeText(value))
    .filter(Boolean);

  return [...new Set(directURLs)];
}

function heuristicTrackingSnapshot(rawText, imageURLs = [], currentUrl = "") {
  const text = normalizeText(rawText).toLowerCase();

  const imageUrl = imageURLs.find((value) => /^https?:\/\//i.test(value)) ?? null;
  const trackingUrl = /^https?:\/\//i.test(currentUrl) ? currentUrl : null;

  if (!text) {
    return {
      status: "unknown",
      title: "Waiting for Instacart update",
      detail: "We could not read a live status from the order page yet.",
      etaText: null,
      imageUrl,
      trackingUrl,
    };
  }

  if (text.includes("delivered") || text.includes("left at your door")) {
    return {
      status: "delivered",
      title: "Delivered",
      detail: "Your Instacart order has been delivered.",
      etaText: null,
      imageUrl,
      trackingUrl,
    };
  }

  if (text.includes("out for delivery") || text.includes("on the way") || text.includes("arriving soon")) {
    return {
      status: "out_for_delivery",
      title: "Out for delivery",
      detail: "Your order is on the way.",
      etaText: null,
      imageUrl,
      trackingUrl,
    };
  }

  if (text.includes("shopping") || text.includes("shopper") || text.includes("picking")) {
    return {
      status: "shopping",
      title: "Shopping in progress",
      detail: "Instacart is still picking items for this order.",
      etaText: null,
      imageUrl,
      trackingUrl,
    };
  }

  if (
    text.includes("problem") ||
    text.includes("issue") ||
    text.includes("delayed") ||
    text.includes("unable") ||
    text.includes("contact support") ||
    text.includes("reschedule")
  ) {
    return {
      status: "issue",
      title: "There’s a delivery hiccup",
      detail: "Instacart flagged a problem with this order.",
      etaText: null,
      imageUrl,
      trackingUrl,
    };
  }

  return {
    status: "submitted",
    title: "Order placed",
    detail: "Instacart has your order and is preparing the next step.",
    etaText: null,
    imageUrl,
    trackingUrl,
  };
}

async function parseTrackingSnapshotWithLLM({ rawText, imageURLs, currentUrl, screenshotPath }) {
  if (!openai) {
    return heuristicTrackingSnapshot(rawText, imageURLs, currentUrl);
  }

  const prompt = [
    "You are extracting the latest Instacart delivery state from a scraped account/order page.",
    "Return strict JSON only with keys: status, title, detail, etaText, imageUrl, trackingUrl.",
    "Allowed status values: submitted, shopping, out_for_delivery, delivered, issue, unknown.",
    "Prefer concise user-facing title/detail. If there is a visible delivery ETA, place it in etaText.",
    "If there is no usable imageUrl or trackingUrl, return null.",
    "Choose imageUrl only from the provided candidate image URLs.",
    "Do not invent facts that are not present in the page text.",
    "",
    `Current URL: ${currentUrl || "none"}`,
    `Screenshot path: ${screenshotPath || "none"}`,
    `Candidate image URLs: ${JSON.stringify(imageURLs.slice(0, 24))}`,
    "",
    "Visible page text:",
    rawText.slice(0, 12000),
  ].join("\n");

  try {
    const response = await openai.responses.create({
      model: INSTACART_TRACKER_MODEL,
      input: prompt,
    });

    const outputText = normalizeText(response.output_text ?? "");
    const parsed = JSON.parse(outputText);
    return {
      status: normalizeText(parsed.status).toLowerCase() || "unknown",
      title: normalizeText(parsed.title) || "Instacart update",
      detail: normalizeText(parsed.detail) || "There is a fresh update on your order.",
      etaText: normalizeText(parsed.etaText) || null,
      imageUrl: normalizeText(parsed.imageUrl) || null,
      trackingUrl: normalizeText(parsed.trackingUrl) || currentUrl || null,
    };
  } catch {
    return heuristicTrackingSnapshot(rawText, imageURLs, currentUrl);
  }
}

async function persistTrackingArtifacts({ orderId, page, rawText, trackingUrl }) {
  await mkdir(INSTACART_TRACKING_ARTIFACT_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const baseName = `${orderId}__${stamp}`;
  const screenshotPath = path.join(INSTACART_TRACKING_ARTIFACT_DIR, `${baseName}.png`);
  const textPath = path.join(INSTACART_TRACKING_ARTIFACT_DIR, `${baseName}.txt`);
  await page.screenshot({ path: screenshotPath, fullPage: true }).catch(() => {});
  await writeFile(textPath, `${trackingUrl}\n\n${rawText}`, "utf8");
  return { screenshotPath, textPath };
}

function buildNotificationFromTracking({ order, tracking }) {
  const orderId = order.id;
  const base = {
    userId: order.user_id,
    orderId,
    imageUrl: tracking.imageUrl,
    actionUrl: tracking.trackingUrl ?? order.provider_tracking_url ?? order.provider_checkout_url ?? null,
    actionLabel: "Open Instacart",
    metadata: {
      provider: order.provider,
      trackingStatus: tracking.status,
      etaText: tracking.etaText,
    },
  };

  switch (tracking.status) {
    case "shopping":
      return {
        ...base,
        kind: "grocery_delivery_update",
        dedupeKey: `grocery-tracking-${orderId}-shopping-${normalizeText(tracking.etaText).toLowerCase() || "live"}`,
        title: tracking.title || "Instacart is shopping your order",
        body: tracking.detail || "Your shopper is working through your cart now.",
      };
    case "out_for_delivery":
      return {
        ...base,
        kind: "grocery_delivery_update",
        dedupeKey: `grocery-tracking-${orderId}-out-for-delivery-${normalizeText(tracking.etaText).toLowerCase() || "live"}`,
        title: tracking.title || "Your groceries are on the way",
        body: tracking.detail || "Instacart is heading to your address now.",
      };
    case "delivered":
      return {
        ...base,
        kind: "grocery_delivery_arrived",
        dedupeKey: `grocery-tracking-${orderId}-delivered`,
        title: tracking.title || "Groceries delivered",
        body: tracking.detail || "Your Instacart order has arrived.",
      };
    case "issue":
      return {
        ...base,
        kind: "grocery_issue",
        dedupeKey: `grocery-tracking-${orderId}-issue-${normalizeText(tracking.detail).toLowerCase() || "live"}`,
        title: tracking.title || "Instacart needs attention",
        body: tracking.detail || "There is a problem with your order.",
      };
    default:
      return null;
  }
}

async function updateOrderTrackingState({ order, tracking, rawText, artifactPaths }) {
  const supabase = getSupabase();
  const stepLogEntry = {
    status: order.status,
    trackingStatus: tracking.status,
    trackingTitle: tracking.title,
    trackingDetail: tracking.detail,
    trackingEtaText: tracking.etaText,
    trackingImageUrl: tracking.imageUrl,
    trackingUrl: tracking.trackingUrl,
    at: new Date().toISOString(),
    artifactPaths,
  };

  const updatePayload = {
    provider_tracking_url: tracking.trackingUrl ?? order.provider_tracking_url ?? null,
    tracking_status: tracking.status,
    tracking_title: tracking.title,
    tracking_detail: tracking.detail,
    tracking_eta_text: tracking.etaText,
    tracking_image_url: tracking.imageUrl,
    tracking_payload: {
      rawTextPreview: rawText.slice(0, 3000),
      artifactPaths,
    },
    tracking_started_at: order.tracking_started_at ?? new Date().toISOString(),
    last_tracked_at: new Date().toISOString(),
  };

  const { data: currentOrder } = await supabase
    .from("grocery_orders")
    .select("step_log")
    .eq("id", order.id)
    .single();

  updatePayload.step_log = [
    ...(Array.isArray(currentOrder?.step_log) ? currentOrder.step_log : []),
    stepLogEntry,
  ];

  if (tracking.status === "delivered") {
    updatePayload.delivered_at = new Date().toISOString();
  }

  const { error } = await supabase
    .from("grocery_orders")
    .update(updatePayload)
    .eq("id", order.id);

  if (error) {
    throw error;
  }
}

async function loadOrder(orderId) {
  const supabase = getSupabase();
  const { data, error } = await supabase
    .from("grocery_orders")
    .select("*")
    .eq("id", orderId)
    .single();

  if (error) {
    throw error;
  }

  return data;
}

export async function trackInstacartOrder({
  orderId,
  accessToken = null,
  headless = true,
  logger = console,
}) {
  const order = await loadOrder(orderId);
  if (!order) {
    throw new Error("Order not found");
  }
  if (String(order.provider ?? "").trim().toLowerCase() !== "instacart") {
    throw new Error("Only Instacart tracking is supported right now");
  }

  const session = await loadProviderSession({
    userId: order.user_id,
    provider: "instacart",
    accessToken,
  });
  if (!session?.cookies?.length) {
    throw new Error("No connected Instacart session found for tracking");
  }

  const browser = await chromium.launch(buildPlaywrightLaunchOptions({
    headless,
    args: [
      "--disable-blink-features=AutomationControlled",
    ],
  }));

  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
  });

  await context.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
  });
  await context.addInitScript(installCaptchaHooksScript());
  await context.addCookies(toPlaywrightCookies(session.cookies));

  const page = await context.newPage();

  try {
    let visitedUrl = null;
    let rawText = "";
    let imageURLs = [];

    for (const url of buildTrackingURLs(order)) {
      try {
        logger.log?.(`[instacart-tracker] opening ${url}`);
        await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30000 });
        await page.waitForTimeout(2200);
        await maybeSolveCaptcha(page, { logger }).catch(() => {});
        rawText = await page.locator("body").innerText().catch(() => "");
        imageURLs = await page.$$eval("img", (images) => images.map((img) => img.src).filter(Boolean).slice(0, 30)).catch(() => []);
        visitedUrl = page.url();

        if (normalizeText(rawText).length > 80) {
          break;
        }
      } catch {
        continue;
      }
    }

    const artifactPaths = await persistTrackingArtifacts({
      orderId,
      page,
      rawText,
      trackingUrl: visitedUrl ?? "",
    });

    const tracking = await parseTrackingSnapshotWithLLM({
      rawText,
      imageURLs,
      currentUrl: visitedUrl ?? "",
      screenshotPath: artifactPaths.screenshotPath,
    });

    await updateOrderTrackingState({
      order,
      tracking,
      rawText,
      artifactPaths,
    });

    const notification = buildNotificationFromTracking({ order, tracking });
    if (notification) {
      await createNotificationEvent(notification).catch(() => {});
    }

    return {
      orderId,
      provider: "instacart",
      trackingStatus: tracking.status,
      trackingTitle: tracking.title,
      trackingDetail: tracking.detail,
      trackingEtaText: tracking.etaText,
      trackingImageUrl: tracking.imageUrl,
      trackingUrl: tracking.trackingUrl,
      artifactPaths,
    };
  } finally {
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
  }
}
