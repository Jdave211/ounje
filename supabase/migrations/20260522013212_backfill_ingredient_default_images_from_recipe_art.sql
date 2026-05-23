-- Promote existing recipe ingredient art into the canonical ingredient catalog.
--
-- Many common ingredients existed in public.ingredients but had no
-- default_image_url, while public.recipe_ingredients already had trusted image
-- URLs for the same names. Filling the catalog keeps future cart/image lookups
-- index-friendly through ingredients.normalized_name.

WITH recipe_art AS (
  SELECT DISTINCT ON (public.main_shop_item_image_lookup_key(display_name))
    public.main_shop_item_image_lookup_key(display_name) AS normalized_name,
    image_url
  FROM public.recipe_ingredients
  WHERE public.main_shop_item_image_lookup_key(display_name) IS NOT NULL
    AND nullif(trim(coalesce(image_url, '')), '') IS NOT NULL
  ORDER BY public.main_shop_item_image_lookup_key(display_name), sort_order NULLS LAST, id
)
UPDATE public.ingredients ingredients
SET default_image_url = recipe_art.image_url,
    updated_at = timezone('utc', now())
FROM recipe_art
WHERE ingredients.normalized_name = recipe_art.normalized_name
  AND nullif(trim(coalesce(ingredients.default_image_url, '')), '') IS NULL;

WITH candidates AS (
  SELECT DISTINCT ON (m.id)
    m.id,
    i.default_image_url
  FROM public.main_shop_items m
  CROSS JOIN LATERAL (
    VALUES
      (1, m.canonical_key),
      (2, m.name),
      (3, m.removal_key)
  ) AS candidate(priority, value)
  JOIN public.ingredients i
    ON i.normalized_name = public.main_shop_item_image_lookup_key(candidate.value)
   AND nullif(trim(coalesce(i.default_image_url, '')), '') IS NOT NULL
  WHERE nullif(trim(coalesce(m.image_url, '')), '') IS NULL
  ORDER BY m.id, candidate.priority
)
UPDATE public.main_shop_items m
SET image_url = candidates.default_image_url
FROM candidates
WHERE m.id = candidates.id
  AND nullif(trim(coalesce(m.image_url, '')), '') IS NULL;
