## [ERR-20260825-031] first_run_guide_refactor

**Logged**: 2026-08-25T05:12:00Z
**Priority**: low
**Status**: resolved
**Area**: frontend

### Summary
The first Swift build after simplifying the guide catalog still referenced the removed template cache.

### Error
```
cannot find 'template' in scope
```

### Context
- File: client/ios/ounje/Features/FirstRunGuide/FirstRunGuideCoordinator.swift
- Cause: `resetInMemory()` retained a cleanup assignment after the cached template property was removed.

### Suggested Fix
Run a reference search after removing coordinator state, then compile before device installation.

### Resolution
- **Resolved**: 2026-08-25T05:12:00Z
- **Notes**: Removed the stale reset assignment and rebuilt.

---
## [ERR-20260825-032] device_build_intermediate_installed

**Logged**: 2026-08-25T05:03:20Z
**Priority**: high
**Status**: resolved
**Area**: frontend

### Summary
An intermediate signed app bundle was installed before Xcode completed linking the current guide code.

### Error
```
The installed phone UI still contained the previous coachmark text and full-card spotlight.
```

### Context
- The build command had not returned a `BUILD SUCCEEDED` result.
- The app bundle already existed in DerivedData, so installation silently used its prior contents.

### Suggested Fix
For device installs, retain the build session until exit code 0, then verify an updated source string in the packaged `ounje.debug.dylib` before installing.

### Resolution
- **Resolved**: 2026-08-25T05:03:20Z
- **Notes**: Rebuilt to `BUILD SUCCEEDED`, verified the new coachmark string and absence of the old string in the signed binary, then reinstalled and launched it.

---
## [ERR-20260825-033] optional_target_preference_syntax

**Logged**: 2026-08-25T05:18:00Z
**Priority**: low
**Status**: resolved
**Area**: frontend

### Summary
Swift does not permit optional binding inside a ternary expression argument.

### Error
```
expected expression in list of expressions
```

### Context
- File: client/ios/ounje/Features/FirstRunGuide/SpotlightGuideOverlay.swift
- Cause: target-preference creation used `enabled, let id ?` inside a function argument.

### Suggested Fix
Use an explicit `if enabled, let id` branch in the `GeometryReader` view builder.

### Resolution
- **Resolved**: 2026-08-25T05:18:00Z
- **Notes**: Replaced the invalid ternary with a SwiftUI conditional view branch.

---
