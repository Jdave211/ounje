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
