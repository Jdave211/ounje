import sharp from "sharp";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../lib/share-data.js", () => ({
  resolveShareRecipe: vi.fn(),
}));

import { GET } from "../app/r/[shareId]/preview-image/route.js";
import { resolveShareRecipe } from "../lib/share-data.js";

describe("recipe share preview image", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("returns a compressed, opaque, cacheable square JPEG", async () => {
    const source = await sharp({
      create: {
        width: 1080,
        height: 1920,
        channels: 3,
        background: { r: 160, g: 82, b: 30 },
      },
    }).jpeg({ quality: 95 }).toBuffer();

    resolveShareRecipe.mockResolvedValue({
      kind: "ready",
      shareID: "JQw4nE_BVP1u",
      recipe: {
        heroURL: "https://images.example/creme.jpg",
        usesSquircleHero: true,
      },
    });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(source, {
      headers: {
        "Content-Length": String(source.length),
        "Content-Type": "image/jpeg",
      },
    })));

    const response = await GET(new Request("https://ounje.test/preview-image"), {
      params: Promise.resolve({ shareId: "JQw4nE_BVP1u" }),
    });
    const output = Buffer.from(await response.arrayBuffer());
    const metadata = await sharp(output).metadata();

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("image/jpeg");
    expect(response.headers.get("cache-control")).toContain("immutable");
    expect(response.headers.get("cdn-cache-control")).toContain("s-maxage=31536000");
    expect(metadata.width).toBe(1080);
    expect(metadata.height).toBe(1080);
    expect(metadata.hasAlpha).toBe(false);
  });
});
