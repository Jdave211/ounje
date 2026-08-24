import { notFound } from "next/navigation";

import { resolveShareRecipe, sharePageURL } from "../../../lib/share-data.js";
import { RecipeSharePage } from "./recipe-page.jsx";

export const dynamic = "force-dynamic";
export const revalidate = 0;

const SHARE_IMAGE_VERSION = "20260824-3";

function metadataDescription(recipe) {
  return recipe.description || `${recipe.ingredients.length} ingredients and ${recipe.steps.length} cooking steps.`;
}

export async function generateMetadata({ params }) {
  const { shareId } = await params;
  let result;
  try {
    result = await resolveShareRecipe(shareId);
  } catch {
    return {
      title: { absolute: "Recipe temporarily unavailable | Ounje" },
      robots: { index: false, follow: false },
    };
  }

  if (result.kind !== "ready") {
    return {
      title: { absolute: "Recipe unavailable | Ounje" },
      robots: { index: false, follow: false },
    };
  }

  const canonicalURL = sharePageURL(result.shareID);
  const description = metadataDescription(result.recipe);
  const shareTitle = `Ounje · ${result.recipe.title}`;
  const shareImageURL = `${canonicalURL}/preview-image?v=${SHARE_IMAGE_VERSION}`;
  const shareImage = {
    url: shareImageURL,
    width: 1080,
    height: 1080,
    alt: `${result.recipe.title} recipe`,
  };

  return {
    title: { absolute: shareTitle },
    description,
    alternates: { canonical: canonicalURL },
    openGraph: {
      type: "article",
      url: canonicalURL,
      siteName: "Ounje",
      title: shareTitle,
      description,
      images: [shareImage],
    },
    twitter: {
      card: "summary",
      title: shareTitle,
      description,
      images: [{ url: shareImageURL, alt: shareImage.alt }],
    },
  };
}

export default async function SharedRecipeRoute({ params }) {
  const { shareId } = await params;
  const result = await resolveShareRecipe(shareId);
  if (result.kind !== "ready") notFound();

  const canonicalURL = sharePageURL(result.shareID);
  return <RecipeSharePage recipe={result.recipe} canonicalURL={canonicalURL} />;
}
