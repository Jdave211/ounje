import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../lib/share-data.js", () => ({
  resolveShareRecipe: vi.fn(),
  sharePageURL: (shareID) => `https://ounje-recipe.vercel.app/r/${shareID}`,
}));

import { resolveShareRecipe } from "../lib/share-data.js";
import { generateMetadata } from "../app/r/[shareId]/page.jsx";

describe("recipe share metadata", () => {
  beforeEach(() => {
    resolveShareRecipe.mockResolvedValue({
      kind: "ready",
      shareID: "JQw4nE_BVP1u",
      recipe: {
        title: "Crème Brûlée",
        description: "Classic custard with caramelized sugar.",
        ingredients: [],
        steps: [],
      },
    });
  });

  it("uses a cache-busted square image without putting copy in its URL", async () => {
    const metadata = await generateMetadata({
      params: Promise.resolve({ shareId: "JQw4nE_BVP1u" }),
    });

    expect(metadata.openGraph.images).toEqual([
      {
        url: "https://ounje-recipe.vercel.app/r/JQw4nE_BVP1u/preview-image?v=20260824-3",
        width: 1080,
        height: 1080,
        alt: "Crème Brûlée recipe",
      },
    ]);
    expect(metadata.twitter.card).toBe("summary");
    expect(metadata.twitter.images).toEqual([
      {
        url: "https://ounje-recipe.vercel.app/r/JQw4nE_BVP1u/preview-image?v=20260824-3",
        alt: "Crème Brûlée recipe",
      },
    ]);
  });
});
