import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";

const { buildShoppingSpecEntries } = await import("../lib/instacart-intent.js");

function sourceKey(source) {
  return [
    String(source.recipeID ?? "").trim().toLowerCase(),
    String(source.ingredientName ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim(),
    String(source.unit ?? "").trim().toLowerCase(),
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

console.log("main-shop collation tests passed");
