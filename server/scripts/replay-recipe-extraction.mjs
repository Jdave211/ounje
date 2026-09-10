#!/usr/bin/env node
// Real extraction without a queue job or any database/storage writes.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
dotenv.config({ path: path.join(root, 'server/.env'), quiet: true });
const argument = (name) => { const index = process.argv.indexOf(name); return index >= 0 ? process.argv[index + 1] : null; };
const sourceURL = argument('--url');
const evidencePath = argument('--evidence');
const output = path.resolve(argument('--out') ?? '/tmp/ounje-extraction-replay');
assert(Boolean(sourceURL) !== Boolean(evidencePath), 'Provide exactly one of --url or --evidence.');
assert(process.env.OPENAI_API_KEY, 'OPENAI_API_KEY is required.');

// Empty values prevent dotenv from reloading credentials in imported modules.
for (const key of ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_DB_PASSWORD', 'REDIS_URL']) process.env[key] = '';
process.env.REDIS_DISABLED = 'true';
process.env.OUNJE_ENABLE_AI_CALL_LOGGING = 'false';
process.env.OUNJE_AI_BUDGET_FAIL_CLOSED = 'false';
process.env.NODE_ENV = 'development';
await fs.mkdir(output, { recursive: true });
const save = (name, value) => fs.writeFile(path.join(output, name), JSON.stringify(value, null, 2));
const hash = (value) => createHash('sha256').update(value).digest('hex');
const codeManifest = async () => {
  const files = ['package.json', 'package-lock.json', 'server/scripts/replay-recipe-extraction.mjs'];
  for (const folder of ['server/lib', 'server/scripts']) {
    for (const entry of await fs.readdir(path.join(root, folder), { recursive: true, withFileTypes: true })) {
      if (entry.isFile() && /\.(?:js|mjs|py|sh|json)$/.test(entry.name)) {
        files.push(path.relative(root, path.join(entry.parentPath ?? entry.path, entry.name)));
      }
    }
  }
  const manifest = {};
  for (const file of [...new Set(files)].sort()) manifest[file] = hash(await fs.readFile(path.join(root, file)));
  return manifest;
};
const initialCode = await codeManifest();
const audit = {
  started_at: new Date().toISOString(), pid: process.pid,
  input: sourceURL ? { mode: 'fresh_url', url: sourceURL } : { mode: 'captured_evidence', path: evidencePath },
  provider_availability: { openai: true, perplexity: Boolean(process.env.PERPLEXITY_API_KEY) },
  application_persistence_disabled: true,
  code_before: initialCode,
};
await save('run-audit.json', audit);
const realFetch = globalThis.fetch;
let callCount = 0;
let forbiddenWrites = 0;
const events = [];
const event = async (stage, extra = {}) => {
  const entry = { at: new Date().toISOString(), stage, ...extra };
  events.push(entry);
  await save('events.json', events);
  console.log(JSON.stringify(entry));
};
globalThis.fetch = async (input, options = {}) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
  const method = String(options.method ?? input?.method ?? 'GET').toUpperCase();
  if ((url.hostname.endsWith('.supabase.co') || url.hostname.endsWith('.supabase.com') || url.hostname === 'ounje-idbl.onrender.com') && !['GET', 'HEAD'].includes(method)) {
    forbiddenWrites += 1;
    throw new Error('Diagnostic blocked an application write.');
  }
  const isAI = ['api.openai.com', 'api.perplexity.ai'].includes(url.hostname);
  if (!isAI) return realFetch(input, options);
  const id = ++callCount;
  let payload = null;
  if (typeof options.body === 'string') { try { payload = JSON.parse(options.body); } catch {} }
  const prefix = `ai-${String(id).padStart(2, '0')}`;
  if (payload) await save(`${prefix}-request.json`, payload);
  await event('ai_started', { id, provider: url.hostname, endpoint: url.pathname, model: payload?.model ?? null });
  const start = Date.now();
  const response = await realFetch(input, options);
  const data = await response.clone().json().catch(() => null);
  await save(`${prefix}-response.json`, data);
  await event('ai_finished', { id, status: response.status, seconds: (Date.now() - start) / 1000, usage: data?.usage ?? null });
  return response;
};
// Observe the installed SDK's resource methods without changing its Node upload
// transport (the web shim cannot upload the worker's fs.ReadStream audio).
for (const [modulePath, className, endpoint] of [
  ['openai/resources/chat/completions/completions', 'Completions', 'chat.completions'],
  ['openai/resources/responses/responses', 'Responses', 'responses'],
  ['openai/resources/audio/transcriptions', 'Transcriptions', 'audio.transcriptions'],
  ['openai/resources/embeddings', 'Embeddings', 'embeddings'],
]) {
  const Resource = (await import(modulePath))[className];
  const originalCreate = Resource.prototype.create;
  Resource.prototype.create = async function (payload, ...rest) {
    const id = ++callCount;
    const prefix = `ai-${String(id).padStart(2, '0')}`;
    const recorded = { ...payload };
    if (recorded.file) recorded.file = '[local audio file]';
    await save(`${prefix}-request.json`, recorded);
    await event('ai_started', { id, provider: 'api.openai.com', endpoint, model: payload?.model ?? null });
    const start = Date.now();
    try {
      const response = await originalCreate.call(this, payload, ...rest);
      await save(`${prefix}-response.json`, response);
      await event('ai_finished', { id, seconds: (Date.now() - start) / 1000, usage: response?.usage ?? null });
      return response;
    } catch (error) {
      await event('ai_failed', { id, seconds: (Date.now() - start) / 1000, error: error.message });
      throw error;
    }
  };
}
const ingestion = await import('../lib/recipe-ingestion.js');
try {
  await event('source_started', { source_url: sourceURL ?? null, evidence_replay: Boolean(evidencePath) });
  let source;
  if (evidencePath) {
    source = JSON.parse(await fs.readFile(evidencePath, 'utf8'));
    // A replay must rerun extraction/research instead of keeping the previous answer.
    delete source.social_completion_context;
    delete source.creator_recipe_reference;
  } else {
    const canonicalURL = await ingestion.expandCanonicalSourceURL(sourceURL);
    const sourceType = ingestion.detectRecipeIngestionSourceType({ sourceUrl: canonicalURL ?? sourceURL });
    source = await ingestion.extractSourceMaterial({ source_type: sourceType, source_url: sourceURL, canonical_url: canonicalURL, attachments: [] });
  }
  await save('source.json', source);
  await event('source_ready', { title: source.title, frames: source.frame_data_urls?.length ?? 0, transcript_chars: source.transcript_text?.length ?? 0 });
  const gate = await ingestion.assessRecipeLikelihood(source);
  await save('gate.json', gate);
  assert(gate.is_recipe, `Source gate rejected: ${gate.reason}`);
  await event('normalization_started');
  const result = await ingestion.buildNormalizedRecipe(source);
  await save('result.json', result);
  audit.result_sha256 = hash(await fs.readFile(path.join(output, 'result.json')));
  await save('source-after.json', source);
  const issues = ingestion.buildFinalRecipeValidationIssues(result.normalized_recipe, source);
  await save('validation.json', { issues, forbiddenWrites, aiCalls: callCount });
  await event('finished', { review_state: result.review_state, ingredients: result.normalized_recipe.ingredients.length, steps: result.normalized_recipe.steps.length, issues, forbiddenWrites });
  assert.equal(forbiddenWrites, 0);
} catch (error) {
  await event('failed', { error: error.message, forbiddenWrites });
  process.exitCode = 1;
} finally {
  audit.finished_at = new Date().toISOString();
  audit.code_after = await codeManifest();
  audit.code_unchanged = JSON.stringify(audit.code_before) === JSON.stringify(audit.code_after);
  audit.forbidden_writes = forbiddenWrites;
  audit.source_sha256 = await fs.readFile(path.join(output, 'source.json')).then(hash).catch(() => null);
  await save('run-audit.json', audit);
  if (!audit.code_unchanged) process.exitCode = 1;
  // OCR workers and provider clients can keep the diagnostic process alive.
  globalThis.fetch = realFetch;
}
process.exit(process.exitCode ?? 0);
