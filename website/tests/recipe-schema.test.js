import { describe, expect, it } from "vitest";

import {
  parseRecipeSnapshot,
  RecipeSnapshotError,
  serializeJSONForHTML,
} from "../lib/recipe-schema.js";

function snapshot(overrides = {}) {
  return {
    version: 1,
    recipe_card: {
      title: "Pepper Prawns",
      author_handle: "@9resha",
    },
    recipe_detail: {
      title: "Pepper Prawns",
      description: "Bright, peppery prawns.",
      author_handle: "@9resha",
      servings_count: 4,
      hero_image_url: "https://images.example/pepper-prawns.jpg",
      source_provenance_json: {
        canonical_url: "https://www.tiktok.com/@9resha/video/123",
      },
      ingredients: [
        { display_name: "Prawns", quantity_text: "1 lb", image_url: "https://images.example/prawns.jpg" },
      ],
      steps: [
        { number: 1, text: "Cook the prawns.", ingredient_refs: ["Prawns"] },
      ],
      ...overrides,
    },
  };
}

describe("parseRecipeSnapshot", () => {
  it("normalizes a complete stored snapshot", () => {
    const recipe = parseRecipeSnapshot(snapshot());
    expect(recipe.title).toBe("Pepper Prawns");
    expect(recipe.creator).toBe("@9resha");
    expect(recipe.originalSourceURL).toBe("https://www.tiktok.com/@9resha/video/123");
    expect(recipe.originalSourceKind).toBe("video");
    expect(recipe.usesSquircleHero).toBe(true);
    expect(recipe.ingredients).toHaveLength(1);
    expect(recipe.steps).toHaveLength(1);
    expect(recipe.metrics).toHaveLength(9);
  });

  it("accepts an older JSON-string snapshot", () => {
    expect(parseRecipeSnapshot(JSON.stringify(snapshot())).title).toBe("Pepper Prawns");
  });

  it("uses the squircle hero for imported recipes without a social source", () => {
    const recipe = parseRecipeSnapshot(snapshot({
      id: "uir_recipe-123",
      source_provenance_json: null,
      original_recipe_url: "https://recipes.example/imported",
    }));
    expect(recipe.originalSourceKind).toBe("link");
    expect(recipe.usesSquircleHero).toBe(true);
  });

  it("keeps native Ounje recipes in the circular treatment", () => {
    const recipe = parseRecipeSnapshot(snapshot({
      id: "recipe-123",
      source_provenance_json: null,
      original_recipe_url: null,
    }));
    expect(recipe.originalSourceURL).toBeNull();
    expect(recipe.usesSquircleHero).toBe(false);
  });

  it("recognizes common video import URLs", () => {
    const recipe = parseRecipeSnapshot(snapshot({
      source_provenance_json: {
        canonical_url: "https://www.instagram.com/reel/ABC123/",
      },
    }));
    expect(recipe.originalSourceKind).toBe("video");
    expect(recipe.usesSquircleHero).toBe(true);
  });

  it("rejects incomplete or malformed snapshots", () => {
    expect(() => parseRecipeSnapshot(snapshot({ ingredients: [] }))).toThrow(RecipeSnapshotError);
    expect(() => parseRecipeSnapshot(snapshot({ steps: "not-a-list" }))).toThrow(RecipeSnapshotError);
    expect(() => parseRecipeSnapshot("{bad json")).toThrow(RecipeSnapshotError);
  });
});

describe("serializeJSONForHTML", () => {
  it("neutralizes closing script tags", () => {
    const serialized = serializeJSONForHTML({ name: "</script><script>alert(1)</script>" });
    expect(serialized).not.toContain("</script>");
    expect(serialized).toContain("\\u003c/script>");
  });
});
