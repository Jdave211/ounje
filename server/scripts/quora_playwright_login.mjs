#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { fileURLToPath } from "node:url";

import { chromium } from "playwright";
import { buildPlaywrightLaunchOptions } from "../lib/playwright-runtime.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../..");
const defaultProfileDir = path.resolve(repoRoot, "tmp/growth-outreach/playwright-profile");

dotenv.config({ path: path.resolve(__dirname, "../.env") });

function parseArgs(argv) {
  const args = {
    profileDir: process.env.GROWTH_PLAYWRIGHT_USER_DATA_DIR || defaultProfileDir,
    url: "https://www.quora.com/login",
  };
  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--profile-dir") args.profileDir = String(argv[index + 1] ?? "").trim() || args.profileDir, index += 1;
    else if (token === "--url") args.url = String(argv[index + 1] ?? "").trim() || args.url, index += 1;
  }
  return args;
}

const args = parseArgs(process.argv);
const context = await chromium.launchPersistentContext(args.profileDir, buildPlaywrightLaunchOptions({
  headless: false,
  viewport: { width: 1280, height: 900 },
}));

try {
  const page = context.pages()[0] ?? await context.newPage();
  await page.goto(args.url, { waitUntil: "domcontentloaded", timeout: 30_000 });
  console.log(`[quora-login] Browser opened with profile: ${args.profileDir}`);
  console.log("[quora-login] Log into Quora in the browser window, then press Enter here.");
  console.log("[quora-login] If Google sign-in says this browser is unsupported, use Quora email/password login instead.");
  const rl = readline.createInterface({ input, output });
  await rl.question("");
  rl.close();
  await page.goto("https://www.quora.com/search?q=meal%20planning%20app", { waitUntil: "domcontentloaded", timeout: 30_000 }).catch(() => {});
  await context.storageState({ path: path.resolve(args.profileDir, "storage-state.json") }).catch(() => {});
  console.log("[quora-login] Saved Playwright profile for growth discovery.");
} finally {
  await context.close().catch(() => {});
}
