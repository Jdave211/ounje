## [ERR-20260322-001] xcodebuild

**Logged**: 2026-03-22T18:11:53Z
**Priority**: medium
**Status**: pending
**Area**: frontend

### Summary
Swift build failed after a patch inserted an escaped quote into a Swift string literal.

### Error
```
/Users/davejaga/Desktop/startups/ounje/client/ios/ounje/OunjeAgenticApp.swift:2266:35: error: unterminated string literal
```

### Context
- Command attempted: `xcodebuild -project client/ios/ounje.xcodeproj -scheme ounje -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Cause: patch inserted `Color(hex: \"FFD166\")` instead of `Color(hex: "FFD166")`

### Suggested Fix
When patching Swift source, avoid escaping quotes inside the patch body unless the Swift code itself requires a backslash.

### Metadata
- Reproducible: yes
- Related Files: /Users/davejaga/Desktop/startups/ounje/client/ios/ounje/OunjeAgenticApp.swift

---
## [ERR-20260322-002] psql

**Logged**: 2026-03-22T18:55:00Z
**Priority**: medium
**Status**: pending
**Area**: infra

### Summary
Direct Supabase schema apply via `psql` failed because the CLI is not installed on this machine.

### Error
```
zsh:1: command not found: psql
```

### Context
- Command attempted: `psql 'postgresql://postgres.ztqptjimmcdoriefkqcx@aws-1-us-east-2.pooler.supabase.com:6543/postgres' -f supabase/migrations/20260322_profiles_onboarding.sql`
- Follow-up checks showed there is no local Postgres Python or Node client installed either (`psycopg`, `psycopg2`, `asyncpg`, `pg`, `postgres`).

### Suggested Fix
Use a scripted client path for DB changes on this machine, for example `python3 -m pip install --user psycopg[binary]`, then execute migrations through Python when `psql` is unavailable.

### Metadata
- Reproducible: yes
- Related Files: /Users/davejaga/Desktop/startups/ounje/supabase/migrations/20260322_profiles_onboarding.sql
- Related Files: /Users/davejaga/Desktop/startups/ounje/.learnings/ERRORS.md

---
## [ERR-20260322-003] xcodebuild

**Logged**: 2026-03-22T19:41:00Z
**Priority**: medium
**Status**: pending
**Area**: frontend

### Summary
Swift build failed because a new `filter` call used an escaped key path token inside source.

### Error
```
/Users/davejaga/Desktop/startups/ounje/client/ios/ounje/OunjeAgenticApp.swift:2441:72: error: expected expression path in Swift key path
```

### Context
- Command attempted: `xcodebuild -project client/ios/ounje.xcodeproj -scheme ounje -configuration Release -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Cause: patch inserted `filter(\\.carriedFromPreviousPlan)` instead of a valid Swift expression.

### Suggested Fix
When patching Swift, prefer plain closure syntax for inline filters in patch bodies if escaping could be ambiguous.

### Metadata
- Reproducible: yes
- Related Files: /Users/davejaga/Desktop/startups/ounje/client/ios/ounje/OunjeAgenticApp.swift
- See Also: ERR-20260322-001

---
- ERR-20260322-004: Large shell refactor left duplicate legacy views and stray braces in `OunjeAgenticApp.swift`, causing top-level brace errors; fixed by deleting the leftover duplicated block before `MainAppBackdrop`.
- ERR-20260322-005: New discover shell introduced a missing `DiscoverTopActionButtonStyle` and an iOS 17-only `foregroundStyle` call inside `TextField` prompt; fixed by adding the style and using an iOS 16-safe prompt.

## [ERR-20260517-001] supabase-cli

**Logged**: 2026-05-17T21:09:34Z
**Priority**: medium
**Status**: pending
**Area**: infra

### Summary
`supabase` CLI is not installed in the local shell, so migration scaffolding via `supabase migration new` is unavailable.

### Error
```
zsh:1: command not found: supabase
```

### Context
- Command attempted: `supabase --version && supabase migration new growth_outreach_agent`
- This blocks the preferred Supabase skill workflow for creating a migration filename, so use the repo's existing timestamped migration convention as a fallback when the CLI is unavailable.

### Suggested Fix
Install the Supabase CLI in the local development environment or add a repo helper that generates migration files consistently without requiring a global CLI.

### Metadata
- Reproducible: yes
- Related Files: /Users/davejaga/Desktop/startups/ounje/supabase/migrations

---

## [ERR-20260518-001] playwright-browser

**Logged**: 2026-05-18T16:58:56Z
**Priority**: medium
**Status**: pending
**Area**: backend

### Summary
Playwright package was installed, but its managed Chromium executable was missing, so browser-based growth discovery failed before navigation.

### Error
```
browserType.launch: Executable doesn't exist at /Users/davejaga/Library/Caches/ms-playwright/chromium_headless_shell-1217/chrome-headless-shell-mac-arm64/chrome-headless-shell
```

### Context
- Command attempted: `GROWTH_SEARCH_PROVIDER=playwright npm run growth:outreach-local -- --mode quora`
- Playwright suggested `npx playwright install`, but `/Applications/Google Chrome.app` exists locally and can be used as a fallback browser.

### Suggested Fix
When running Playwright automation on this Mac, prefer a system Chrome executable fallback before requiring a Playwright browser download.

### Metadata
- Reproducible: yes
- Related Files: /Users/davejaga/Desktop/startups/ounje/server/lib/growth-outreach-agent.js

---

## [ERR-20260518-002] browser-use-credits

**Logged**: 2026-05-18T17:04:00Z
**Priority**: medium
**Status**: pending
**Area**: backend

### Summary
Browser-use search provider failed because the configured account has no available credits.

### Error
```
browser-use createSession 402: {"detail":"You need at least $1.00 in credits. Current balance: $0.00"}
```

### Context
- Command attempted: `GROWTH_SEARCH_PROVIDER=browser-use npm run growth:outreach-local -- --mode quora`
- The local runner should treat this as a provider failure and continue/fail gracefully, not crash the process before writing a run summary.

### Suggested Fix
Handle browser-use session creation failures as non-fatal search-provider failures and require account credits before using `GROWTH_SEARCH_PROVIDER=browser-use`.

### Metadata
- Reproducible: yes
- Related Files: /Users/davejaga/Desktop/startups/ounje/server/lib/growth-outreach-agent.js

---
