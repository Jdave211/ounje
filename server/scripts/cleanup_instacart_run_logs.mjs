#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const serverDir = path.resolve(__dirname, "..");
const repoRoot = path.resolve(serverDir, "..");

dotenv.config({ path: path.join(serverDir, ".env"), override: true });

const result = spawnSync(
  "python3",
  [path.join(__dirname, "backfill_instacart_run_logs.py")],
  {
    cwd: repoRoot,
    env: process.env,
    stdio: "inherit",
  }
);

process.exit(result.status ?? 1);
