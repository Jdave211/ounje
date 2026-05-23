-- Fill main shop/cart item images from the canonical ingredient catalog.
--
-- The client usually sends image_url from MainShopSnapshot, but fallback rows
-- can still be inserted with a null image_url. This keeps cart rows visually
-- useful without making clients perform extra image lookups on hot paths.

CREATE OR REPLACE FUNCTION public.main_shop_item_image_lookup_key(value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(
    regexp_replace(
      regexp_replace(lower(trim(coalesce(value, ''))), '[^a-z0-9]+', ' ', 'g'),
      '\s+',
      ' ',
      'g'
    ),
    ''
  )
$$;

CREATE OR REPLACE FUNCTION public.fill_main_shop_item_image_url()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $$
DECLARE
  candidate_key text;
  candidate_keys text[];
BEGIN
  IF nullif(trim(coalesce(NEW.image_url, '')), '') IS NOT NULL THEN
    RETURN NEW;
  END IF;

  candidate_keys := ARRAY[
    public.main_shop_item_image_lookup_key(NEW.canonical_key),
    public.main_shop_item_image_lookup_key(NEW.name),
    public.main_shop_item_image_lookup_key(NEW.removal_key)
  ];

  FOREACH candidate_key IN ARRAY candidate_keys LOOP
    CONTINUE WHEN candidate_key IS NULL;

    SELECT i.default_image_url
      INTO NEW.image_url
    FROM public.ingredients i
    WHERE i.normalized_name = candidate_key
      AND nullif(trim(coalesce(i.default_image_url, '')), '') IS NOT NULL
    LIMIT 1;

    IF nullif(trim(coalesce(NEW.image_url, '')), '') IS NOT NULL THEN
      RETURN NEW;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fill_main_shop_item_image_url ON public.main_shop_items;
CREATE TRIGGER trg_fill_main_shop_item_image_url
  BEFORE INSERT OR UPDATE OF canonical_key, name, removal_key, image_url
  ON public.main_shop_items
  FOR EACH ROW
  EXECUTE FUNCTION public.fill_main_shop_item_image_url();

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
