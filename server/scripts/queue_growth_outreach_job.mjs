#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

function parseArgs(argv) {
  const args = {
    userID: "",
    mode: "both",
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--user-id") args.userID = String(argv[index + 1] ?? "").trim(), index += 1;
    else if (token === "--mode") args.mode = String(argv[index + 1] ?? "both").trim(), index += 1;
  }

  return args;
}

function normalizeMode(value) {
  const mode = String(value ?? "").trim().toLowerCase();
  if (mode === "quora" || mode === "roundups" || mode === "both") return mode;
  return "both";
}

const args = parseArgs(process.argv);
if (!args.userID) {
  console.error("Usage: node server/scripts/queue_growth_outreach_job.mjs --user-id <auth_user_uuid> [--mode both|quora|roundups]");
  process.exit(1);
}

const { createAutomationJob } = await import("../lib/automation-jobs.js");

const job = await createAutomationJob({
  userID: args.userID,
  kind: "growth_outreach_run",
  payload: {
    mode: normalizeMode(args.mode),
    queuedBy: "queue_growth_outreach_job",
  },
  maxAttempts: 2,
});

console.log(JSON.stringify(job, null, 2));
