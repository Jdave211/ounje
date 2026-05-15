import { parseIngredientObjects } from "./recipe-detail-utils.js";

const WORD_SPLIT = /[^a-z0-9]+/g;

function normalizeText(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[’']/g, "")
    .replace(WORD_SPLIT, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function singularizeToken(token) {
  if (token.length <= 3) return token;
  if (token.endsWith("ies")) return `${token.slice(0, -3)}y`;
  if (token.endsWith("es") && !token.endsWith("ses")) return token.slice(0, -2);
  if (token.endsWith("s") && !token.endsWith("ss")) return token.slice(0, -1);
  return token;
}

function normalizedName(value) {
  return normalizeText(value)
    .split(" ")
    .map(singularizeToken)
    .join(" ")
    .trim();
}

function normalizedIngredientRowsFromRecipe(value) {
  const rawIngredients = Array.isArray(value?.ingredients) ? value.ingredients : [];
  return parseIngredientObjects(rawIngredients)
    .map((ingredient, index) => ({
      displayName: String(ingredient.display_name ?? ingredient.name ?? "").trim(),
      quantityText: String(
        ingredient.quantity_text
          ?? ([ingredient.quantity != null ? String(ingredient.quantity) : null, ingredient.unit]
            .filter(Boolean)
            .join(" ")
            .trim() || "")
      ).trim(),
      index,
    }))
    .filter((ingredient) => ingredient.displayName);
}

function normalizedIngredientRowsFromDetail(detail) {
  return (detail?.ingredients ?? [])
    .map((ingredient, index) => ({
      displayName: String(ingredient.display_name ?? ingredient.displayName ?? ingredient.name ?? "").trim(),
      quantityText: String(ingredient.quantity_text ?? ingredient.quantityText ?? "").trim(),
      index,
    }))
    .filter((ingredient) => ingredient.displayName);
}

function normalizedStepTextsFromRecipe(value) {
  return (value?.steps ?? [])
    .map((step) => normalizeText(typeof step === "string" ? step : step?.text ?? step?.instruction_text ?? ""))
    .filter(Boolean);
}

function normalizedStepTextsFromDetail(detail) {
  return (detail?.steps ?? [])
    .map((step) => normalizeText(step?.text ?? step?.instruction_text ?? ""))
    .filter(Boolean);
}

const INTENT_CONTRACTS = {
  vegetarian: {
    key: "vegetarian",
    label: "Make it vegetarian",
    requiredActions: [
      "Remove meat, seafood, meat stock, fish sauce, gelatin, and animal-derived broth from ingredients and steps.",
      "Add a plausible vegetarian protein or plant-forward base so the dish still feels complete.",
      "Rewrite affected cooking steps so removed animal ingredients are not referenced.",
      "Update dietary tags and summary to reflect the vegetarian version.",
    ],
    validationHints: [
      "The rewrite should remove animal ingredients from both ingredients and steps.",
      "The rewrite should keep the dish complete with a fitting vegetarian base or protein.",
    ],
    doNot: [
      "Do not leave meat, seafood, fish sauce, gelatin, meat stock, or animal broth in ingredients or steps.",
      "Do not simply remove the protein and leave the dish thin or incomplete.",
      "Do not only change the title or dietary tags.",
      "Do not add a vegetarian ingredient without using it in the cooking steps.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 lb chicken thighs", "1 tbsp fish sauce"],
          step_change: "Marinate chicken, skewer, then grill until cooked through.",
        },
        adapted: {
          ingredient_changes: ["14 oz extra-firm tofu, pressed and cubed", "2 tbsp soy sauce", "1 tbsp lemon juice"],
          step_change: "Press tofu, cube it, coat in shawarma marinade, then roast or air-fry until browned at the edges.",
        },
      },
      {
        base: {
          ingredient_changes: ["1 lb ground beef", "1 cup beef broth", "worcestershire sauce"],
          step_change: "Brown beef, simmer with beef broth, then spoon over rice.",
        },
        adapted: {
          ingredient_changes: ["1 1/2 cups cooked lentils", "8 oz mushrooms, finely chopped", "1 cup vegetable broth", "1 tbsp soy sauce"],
          step_change: "Brown mushrooms until their moisture cooks off, fold in lentils, then simmer with vegetable broth and soy sauce until savory and thick.",
        },
      },
    ],
  },
  dairy_free: {
    key: "dairy_free",
    label: "Make it dairy-free",
    requiredActions: [
      "Remove or replace dairy ingredients with practical dairy-free alternatives.",
      "Update quantities and steps so the sauce, texture, or fat source still works.",
      "Update dietary tags and summary to reflect the dairy-free version.",
    ],
    doNot: [
      "Do not leave butter, milk, cream, cheese, yogurt, sour cream, or dairy-based sauce in ingredients or steps.",
      "Do not remove dairy without replacing needed fat, body, saltiness, or creaminess.",
      "Do not use vague phrases like dairy-free substitute without naming a concrete grocery item.",
      "Do not only change the title or dietary tags.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 cup heavy cream", "1/2 cup grated parmesan", "2 tbsp butter"],
          step_change: "Simmer cream and parmesan until the sauce thickens.",
        },
        adapted: {
          ingredient_changes: ["3/4 cup full-fat coconut milk", "2 tbsp olive oil", "1 tbsp nutritional yeast"],
          step_change: "Simmer coconut milk with nutritional yeast and olive oil until glossy; do not add dairy.",
        },
      },
      {
        base: {
          ingredient_changes: ["1/2 cup sour cream", "1 cup shredded mozzarella", "2 tbsp butter"],
          step_change: "Stir sour cream into the filling, top with mozzarella, and broil until melted.",
        },
        adapted: {
          ingredient_changes: ["1/2 cup cashew cream", "2 tbsp olive oil", "2 tbsp nutritional yeast", "1 tbsp lemon juice"],
          step_change: "Stir cashew cream, nutritional yeast, olive oil, and lemon juice into the filling off heat for body and tang without dairy.",
        },
      },
    ],
  },
  less_sugar: {
    key: "less_sugar",
    label: "Less sugar",
    requiredActions: [
      "Reduce sweeteners and sugary ingredients without making the recipe flat.",
      "Adjust steps that depend on sweetness, caramelization, glaze thickness, or dessert texture.",
      "Keep enough balance that the dish remains satisfying.",
    ],
    doNot: [
      "Do not remove all sweetness when the recipe needs sweetness to work.",
      "Do not leave the same sugar, syrup, honey, glaze, or sweetened dairy quantities unchanged.",
      "Do not replace sugar with an unnamed sweetener.",
      "Do not only change the title, summary, or nutrition tags.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1/2 cup brown sugar", "1/4 cup honey", "1 cup sweetened yogurt"],
          step_change: "Whisk sugar and honey into the filling until very sweet.",
        },
        adapted: {
          ingredient_changes: ["2 tbsp brown sugar", "1 tbsp honey", "1 cup plain Greek yogurt", "1/2 tsp vanilla"],
          step_change: "Whisk the smaller amount of honey and sugar with vanilla into plain yogurt; rely on fruit or spice for balance.",
        },
      },
      {
        base: {
          ingredient_changes: ["1 cup white sugar", "1/2 cup chocolate chips", "1/4 cup caramel sauce"],
          step_change: "Cream sugar into the batter, fold in chocolate chips, then drizzle caramel before baking.",
        },
        adapted: {
          ingredient_changes: ["1/2 cup white sugar", "1/4 cup chocolate chips", "1/2 cup mashed banana", "1 tsp cinnamon"],
          step_change: "Beat the reduced sugar with mashed banana and cinnamon, fold in fewer chocolate chips, and skip the caramel drizzle.",
        },
      },
    ],
  },
  more_protein: {
    key: "more_protein",
    label: "More protein",
    requiredActions: [
      "Increase or add a real, named protein source that fits the dish.",
      "Use concrete grocery ingredients, not abstract nutrition labels.",
      "Keep the base dish format intact and upgrade the filling, topping, sauce, or core ingredient with a real protein where appropriate.",
      "Adjust quantities and steps for the higher-protein version.",
      "Update title, summary, and protein-aware tags if helpful.",
    ],
    doNot: [
      "Do not add vague ingredients like extra protein, protein boost, protein source, or protein powder unless the base recipe already uses protein powder.",
      "Do not add a random protein that clashes with the dish format or flavor profile.",
      "Do not add a protein ingredient without using it in the steps.",
      "Do not only increase serving size, title, or macros while leaving the recipe unchanged.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 cup all-purpose flour", "2 bananas", "1 egg"],
          step_change: "Mix the batter and bake.",
        },
        adapted: {
          ingredient_changes: ["3/4 cup all-purpose flour", "1/2 cup vanilla Greek yogurt", "2 eggs", "2 tbsp almond butter"],
          step_change: "Whisk Greek yogurt, eggs, and almond butter into the wet ingredients before folding in the reduced flour.",
        },
      },
      {
        base: {
          ingredient_changes: ["4 hot dog buns", "4 beef hot dogs"],
          step_change: "Warm hot dogs and assemble in buns.",
        },
        adapted: {
          ingredient_changes: ["4 turkey or beef hot dogs", "1 cup turkey chili", "1/2 cup shredded cheddar"],
          step_change: "Heat the turkey chili separately, spoon it over the hot dogs, then finish with cheddar so the extra protein is part of the dish.",
        },
      },
      {
        base: {
          ingredient_changes: ["1/2 lb ground beef", "2 cups roasted sweet potatoes", "1/4 cup corn", "2 tbsp mayo"],
          step_change: "Cook the beef, roast the sweet potatoes, and top with corn mayo.",
        },
        adapted: {
          ingredient_changes: ["3/4 lb lean ground beef", "1 cup black beans, drained and rinsed", "2 cups roasted sweet potatoes", "1/2 cup corn", "1/4 cup Greek yogurt", "1 tbsp lime juice"],
          step_change: "Brown the lean beef, fold in black beans to warm through, roast the sweet potatoes, then mix Greek yogurt, lime, and corn into a higher-protein street-corn topping.",
        },
      },
    ],
  },
  spicy: {
    key: "spicy",
    label: "Make it spicy",
    requiredActions: [
      "Add heat in a cuisine-appropriate way.",
      "Balance spice with acid, fat, sweetness, or freshness where needed.",
      "Update steps so the heat source is cooked, bloomed, finished, or served correctly.",
    ],
    doNot: [
      "Do not just add hot sauce to every recipe.",
      "Do not make the recipe one-note hot without balance.",
      "Do not add a spice that clashes with the cuisine or base flavor profile.",
      "Do not add a heat source without adding it to a specific step.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 tsp paprika", "1 tbsp olive oil", "1 tbsp lemon juice"],
          step_change: "Season and cook the protein.",
        },
        adapted: {
          ingredient_changes: ["1 tsp paprika", "1 tsp cayenne", "1 tbsp chili crisp", "2 tbsp lime juice"],
          step_change: "Bloom cayenne in the hot oil, cook the protein, then finish with chili crisp and lime so the heat has balance.",
        },
      },
      {
        base: {
          ingredient_changes: ["2 tbsp soy sauce", "1 tbsp honey", "1 tsp sesame oil"],
          step_change: "Whisk sauce and toss with cooked noodles.",
        },
        adapted: {
          ingredient_changes: ["2 tbsp soy sauce", "1 tbsp chili crisp", "1 tsp gochujang", "1 tbsp rice vinegar", "1 tsp sesame oil"],
          step_change: "Whisk chili crisp and gochujang into the sauce with rice vinegar, then toss with hot noodles so the heat coats evenly.",
        },
      },
    ],
  },
  quick: {
    key: "quick",
    label: "Make it quick",
    requiredActions: [
      "Shorten cook/prep time or simplify the method.",
      "Cut fussy prep, long marinades, long bakes, or unnecessary steps.",
      "Keep the recipe coherent and weeknight-practical.",
    ],
    doNot: [
      "Do not claim the recipe is quicker without reducing actual prep, cook, marinade, chill, bake, or simmer time.",
      "Do not remove steps that are required for food safety or doneness.",
      "Do not add more ingredients or more pans unless it clearly saves time.",
      "Do not only change cook_time_text while leaving the method unchanged.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["2-hour marinade", "whole roasted vegetables", "long-simmer sauce"],
          step_change: "Marinate for 2 hours, roast vegetables for 45 minutes, then simmer sauce.",
        },
        adapted: {
          ingredient_changes: ["10-minute spice rub", "thin-sliced vegetables", "quick skillet sauce"],
          step_change: "Rub seasoning directly onto the protein, sear it, saute thin-sliced vegetables in the same pan, and reduce sauce for 3-5 minutes.",
        },
      },
      {
        base: {
          ingredient_changes: ["whole chicken breasts", "whole potatoes", "scratch sauce"],
          step_change: "Bake whole chicken breasts for 35 minutes, roast potatoes for 45 minutes, then simmer sauce for 20 minutes.",
        },
        adapted: {
          ingredient_changes: ["thin-sliced chicken cutlets", "microwave-steamed baby potatoes, halved", "quick lemon-yogurt sauce"],
          step_change: "Sear thin chicken cutlets for 3-4 minutes per side, crisp the halved steamed potatoes in the same pan, and stir together the no-simmer sauce while they rest.",
        },
      },
    ],
  },
  extra_veggies: {
    key: "extra_veggies",
    label: "More veggies",
    requiredActions: [
      "Add vegetables that make sense for the dish.",
      "Adjust seasoning, moisture, and cooking steps so the added vegetables do not water down the recipe.",
    ],
    doNot: [
      "Do not add random vegetables that clash with the dish.",
      "Do not add watery vegetables without changing the cooking order or seasoning.",
      "Do not add vegetables only as a garnish if the request implies a more vegetable-forward recipe.",
      "Do not add a vegetable ingredient without using it in the steps.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 bell pepper", "1/2 onion"],
          step_change: "Cook aromatics, then add sauce.",
        },
        adapted: {
          ingredient_changes: ["1 bell pepper", "1 zucchini, diced", "1 cup mushrooms, sliced", "1/2 onion"],
          step_change: "Brown mushrooms first to drive off moisture, then add zucchini and bell pepper before the sauce.",
        },
      },
      {
        base: {
          ingredient_changes: ["1 cup pasta", "1/2 cup tomato sauce", "1/4 cup cheese"],
          step_change: "Boil pasta, toss with sauce, and top with cheese.",
        },
        adapted: {
          ingredient_changes: ["1 cup pasta", "1 cup chopped spinach", "1/2 cup zucchini, diced", "3/4 cup tomato sauce", "1/4 cup cheese"],
          step_change: "Saute zucchini until lightly browned, wilt spinach into the tomato sauce, then toss with pasta so the vegetables are built into the dish.",
        },
      },
    ],
  },
  low_carb: {
    key: "low_carb",
    label: "Make it low carb",
    requiredActions: [
      "Reduce or replace starch-heavy ingredients where it makes culinary sense.",
      "Update steps and serving format to match the lower-carb version.",
    ],
    doNot: [
      "Do not remove all structure from the dish by deleting its main base without a replacement.",
      "Do not call a recipe low carb while leaving the same rice, pasta, bread, tortilla, potato, flour, or sugar quantities unchanged.",
      "Do not use cauliflower rice or lettuce wraps automatically when they do not fit the dish.",
      "Do not only change the title or tags.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["2 cups cooked rice", "4 flour tortillas"],
          step_change: "Serve the filling over rice or wrapped in tortillas.",
        },
        adapted: {
          ingredient_changes: ["3 cups cauliflower rice", "large romaine leaves or low-carb wraps"],
          step_change: "Saute cauliflower rice until dry and fluffy, then serve the filling over it or tuck into lettuce leaves.",
        },
      },
      {
        base: {
          ingredient_changes: ["12 oz pasta", "1 cup cream sauce", "1/2 cup breadcrumbs"],
          step_change: "Boil pasta, toss with cream sauce, top with breadcrumbs, and bake.",
        },
        adapted: {
          ingredient_changes: ["4 cups roasted spaghetti squash", "1 cup cream sauce", "1/4 cup toasted almonds"],
          step_change: "Roast spaghetti squash until strands form, toss the strands with sauce, and finish with toasted almonds instead of breadcrumbs.",
        },
      },
    ],
  },
  crispy: {
    key: "crispy",
    label: "Make it crunchy",
    requiredActions: [
      "Add crunch or crisp texture through technique or ingredient choice.",
      "Update steps with the exact moment and method for getting the texture.",
    ],
    doNot: [
      "Do not just rename the dish crunchy.",
      "Do not add a crisp topping that will get soggy without instructions to keep or add it at the right time.",
      "Do not use the same soft method if the request needs texture change.",
      "Do not add crunch that clashes with the dish.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["plain baked topping"],
          step_change: "Bake until warmed through.",
        },
        adapted: {
          ingredient_changes: ["1/2 cup toasted panko", "2 tbsp chopped peanuts", "1 tbsp olive oil"],
          step_change: "Toast panko and peanuts in olive oil until golden, then scatter over the finished dish right before serving.",
        },
      },
      {
        base: {
          ingredient_changes: ["soft tortillas", "creamy filling", "salsa"],
          step_change: "Fill tortillas and serve immediately.",
        },
        adapted: {
          ingredient_changes: ["soft tortillas", "creamy filling", "1/2 cup shredded cabbage", "1/4 cup toasted pepitas"],
          step_change: "Warm tortillas, add creamy filling, then finish with shredded cabbage and toasted pepitas right before serving for crunch.",
        },
      },
    ],
  },
  healthier: {
    key: "healthier",
    label: "Make it healthy",
    requiredActions: [
      "Improve the nutrition profile while keeping the dish satisfying and recognizable.",
      "Identify the least balanced parts of the base recipe, then improve them with more produce, fiber, protein, or better fats where they fit.",
      "Reduce excess sugar, heavy fat, or refined starch only when it improves the dish.",
      "Update quantities, steps, timing, and summary so the healthier version is still fully cookable.",
    ],
    doNot: [
      "Do not turn every recipe into a salad or bowl.",
      "Do not remove flavor, sauce, or fat so aggressively that the dish becomes dry or joyless.",
      "Do not use vague health words without concrete ingredient or quantity changes.",
      "Do not only change nutrition tags, title, or summary.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 cup mayonnaise", "1 cup white rice", "2 tbsp butter"],
          step_change: "Stir mayonnaise into the sauce and serve over white rice.",
        },
        adapted: {
          ingredient_changes: ["1/3 cup Greek yogurt", "1 cup brown rice or quinoa", "1 tbsp olive oil", "2 cups greens"],
          step_change: "Fold Greek yogurt in off heat, serve over brown rice or quinoa, and wilt greens into the pan at the end.",
        },
      },
      {
        base: {
          ingredient_changes: ["1 lb ground beef", "1 cup white rice", "1/2 cup sour cream", "1 cup cheese"],
          step_change: "Cook beef, serve over rice, and top with sour cream and cheese.",
        },
        adapted: {
          ingredient_changes: ["3/4 lb lean ground beef", "1 cup brown rice", "1 cup black beans", "1/3 cup Greek yogurt", "1/2 cup cheese", "2 cups shredded lettuce"],
          step_change: "Cook lean beef, fold in black beans, serve over brown rice, then top with Greek yogurt, less cheese, and shredded lettuce for freshness.",
        },
      },
    ],
  },
  lighter: {
    key: "lighter",
    label: "Make it lighter",
    requiredActions: [
      "Reduce heaviness from excess fat, cream, starch, or overly rich components where present.",
      "Add freshness, acid, herbs, or lighter cooking technique where appropriate.",
      "Update steps and quantities to match the lighter version.",
    ],
    doNot: [
      "Do not make the recipe bland by simply deleting fat, sauce, or starch.",
      "Do not replace every rich ingredient with water or plain broth.",
      "Do not remove the component that makes the dish recognizable.",
      "Do not only change the title or summary.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 cup cream", "3 tbsp butter", "fried topping"],
          step_change: "Finish with cream, butter, and fried topping.",
        },
        adapted: {
          ingredient_changes: ["1/2 cup broth", "1/4 cup Greek yogurt", "1 tbsp olive oil", "2 tbsp lemon juice", "fresh herbs"],
          step_change: "Reduce broth, stir in Greek yogurt off heat, then finish with lemon juice and herbs instead of frying a topping.",
        },
      },
      {
        base: {
          ingredient_changes: ["fried chicken", "1/2 cup mayo dressing", "buttered buns"],
          step_change: "Fry chicken, coat in mayo dressing, and serve on buttered buns.",
        },
        adapted: {
          ingredient_changes: ["oven-baked chicken cutlets", "1/4 cup Greek yogurt", "1 tbsp mayo", "2 tbsp lemon juice", "toasted buns"],
          step_change: "Bake the chicken cutlets until crisp, whisk yogurt with a little mayo and lemon, then spread lightly on toasted buns.",
        },
      },
    ],
  },
  low_calories: {
    key: "low_calories",
    label: "Lower calories",
    requiredActions: [
      "Reduce calories with concrete ingredient swaps, quantity changes, or cooking technique changes.",
      "Preserve the dish's core identity, main flavor profile, and satisfying texture.",
      "Update ingredients, quantities, steps, serving size, and nutrition estimates where available.",
      "Prefer leaner proteins, more vegetables, broth, yogurt, herbs, acid, spices, roasting, baking, or air-frying when they fit the recipe.",
    ],
    validationHints: [
      "The adapted recipe should visibly reduce calorie-dense ingredients or techniques.",
      "The rewrite should remain recognizable as the same dish, not a generic diet meal.",
      "Nutrition estimates should be recalculated or directionally reduced when present.",
    ],
    doNot: [
      "Do not make portion shrinkage the main calorie-reduction strategy.",
      "Do not turn the dish into a generic salad, bowl, or plain grilled protein unless that is already close to the original.",
      "Do not remove the ingredient or technique that makes the dish recognizable without a fitting replacement.",
      "Do not only change nutrition labels, title, tags, or summary.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 cup heavy cream", "3 tbsp butter", "1 cup full-fat cheese"],
          step_change: "Simmer the sauce with cream and butter, then melt in cheese before serving.",
        },
        adapted: {
          ingredient_changes: ["1/2 cup low-sodium broth", "1/3 cup Greek yogurt", "1 tbsp olive oil", "1/2 cup sharp cheese"],
          step_change: "Reduce broth for body, stir in Greek yogurt off heat, finish with a measured amount of sharp cheese, and skip the butter-heavy finish.",
        },
      },
      {
        base: {
          ingredient_changes: ["fried chicken cutlets", "1/2 cup mayo dressing", "buttered buns"],
          step_change: "Fry the chicken, coat it in mayo dressing, and serve on buttered buns.",
        },
        adapted: {
          ingredient_changes: ["oven-baked chicken cutlets", "1/4 cup Greek yogurt", "1 tbsp mayo", "2 tbsp lemon juice", "toasted buns"],
          step_change: "Bake the chicken cutlets until crisp, whisk yogurt with a little mayo and lemon, then spread lightly on toasted buns.",
        },
      },
    ],
  },
  sweeter: {
    key: "sweeter",
    label: "Make it sweet",
    requiredActions: [
      "Increase sweetness or fruit/dessert energy in a balanced way.",
      "Update quantities and steps so the sweetness is integrated, not just renamed.",
    ],
    doNot: [
      "Do not make savory dishes sweet unless the base recipe can handle a sweet glaze, fruit, or sauce.",
      "Do not dump sugar into the recipe without balancing it.",
      "Do not add sweetness only in the title.",
      "Do not add a sweet ingredient without updating the relevant step.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 tbsp maple syrup", "plain yogurt"],
          step_change: "Top with yogurt and serve.",
        },
        adapted: {
          ingredient_changes: ["2 tbsp maple syrup", "1/2 cup sliced strawberries", "1 tbsp honey", "1/4 tsp cinnamon"],
          step_change: "Warm maple syrup with cinnamon, spoon it over the fruit, then drizzle honey over the finished bowl.",
        },
      },
      {
        base: {
          ingredient_changes: ["plain pancakes", "plain yogurt", "berries"],
          step_change: "Cook pancakes and serve with yogurt and berries.",
        },
        adapted: {
          ingredient_changes: ["plain pancakes", "1 tbsp maple syrup", "1/2 cup warm berries", "1/4 tsp vanilla", "plain yogurt"],
          step_change: "Warm berries with maple syrup and vanilla until glossy, then spoon over pancakes with yogurt.",
        },
      },
    ],
  },
  budget_friendly: {
    key: "budget_friendly",
    label: "Budget-friendly",
    requiredActions: [
      "Swap expensive proteins, specialty cheeses, nuts, oils, or one-off ingredients for cheaper practical grocery alternatives while preserving the dish.",
      "Keep ingredient count reasonable and avoid adding too many new items.",
      "Update quantities and steps for every substitution.",
    ],
    doNot: [
      "Do not make the recipe cheaper by removing the main satisfying component without replacing it.",
      "Do not add obscure budget ingredients that are harder to shop for.",
      "Do not keep the expensive ingredient unchanged if it is the obvious cost driver.",
      "Do not only reduce portion size.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 lb salmon", "1 cup specialty cheese", "pine nuts"],
          step_change: "Sear salmon and finish with cheese and pine nuts.",
        },
        adapted: {
          ingredient_changes: ["1 lb chicken thighs or canned chickpeas", "1/2 cup shredded cheddar", "sunflower seeds"],
          step_change: "Cook the cheaper protein with the same seasoning profile, then finish with cheddar and toasted sunflower seeds.",
        },
      },
      {
        base: {
          ingredient_changes: ["1 lb shrimp", "1/2 cup pine nuts", "specialty herb oil"],
          step_change: "Sear shrimp and finish with pine nuts and herb oil.",
        },
        adapted: {
          ingredient_changes: ["1 lb chicken thighs", "1/4 cup sunflower seeds", "2 tbsp olive oil", "mixed dried herbs"],
          step_change: "Sear chicken thighs with dried herbs, then finish with toasted sunflower seeds and olive oil for a cheaper but similar savory finish.",
        },
      },
    ],
  },
  meal_prep: {
    key: "meal_prep",
    label: "Make it reheat well",
    requiredActions: [
      "Make the recipe hold up after storage and reheating.",
      "Adjust sauces, vegetables, starches, crisp components, and serving notes so the dish stores cleanly and stays good later.",
      "Update steps with cooling, separating, reheating, or finishing instructions where needed.",
    ],
    doNot: [
      "Do not leave delicate crisp greens, crunchy toppings, or fragile sauces mixed in if they will get soggy.",
      "Do not claim it reheats well without adding storage or reheating instructions.",
      "Do not add ingredients that degrade badly after storage unless they are packed separately.",
      "Do not only change the title.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["crispy lettuce", "delicate sauce mixed in"],
          step_change: "Assemble everything together immediately.",
        },
        adapted: {
          ingredient_changes: ["sturdy greens or roasted vegetables", "sauce packed separately", "extra 1/4 cup sauce for reheating"],
          step_change: "Cook components fully, cool before packing, store sauce separately, and add it after reheating.",
        },
      },
      {
        base: {
          ingredient_changes: ["crispy chicken", "dressed slaw", "sauce mixed into rice"],
          step_change: "Assemble bowls with chicken, slaw, rice, and sauce all together.",
        },
        adapted: {
          ingredient_changes: ["roasted chicken pieces", "undressed cabbage slaw", "sauce packed separately", "extra 2 tbsp sauce for reheating"],
          step_change: "Pack rice and chicken together, cool fully, keep slaw and sauce separate, then reheat the bowl before adding slaw and sauce.",
        },
      },
    ],
  },
  saucy: {
    key: "saucy",
    label: "Make it saucy",
    requiredActions: [
      "Add or improve a practical sauce, glaze, dressing, or pan sauce that fits the dish.",
      "Update ingredient quantities so the sauce has enough liquid, fat, acid, seasoning, or thickener to work.",
      "Update steps so the sauce is cooked, reduced, tossed, spooned, or served at the right moment.",
    ],
    doNot: [
      "Do not just say serve with sauce without naming and building the sauce.",
      "Do not add a sauce that clashes with the cuisine or base flavors.",
      "Do not make the recipe watery.",
      "Do not add sauce ingredients without a step that mixes, cooks, reduces, or serves them.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["dry grilled chicken", "plain rice", "raw vegetables"],
          step_change: "Grill chicken and serve with rice and vegetables.",
        },
        adapted: {
          ingredient_changes: ["1/2 cup Greek yogurt", "2 tbsp lemon juice", "1 tbsp olive oil", "1 grated garlic clove", "2 tbsp chopped herbs"],
          step_change: "Whisk the yogurt sauce while the chicken rests, then spoon it over the chicken and rice right before serving.",
        },
      },
      {
        base: {
          ingredient_changes: ["seared steak", "roasted peppers", "plain baguette"],
          step_change: "Sear steak, roast peppers, and serve with baguette.",
        },
        adapted: {
          ingredient_changes: ["seared steak", "roasted peppers", "1/3 cup Greek yogurt", "1 tbsp horseradish", "1 tbsp lemon juice", "1 tsp Dijon mustard"],
          step_change: "Whisk yogurt, horseradish, lemon juice, and Dijon into a sharp sauce, then spoon it over sliced steak and roasted peppers.",
        },
      },
    ],
  },
  kid_friendly: {
    key: "kid_friendly",
    label: "Kid-friendly",
    requiredActions: [
      "Make flavors gentler and texture easier to eat without making the dish bland.",
      "Update steps and serving style for a family-friendly version.",
    ],
    doNot: [
      "Do not make the recipe sugary by default.",
      "Do not remove all seasoning or texture.",
      "Do not leave intense spice, sharp pickles, or large hard-to-eat chunks unchanged when they are the issue.",
      "Do not only change the title.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 tbsp chili flakes", "sharp pickled garnish", "large chunks"],
          step_change: "Finish with chili flakes and pickled garnish.",
        },
        adapted: {
          ingredient_changes: ["1/4 tsp mild paprika", "1 tbsp honey or ketchup-style glaze", "finely diced vegetables"],
          step_change: "Keep heat mild, dice vegetables smaller, and serve spicy garnish on the side for adults.",
        },
      },
      {
        base: {
          ingredient_changes: ["1 tbsp hot sauce", "large onion chunks", "sharp pickled jalapenos"],
          step_change: "Toss everything with hot sauce and top with pickled jalapenos.",
        },
        adapted: {
          ingredient_changes: ["1/2 tsp mild paprika", "finely diced onion", "1 tbsp ketchup-style glaze", "pickled jalapenos on the side"],
          step_change: "Cook the finely diced onion until soft, season mildly, glaze lightly, and serve jalapenos separately for adults.",
        },
      },
    ],
  },
  comfort: {
    key: "comfort",
    label: "More comfort",
    requiredActions: [
      "Make the dish cozier and more comforting through sauce, texture, warmth, or seasoning.",
      "Update ingredients and steps to create that result.",
    ],
    doNot: [
      "Do not only add cheese or butter by default.",
      "Do not make the dish heavy without improving texture, warmth, or flavor.",
      "Do not add ingredients without using them in steps.",
      "Do not only change the title.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["dry grilled protein", "plain vegetables"],
          step_change: "Grill and serve with vegetables.",
        },
        adapted: {
          ingredient_changes: ["1 cup warm tomato or mushroom sauce", "1/2 cup melty cheese", "1 tbsp butter"],
          step_change: "Nestle the cooked protein into the warm sauce, melt cheese over top, and finish with butter for a richer texture.",
        },
      },
      {
        base: {
          ingredient_changes: ["plain roasted vegetables", "dry grilled protein"],
          step_change: "Roast vegetables and grill protein.",
        },
        adapted: {
          ingredient_changes: ["plain roasted vegetables", "dry grilled protein", "3/4 cup warm tomato sauce", "1/2 tsp smoked paprika", "1 tbsp olive oil"],
          step_change: "Warm tomato sauce with smoked paprika and olive oil, then spoon it over the grilled protein and roasted vegetables before serving.",
        },
      },
    ],
  },
};

export function getRecipeAdaptationContract(intentKey = "", intentLabel = "", adaptationPrompt = "") {
  const normalizedKey = normalizeText(intentKey).replace(/\s+/g, "_");
  const inferredKey = normalizedKey || inferIntentKeyFromPrompt(adaptationPrompt);
  const contract = INTENT_CONTRACTS[inferredKey] ?? null;
  if (!contract) {
    return {
      key: inferredKey || "custom",
      label: intentLabel || "Custom rewrite",
      requiredActions: [
        "Rewrite the full recipe to satisfy the user's request.",
        "Update ingredients, quantities, steps, title, summary, tags, and timing wherever the request changes the dish.",
      ],
      validationHints: [
        "The output must not be a title-only or summary-only edit.",
        "Ingredients or quantities and at least one step must change.",
      ],
      doNot: [
        "Do not only change the title, summary, tags, or nutrition labels.",
        "Do not add vague placeholder ingredients.",
        "Do not add an ingredient without using it in the steps.",
        "Do not leave steps unchanged when ingredients or quantities change.",
      ],
      editExamples: [
        {
          base: {
            ingredient_changes: ["base ingredient and quantity stay unchanged"],
            step_change: "base method stays unchanged",
          },
          adapted: {
            ingredient_changes: ["change at least one concrete grocery item or quantity based on the request"],
            step_change: "rewrite at least one method step so the ingredient or quantity change is actually cooked into the recipe",
          },
        },
      ],
    };
  }
  return {
    ...contract,
    label: intentLabel || contract.label,
  };
}

function inferIntentKeyFromPrompt(prompt) {
  const text = normalizeText(prompt);
  if (/vegetarian|veggie|plant/.test(text)) return "vegetarian";
  if (/dairy free|no dairy|without dairy/.test(text)) return "dairy_free";
  if (/less sugar|lower sugar|reduce sugar/.test(text)) return "less_sugar";
  if (/protein/.test(text)) return "more_protein";
  if (/spicy|spicier|heat/.test(text)) return "spicy";
  if (/quick|faster|busy weeknight/.test(text)) return "quick";
  if (/vegetable|veggies/.test(text)) return "extra_veggies";
  if (/low calorie|lower calorie|less calorie|reduce calorie|calorie reduction/.test(text)) return "low_calories";
  if (/low carb|lower carb/.test(text)) return "low_carb";
  if (/crisp|crunch/.test(text)) return "crispy";
  if (/healthy|healthier/.test(text)) return "healthier";
  if (/lighter/.test(text)) return "lighter";
  if (/sweet|sweeter/.test(text)) return "sweeter";
  if (/budget|cheap|affordable/.test(text)) return "budget_friendly";
  if (/meal prep|prep ready|reheat/.test(text)) return "meal_prep";
  if (/kid|child|family/.test(text)) return "kid_friendly";
  if (/sauce|saucy|glaze|dressing/.test(text)) return "saucy";
  if (/comfort|cozy/.test(text)) return "comfort";
  return "";
}

export function validateAdaptedRecipe({ baseDetail, adaptedRecipe, contract, strict = true } = {}) {
  const baseIngredients = normalizedIngredientRowsFromDetail(baseDetail);
  const adaptedIngredients = normalizedIngredientRowsFromRecipe(adaptedRecipe);
  const baseSteps = normalizedStepTextsFromDetail(baseDetail);
  const adaptedSteps = normalizedStepTextsFromRecipe(adaptedRecipe);
  const baseNames = new Set(baseIngredients.map((ingredient) => normalizedName(ingredient.displayName)).filter(Boolean));
  const adaptedNames = new Set(adaptedIngredients.map((ingredient) => normalizedName(ingredient.displayName)).filter(Boolean));
  const addedIngredients = adaptedIngredients
    .filter((ingredient) => !baseNames.has(normalizedName(ingredient.displayName)))
    .map((ingredient) => ingredient.displayName);
  const removedIngredients = baseIngredients
    .filter((ingredient) => !adaptedNames.has(normalizedName(ingredient.displayName)))
    .map((ingredient) => ingredient.displayName);
  const changedQuantities = changedQuantityLines(baseIngredients, adaptedIngredients);
  const changedSteps = changedStepLines(baseSteps, adaptedSteps);
  const failures = [];
  if (adaptedIngredients.length < 3) {
    failures.push("The adapted recipe must include at least 3 practical ingredients.");
  }
  if (adaptedSteps.length < 3) {
    failures.push("The adapted recipe must include at least 3 concrete cooking steps.");
  }
  if (!addedIngredients.length && !removedIngredients.length && !changedQuantities.length) {
    failures.push("The adaptation changed no ingredients or quantities.");
  }
  if (!changedSteps.length) {
    failures.push("The adaptation changed no cooking steps.");
  }

  if (strict && failures.length) {
    return {
      valid: false,
      failures,
      editSummary: buildEditSummary({ addedIngredients, removedIngredients, changedQuantities, changedSteps, validationNotes: failures }),
    };
  }

  return {
    valid: failures.length === 0,
    failures,
    editSummary: buildEditSummary({ addedIngredients, removedIngredients, changedQuantities, changedSteps, validationNotes: failures }),
  };
}

function changedQuantityLines(baseIngredients, adaptedIngredients) {
  const adaptedByName = new Map(adaptedIngredients.map((ingredient) => [normalizedName(ingredient.displayName), ingredient]));
  const changes = [];
  for (const baseIngredient of baseIngredients) {
    const key = normalizedName(baseIngredient.displayName);
    const adaptedIngredient = adaptedByName.get(key);
    if (!adaptedIngredient) continue;
    const baseQuantity = normalizeText(baseIngredient.quantityText);
    const adaptedQuantity = normalizeText(adaptedIngredient.quantityText);
    if (adaptedQuantity && baseQuantity !== adaptedQuantity) {
      changes.push(`${baseIngredient.displayName}: ${baseIngredient.quantityText || "unspecified"} -> ${adaptedIngredient.quantityText || "unspecified"}`);
    }
  }
  return changes;
}

function changedStepLines(baseSteps, adaptedSteps) {
  const changes = [];
  const count = Math.max(baseSteps.length, adaptedSteps.length);
  for (let index = 0; index < count; index += 1) {
    const baseStep = baseSteps[index] ?? "";
    const adaptedStep = adaptedSteps[index] ?? "";
    if (baseStep !== adaptedStep && adaptedStep) {
      changes.push(`Step ${index + 1}: ${adaptedStep}`);
    }
  }
  return changes.slice(0, 12);
}

function buildEditSummary({ addedIngredients, removedIngredients, changedQuantities, changedSteps, validationNotes }) {
  return {
    added_ingredients: uniqueStrings(addedIngredients).slice(0, 12),
    removed_ingredients: uniqueStrings(removedIngredients).slice(0, 12),
    changed_ingredients: uniqueStrings([...addedIngredients, ...removedIngredients]).slice(0, 12),
    changed_quantities: uniqueStrings(changedQuantities).slice(0, 12),
    changed_steps: uniqueStrings(changedSteps).slice(0, 12),
    validation_notes: uniqueStrings(validationNotes).slice(0, 12),
  };
}

function uniqueStrings(values) {
  return [...new Set((values ?? []).map((value) => String(value ?? "").trim()).filter(Boolean))];
}

export function mergeEditSummaries(modelSummary = {}, computedSummary = {}) {
  return {
    added_ingredients: uniqueStrings([
      ...(computedSummary.added_ingredients ?? []),
      ...(modelSummary.added_ingredients ?? []),
    ]).slice(0, 12),
    removed_ingredients: uniqueStrings([
      ...(computedSummary.removed_ingredients ?? []),
      ...(modelSummary.removed_ingredients ?? []),
    ]).slice(0, 12),
    changed_ingredients: uniqueStrings([
      ...(computedSummary.changed_ingredients ?? []),
      ...(modelSummary.changed_ingredients ?? []),
    ]).slice(0, 12),
    changed_quantities: uniqueStrings([
      ...(computedSummary.changed_quantities ?? []),
      ...(modelSummary.changed_quantities ?? []),
    ]).slice(0, 12),
    changed_steps: uniqueStrings([
      ...(computedSummary.changed_steps ?? []),
      ...(modelSummary.changed_steps ?? []),
    ]).slice(0, 12),
    validation_notes: uniqueStrings([
      ...(computedSummary.validation_notes ?? []),
      ...(modelSummary.validation_notes ?? []),
    ]).slice(0, 12),
  };
}
