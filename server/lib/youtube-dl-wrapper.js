let cachedYoutubeDl = null;

export async function runYoutubeDl(sourceURL, options = {}, execOptions = {}) {
  const youtubeDl = await loadYoutubeDl();
  if (execOptions && Object.keys(execOptions).length > 0 && typeof youtubeDl.exec === "function") {
    const result = await youtubeDl.exec(sourceURL, options, execOptions);
    const stdout = String(result?.stdout ?? "").trim();
    if (stdout.startsWith("{")) {
      return JSON.parse(stdout);
    }
    return stdout;
  }
  return youtubeDl(sourceURL, options);
}

async function loadYoutubeDl() {
  if (cachedYoutubeDl) {
    return cachedYoutubeDl;
  }

  const configuredBinaryPath = String(
    process.env.YOUTUBE_DL_BINARY
      ?? process.env.YOUTUBE_DL_PATH
      ?? ""
  ).trim();

  try {
    const module = await import("youtube-dl-exec");
    if (configuredBinaryPath) {
      const createYoutubeDl = module.create ?? module.default?.create ?? null;
      if (typeof createYoutubeDl !== "function") {
        throw new Error("youtube-dl-exec.create is unavailable.");
      }
      cachedYoutubeDl = createYoutubeDl(configuredBinaryPath);
      return cachedYoutubeDl;
    }
    cachedYoutubeDl = module.default ?? module;
    return cachedYoutubeDl;
  } catch (error) {
    const wrapped = new Error(configuredBinaryPath
      ? `youtube-dl-exec could not use configured binary: ${configuredBinaryPath}`
      : "youtube-dl-exec is unavailable in this runtime.");
    wrapped.cause = error;
    throw wrapped;
  }
}
