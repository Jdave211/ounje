#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const serverDir = path.resolve(__dirname, "..");

process.env.NODE_ENV = process.env.NODE_ENV || "production";
process.env.OUNJE_SKIP_IOS_HOST_SYNC = process.env.OUNJE_SKIP_IOS_HOST_SYNC || "1";
process.chdir(serverDir);

await import("./start-server.mjs");
