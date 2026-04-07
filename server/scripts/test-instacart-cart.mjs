#!/usr/bin/env node
/**
 * Test adding items to Instacart cart using saved session
 */

import { chromium } from "playwright";
import { existsSync, readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SESSION_PATH = join(__dirname, "../.sessions/instacart-session.json");

const ITEMS_TO_ADD = [
  "bananas",
  "milk 2%", 
  "eggs large",
];

async function addItemsToCart() {
  if (!existsSync(SESSION_PATH)) {
    console.error("❌ No Instacart session found. Run login first:");
    console.log("   node server/scripts/test-session-simple.mjs instacart login");
    process.exit(1);
  }

  const session = JSON.parse(readFileSync(SESSION_PATH, 'utf-8'));
  console.log(`\n📂 Loading Instacart session (${session.cookies.length} cookies)`);

  const browser = await chromium.launch({
    headless: false,
    args: ['--disable-blink-features=AutomationControlled', '--no-sandbox'],
    slowMo: 300,
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  });

  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => false });
  });

  await context.addCookies(session.cookies);

  const page = await context.newPage();

  try {
    console.log(`\n📍 Opening Instacart...`);
    await page.goto('https://www.instacart.ca/store', { 
      waitUntil: 'domcontentloaded',
      timeout: 30000 
    });
    await page.waitForTimeout(3000);

    const currentUrl = page.url();
    if (currentUrl.includes('login')) {
      console.log(`\n❌ Not logged in - session may have expired`);
      await browser.close();
      return;
    }

    console.log(`✓ Loaded: ${currentUrl}`);

    // Add each item
    for (const item of ITEMS_TO_ADD) {
      console.log(`\n🔍 Searching for "${item}"...`);
      
      // Navigate to search URL directly (more reliable than clicking search box)
      const searchUrl = `https://www.instacart.ca/store/search/${encodeURIComponent(item)}`;
      await page.goto(searchUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
      await page.waitForTimeout(3000);
      
      console.log(`   ✓ Search results loaded`);

      // Look for Add to cart button on first product
      // Instacart uses various button patterns
      const addButtonSelectors = [
        'button[aria-label*="Add"]',
        'button:has-text("Add")',
        '[data-testid="add-button"]',
        '[data-testid="product-card"] button',
        '.product-card button',
        'button:has-text("+")',
      ];

      let added = false;
      for (const selector of addButtonSelectors) {
        try {
          const buttons = await page.$$(selector);
          if (buttons.length > 0) {
            // Click the first visible add button
            for (const btn of buttons) {
              if (await btn.isVisible()) {
                await btn.click({ timeout: 5000 });
                console.log(`   ✓ Added "${item}" to cart!`);
                added = true;
                await page.waitForTimeout(2000);
                break;
              }
            }
            if (added) break;
          }
        } catch (err) {
          // Try next selector
        }
      }

      if (!added) {
        console.log(`   ⚠️ Could not find Add button for "${item}"`);
        
        // Take screenshot for debugging
        const screenshotPath = join(__dirname, `../debug-${item.replace(/\s+/g, '-')}.png`);
        await page.screenshot({ path: screenshotPath });
        console.log(`   📸 Screenshot saved: ${screenshotPath}`);
      }
    }

    // Go to cart
    console.log(`\n🛒 Opening cart...`);
    await page.goto('https://www.instacart.ca/store/cart', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3000);

    console.log(`\n${"═".repeat(60)}`);
    console.log(`\n✅ Done! Check the browser window to see your cart.`);
    console.log(`   Browser stays open for 30 seconds...`);
    console.log(`\n${"═".repeat(60)}`);

    await page.waitForTimeout(30000);

  } catch (err) {
    console.error(`\n❌ Error: ${err.message}`);
    const screenshotPath = join(__dirname, `../debug-error.png`);
    await page.screenshot({ path: screenshotPath });
    console.log(`   📸 Error screenshot saved: ${screenshotPath}`);
  } finally {
    await browser.close();
  }
}

await addItemsToCart();
