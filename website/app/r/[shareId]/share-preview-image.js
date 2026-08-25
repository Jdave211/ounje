import sharp from "sharp";

const MAX_SOURCE_BYTES = 8 * 1024 * 1024;

export const SHARE_PREVIEW_SIZE = 1080;
export const SHARE_PREVIEW_QUALITY = 78;

function clampFocus(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(1, Math.max(0, number)) : 0.5;
}

function squareCrop(width, height, verticalFocus) {
  const side = Math.min(width, height);
  return {
    left: width > side ? Math.round((width - side) / 2) : 0,
    top: height > side ? Math.round((height - side) * clampFocus(verticalFocus)) : 0,
    width: side,
    height: side,
  };
}

async function fetchSourceImage(imageURL, fetchImplementation) {
  if (!imageURL) return null;

  const response = await fetchImplementation(imageURL, {
    cache: "force-cache",
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) return null;

  const contentType = response.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase();
  if (!contentType?.startsWith("image/") || contentType === "image/svg+xml") return null;

  const contentLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(contentLength) && contentLength > MAX_SOURCE_BYTES) return null;

  const bytes = Buffer.from(await response.arrayBuffer());
  return bytes.length > 0 && bytes.length <= MAX_SOURCE_BYTES ? bytes : null;
}

export async function createSharePreviewImage(imageURL, options = {}) {
  const fetchImplementation = options.fetchImplementation ?? fetch;
  const source = await fetchSourceImage(imageURL, fetchImplementation);
  if (!source) return null;

  const metadata = await sharp(source, { failOn: "error", limitInputPixels: 40_000_000 }).metadata();
  const width = metadata.autoOrient?.width ?? metadata.width;
  const height = metadata.autoOrient?.height ?? metadata.height;
  if (!width || !height) return null;

  return sharp(source, { failOn: "error", limitInputPixels: 40_000_000 })
    .rotate()
    .extract(squareCrop(width, height, options.verticalFocus))
    .resize(SHARE_PREVIEW_SIZE, SHARE_PREVIEW_SIZE, { fit: "fill" })
    .flatten({ background: "#ffffff" })
    .jpeg({
      quality: SHARE_PREVIEW_QUALITY,
      progressive: true,
      chromaSubsampling: "4:2:0",
      optimiseCoding: true,
    })
    .toBuffer();
}
