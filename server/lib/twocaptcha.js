import fs from "node:fs";
import path from "node:path";
import dotenv from "dotenv";

const envPath = path.resolve(process.cwd(), "server/.env");
if (fs.existsSync(envPath)) {
  dotenv.config({ path: envPath, override: false });
}

const TWO_CAPTCHA_API_KEY = process.env.TWOCAPTCHA_API_KEY
  ?? process.env.TWO_CAPTCHA_API_KEY
  ?? process.env.CAPTCHA_2CAPTCHA_API_KEY
  ?? "";

const TWO_CAPTCHA_BASE = "https://api.2captcha.com";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function hasApiKey() {
  return Boolean(TWO_CAPTCHA_API_KEY.trim());
}

async function createTask(task) {
  const resp = await fetch(`${TWO_CAPTCHA_BASE}/createTask`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      clientKey: TWO_CAPTCHA_API_KEY,
      task,
    }),
  });

  if (!resp.ok) {
    const text = await resp.text().catch(() => resp.statusText);
    throw new Error(`2captcha createTask ${resp.status}: ${text}`);
  }

  const payload = await resp.json();
  if (payload.errorId && payload.errorId !== 0) {
    throw new Error(`2captcha createTask error ${payload.errorId}: ${payload.errorCode ?? payload.errorDescription ?? "unknown"}`);
  }

  return payload.taskId;
}

async function getTaskResult(taskId) {
  const resp = await fetch(`${TWO_CAPTCHA_BASE}/getTaskResult`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      clientKey: TWO_CAPTCHA_API_KEY,
      taskId,
    }),
  });

  if (!resp.ok) {
    const text = await resp.text().catch(() => resp.statusText);
    throw new Error(`2captcha getTaskResult ${resp.status}: ${text}`);
  }

  return await resp.json();
}

async function pollTask(taskId, { timeoutMs = 180_000, intervalMs = 5_000 } = {}) {
  const startedAt = Date.now();

  while (Date.now() - startedAt < timeoutMs) {
    const payload = await getTaskResult(taskId);
    if (payload.errorId && payload.errorId !== 0) {
      throw new Error(`2captcha task ${taskId} failed: ${payload.errorCode ?? payload.errorDescription ?? "unknown"}`);
    }

    if (payload.status === "ready") {
      return payload.solution ?? {};
    }

    await sleep(intervalMs);
  }

  throw new Error(`2captcha task ${taskId} timed out after ${timeoutMs}ms`);
}

function normalizeString(value) {
  return String(value ?? "").trim();
}

async function injectToken(page, { token, callbackName = null, fieldNames = [] }) {
  await page.evaluate(({ token, callbackName, fieldNames }) => {
    const fireEvents = (element) => {
      if (!element) return;
      element.dispatchEvent(new Event("input", { bubbles: true }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
    };

    const setValue = (selector, value) => {
      const element = document.querySelector(selector);
      if (!element) return false;
      element.value = value;
      fireEvents(element);
      return true;
    };

    for (const selector of fieldNames) {
      setValue(selector, token);
    }

    const hiddenInputs = [
      'textarea[name="g-recaptcha-response"]',
      'input[name="g-recaptcha-response"]',
      'textarea[name="cf-turnstile-response"]',
      'input[name="cf-turnstile-response"]',
    ];
    hiddenInputs.forEach((selector) => setValue(selector, token));

    if (callbackName && typeof window[callbackName] === "function") {
      try {
        window[callbackName](token);
      } catch {
        // Ignore callback errors; hidden inputs are the main fallback.
      }
    }
  }, { token, callbackName, fieldNames });
}

function extractRecordedChallenge(records, preferredType = null) {
  const normalized = Array.isArray(records) ? records : [];
  const filtered = preferredType ? normalized.filter((entry) => entry?.type === preferredType) : normalized;
  return filtered.find((entry) => normalizeString(entry?.sitekey)) ?? normalized.find((entry) => normalizeString(entry?.sitekey)) ?? null;
}

async function readCaptchaContext(page) {
  return await page.evaluate(() => {
    const sanitize = (value) => String(value ?? "").trim() || null;
    const challengeRecords = Array.isArray(window.__ounjeCaptchaChallenges) ? window.__ounjeCaptchaChallenges : [];
    const dataSitekeyNode = document.querySelector("[data-sitekey]");
    const recaptchaTextarea = document.querySelector('textarea[name="g-recaptcha-response"], input[name="g-recaptcha-response"]');
    const turnstileTextarea = document.querySelector('textarea[name="cf-turnstile-response"], input[name="cf-turnstile-response"]');
    const turnstileIframe = document.querySelector('iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"]');
    const recaptchaIframe = document.querySelector('iframe[src*="recaptcha"]');

    const extractSitekeyFromIframe = (iframe) => {
      if (!iframe) return null;
      try {
        const url = new URL(iframe.src);
        return sanitize(url.searchParams.get("k"));
      } catch {
        return null;
      }
    };

    return {
      challengeRecords,
      sitekeyFromDataAttr: sanitize(dataSitekeyNode?.getAttribute?.("data-sitekey")),
      turnstile: {
        present: Boolean(turnstileTextarea || turnstileIframe || challengeRecords.some((entry) => entry?.type === "turnstile")),
        sitekey: sanitize(
          challengeRecords.find((entry) => entry?.type === "turnstile" && entry?.sitekey)?.sitekey
          ?? dataSitekeyNode?.getAttribute?.("data-sitekey")
          ?? extractSitekeyFromIframe(turnstileIframe)
        ),
        action: sanitize(challengeRecords.find((entry) => entry?.type === "turnstile" && entry?.action)?.action),
        data: sanitize(challengeRecords.find((entry) => entry?.type === "turnstile" && entry?.data)?.data),
        pagedata: sanitize(challengeRecords.find((entry) => entry?.type === "turnstile" && entry?.pagedata)?.pagedata),
        callbackName: sanitize(challengeRecords.find((entry) => entry?.type === "turnstile" && entry?.callbackName)?.callbackName),
      },
      recaptcha: {
        present: Boolean(recaptchaTextarea || recaptchaIframe || challengeRecords.some((entry) => entry?.type === "recaptcha")),
        sitekey: sanitize(
          challengeRecords.find((entry) => entry?.type === "recaptcha" && entry?.sitekey)?.sitekey
          ?? dataSitekeyNode?.getAttribute?.("data-sitekey")
          ?? extractSitekeyFromIframe(recaptchaIframe)
        ),
        isInvisible: Boolean(recaptchaTextarea?.closest?.(".grecaptcha-badge, [data-size='invisible'], [size='invisible']")),
      },
    };
  }).catch(() => ({
    challengeRecords: [],
    turnstile: { present: false, sitekey: null, action: null, data: null, pagedata: null, callbackName: null },
    recaptcha: { present: false, sitekey: null, isInvisible: false },
  }));
}

export async function maybeSolveCaptcha(page, { logger = console, timeoutMs = 180_000 } = {}) {
  if (!hasApiKey()) return { solved: false, reason: "2captcha_not_configured" };
  if (!page || page.isClosed?.()) return { solved: false, reason: "page_closed" };

  const context = await readCaptchaContext(page);
  const turnstile = context.turnstile ?? {};
  const recaptcha = context.recaptcha ?? {};

  if (!turnstile.present && !recaptcha.present) {
    return { solved: false, reason: "no_captcha_detected" };
  }

  if (turnstile.present && turnstile.sitekey) {
    logger.log?.(`[2captcha] solving turnstile for ${page.url()}`);
    const task = {
      type: "TurnstileTaskProxyless",
      websiteURL: page.url(),
      websiteKey: turnstile.sitekey,
      ...(turnstile.action ? { action: turnstile.action } : {}),
      ...(turnstile.data ? { data: turnstile.data } : {}),
      ...(turnstile.pagedata ? { pagedata: turnstile.pagedata } : {}),
    };
    const taskId = await createTask(task);
    const solution = await pollTask(taskId, { timeoutMs });
    await injectToken(page, {
      token: solution.token ?? solution.gRecaptchaResponse ?? "",
      callbackName: turnstile.callbackName,
    });
    await page.waitForTimeout(1500);
    return { solved: true, type: "turnstile", taskId };
  }

  if (recaptcha.present && recaptcha.sitekey) {
    logger.log?.(`[2captcha] solving recaptcha for ${page.url()}`);
    const task = {
      type: recaptcha.isInvisible ? "RecaptchaV2TaskProxyless" : "RecaptchaV2TaskProxyless",
      websiteURL: page.url(),
      websiteKey: recaptcha.sitekey,
      ...(recaptcha.isInvisible ? { isInvisible: true } : {}),
    };
    const taskId = await createTask(task);
    const solution = await pollTask(taskId, { timeoutMs });
    await injectToken(page, {
      token: solution.gRecaptchaResponse ?? solution.token ?? "",
    });
    await page.waitForTimeout(1500);
    return { solved: true, type: "recaptcha", taskId };
  }

  return { solved: false, reason: "captcha_present_but_missing_sitekey" };
}

export function installCaptchaHooksScript() {
  return () => {
    window.__ounjeCaptchaChallenges = window.__ounjeCaptchaChallenges || [];

    const record = (type, config = {}) => {
      const sitekey = String(config.sitekey ?? config.siteKey ?? config.key ?? "").trim() || null;
      window.__ounjeCaptchaChallenges.push({
        type,
        sitekey,
        action: String(config.action ?? "").trim() || null,
        data: String(config.cData ?? config.data ?? "").trim() || null,
        pagedata: String(config.chlPageData ?? config.pagedata ?? "").trim() || null,
        callbackName: typeof config.callback === "function" ? "__ounjeCaptchaCallback" : null,
      });
      if (typeof config.callback === "function") {
        window.__ounjeCaptchaCallback = config.callback;
      }
    };

    const patchTurnstile = (turnstile) => {
      if (!turnstile || turnstile.__ounjePatched) return turnstile;
      const originalRender = turnstile.render?.bind(turnstile);
      if (typeof originalRender === "function") {
        turnstile.render = function patchedRender(container, config = {}) {
          record("turnstile", config);
          return originalRender(container, config);
        };
      }
      turnstile.__ounjePatched = true;
      return turnstile;
    };

    const patchRecaptcha = (grecaptcha) => {
      if (!grecaptcha || grecaptcha.__ounjePatched) return grecaptcha;
      const originalRender = grecaptcha.render?.bind(grecaptcha);
      if (typeof originalRender === "function") {
        grecaptcha.render = function patchedRender(container, config = {}) {
          record("recaptcha", config);
          return originalRender(container, config);
        };
      }
      grecaptcha.__ounjePatched = true;
      return grecaptcha;
    };

    let turnstileValue = window.turnstile;
    let grecaptchaValue = window.grecaptcha;

    try {
      Object.defineProperty(window, "turnstile", {
        configurable: true,
        get() {
          return turnstileValue;
        },
        set(value) {
          turnstileValue = patchTurnstile(value);
        },
      });
    } catch {
      window.turnstile = patchTurnstile(window.turnstile);
    }

    try {
      Object.defineProperty(window, "grecaptcha", {
        configurable: true,
        get() {
          return grecaptchaValue;
        },
        set(value) {
          grecaptchaValue = patchRecaptcha(value);
        },
      });
    } catch {
      window.grecaptcha = patchRecaptcha(window.grecaptcha);
    }

    if (window.turnstile) {
      window.turnstile = patchTurnstile(window.turnstile);
    }
    if (window.grecaptcha) {
      window.grecaptcha = patchRecaptcha(window.grecaptcha);
    }
  };
}
