import assert from 'node:assert/strict';

// No credentials or network access: exercise the real enqueue path against a
// tiny REST double and count requests that previously ran as false lock retries.
process.env.OPENAI_API_KEY = '';
process.env.SUPABASE_URL = 'https://enqueue-test.invalid';
process.env.SUPABASE_ANON_KEY = 'test';
process.env.SUPABASE_SERVICE_ROLE_KEY = '';
process.env.REDIS_DISABLED = 'true';
process.env.NODE_ENV = 'production';
const requests = [];
const originalFetch = globalThis.fetch;
globalThis.fetch = async (url, options = {}) => {
  const parsed = new URL(url);
  assert.equal(parsed.hostname, 'enqueue-test.invalid', 'enqueue must never contact TikTok or another external service');
  requests.push({ url: parsed, method: options.method ?? 'GET' });
  const body = options.method === 'POST' ? JSON.parse(options.body) : [];
  return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } });
};
try {
  const { queueRecipeIngestion } = await import('../lib/recipe-ingestion.js');
  const result = await queueRecipeIngestion({ user_id: 'test-user', source_url: 'https://vt.tiktok.com/test-link/', target_state: 'saved' });
  assert.equal(result.job.status, 'queued');
  assert.ok(result.job.id);
  assert.equal(requests.filter((request) => request.method === 'POST').length, 1, 'store one durable job');
  const jobReads = requests.filter((request) => request.method === 'GET' && request.url.pathname === '/rest/v1/recipe_ingestion_jobs');
  assert.equal(jobReads.length, 4, 'disabled Redis must skip both contention retry passes (four redundant job reads)');
  assert.equal(result.processing_mode, 'queued', 'the share request must acknowledge enqueue without running extraction');
  console.log('share import enqueue: all assertions passed');
} finally {
  globalThis.fetch = originalFetch;
}
