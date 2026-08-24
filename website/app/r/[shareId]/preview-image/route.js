import { resolveShareRecipe } from "../../../../lib/share-data.js";
import { createSharePreviewImage } from "../share-preview-image.js";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BROWSER_CACHE = "public, max-age=31536000, immutable";
const EDGE_CACHE = "public, s-maxage=31536000, stale-while-revalidate=86400";

export async function GET(_request, { params }) {
  const { shareId } = await params;
  let result;
  try {
    result = await resolveShareRecipe(shareId, { hydrateIngredientImages: false });
  } catch {
    return new Response(null, { status: 503 });
  }

  if (result.kind !== "ready" || !result.recipe.heroURL) {
    return new Response(null, { status: 404 });
  }

  try {
    const image = await createSharePreviewImage(result.recipe.heroURL, {
      verticalFocus: result.recipe.usesSquircleHero ? 0.79 : 0.5,
    });
    if (!image) return new Response(null, { status: 404 });

    return new Response(image, {
      headers: {
        "Cache-Control": BROWSER_CACHE,
        "CDN-Cache-Control": EDGE_CACHE,
        "Content-Length": String(image.length),
        "Content-Type": "image/jpeg",
        "Vercel-CDN-Cache-Control": EDGE_CACHE,
      },
    });
  } catch {
    return new Response(null, { status: 502 });
  }
}
