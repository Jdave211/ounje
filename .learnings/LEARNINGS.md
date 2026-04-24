## [LRN-20260406-001] recovery.build-artifact-vs-git-checkout

**Logged**: 2026-04-06T20:40:00-04:00
**Priority**: high
**Status**: pending
**Area**: infra

### Summary
The installed app can be newer than the current git checkout because a richer build artifact may still exist in DerivedData even after the source tree was reset.

### Details
I initially verified the working tree and concluded the newer cart/profile UI was missing from source, which was true for the checkout. A second pass found a separate DerivedData bundle whose compiled binary contained the missing boxed cart and paywall symbols, meaning the device/app state had diverged from the tracked source. The recovery path should consider compiled build artifacts, not just current git HEAD.

### Suggested Action
When a user reports "the app rolled back", check both:
1. the current git checkout
2. existing DerivedData / installed app bundles
before assuming the feature was destroyed.

### Metadata
- Source: user_feedback
- Related Files: /Users/davejaga/Desktop/startups/ounje/client/ios/ounje/OunjeAgenticApp.swift
- Tags: ios, xcode, deriveddata, stale-build, recovery
- Pattern-Key: build.artifact.may.outlive.checkout
- Recurrence-Count: 1
- First-Seen: 2026-04-06
- Last-Seen: 2026-04-06

---

## [LRN-20260417-001] correction.search-root-cause-before-hardcoding

**Logged**: 2026-04-17T11:56:00-06:00
**Priority**: high
**Status**: pending
**Area**: frontend

### Summary
When Discover search blanks out, fix the request/transition state first instead of adding query-specific server shortcuts.

### Details
I responded to a broken Discover search report by adding deterministic server aliases and a preset fast-path. That changed ranking behavior without fixing the actual complaint. The real issue was the client search flow clearing visible recipes before the semantic discover request resolved. For this class of bug, confirm whether the problem is request routing, request completion, or UI state transition before patching ranking logic.

### Suggested Action
For Discover regressions, inspect:
1. whether the app is clearing `recipes` during `refresh`
2. whether the semantic `/v1/recipe/discover` route is still being called
3. whether the UI is showing an empty state before the request resolves

Only change ranking/query semantics after that path is verified.

### Metadata
- Source: user_feedback
- Related Files: /Users/davejaga/Desktop/startups/ounje/client/ios/ounje/OunjeAgenticApp.swift, /Users/davejaga/Desktop/startups/ounje/server/api/v1/recipe.js
- Tags: discover, search, ui-state, semantic-search, correction
- Pattern-Key: diagnose.ui-state.before-query-hardcode
- Recurrence-Count: 1
- First-Seen: 2026-04-17
- Last-Seen: 2026-04-17

---

## [LRN-20260419-001] correction.profile-compact-over-clever

**Logged**: 2026-04-19T15:58:18-06:00
**Priority**: high
**Status**: pending
**Area**: frontend

### Summary
For Profile, default to a compact control hub with one strong animated focal point instead of stacking multiple expressive sections.

### Details
I replaced the original profile page with a long, highly-styled dashboard that added visual noise and too much vertical travel. The user explicitly called it overstimulating, too long, and still not animated in the way that mattered. For personal-settings surfaces, the right move is to keep only the highest-frequency controls above the fold, collapse secondary utilities, and concentrate motion into one intentional mascot or hero stage rather than spreading decorative styling everywhere.

### Suggested Action
When redesigning settings-heavy screens:
1. keep the primary path within one thumb zone
2. hide billing, providers, and diagnostics behind a secondary expansion by default
3. use one animated focal element instead of multiple competing sections
4. validate vertical density before calling the redesign done

### Metadata
- Source: user_feedback
- Related Files: /Users/davejaga/Desktop/startups/ounje/client/ios/ounje/OunjeAgenticApp.swift
- Tags: profile, ios, swiftui, animation, density, correction
- Pattern-Key: compact.settings.hub.over.decorative.dashboard
- Recurrence-Count: 1
- First-Seen: 2026-04-19
- Last-Seen: 2026-04-19

---

## [LRN-20260422-001] correction.guard-exact-match-pantry-items

**Logged**: 2026-04-22T08:20:00-06:00
**Priority**: high
**Status**: pending
**Area**: backend

### Summary
Exact pantry/spice matches should not be rejected by fresh-item mismatch heuristics or overly sensitive descriptor tokens like `table`.

### Details
The Instacart guard layer was rejecting exact or near-exact pantry items such as `salt` and `onion powder` after the picker had already found a good candidate. The failure came from post-pick guard logic, not search ranking: `salt` was rejected because `table` was treated as a sensitive extra descriptor, and `onion powder` was misclassified as a fresh produce item because the query contained `onion` while also mentioning powder/spice. These exact-name pantry cases should flow through unless there is a real form mismatch.

### Suggested Action
When a query is pantry/spice-like:
1. do not classify it as fresh produce just because it contains a produce token like `onion`
2. ignore benign descriptors such as `table` for salt-style queries
3. keep the picker simple and fix false negatives in guard logic, not search narrowing

### Metadata
- Source: user_feedback
- Related Files: /Users/davejaga/Desktop/startups/ounje/server/lib/instacart-cart.js
- Tags: instacart, guards, false-negative, pantry, spice, correction
- Pattern-Key: harden.guard.exact.pantry.matches
- Recurrence-Count: 1
- First-Seen: 2026-04-22
- Last-Seen: 2026-04-22

---

## [LRN-20260422-002] correction.full-mapping-should-not-retry

**Logged**: 2026-04-22T08:55:00-06:00
**Priority**: high
**Status**: pending
**Area**: backend

### Summary
If the warden rejudges every requested item as correct and there are no unresolved items, the Instacart run should be completed and must not queue another pass just because the cart screenshot or finalizer snapshot was broken.

### Details
The warden can recover a run from a bad cart screenshot and mark all 40/40 items as correct. In that case the run should remain current/completed, not partial/historic, and no retry should be queued. A broken snapshot is a verification artifact problem, not a signal that the cart needs another shopping pass.

### Suggested Action
When `correctedItemCount === itemCount` and `unresolvedCount === 0`, force the run to `success=true`, `partialSuccess=false`, and `retryRecommendation=none` even if the finalizer originally suggested a full rerun because the cart page was corrupted.

### Metadata
- Source: user_feedback
- Related Files: /Users/davejaga/Desktop/startups/ounje/server/lib/instacart-cart.js, /Users/davejaga/Desktop/startups/ounje/server/lib/instacart-run-logs.js
- Tags: instacart, warden, retry, current-historic, correction
- Pattern-Key: suppress.retry.when.mapping.is_complete
- Recurrence-Count: 1
- First-Seen: 2026-04-22
- Last-Seen: 2026-04-22
