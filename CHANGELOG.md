# Changelog

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
