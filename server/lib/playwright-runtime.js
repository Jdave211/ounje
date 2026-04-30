import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const PLAYWRIGHT_EXECUTABLE_PATH = String(process.env.PLAYWRIGHT_EXECUTABLE_PATH ?? "").trim();

function fileExists(filePath) {
  if (!filePath) return false;
  try {
    return fs.existsSync(filePath);
  } catch {
    return false;
  }
}

function resolveLinuxPlaywrightExecutable() {
  const cacheRoot = path.join(os.homedir(), ".cache", "ms-playwright");
  if (!fileExists(cacheRoot)) {
    return null;
  }

  const candidates = fs.readdirSync(cacheRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("chromium-"))
    .map((entry) => path.join(cacheRoot, entry.name, "chrome-linux64", "chrome"))
    .filter(fileExists)
    .sort((left, right) => right.localeCompare(left));

  return candidates[0] ?? null;
}

export function resolvePlaywrightExecutablePath() {
  if (fileExists(PLAYWRIGHT_EXECUTABLE_PATH)) {
    return PLAYWRIGHT_EXECUTABLE_PATH;
  }

  if (process.platform === "linux") {
    return resolveLinuxPlaywrightExecutable();
  }

  return null;
}

export function buildPlaywrightLaunchOptions({ headless = true, args = [], ...overrides } = {}) {
  const launchArgs = [...args];

  if (process.platform === "linux" && !launchArgs.includes("--no-sandbox")) {
    launchArgs.push("--no-sandbox");
  }

  if (process.platform === "linux" && !launchArgs.includes("--disable-gpu")) {
    launchArgs.push("--disable-gpu");
  }

  const executablePath = resolvePlaywrightExecutablePath();

  return {
    headless,
    args: launchArgs,
    ...(executablePath ? { executablePath } : {}),
    ...overrides,
  };
}
