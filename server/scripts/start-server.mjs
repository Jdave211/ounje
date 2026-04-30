import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const serverDir = path.resolve(__dirname, "..");
const repoRoot = path.resolve(serverDir, "..");
const runtimeMode = String(process.env.OUNJE_RUNTIME_ENV ?? process.env.NODE_ENV ?? "development")
  .trim()
  .toLowerCase();
const isProductionRuntime = runtimeMode === "production";

function isPrivateLanIPv4(address) {
  if (!address || typeof address !== "string") return false;
  if (address.startsWith("10.")) return true;
  if (address.startsWith("192.168.")) return true;
  const match = /^172\.(\d{1,3})\./.exec(address);
  if (!match) return false;
  const second = Number.parseInt(match[1], 10);
  return Number.isFinite(second) && second >= 16 && second <= 31;
}

function detectLanIPv4() {
  const interfaces = os.networkInterfaces();
  const preferredInterfaces = ["en0", "en1", "eth0", "Ethernet"];
  const ordered = [
    ...preferredInterfaces.filter((name) => interfaces[name]),
    ...Object.keys(interfaces).filter((name) => !preferredInterfaces.includes(name)),
  ];

  for (const name of ordered) {
    const entries = interfaces[name] ?? [];
    for (const entry of entries) {
      if (!entry || entry.family !== "IPv4" || entry.internal) continue;
      if (!isPrivateLanIPv4(entry.address)) continue;
      return entry.address;
    }
  }

  return null;
}

function syncIOSDevServerHost(ipAddress) {
  if (!ipAddress) return;

  const plistPaths = [
    path.join(repoRoot, "client/ios/ounje/Info.plist"),
    path.join(repoRoot, "client/ios/OunjeShareExtension/Info.plist"),
  ];

  for (const plistPath of plistPaths) {
    if (!fs.existsSync(plistPath)) continue;
    const before = fs.readFileSync(plistPath, "utf8");
    const hostKeys = [
      "OunjeDevServerHost",
      "OunjePrimaryServerHost",
    ];
    let after = before;
    for (const key of hostKeys) {
      const hostKeyPattern = new RegExp(`(<key>${key}<\\/key>\\s*<string>)([^<]*)(<\\/string>)`, "m");
      if (!hostKeyPattern.test(after)) continue;
      after = after.replace(hostKeyPattern, `$1${ipAddress}$3`);
    }
    if (after !== before) {
      fs.writeFileSync(plistPath, after, "utf8");
      console.log(`[server/bootstrap] synced iOS host keys=${ipAddress} -> ${plistPath}`);
    }
  }
}

const forcedHost = String(process.env.OUNJE_DEV_SERVER_HOST ?? "").trim();
const shouldSkipHostSync = isProductionRuntime
  || ["1", "true", "yes"].includes(String(process.env.OUNJE_SKIP_IOS_HOST_SYNC ?? "").trim().toLowerCase());
const lanIPv4 = forcedHost || detectLanIPv4();
if (shouldSkipHostSync) {
  console.log("[server/bootstrap] skipping iOS host sync");
} else if (!lanIPv4) {
  console.warn("[server/bootstrap] unable to detect private LAN IPv4; skipping iOS host sync");
} else {
  if (forcedHost) {
    console.log(`[server/bootstrap] using forced LAN host ${lanIPv4}`);
  } else {
    console.log(`[server/bootstrap] detected LAN IPv4 ${lanIPv4}`);
  }
  syncIOSDevServerHost(lanIPv4);
}

if (process.argv.includes("--sync-only")) {
  console.log("[server/bootstrap] sync-only mode complete");
  process.exit(0);
}

dotenv.config({ path: path.join(serverDir, ".env"), override: true });
process.chdir(serverDir);

if (!process.env.OPENAI_API_KEY && !isProductionRuntime) {
  const zshrcPath = path.resolve(process.env.HOME ?? "", ".zshrc");
  let openaiLoadedFromZshrc = false;
  if (fs.existsSync(zshrcPath)) {
    const zshrc = fs.readFileSync(zshrcPath, "utf8");
    for (const line of zshrc.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("export OPENAI_API_KEY=")) continue;
      const rawValue = trimmed.slice("export OPENAI_API_KEY=".length).trim();
      const unquoted = rawValue.replace(/^['"]|['"]$/g, "");
      if (unquoted) {
        process.env.OPENAI_API_KEY = unquoted;
        openaiLoadedFromZshrc = true;
      }
      break;
    }
  }
  if (!process.env.OPENAI_API_KEY) {
    console.warn("[server/bootstrap] OPENAI_API_KEY still missing after zshrc fallback");
  } else if (openaiLoadedFromZshrc) {
    console.log("[server/bootstrap] OPENAI_API_KEY loaded from zshrc fallback");
  }
}

console.log(
  "[server/bootstrap] env loaded",
  JSON.stringify({
    runtimeMode,
    openai: Boolean(process.env.OPENAI_API_KEY),
    supabaseUrl: Boolean(process.env.SUPABASE_URL),
    supabaseAnon: Boolean(process.env.SUPABASE_ANON_KEY),
  })
);

await import("../server.js");
