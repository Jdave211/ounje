#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

function parseArgs(argv) {
  const args = {
    mode: "both",
    outputDir: "",
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--mode") args.mode = String(argv[index + 1] ?? "both").trim(), index += 1;
    else if (token === "--output-dir") args.outputDir = String(argv[index + 1] ?? "").trim(), index += 1;
  }

  return args;
}

const args = parseArgs(process.argv);
const { executeLocalGrowthOutreachRun } = await import("../lib/growth-outreach-agent.js");

const summary = await executeLocalGrowthOutreachRun({
  mode: args.mode,
  outputDir: args.outputDir || undefined,
  logger: console,
});

console.log(JSON.stringify(summary, null, 2));
