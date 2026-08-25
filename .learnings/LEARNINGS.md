## [LRN-20260825-001] correction.guide-context-before-coachmark

**Logged**: 2026-08-25T04:38:32Z
**Priority**: high
**Status**: resolved
**Area**: frontend

### Summary
For first-run guidance, make the task's real content the screen state before adding a spotlight; do not use a coachmark to turn an unrelated page into a selector.

### Details
The first guide put two suggested recipes ahead of the normal Recipes section and used a floating spotlight on a save control. The physical-phone review showed the highlight detached from the task and the user clarified the correct hierarchy: the regular Recipes section must present five normal recipe cards, with the first card itself highlighted and tappable to save before the fixed preset-plan flow continues.

### Suggested Action
Before adding a guide overlay, verify that the target is already the primary, visible component for the current task. Build the task state into the existing product surface first, then attach any guidance to that exact component.

### Metadata
- Source: user_feedback
- Related Files: client/ios/ounje/App/AppRootView.swift, client/ios/ounje/Features/FirstRunGuide/SpotlightGuideOverlay.swift
- Tags: onboarding, first-run-guide, hierarchy, physical-device, correction
- Pattern-Key: guide.context_before_coachmark
- Recurrence-Count: 1
- First-Seen: 2026-08-25
- Last-Seen: 2026-08-25

### Resolution
- **Resolved**: 2026-08-25T04:38:32Z
- **Notes**: The corrected implementation uses four varied TikTok recipe cards in the existing Recipes grid and attaches the guide only to the first card's add control.

---

## [LRN-20260825-002] correction.replay_uses_newcomer_canonical_state

**Logged**: 2026-08-25T05:08:00Z
**Priority**: high
**Status**: resolved
**Area**: frontend

### Summary
Replaying onboarding must create and display its own canonical starter plan, never a user's existing plans.

### Details
The prior replay path preserved the current plan and showed it during the guide. The intended walkthrough begins with four varied public TikTok imports, asks the user to press a card's add control, then creates a fixed three-recipe preset and its exact cart.

### Suggested Action
Keep replay presentation scoped to the guide's plan ID and make selection resolve to an editorial preset—not similarity search or user-plan state.

### Metadata
- Source: user_feedback
- Related Files: client/ios/ounje/App/AppRootView.swift, client/ios/ounje/Features/FirstRunGuide/FirstRunGuideCoordinator.swift
- Tags: onboarding, replay, presets, cart
- Pattern-Key: guide.replay_isolated_newcomer_state

### Resolution
- **Resolved**: 2026-08-25T05:08:00Z
- **Notes**: The Recipes step now hides plans; later guide steps render only the just-created preset cycle.

---

## [LRN-20260825-003] correction.verify_phone_binary_before_claiming_delivery

**Logged**: 2026-08-25T05:03:20Z
**Priority**: critical
**Status**: resolved
**Area**: frontend

### Summary
Do not say a phone flow is installed until the exact completed binary has been verified and installed.

### Details
The physical phone screenshot showed the old guide even though a signed bundle had been installed. The bundle was an intermediate DerivedData product because the previous build had not finished. Source changes and a build directory are not delivery evidence.

### Suggested Action
Require all three before reporting a physical-device update: successful build exit, source-string verification in the packaged binary, and successful device install/launch.

### Metadata
- Source: user_feedback
- Related Files: client/ios/ounje/App/AppRootView.swift
- Tags: ios, build, device, verification
- Pattern-Key: device.verify_completed_binary_before_delivery

### Resolution
- **Resolved**: 2026-08-25T05:03:20Z
- **Notes**: Rebuilt to completion, verified the current coachmark string in the packaged dylib, and reinstalled that package.

---

## [LRN-20260825-004] correction.guide_preserves_page_hierarchy

**Logged**: 2026-08-25T05:16:00Z
**Priority**: critical
**Status**: resolved
**Area**: frontend

### Summary
The first guide step must be a subdued real page, not an isolated recipe selector.

### Details
The correct newcomer state still shows the normal Plans header and the existing New plan tile. The first recipe remains visually real; only the other choices recede. Guidance belongs exactly on the card's native plus button, with no enclosing card highlight or invented target shape.

### Suggested Action
Model walkthroughs as a constrained version of the product state before adding coachmarks: keep the real layout, hide account data, and target native controls directly.

### Metadata
- Source: user_feedback
- Related Files: client/ios/ounje/App/AppRootView.swift, client/ios/ounje/Core/DesignSystem/Components/RecipeCardComponents.swift
- Tags: onboarding, hierarchy, focus, native-controls
- Pattern-Key: guide.constrain_real_page_not_selector

### Resolution
- **Resolved**: 2026-08-25T05:16:00Z
- **Notes**: The guide now retains the normal blank Plans area, mutes only the three non-focus cards, and attaches the target to the native add button.

---

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

---

## [LRN-20260822-001] correction.profile-name-field-precedence

**Logged**: 2026-08-22T01:52:00-06:00
**Priority**: high
**Status**: pending
**Area**: backend

### Summary
Inspect `display_name`, `preferred_name`, and structured profile name fields separately before concluding that an Apple relay account has no saved name.

### Details
The first subscription audit collapsed names with `display_name || preferred_name`. Because `display_name` was populated with an opaque Apple relay prefix, it masked a potentially meaningful `preferred_name`. The user correctly noted that most profile rows have a displayable name.

### Suggested Action
For identity reconciliation, return every candidate name source independently and prefer a meaningful onboarding `preferred_name` over an autogenerated relay-prefix `display_name`.

### Metadata
- Source: user_feedback
- Related Files: supabase public.profiles
- Tags: supabase, profiles, identity, apple-relay, correction
- Pattern-Key: identity.inspect.all.profile.name.fields
- Recurrence-Count: 1
- First-Seen: 2026-08-22
- Last-Seen: 2026-08-22

---

## [LRN-20260823-001] correction.social-preview-image-separates-copy

**Logged**: 2026-08-23T21:18:00-06:00
**Priority**: medium
**Status**: resolved
**Area**: frontend

### Summary
Recipe titles and Ounje attribution belong in Open Graph metadata, not rendered into the social-preview image itself.

### Details
The first share-card treatment baked the Ounje wordmark, “Recipe on Ounje,” and the recipe title into the image. A later revision removed the copy but still staged a bordered 560px squircle on a separate 1200×630 dark card. Social clients already render metadata copy and their own preview chrome, so both treatments were busier than necessary.

### Suggested Action
Keep generated social images purely visual and structurally simple. For social/video imports, make the metadata image itself the regular square recipe squircle—no surrounding card, border, wordmark, or text overlay. Supply `Ounje · <recipe title>` only through `og:title` and `twitter:title`.

### Metadata
- Source: user_feedback
- Related Files: website/app/r/[shareId]/share-preview-image.jsx, website/app/r/[shareId]/page.jsx
- Tags: open-graph, social-preview, metadata, image, correction
- Pattern-Key: social.preview.copy.outside.image
- Recurrence-Count: 2
- First-Seen: 2026-08-23
- Last-Seen: 2026-08-23

### Resolution
- **Resolved**: 2026-08-23T21:18:00-06:00
- **Notes**: Replaced the landscape share-card composition with a filled 1200×1200 recipe squircle, kept all copy in metadata only, and versioned the public image URL so social clients fetch the corrected asset.

---

---

## [LRN-20260822-002] best_practice.require-import-job-acknowledgement

**Logged**: 2026-08-22T22:46:00-06:00
**Priority**: critical
**Status**: resolved
**Area**: frontend

### Summary
A scheduled background upload must not be represented as a server-submitted recipe import until the API returns a job ID.

### Details
The share extension persisted a local envelope, scheduled a background URLSession upload, and changed the envelope to `submitted` even when no backend job existed. The containing app then refused to resubmit envelopes carrying that transport-only timestamp, leaving imports indefinitely labeled `Sending to server`. Background upload errors also returned without repairing the envelope.

### Suggested Action
Keep unacknowledged handoffs locally queued, automatically submit any non-terminal envelope without a job ID when the app is active, and requeue background transport failures. Treat the API job ID as the server acknowledgement boundary.

### Metadata
- Source: error
- Related Files: client/ios/OunjeShareExtension/OunjeShareViewController.swift, client/ios/ounje/App/OunjeAppDelegate.swift, client/ios/ounje/App/AppRootView.swift, client/ios/ounje/ShareExtensionShared/SharedImportModels.swift
- Tags: ios, share-extension, background-upload, recipe-import, reliability
- Pattern-Key: harden.import.handoff.requires.job-id
- Recurrence-Count: 1
- First-Seen: 2026-08-22
- Last-Seen: 2026-08-22

---

## [LRN-20260823-002] correction.metadata-image-shape-preserves-recipe-origin

**Logged**: 2026-08-23T21:38:00-06:00
**Priority**: medium
**Status**: resolved
**Area**: frontend

### Summary
Metadata image shape must preserve whether a recipe is native to Ounje or separately imported.

### Details
Applying the filled squircle treatment to every recipe erased an existing visual distinction. Native Ounje recipes and plate images use circles; separately imported recipes and social/video recipes use squircles.

### Suggested Action
Drive both webpage and metadata-image shape from the existing `usesSquircleHero` classification: `false` renders a circle and `true` renders a squircle.

### Metadata
- Source: user_feedback
- Related Files: website/lib/recipe-schema.js, website/app/r/[shareId]/share-preview-image.jsx
- Tags: open-graph, social-preview, circle, squircle, recipe-origin
- Pattern-Key: social.preview.shape.preserves.recipe.origin
- Recurrence-Count: 1
- First-Seen: 2026-08-23
- Last-Seen: 2026-08-23

### Resolution
- **Resolved**: 2026-08-23T21:38:00-06:00
- **Notes**: Metadata images now render native Ounje and plate recipes as circles while retaining squircles for imported and social/video recipes.

---

## [LRN-20260823-003] correction.native-preview-needs-opaque-cached-image

**Logged**: 2026-08-23T21:52:00-06:00
**Priority**: high
**Status**: resolved
**Area**: frontend

### Summary
Native messaging previews need a lightweight, opaque, full-bleed square even when the recipe page itself uses a circle or squircle.

### Details
Transparent circle and squircle corners let iMessage's sampled card color leak around the image's top edge. Rebuilding a large PNG on every request also made the preview noticeably slow. The recipe-origin shape is valuable on the webpage, but native clients already provide their own outer card mask.

### Suggested Action
Keep circle versus squircle classification on the web recipe page. For share metadata, crop the photo to an opaque 1080×1080 JPEG, use moderate compression, and cache the versioned response at the browser and CDN layers.

### Metadata
- Source: user_feedback
- Related Files: website/app/r/[shareId]/share-preview-image.js, website/app/r/[shareId]/preview-image/route.js, website/app/r/[shareId]/page.jsx
- Tags: open-graph, imessage, performance, jpeg, caching, correction
- Pattern-Key: social.preview.native-client.full-bleed.cached
- Recurrence-Count: 1
- First-Seen: 2026-08-23
- Last-Seen: 2026-08-23

### Resolution
- **Resolved**: 2026-08-23T21:52:00-06:00
- **Notes**: Replaced the dynamically rendered transparent PNG with a compressed opaque square JPEG and long-lived versioned caching; left webpage shape classification unchanged.
