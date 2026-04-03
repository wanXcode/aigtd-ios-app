# Changelog

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
