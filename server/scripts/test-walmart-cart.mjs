#!/usr/bin/env node
/**
 * Test adding items to Walmart cart using saved session
 */

import { chromium } from "playwright";
import { existsSync, readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SESSION_PATH = join(__dirname, "../.sessions/walmart-session.json");

const ITEMS_TO_ADD = [
  "bananas",
  "milk 2%",
  "eggs",
];

async function addItemsToCart() {
  if (!existsSync(SESSION_PATH)) {
    console.error("❌ No Walmart session found. Run login first:");
    console.log("   node server/scripts/test-session-simple.mjs walmart login");
    process.exit(1);
  }

  const session = JSON.parse(readFileSync(SESSION_PATH, 'utf-8'));
  console.log(`\n📂 Loading Walmart session (${session.cookies.length} cookies)`);

  const browser = await chromium.launch({
    headless: false,
    args: ['--disable-blink-features=AutomationControlled', '--no-sandbox'],
    slowMo: 500,  // Slow down so we can see what's happening
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  });

  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => false });
  });

  // Restore session
  await context.addCookies(session.cookies);

  const page = await context.newPage();

  try {
    // Go to Walmart grocery
    console.log(`\n📍 Opening Walmart grocery...`);
    await page.goto('https://www.walmart.ca/grocery', { 
      waitUntil: 'domcontentloaded',
      timeout: 30000 
    });
    await page.waitForTimeout(3000);

    // Check if we're logged in
    const currentUrl = page.url();
    if (currentUrl.includes('sign-in')) {
      console.log(`\n❌ Not logged in - session may have expired`);
      console.log(`   Run: node server/scripts/test-session-simple.mjs walmart login`);
      await browser.close();
      return;
    }

    console.log(`✓ Loaded: ${currentUrl}`);

    // Dismiss any modals/popups
    console.log(`\n🔄 Checking for popups to dismiss...`);
    
    // Try various ways to close modals
    const closeSelectors = [
      '[aria-label="Close"]',
      '[data-testid="modal-close"]', 
      'button:has-text("Close")',
      'button:has-text("No thanks")',
      'button:has-text("Maybe later")',
      'button:has-text("Continue")',
      '.modal-close',
      '[data-automation="modal-close"]',
      'button[aria-label*="close" i]',
      'button[aria-label*="dismiss" i]',
    ];

    for (const selector of closeSelectors) {
      try {
        const closeBtn = await page.$(selector);
        if (closeBtn && await closeBtn.isVisible()) {
          await closeBtn.click({ timeout: 2000 });
          console.log(`   ✓ Dismissed popup with: ${selector}`);
          await page.waitForTimeout(1000);
          break;
        }
      } catch {
        // Continue trying
      }
    }

    // Also try pressing Escape
    await page.keyboard.press('Escape');
    await page.waitForTimeout(500);
    
    // Click somewhere neutral to dismiss overlays
    try {
      await page.mouse.click(100, 100);
      await page.waitForTimeout(500);
    } catch {}

    console.log(`   Done checking for popups`);

    // Add each item
    for (const item of ITEMS_TO_ADD) {
      console.log(`\n🔍 Searching for "${item}"...`);
      
      // Find and click search box
      const searchBox = await page.$('input[type="search"], input[name="q"], [data-testid="search-input"], #search-form-input');
      
      if (!searchBox) {
        console.log(`   ⚠️ Could not find search box, trying alternative...`);
        // Try clicking on search icon/area first
        const searchButton = await page.$('[data-testid="search-button"], .search-icon, [aria-label="Search"]');
        if (searchButton) {
          await searchButton.click();
          await page.waitForTimeout(1000);
        }
      }

      // Clear and type search
      const searchInput = await page.$('input[type="search"], input[name="q"], [data-testid="search-input"]');
      if (searchInput) {
        await searchInput.click();
        await searchInput.fill('');
        await searchInput.fill(item);
        await page.waitForTimeout(500);
        
        // Press Enter to search
        await searchInput.press('Enter');
        console.log(`   ✓ Searching...`);
        
        // Wait for results
        await page.waitForTimeout(3000);
        
        // Try to find and click "Add to cart" on first result
        const addToCartButton = await page.$('[data-testid="add-to-cart-button"], button:has-text("Add to cart"), [aria-label*="Add to cart"]');
        
        if (addToCartButton) {
          await addToCartButton.click();
          console.log(`   ✓ Added "${item}" to cart!`);
          await page.waitForTimeout(2000);
        } else {
          // Try finding product card and its add button
          const productCard = await page.$('[data-testid="product-tile"], .product-card, [data-automation="product"]');
          if (productCard) {
            const addBtn = await productCard.$('button:has-text("Add"), [aria-label*="Add"]');
            if (addBtn) {
              await addBtn.click();
              console.log(`   ✓ Added "${item}" to cart!`);
              await page.waitForTimeout(2000);
            } else {
              console.log(`   ⚠️ Found product but no Add button`);
            }
          } else {
            console.log(`   ⚠️ Could not find Add to Cart button for "${item}"`);
          }
        }
      } else {
        console.log(`   ❌ Could not find search input`);
      }
    }

    // Go to cart to verify
    console.log(`\n🛒 Opening cart...`);
    await page.goto('https://www.walmart.ca/cart', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3000);

    console.log(`\n${"═".repeat(60)}`);
    console.log(`\n✅ Done! Check the browser window to see your cart.`);
    console.log(`   Browser stays open for 30 seconds...`);
    console.log(`\n${"═".repeat(60)}`);

    await page.waitForTimeout(30000);

  } catch (err) {
    console.error(`\n❌ Error: ${err.message}`);
  } finally {
    await browser.close();
  }
}

await addItemsToCart();
