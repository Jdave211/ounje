import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { RecipeSharePage } from "../app/r/[shareId]/recipe-page.jsx";
import { parseRecipeSnapshot } from "../lib/recipe-schema.js";

function longRecipe() {
  return parseRecipeSnapshot({
    version: 1,
    recipe_card: { title: "A <script>alert('x')</script> recipe" },
    recipe_detail: {
      title: "A <script>alert('x')</script> recipe",
      description: "Complete & carefully tested.",
      author_handle: "@creator",
      original_recipe_url: "https://example.com/original",
      hero_image_url: "https://images.example/hero.jpg",
      servings_count: 6,
      ingredients: Array.from({ length: 17 }, (_, index) => ({
        id: `ingredient-${index + 1}`,
        display_name: `Ingredient ${index + 1}`,
        quantity_text: `${index + 1} cups`,
        image_url: `https://images.example/${index + 1}.jpg`,
      })),
      steps: Array.from({ length: 15 }, (_, index) => ({
        number: index + 1,
        text: `Complete cooking step ${index + 1}.`,
      })),
    },
  });
}

describe("RecipeSharePage", () => {
  it("uses a squircle hero for TikTok or imported recipes", () => {
    const recipe = longRecipe();
    recipe.usesSquircleHero = true;
    const html = renderToStaticMarkup(
      <RecipeSharePage
        shareID="yQek7g_tAFvN"
        recipe={recipe}
        canonicalURL="https://recipes.example/r/yQek7g_tAFvN"
      />
    );
    expect(html).toContain("hero-image--squircle");
  });

  it("labels video imports as the original video", () => {
    const recipe = longRecipe();
    recipe.originalSourceKind = "video";
    const html = renderToStaticMarkup(
      <RecipeSharePage
        shareID="yQek7g_tAFvN"
        recipe={recipe}
        canonicalURL="https://recipes.example/r/yQek7g_tAFvN"
      />
    );
    expect(html).toContain("See original video");
    expect(html).not.toContain("See original link");
  });

  it("renders every ingredient and every long-list step", () => {
    const html = renderToStaticMarkup(
      <RecipeSharePage
        shareID="yQek7g_tAFvN"
        recipe={longRecipe()}
        canonicalURL="https://recipes.example/r/yQek7g_tAFvN"
      />
    );
    expect(html.match(/data-testid="ingredient-item"/g)).toHaveLength(17);
    expect(html.match(/data-testid="cooking-step"/g)).toHaveLength(15);
    expect(html.match(/data-testid="recipe-metric"/g)).toHaveLength(9);
    expect(html).toContain("Share");
    expect(html).toContain("Save on Ounje");
    expect(html).toContain('data-testid="copy-recipe-link"');
    expect(html).toContain('data-testid="save-on-ounje-link"');
    expect(html).toContain('href="https://apps.apple.com/app/id6504951799"');
    expect(html).not.toContain('class="recipe-actions__logo"');
    expect(html).not.toContain('class="open-in-app"');
    expect(html).not.toContain("share-masthead");
    expect(html).toContain("See original link");
    expect(html).toContain('data-testid="original-source-dialog"');
    expect(html).toContain('class="original-source-dialog__logo"');
    expect(html).toContain("Turn any TikTok into an actual recipe.");
    expect(html).toContain('data-testid="original-source-download"');
    expect(html).toContain('data-testid="original-source-proceed"');
    expect(html).toContain('href="https://example.com/original"');
  });

  it("escapes visible content and JSON-LD script content", () => {
    const html = renderToStaticMarkup(
      <RecipeSharePage
        shareID="yQek7g_tAFvN"
        recipe={longRecipe()}
        canonicalURL="https://recipes.example/r/yQek7g_tAFvN"
      />
    );
    expect(html).not.toContain("<script>alert('x')</script>");
    expect(html).toContain("&lt;script&gt;alert(&#x27;x&#x27;)&lt;/script&gt;");
    expect(html).toContain("\\u003cscript>alert('x')\\u003c/script>");
  });
});
