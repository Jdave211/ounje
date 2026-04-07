# Ounje

This repo is the Ounje iOS app + backend.

## Working rules
- Prefer the local Codex profile when requested: `codex --profile ollama-launch`.
- Use OpenClaw gateway as the orchestration layer for multi-step, long-running, or recoverable work.
- If the gateway looks stale, restart it with `openclaw gateway restart` or `launchctl kickstart -k gui/$UID/ai.openclaw.gateway`.
- Use `swift-expert` for iOS / SwiftUI work and `supabase` for any database, auth, or storage work.
- Keep changes incremental and verify before reporting success.
- Do not overwrite unrelated user changes.
