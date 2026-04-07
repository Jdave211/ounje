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
