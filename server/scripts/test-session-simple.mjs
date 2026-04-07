#!/usr/bin/env node
/**
 * Simple session persistence test - auto-detects login
 * 
 * Usage:
 *   node server/scripts/test-session-simple.mjs instacart login
 *   node server/scripts/test-session-simple.mjs instacart verify
 */

import { chromium } from "playwright";
import { existsSync, mkdirSync, writeFileSync, readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SESSIONS_DIR = join(__dirname, "../.sessions");

const PROVIDERS = {
  instacart: {
    name: "Instacart Canada",
    loginUrl: "https://www.instacart.ca/login",
    homeUrl: "https://www.instacart.ca/store",
  },
  walmart: {
    name: "Walmart Canada",
    loginUrl: "https://www.walmart.ca/sign-in",
    homeUrl: "https://www.walmart.ca/grocery",
  },
  amazon: {
    name: "Amazon Fresh", 
    loginUrl: "https://www.amazon.com/ap/signin",
    homeUrl: "https://www.amazon.com/alm/storefront",
  },
  target: {
    name: "Target",
    loginUrl: "https://www.target.com/login",
    homeUrl: "https://www.target.com/c/grocery/-/N-5xt1a",
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

  if (!existsSync(SESSIONS_DIR)) {
    mkdirSync(SESSIONS_DIR, { recursive: true });
  }

  console.log(`\n🌐 Launching browser for ${config.name}...`);

  const browser = await chromium.launch({
    headless: false,
    args: ['--disable-blink-features=AutomationControlled', '--no-sandbox'],
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  });

  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => false });
  });

  const page = await context.newPage();

  console.log(`📍 Opening ${config.loginUrl}`);
  await page.goto(config.loginUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });

  console.log(`\n${"═".repeat(60)}`);
  console.log(`\n👆 LOG IN NOW in the browser window.`);
  console.log(`   The script will auto-detect when you're logged in.`);
  console.log(`   (Waiting up to 3 minutes...)`);
  console.log(`\n${"═".repeat(60)}\n`);

  // Auto-detect login by watching for URL change away from login page
  const maxWait = 180_000; // 3 minutes
  const startTime = Date.now();
  let loggedIn = false;

  while (Date.now() - startTime < maxWait) {
    await new Promise(r => setTimeout(r, 2000));
    
    const currentUrl = page.url();
    const isStillOnLogin = currentUrl.includes('login') || currentUrl.includes('signin') || currentUrl.includes('ap/signin');
    
    if (!isStillOnLogin) {
      console.log(`✓ Detected navigation away from login page`);
      console.log(`  Current URL: ${currentUrl}`);
      loggedIn = true;
      break;
    }
    
    process.stdout.write(".");
  }

  if (!loggedIn) {
    console.log(`\n⚠️  Timeout - saving session anyway...`);
  }

  // Wait a moment for any redirects to settle
  await new Promise(r => setTimeout(r, 3000));

  // Save session
  const cookies = await context.cookies();
  const sessionPath = getSessionPath(provider);
  
  writeFileSync(sessionPath, JSON.stringify({
    cookies,
    savedAt: new Date().toISOString(),
    lastUrl: page.url(),
  }, null, 2));

  console.log(`\n✅ Session saved!`);
  console.log(`   File: ${sessionPath}`);
  console.log(`   Cookies: ${cookies.length}`);
  console.log(`\n💡 Now verify with:`);
  console.log(`   node server/scripts/test-session-simple.mjs ${provider} verify`);

  await browser.close();
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
    console.log(`   Run: node server/scripts/test-session-simple.mjs ${provider} login`);
    process.exit(1);
  }

  const session = JSON.parse(readFileSync(sessionPath, 'utf-8'));
  console.log(`\n📂 Loading session from: ${session.savedAt}`);
  console.log(`   Cookies: ${session.cookies.length}`);

  const browser = await chromium.launch({
    headless: false,
    args: ['--disable-blink-features=AutomationControlled', '--no-sandbox'],
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  });

  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => false });
  });

  // Restore cookies BEFORE navigating
  await context.addCookies(session.cookies);
  console.log(`   ✓ Cookies restored`);

  const page = await context.newPage();

  console.log(`\n📍 Navigating to ${config.homeUrl}...`);
  await page.goto(config.homeUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });

  await new Promise(r => setTimeout(r, 3000));

  const currentUrl = page.url();
  const wasRedirectedToLogin = currentUrl.includes('login') || currentUrl.includes('signin');

  console.log(`\n${"═".repeat(60)}`);
  
  if (wasRedirectedToLogin) {
    console.log(`\n❌ SESSION DID NOT PERSIST`);
    console.log(`   Redirected to: ${currentUrl}`);
    console.log(`\n   This could mean:`);
    console.log(`   - Provider expired the session`);
    console.log(`   - Cookies alone aren't enough (needs localStorage)`);
    console.log(`   - Provider detected automation`);
  } else {
    console.log(`\n✅ SESSION PERSISTED!`);
    console.log(`   URL: ${currentUrl}`);
    console.log(`\n   Check the browser window - you should be logged in!`);
  }
  
  console.log(`\n${"═".repeat(60)}`);
  console.log(`\n   Browser stays open for 20 seconds to verify...`);

  await new Promise(r => setTimeout(r, 20000));
  await browser.close();
}

// ── CLI ────────────────────────────────────────────────────────────────────────

const [,, provider, action = "login"] = process.argv;

if (!provider) {
  console.log(`\nUsage:`);
  console.log(`  node server/scripts/test-session-simple.mjs <provider> login`);
  console.log(`  node server/scripts/test-session-simple.mjs <provider> verify`);
  console.log(`\nProviders: ${Object.keys(PROVIDERS).join(", ")}`);
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
