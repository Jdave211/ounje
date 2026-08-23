import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";
process.env.SUPABASE_SERVICE_ROLE_KEY = "";
process.env.REDIS_URL = "";
process.env.RECIPE_INGESTION_TIKTOK_CANONICAL_RESOLVE_TIMEOUT_MS = "1000";

const execFileAsync = promisify(execFile);
const {
  expandCanonicalSourceURL,
  needsTikTokVideoFallback,
  sampleVideoFrames,
} = await import("../lib/recipe-ingestion.js");

const stalledServer = createServer(() => {});
await new Promise((resolve) => stalledServer.listen(0, "127.0.0.1", resolve));

try {
  assert.equal(needsTikTokVideoFallback("tiktok", null), true);
  assert.equal(needsTikTokVideoFallback("tiktok", ""), true);
  assert.equal(needsTikTokVideoFallback("tiktok", "https://cdn.example.com/video.mp4"), false);
  assert.equal(needsTikTokVideoFallback("instagram", null), false);

  const canonicalURL = "https://www.tiktok.com/@ounje/video/7616089987406368022";
  const canonicalStartedAt = performance.now();
  assert.equal(await expandCanonicalSourceURL(canonicalURL, "tiktok"), canonicalURL);
  assert.ok(performance.now() - canonicalStartedAt < 100, "a canonical TikTok URL must bypass redirect cleanup");

  const address = stalledServer.address();
  const sharedURL = `http://127.0.0.1:${address.port}/shared-tiktok-link`;
  const resolveStartedAt = performance.now();
  const resolvedURL = await expandCanonicalSourceURL(sharedURL, "tiktok");
  const resolveDurationMs = performance.now() - resolveStartedAt;

  assert.equal(resolvedURL, sharedURL, "a timed-out redirect must preserve the original shared URL");
  assert.ok(resolveDurationMs < 2_500, `redirect cleanup exceeded its budget (${Math.round(resolveDurationMs)}ms)`);

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "ounje-video-pipeline-test-"));
  try {
    const videoPath = path.join(tempDir, "sample.mp4");
    await execFileAsync("ffmpeg", [
      "-y",
      "-f", "lavfi",
      "-i", "testsrc2=duration=12:size=640x360:rate=24",
      "-c:v", "libx264",
      "-pix_fmt", "yuv420p",
      videoPath,
    ], { timeout: 20_000 });

    const frameStartedAt = performance.now();
    const frames = await sampleVideoFrames(videoPath, 12);
    const frameDurationMs = performance.now() - frameStartedAt;

    assert.equal(frames.length, 12, `expected 12 frames from one batch, received ${frames.length}`);
    assert.ok(frames.every((frame) => frame.startsWith("data:image/jpeg;base64,")), "all sampled frames must be JPEG data URLs");

    console.log(JSON.stringify({
      redirect_cleanup_ms: Math.round(resolveDurationMs),
      frame_count: frames.length,
      frame_batch_ms: Math.round(frameDurationMs),
    }, null, 2));
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
} finally {
  await new Promise((resolve) => stalledServer.close(resolve));
}
