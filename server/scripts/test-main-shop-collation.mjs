import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";

const { buildShoppingSpecEntries } = await import("../lib/instacart-intent.js");
const { isNonShoppingWater } = await import("../lib/main-shop-collation.js");

function sourceKey(source) {
  return [
    String(source.recipeID ?? "").trim().toLowerCase(),
    String(source.ingredientName ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim(),
    String(source.unit ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim(),
  ].join("::");
}

function groceryItem(name, recipeID, amount = 1, unit = "item") {
  return {
    name,
    amount,
    unit,
    estimatedPrice: 0,
    sourceIngredients: [
      {
        recipeID,
        ingredientName: name,
        unit,
      },
    ],
  };
}

async function specFor(items) {
  return buildShoppingSpecEntries({ originalItems: items, plan: null });
}

async function specForWithDecisions(items, decisionsByIndex) {
  return buildShoppingSpecEntries({
    originalItems: items,
    plan: null,
    clusterDecisionResolver: async (clusters) => new Map(
      clusters.map((cluster) => {
        const decision = decisionsByIndex[cluster.index] ?? { merge: false };
        return [
          cluster.index,
          {
            index: cluster.index,
            merge: Boolean(decision.merge),
            canonicalName: decision.canonicalName ?? cluster.items[0]?.canonicalName ?? cluster.items[0]?.name ?? "",
            preferredDisplayName: decision.preferredDisplayName ?? decision.canonicalName ?? cluster.items[0]?.name ?? "",
            mergeAmountStrategy: decision.mergeAmountStrategy ?? "sum",
            preferredUnit: decision.preferredUnit ?? null,
            confidence: decision.confidence ?? 0.9,
            reason: decision.reason ?? "mock_adjudicator",
          },
        ];
      })
    ),
  });
}

function canonicalKeys(spec) {
  return spec.items.map((item) => item.canonicalKey ?? item.shoppingContext?.canonicalKey ?? item.canonicalName ?? item.name);
}

function assertCoversEverySourceOnce(inputItems, spec) {
  const expected = inputItems.flatMap((item) => item.sourceIngredients.map(sourceKey));
  const covered = spec.items.flatMap((item) => item.sourceEdgeIDs ?? item.shoppingContext?.sourceEdgeIDs ?? []);
  assert.equal(new Set(covered).size, covered.length, "source edges must not be duplicated across canonical rows");
  assert.deepEqual(new Set(covered), new Set(expected), "canonical rows must cover every input source edge");
}

{
  const excludedNames = [
    "Water", "Cold Water", "Warm Water", "Boiling Water", "Filtered Water",
    "Room Temperature Water", "Water as needed", "Water for cooking",
    "Water for the dough", "Reserved pasta water",
  ];
  for (const name of excludedNames) {
    assert.equal(isNonShoppingWater(name), true, `${name} should not be shoppable`);
  }
  for (const name of ["Coconut Water", "Rose Water", "Soda Water", "Sparkling Water"]) {
    assert.equal(isNonShoppingWater(name), false, `${name} should remain shoppable`);
  }
}

{
  const input = [
    groceryItem("Cold Water", "r1", 2, "cups"),
    groceryItem("Coconut Water", "r2", 1, "bottle"),
    groceryItem("Chicken Breast", "r3", 2, "breasts"),
  ];
  const spec = await specFor(input);
  assert.deepEqual(canonicalKeys(spec).sort(), ["chicken breast", "coconut water"]);
}

{
  const input = [
    groceryItem("Chicken Thigh Or Rotisserie Chicken", "r1", 4, "thighs"),
    groceryItem("Chicken Thighs", "r2", 6, "thighs"),
  ];
  const spec = await specForWithDecisions(input, {
    0: { merge: true, canonicalName: "chicken thigh", preferredDisplayName: "Chicken Thighs" },
  });
  assert.equal(spec.items.length, 1);
  assert.equal(canonicalKeys(spec)[0], "chicken thigh");
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Instant Rice Cup", "r1", 1, "cup"),
    groceryItem("cooked rice", "r2", 1, "cup"),
    groceryItem("rice cup", "r3", 1, "cup"),
  ];
  const spec = await specForWithDecisions(input, {
    0: { merge: true, canonicalName: "rice", preferredDisplayName: "Rice" },
  });
  assert.equal(spec.items.length, 1);
  assert.equal(canonicalKeys(spec)[0], "rice");
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Chicken Breast", "r1", 2, "breasts"),
    groceryItem("Chicken Thighs", "r2", 2, "thighs"),
  ];
  const spec = await specFor(input);
  assert.deepEqual(canonicalKeys(spec).sort(), ["chicken breast", "chicken thigh"]);
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Rice", "r1", 1, "cup"),
    groceryItem("Cauliflower Rice", "r2", 1, "cup"),
  ];
  const spec = await specForWithDecisions(input, {
    0: { merge: false },
  });
  assert.deepEqual(canonicalKeys(spec).sort(), ["cauliflower rice", "rice"]);
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Green Onion", "r1"),
    groceryItem("Yellow Onion", "r2"),
  ];
  const spec = await specForWithDecisions(input, {
    0: { merge: false },
  });
  assert.deepEqual(canonicalKeys(spec).sort(), ["green onion", "yellow onion"]);
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Coconut Milk", "r1"),
    groceryItem("Coconut Water", "r2"),
  ];
  const spec = await specForWithDecisions(input, {
    0: { merge: false },
  });
  assert.deepEqual(canonicalKeys(spec).sort(), ["coconut milk", "coconut water"]);
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Sweet Potato", "r1"),
    groceryItem("Potato", "r2"),
  ];
  const spec = await specForWithDecisions(input, {
    0: { merge: false },
  });
  assert.deepEqual(canonicalKeys(spec).sort(), ["potato", "sweet potato"]);
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Sweet Potato", "r1"),
    groceryItem("Potato", "r2"),
  ];
  const spec = await specFor(input);
  assert.deepEqual(canonicalKeys(spec).sort(), ["potato", "sweet potato"], "offline fallback must not semantically collapse related names");
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Black Pepper", "r1", 1, "tsp"),
    groceryItem("Black Pepper Powder", "r2", 1, "tbsp"),
    groceryItem("Freshly Cracked Black Pepper", "r3", 0.5, "tsp"),
  ];
  const spec = await specFor(input);
  assert.equal(spec.items.length, 1);
  assert.equal(canonicalKeys(spec)[0], "black pepper");
  assert.equal(spec.items[0].amount, 4.5);
  assert.equal(spec.items[0].unit, "tsp");
  assert.equal(spec.items[0].name, "Black Pepper");
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Black Pepper", "r1", 2, "items"),
    groceryItem("Black Pepper Powder", "r2", 1, "tsp"),
  ];
  const spec = await specFor(input);
  assert.equal(spec.items.length, 1, "a canonical ingredient must never split by measurement type");
  assert.equal(canonicalKeys(spec)[0], "black pepper");
  assert.equal(spec.items[0].amount, 1, "placeholder item counts must not inflate a concrete measurement");
  assert.equal(spec.items[0].unit, "tsp");
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Flour", "r1", 240, "g (2 cups)"),
    groceryItem("Flour", "r2", 2, "cups"),
  ];
  const spec = await specFor(input);
  assert.equal(spec.items.length, 1);
  assert.equal(canonicalKeys(spec)[0], "all purpose flour");
  assert.equal(spec.items[0].amount, 4, "an explicit recipe equivalence can safely merge mass and volume entries");
  assert.equal(spec.items[0].unit, "cup");
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Flour", "r1", 240, "g"),
    groceryItem("Flour", "r2", 2, "cups"),
  ];
  const spec = await specFor(input);
  assert.equal(spec.items.length, 1);
  assert.equal(spec.items[0].amount, 240, "mass-to-volume conversion must not be inferred without an explicit equivalence");
  assert.equal(spec.items[0].unit, "g");
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Onion Powder", "r1", 1, "tsp"),
    groceryItem("Onion Granules", "r2", 2, "tsp"),
  ];
  const spec = await specFor(input);
  assert.equal(spec.items.length, 1);
  assert.equal(canonicalKeys(spec)[0], "onion powder");
  assert.equal(spec.items[0].amount, 3);
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Boneless Skinless Chicken Breast", "r1", 2, "breasts"),
    groceryItem("Chicken Breasts", "r2", 3, "breasts"),
  ];
  const spec = await specFor(input);
  assert.equal(spec.items.length, 1);
  assert.equal(canonicalKeys(spec)[0], "chicken breast");
  assert.equal(spec.items[0].amount, 5);
  assert.equal(spec.items[0].name, "Chicken Breast");
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Scallions", "r1", 2, "items"),
    groceryItem("Spring Onions", "r2", 3, "items"),
    groceryItem("Green Onion", "r3", 1, "item"),
  ];
  const spec = await specFor(input);
  assert.equal(spec.items.length, 1);
  assert.equal(canonicalKeys(spec)[0], "green onion");
  assert.equal(spec.items[0].amount, 6);
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Cornstarch", "r1", 1, "tbsp"),
    groceryItem("Corn Flour", "r2", 2, "tbsp"),
  ];
  const spec = await specFor(input);
  assert.equal(spec.items.length, 1);
  assert.equal(canonicalKeys(spec)[0], "cornstarch");
  assert.equal(spec.items[0].amount, 3);
  assertCoversEverySourceOnce(input, spec);
}

{
  const input = [
    groceryItem("Chicken Breast", "r1", 2, "breasts"),
    groceryItem("Chicken Thighs", "r2", 2, "thighs"),
    groceryItem("Bone-In Chicken Thighs", "r3", 2, "thighs"),
    groceryItem("Garlic", "r4", 2, "cloves"),
    groceryItem("Garlic Powder", "r5", 1, "tsp"),
    groceryItem("Tomatoes", "r6", 2, "items"),
    groceryItem("Crushed Tomatoes", "r7", 1, "can"),
  ];
  const spec = await specFor(input);
  assert.deepEqual(
    canonicalKeys(spec).sort(),
    ["bone in chicken thigh", "chicken breast", "chicken thigh", "crushed tomato", "garlic", "garlic powder", "tomato"]
  );
  assertCoversEverySourceOnce(input, spec);
}

console.log("main-shop collation tests passed");
