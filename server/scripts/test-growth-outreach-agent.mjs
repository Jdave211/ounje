#!/usr/bin/env node
import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";

const {
  buildCreatorSearchQueries,
  buildQuoraSearchQueries,
  buildRoundupSearchQueries,
  composeFallbackCreatorOutreach,
  composeFallbackQuoraAnswer,
  composeFallbackRoundupPitch,
  evaluateCreatorCandidateHeuristic,
  evaluateQuoraCandidateHeuristic,
  loadGrowthOutreachConfig,
} = await import("../lib/growth-outreach-agent.js");

const config = await loadGrowthOutreachConfig();

assert.ok(buildQuoraSearchQueries(config).length >= 3, "expected Quora discovery queries");
assert.ok(buildRoundupSearchQueries(config).length >= 3, "expected roundup discovery queries");
assert.ok(buildCreatorSearchQueries(config).length >= 3, "expected creator discovery queries");

const strongCandidate = {
  title: "What is the best app to turn recipes into a grocery list?",
  url: "https://www.quora.com/What-is-the-best-app-to-turn-recipes-into-a-grocery-list",
  snippet: "I save lots of recipes and want a grocery list for meal prep.",
};
const strongEvaluation = evaluateQuoraCandidateHeuristic(strongCandidate, config);
assert.ok(strongEvaluation.relevanceScore >= 0.55, `expected strong relevance, got ${strongEvaluation.relevanceScore}`);
assert.equal(strongEvaluation.blockedReason, null);

const riskyCandidate = {
  title: "What diet cures diabetes fast?",
  url: "https://www.quora.com/What-diet-cures-diabetes-fast",
  snippet: "I need medical nutrition advice and weight loss guarantees.",
};
const riskyEvaluation = evaluateQuoraCandidateHeuristic(riskyCandidate, config);
assert.ok(riskyEvaluation.blockedReason, "expected health-adjacent question to be blocked");

const answer = composeFallbackQuoraAnswer(strongCandidate, config.app);
assert.match(answer, /I work on Ounje/i, "fallback answer must disclose affiliation");
assert.match(answer, /review/i, "fallback answer must include review caveat");
assert.match(answer, /\n\n1\./, "fallback answer should preserve paragraph breaks");
assert.doesNotMatch(answer, /Great question|I hope this helps|seamless|leverage/i, "fallback answer should avoid obvious AI filler");

const pitch = composeFallbackRoundupPitch({
  postTitle: "Best Meal Planning Apps",
  authorName: "Alex",
}, config.app);
assert.match(pitch.body, /Hi Alex/);
assert.match(pitch.body, /Ounje/);
assert.match(pitch.body, /\* /, "pitch should include bullet points");

const creatorCandidate = {
  title: "Meal Prep with Maya (@mealprepmaya) • Instagram photos and videos",
  url: "https://www.instagram.com/mealprepmaya/",
  snippet: "Food creator sharing meal prep, easy dinner recipes, grocery hauls, and UGC collaborations.",
};
const creatorEvaluation = evaluateCreatorCandidateHeuristic(creatorCandidate, config);
assert.equal(creatorEvaluation.platform, "instagram");
assert.equal(creatorEvaluation.handle, "@mealprepmaya");
assert.ok(creatorEvaluation.relevanceScore >= 0.42, `expected creator relevance, got ${creatorEvaluation.relevanceScore}`);
assert.equal(creatorEvaluation.blockedReason, null);

const creatorDraft = composeFallbackCreatorOutreach({
  handle: "@mealprepmaya",
  outreachAngle: "Saved TikTok Recipe Rescue",
}, config.app);
assert.match(creatorDraft.messageBody, /I work on Ounje/i);
assert.match(creatorDraft.messageBody, /paid UGC|promotion test/i);
assert.match(creatorDraft.briefSummary, /Saved TikTok Recipe Rescue/);

console.log("growth outreach agent tests passed");
