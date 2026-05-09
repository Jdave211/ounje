-- Backfill Discover bracket shelves from deterministic recipe fields.
--
-- This keeps bracket browsing fast and non-inferential: the app can fetch
-- recipes by discover_brackets directly instead of running semantic retrieval
-- when a user taps Lunch, Drinks, Dessert, etc.

WITH recipe_text AS (
  SELECT
    id,
    COALESCE(discover_brackets, '{}'::text[]) AS existing_brackets,
    LOWER(CONCAT_WS(
      ' ',
      title,
      description,
      category,
      subcategory,
      recipe_type,
      skill_level,
      main_protein,
      cook_method,
      ARRAY_TO_STRING(COALESCE(dietary_tags, '{}'::text[]), ' '),
      ARRAY_TO_STRING(COALESCE(flavor_tags, '{}'::text[]), ' '),
      ARRAY_TO_STRING(COALESCE(cuisine_tags, '{}'::text[]), ' '),
      ARRAY_TO_STRING(COALESCE(occasion_tags, '{}'::text[]), ' '),
      ingredients_text,
      instructions_text
    )) AS haystack,
    LOWER(COALESCE(category, '')) AS category_text,
    LOWER(COALESCE(recipe_type, '')) AS recipe_type_text,
    LOWER(COALESCE(skill_level, '')) AS skill_text,
    COALESCE(calories_kcal, 0) AS calories_kcal
  FROM public.recipes
),
inferred AS (
  SELECT
    id,
    existing_brackets,
    ARRAY_REMOVE(ARRAY[
      CASE
        WHEN recipe_type_text = 'breakfast'
          OR category_text = 'breakfast'
          OR haystack ~ '\m(breakfast|brunch|overnight oats?|baked oats?|oatmeal|porridge|pancakes?|waffles?|omelet|omelette|frittata|granola|parfait|smoothie bowl|yogurt bowl|avocado toast|bagel|breakfast sandwich|breakfast burrito|hash brown)\M'
        THEN 'breakfast'
      END,
      CASE
        WHEN recipe_type_text = 'lunch'
          OR category_text = 'lunch'
          OR haystack ~ '\m(lunch|sandwich|wrap|bowl|salad|toastie|panini)\M'
        THEN 'lunch'
      END,
      CASE
        WHEN recipe_type_text = 'dinner'
          OR category_text = 'dinner'
          OR haystack ~ '\m(dinner|roast|stir[- ]?fry|traybake|skillet|curry|chili|braise|casserole)\M'
        THEN 'dinner'
      END,
      CASE
        WHEN recipe_type_text = 'dessert'
          OR category_text = 'dessert'
          OR haystack ~ '\m(cookie|cookies|cake|cheesecake|brownie|brownies|pudding|ice cream|gelato|pie|tart|cobbler|cupcake|fudge|dessert|sweet rolls?|banana bread)\M'
        THEN 'dessert'
      END,
      CASE
        WHEN (
          recipe_type_text IN ('drink', 'drinks', 'beverage', 'beverages')
          OR category_text IN ('drink', 'drinks', 'beverage', 'beverages')
          OR haystack ~ '\m(smoothie|smoothies|juice|juices|latte|lattes|coffee|tea|matcha|lemonade|spritz|cocktail|mocktail|soda|shake|milkshake|margarita|mojito|punch|cocoa|espresso)\M'
        )
        AND haystack !~ '\m(soup|salad|bowl|sandwich|wrap|taco|pasta|noodle|rice|chicken|beef|steak|salmon|shrimp|cod|bean|potato)\M'
        THEN 'drinks'
      END,
      CASE WHEN haystack ~ '\mvegetarian\M' THEN 'vegetarian' END,
      CASE WHEN haystack ~ '\mvegan\M' THEN 'vegan' END,
      CASE WHEN haystack ~ '\m(pasta|spaghetti|linguine|penne|rigatoni|fusilli|macaroni|ravioli|noodle|noodles)\M' THEN 'pasta' END,
      CASE WHEN haystack ~ '\mchicken\M' THEN 'chicken' END,
      CASE WHEN haystack ~ '\m(steak|beef|sirloin|ribeye|flank|brisket|short rib)\M' THEN 'steak' END,
      CASE WHEN haystack ~ '\msalmon\M' THEN 'salmon' END,
      CASE WHEN haystack ~ '\m(salmon|fish|cod|snapper|tilapia|trout|sea bass|halibut|mackerel|tuna|shrimp|prawn|lobster|crab|scallop|seafood)\M' THEN 'fish' END,
      CASE WHEN haystack ~ '\m(nigerian|west african|jollof|egusi|suya|akara|moin[[:space:]]?moin|ofada|banga|pepper soup|puff puff|yam porridge|okro|ogbono)\M' THEN 'nigerian' END,
      CASE WHEN haystack ~ '\m(salad|slaw|greens|caesar)\M' THEN 'salad' END,
      CASE WHEN haystack ~ '\m(sandwich|sandwiches|burger|wrap|panini|toastie)\M' THEN 'sandwich' END,
      CASE WHEN haystack ~ '\m(bean|beans|lentil|lentils|chickpea|chickpeas|legume|legumes)\M' THEN 'beans' END,
      CASE WHEN haystack ~ '\m(potato|potatoes|sweet potato|hash brown)\M' THEN 'potatoes' END,
      CASE WHEN skill_text ~ '(beginner|easy|simple)' OR haystack ~ '\m(beginner|easy|simple|quick)\M' THEN 'beginner' END,
      CASE WHEN calories_kcal > 0 AND calories_kcal <= 500 THEN 'under500' END
    ]::text[], NULL) AS inferred_brackets,
    recipe_type_text,
    category_text
  FROM recipe_text
),
merged AS (
  SELECT
    id,
    ARRAY(
      SELECT DISTINCT bracket
      FROM UNNEST(
        CASE
          WHEN CARDINALITY(existing_brackets || inferred_brackets) > 0
            THEN existing_brackets || inferred_brackets
          WHEN recipe_type_text = 'breakfast' OR category_text = 'breakfast'
            THEN ARRAY['breakfast']::text[]
          WHEN recipe_type_text = 'lunch' OR category_text = 'lunch'
            THEN ARRAY['lunch']::text[]
          WHEN recipe_type_text = 'dessert' OR category_text = 'dessert'
            THEN ARRAY['dessert']::text[]
          ELSE ARRAY['dinner']::text[]
        END
      ) AS bracket
      WHERE bracket IS NOT NULL
        AND bracket <> ''
        AND bracket <> 'all'
      ORDER BY bracket
    ) AS discover_brackets
  FROM inferred
)
UPDATE public.recipes AS recipes
SET
  discover_brackets = merged.discover_brackets,
  discover_brackets_enriched_at = NOW()
FROM merged
WHERE recipes.id = merged.id
  AND CARDINALITY(merged.discover_brackets) > 0
  AND recipes.discover_brackets IS DISTINCT FROM merged.discover_brackets;
