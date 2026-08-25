#!/usr/bin/env node

import assert from "node:assert/strict";

import { mergePlanWithRicherBatchStructure } from "../api/v1/bootstrap.js";

const usualBatch = {
  id: "usual-batch",
  name: "Usual",
  recipes: [{ recipe: { id: "usual-recipe" } }],
  groceryItems: [],
};
const deletedBatch = {
  id: "deleted-batch",
  name: "Bulking",
  recipes: [{ recipe: { id: "bulking-recipe" } }],
  groceryItems: [],
};
const latestPlan = {
  id: "latest-plan",
  activeBatchID: usualBatch.id,
  batches: [usualBatch],
  recipes: usualBatch.recipes,
  groceryItems: [],
  deletedBatchIDs: [deletedBatch.id],
};
const richerHistoricalPlan = {
  id: "historical-plan",
  activeBatchID: usualBatch.id,
  batches: [usualBatch, deletedBatch],
  recipes: usualBatch.recipes,
  groceryItems: [],
};

const deletionSafePlan = mergePlanWithRicherBatchStructure(latestPlan, richerHistoricalPlan);
assert.deepEqual(deletionSafePlan.batches.map((batch) => batch.id), [usualBatch.id]);
assert.deepEqual(deletionSafePlan.deletedBatchIDs, [deletedBatch.id]);

const legacyPlan = { ...latestPlan, deletedBatchIDs: [] };
const repairedLegacyPlan = mergePlanWithRicherBatchStructure(legacyPlan, richerHistoricalPlan);
assert.deepEqual(
  repairedLegacyPlan.batches.map((batch) => batch.id),
  [usualBatch.id, deletedBatch.id]
);

console.log("bootstrap-prep-deletion: all assertions passed");
