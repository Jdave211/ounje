import { describe, expect, it, vi } from "vitest";

import {
  fetchActiveShareRow,
  hydrateRecipeIngredientImages,
  ingredientImageLookupKeys,
  isValidShareID,
  resolveShareRecipeOnce,
} from "../lib/share-data.js";

const environment = {
  SUPABASE_URL: "https://project.supabase.co",
  SUPABASE_SECRET_KEY: "sb_secret_test",
};

describe("share ID validation", () => {
  it("accepts generated base64url IDs and rejects malformed IDs", () => {
    expect(isValidShareID("yQek7g_tAFvN")).toBe(true);
    expect(isValidShareID("../private" )).toBe(false);
    expect(isValidShareID("too-short")).toBe(false);
    expect(isValidShareID("<script>alert(1)</script>")).toBe(false);
  });

  it("does not query Supabase for a bad share ID", async () => {
    const fetchImplementation = vi.fn();
    const result = await resolveShareRecipeOnce("bad", { environment, fetchImplementation });
    expect(result.kind).toBe("not_found");
    expect(fetchImplementation).not.toHaveBeenCalled();
  });
});

describe("active share lookup", () => {
  it("uses the narrow active-row contract and keeps the secret out of Authorization", async () => {
    const fetchImplementation = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => [],
    }));
    await fetchActiveShareRow("yQek7g_tAFvN", { environment, fetchImplementation });
    const [url, options] = fetchImplementation.mock.calls[0];
    expect(url.searchParams.get("select")).toBe("share_id,status,snapshot_json");
    expect(url.searchParams.get("status")).toBe("eq.active");
    expect(options.headers.apikey).toBe("sb_secret_test");
    expect(options.headers.Authorization).toBeUndefined();
  });
});

describe("ingredient image hydration", () => {
  it("matches trusted catalogue images across common imported-ingredient wording", async () => {
    const fetchImplementation = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => [
        { normalized_name: "butter", display_name: "Butter", default_image_url: "https://images.example/butter.jpg" },
        { normalized_name: "red bell pepper", display_name: "Red Bell Pepper", default_image_url: "https://images.example/pepper.jpg" },
        { normalized_name: "sugar", display_name: "Sugar", default_image_url: "https://images.example/sugar.jpg" },
      ],
    }));
    const recipe = {
      ingredients: [
        { name: "Unsalted butter, softened", imageURL: null },
        { name: "Red bell peppers", imageURL: null },
        { name: "Sugar (for topping)", imageURL: null },
        { name: "Eggs", imageURL: "https://images.example/eggs.jpg" },
      ],
    };

    const hydrated = await hydrateRecipeIngredientImages(recipe, { environment, fetchImplementation });

    expect(hydrated.ingredients.map((ingredient) => ingredient.imageURL)).toEqual([
      "https://images.example/butter.jpg",
      "https://images.example/pepper.jpg",
      "https://images.example/sugar.jpg",
      "https://images.example/eggs.jpg",
    ]);
    const [url] = fetchImplementation.mock.calls[0];
    expect(url.pathname).toBe("/rest/v1/ingredients");
    expect(url.searchParams.get("default_image_url")).toBe("not.is.null");
  });

  it("generates aliases without losing the original ingredient name", () => {
    expect(ingredientImageLookupKeys("Fresh lemon wedges")).toEqual(expect.arrayContaining(["fresh lemon wedges", "lemon wedge", "lemon"]));
    expect(ingredientImageLookupKeys("Whole milk")).toContain("milk");
  });
});
