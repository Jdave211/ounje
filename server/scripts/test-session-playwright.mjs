#!/usr/bin/env node
/**
 * Test session persistence with plain Playwright (FREE - no paid services)
 * 
 * This tests the core assumption: can we save and restore login sessions?
 * 
 * Usage:
 *   node server/scripts/test-session-playwright.mjs instacart login
 *   node server/scripts/test-session-playwright.mjs instacart verify
 *   node server/scripts/test-session-playwright.mjs walmart login
 */

import { chromium } from "playwright";
import { existsSync, mkdirSync, writeFileSync, readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SESSIONS_DIR = join(__dirname, "../.sessions");

const PROVIDERS = {
  instacart: {
    name: "Instacart",
    loginUrl: "https://www.instacart.com/login",
    homeUrl: "https://www.instacart.com/store",
    checkSelector: '[data-testid="user-menu"], [aria-label*="Account"], .user-menu, [data-testid="header-account-button"]',
  },
  walmart: {
    name: "Walmart Grocery",
    loginUrl: "https://www.walmart.com/account/login?returnUrl=/grocery",
    homeUrl: "https://www.walmart.com/grocery",
    checkSelector: '[data-testid="account-menu"], .account-link, [aria-label*="Account"]',
  },
  amazon: {
    name: "Amazon Fresh", 
    loginUrl: "https://www.amazon.com/ap/signin?openid.pape.max_auth_age=0&openid.return_to=https%3A%2F%2Fwww.amazon.com%2Falm%2Fstorefront",
    homeUrl: "https://www.amazon.com/alm/storefront?almBrandId=QW1hem9uIEZyZXNo",
    checkSelector: '#nav-link-accountList-nav-line-1, [data-nav-ref="nav_youraccount_btn"]',
  },
  target: {
    name: "Target",
    loginUrl: "https://www.target.com/login?client_id=ecom-web-1.0.0",
    homeUrl: "https://www.target.com/c/grocery/-/N-5xt1a",
    checkSelector: '[data-test="accountNav-signIn"], [data-test="@web/AccountLink"]',
  },
};

function getSessionPath(provider) {
  return join(SESSIONS_DIR, `${provider}-session.json`);
}

async function loginFlow(provider) {
  const config = PROVIDERS[provider];
  if (!config) {
    console.error(`Unknown provider: ${provider}`);
    console.log(`Available: ${Object.keys(PROVIDERS).join(", ")}`);
    process.exit(1);
  }

  // Ensure sessions directory exists
  if (!existsSync(SESSIONS_DIR)) {
    mkdirSync(SESSIONS_DIR, { recursive: true });
  }

  console.log(`\n🌐 Launching browser for ${config.name}...`);
  console.log(`   This will open a VISIBLE browser window.`);
  console.log(`   You'll need to log in manually.\n`);

  const browser = await chromium.launch({
    headless: false,  // Visible browser so user can log in
    args: [
      '--disable-blink-features=AutomationControlled',
      '--no-sandbox',
    ],
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  });

  // Remove webdriver property
  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => false });
  });

  const page = await context.newPage();

  try {
    console.log(`📍 Navigating to ${config.loginUrl}...`);
    await page.goto(config.loginUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });

    console.log(`\n${"═".repeat(60)}`);
    console.log(`\n👆 LOG IN NOW in the browser window that opened.`);
    console.log(`   After logging in, come back here and press ENTER.`);
    console.log(`\n${"═".repeat(60)}\n`);

    // Wait for user to press Enter
    await waitForEnter();

    // Check if logged in
    console.log(`\n🔍 Checking login status...`);
    
    // Give the page a moment to settle
    await page.waitForTimeout(2000);

    // Try to find any logged-in indicator
    const currentUrl = page.url();
    console.log(`   Current URL: ${currentUrl}`);

    // Save the session (cookies + storage)
    const cookies = await context.cookies();
    const sessionPath = getSessionPath(provider);
    
    writeFileSync(sessionPath, JSON.stringify({
      cookies,
      savedAt: new Date().toISOString(),
      lastUrl: currentUrl,
    }, null, 2));

    console.log(`\n✅ Session saved to: ${sessionPath}`);
    console.log(`   Cookies saved: ${cookies.length}`);
    console.log(`\n💡 Now test session persistence with:`);
    console.log(`   node server/scripts/test-session-playwright.mjs ${provider} verify`);

  } finally {
    await browser.close();
  }
}

async function verifyFlow(provider) {
  const config = PROVIDERS[provider];
  if (!config) {
    console.error(`Unknown provider: ${provider}`);
    process.exit(1);
  }

  const sessionPath = getSessionPath(provider);
  if (!existsSync(sessionPath)) {
    console.error(`\n❌ No saved session for ${provider}`);
    console.log(`   Run login first: node server/scripts/test-session-playwright.mjs ${provider} login`);
    process.exit(1);
  }

  const session = JSON.parse(readFileSync(sessionPath, 'utf-8'));
  console.log(`\n📂 Loading session saved at: ${session.savedAt}`);
  console.log(`   Cookies: ${session.cookies.length}`);

  console.log(`\n🌐 Launching browser with saved session...`);

  const browser = await chromium.launch({
    headless: false,  // Visible so we can see the result
    args: [
      '--disable-blink-features=AutomationControlled',
      '--no-sandbox',
    ],
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  });

  // Remove webdriver property
  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => false });
  });

  // Restore cookies
  await context.addCookies(session.cookies);
  console.log(`   ✓ Cookies restored`);

  const page = await context.newPage();

  try {
    console.log(`\n📍 Navigating to ${config.homeUrl}...`);
    await page.goto(config.homeUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });

    // Wait for page to load
    await page.waitForTimeout(3000);

    const currentUrl = page.url();
    console.log(`   Current URL: ${currentUrl}`);

    // Check for login redirect (means session didn't persist)
    const isLoginPage = currentUrl.includes('login') || currentUrl.includes('signin') || currentUrl.includes('ap/signin');
    
    console.log(`\n${"═".repeat(60)}`);
    
    if (isLoginPage) {
      console.log(`\n❌ SESSION DID NOT PERSIST`);
      console.log(`   The browser was redirected to login page.`);
      console.log(`   This provider may:`);
      console.log(`   - Require additional auth (2FA, CAPTCHA)`);
      console.log(`   - Have short session expiry`);
      console.log(`   - Block automated browsers`);
    } else {
      console.log(`\n✅ SESSION APPEARS TO HAVE PERSISTED!`);
      console.log(`   The browser loaded ${config.name} without redirecting to login.`);
      console.log(`   Check the browser window to confirm you're logged in.`);
    }
    
    console.log(`\n${"═".repeat(60)}`);
    console.log(`\n   Browser will stay open for 30 seconds so you can verify.`);
    console.log(`   Press Ctrl+C to close early.\n`);

    // Keep browser open for verification
    await page.waitForTimeout(30000);

  } finally {
    await browser.close();
  }
}

function waitForEnter() {
  return new Promise((resolve) => {
    process.stdin.setRawMode?.(false);
    process.stdin.resume();
    process.stdin.once('data', () => {
      resolve();
    });
    console.log("Press ENTER when you've finished logging in...");
  });
}

// ── CLI ────────────────────────────────────────────────────────────────────────

const [,, provider, action = "login"] = process.argv;

if (!provider) {
  console.log(`
Session Persistence Test (Playwright - FREE)
${"═".repeat(50)}

This tests if we can save and restore login sessions
using cookies. No paid services required.

Usage:
  node server/scripts/test-session-playwright.mjs <provider> login   # Log in and save session
  node server/scripts/test-session-playwright.mjs <provider> verify  # Verify session persists

Providers: ${Object.keys(PROVIDERS).join(", ")}

Example:
  node server/scripts/test-session-playwright.mjs instacart login
  # (log in manually in the browser that opens)
  node server/scripts/test-session-playwright.mjs instacart verify
  # (see if you're still logged in)
`);
  process.exit(0);
}

if (action === "login") {
  await loginFlow(provider);
} else if (action === "verify") {
  await verifyFlow(provider);
} else {
  console.error(`Unknown action: ${action}`);
  process.exit(1);
}
