#!/usr/bin/env node
import fs from "fs";
import crypto from "crypto";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const value = argv[i + 1];
    if (!value || value.startsWith("--")) {
      args[key] = "true";
      continue;
    }
    args[key] = value;
    i += 1;
  }
  return args;
}

function toBase64URL(input) {
  const buffer = Buffer.isBuffer(input) ? input : Buffer.from(input);
  return buffer
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function usage() {
  console.error(
    "Usage: node scripts/generate_apple_client_secret.mjs --team-id <TEAM_ID> --client-id <CLIENT_ID> --key-id <KEY_ID> --key-file <PATH_TO_P8> [--ttl-days 180]"
  );
}

const args = parseArgs(process.argv);
const teamId = args["team-id"];
const clientId = args["client-id"];
const keyId = args["key-id"];
const keyFile = args["key-file"];
const ttlDays = Number(args["ttl-days"] ?? "180");

if (!teamId || !clientId || !keyId || !keyFile || Number.isNaN(ttlDays) || ttlDays <= 0) {
  usage();
  process.exit(1);
}

const privateKey = fs.readFileSync(keyFile, "utf8");
const issuedAt = Math.floor(Date.now() / 1000);
const expiresAt = issuedAt + Math.floor(ttlDays * 24 * 60 * 60);

const header = toBase64URL(
  JSON.stringify({
    alg: "ES256",
    kid: keyId,
    typ: "JWT",
  })
);

const payload = toBase64URL(
  JSON.stringify({
    iss: teamId,
    iat: issuedAt,
    exp: expiresAt,
    aud: "https://appleid.apple.com",
    sub: clientId,
  })
);

const unsignedToken = `${header}.${payload}`;
const signer = crypto.createSign("SHA256");
signer.update(unsignedToken);
signer.end();
const signature = signer.sign(privateKey);
const clientSecret = `${unsignedToken}.${toBase64URL(signature)}`;

console.log(
  JSON.stringify(
    {
      client_id: clientId,
      team_id: teamId,
      key_id: keyId,
      issued_at: issuedAt,
      expires_at: expiresAt,
      client_secret: clientSecret,
    },
    null,
    2
  )
);
