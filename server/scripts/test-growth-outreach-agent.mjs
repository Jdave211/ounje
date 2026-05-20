#!/usr/bin/env node
import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";

const {
  buildQuoraSearchQueries,
  buildRoundupSearchQueries,
  composeFallbackQuoraAnswer,
  composeFallbackRoundupPitch,
  evaluateQuoraCandidateHeuristic,
  loadGrowthOutreachConfig,
} = await import("../lib/growth-outreach-agent.js");

const config = await loadGrowthOutreachConfig();

assert.ok(buildQuoraSearchQueries(config).length >= 3, "expected Quora discovery queries");
assert.ok(buildRoundupSearchQueries(config).length >= 3, "expected roundup discovery queries");

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

console.log("growth outreach agent tests passed");
