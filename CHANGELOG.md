# Changelog

## Unreleased

Current development changes after `0.2.0`.

### Added

- redesigned the in-app Reminders browser with system-list ordering, empty-list visibility, latest-sync status, and direct completion / deletion actions
- added reminder browser states for permission missing, sync failure, empty store, and no remaining active tasks
- documented the structured AI action execution plan for chat-driven Reminders operations under `docs/ai-structured-action-execution.md`

### Improved

- improved Reminders tab consistency with Apple Reminders by preserving the system list order instead of re-sorting list titles in app code
- updated microphone permission handling for newer iOS APIs in Agent settings
- aligned remote streaming text callbacks with `@MainActor` expectations to keep chat reply rendering safer on the UI thread
- improved voice session lifecycle handling when the Doubao ASR engine is not fully ready or disconnects during finalize
- kept reminder sync state metadata (`lastReminderSyncAt`) so the UI can show the latest refresh time more clearly
- switched the remote chat runtime to prefer structured JSON actions so the app can distinguish task execution from plain conversation more reliably
- updated chat execution flow to show pending wording first and only confirm success after local Reminders writes actually finish

### Fixed

- fixed Reminders sections disappearing when a list had no active tasks
- fixed stale reminder data remaining visible after reminders permission was revoked
- fixed speech session user ID generation to avoid depending on `identifierForVendor`
- fixed chat replies claiming a reminder was created even when no executable action had been produced or persisted

## 0.2.0

Second development release focused on remote-agent stability and chat input experience.

### Added

- integrated CocoaPods workspace and speech engine dependencies
- Doubao official ASR websocket session service
- in-app voice transcription pipeline (start/stop, live partials, final refinement)
- chat composer voice toggle and keyboard takeover behavior
- default agent documents (`memory.md` / `solu.md`) bootstrap and persistence
- remote response debug capture utilities for troubleshooting model payloads
- release and interaction PRD docs under `docs/`

### Improved

- OpenAI-compatible `responses` wire API handling aligned with real-world gateway behavior
- better streaming render path for assistant replies in chat
- keyboard + message list coordination (dismiss, focus, scroll-to-bottom restoration)
- composer growth and multi-line editing behavior
- reminder list read/refresh consistency in Reminders tab
- onboarding-to-chat transition and startup responsiveness

### Fixed

- fixed first-send model-setup edge cases with existing chat history
- fixed chat action card navigation to Reminders list
- fixed replies that returned empty/unsupported aggregated response payloads
- fixed voice input session stop/finalize race conditions
- fixed keyboard takeover leaving voice indicator dots in the input area
- fixed multiple UI states where keyboard or composer could become unresponsive

### Security

- removed hardcoded model/voice credential defaults from source code
- keep credentials user-provided in settings/local storage only

## 0.1.0

First usable development release.

### Added

- initial SwiftUI iOS app shell
- onboarding flow for welcome, Reminders permission, starter lists, and chat entry
- chat-first main experience
- local chat persistence with SwiftData
- model settings with provider, wire API, API key, and connection test
- support for both `chat_completions` and `responses`
- remote runtime with local fallback behavior
- real EventKit integration for:
  - reading reminder lists
  - reading reminder items
  - creating reminder lists
  - creating reminders
  - moving reminders
  - completing reminders
- grouped Reminders view inside the app
- automatic focus/scroll support for newly created reminders
- ambiguity detection for reminder matching

### Reused / aligned from gtd-tasks

- natural-language parsing direction
- GTD-style semantic mapping
- Apple Reminders mapping priorities
- task title cleanup and time parsing heuristics

### Notes

- this version is an MVP-style foundation release
- the product is usable for core reminder creation and completion flows, with more rule migration still planned
