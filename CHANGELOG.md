# Changelog

## Unreleased

Development continues after the `0.4.0` context-and-memory candidate.

## 0.4.0 - Release Candidate

Context and memory release candidate validated through build `0.4.0 (17)`.

### Added

- added a versioned, immutable `AgentContextSnapshot` for every model request
- added per-session summaries and stable references for recently created, modified, moved, completed, shown, and selected reminders
- added deterministic reference resolution for stable IDs, ordinal phrases such as “第二条”, stale targets, and duplicate titles
- added explicit long-term preference detection with whitelist and sensitive-data rejection rules
- added Agent context and privacy controls for notes, completed reminders, task limits, local context, and saved memory
- added context, reference, summary, and memory diagnostic stages without persisting private source content by default
- added offline context, memory, privacy, reference, and persistence test suites

### Improved

- all four Agent documents now enter the runtime prompt, with safe defaults and independent 4,000-character budgets
- task context now carries stable Reminder IDs, list, due date, completion state, relevance reason, and optional note preview
- successful reminder actions now write their returned EventKit IDs back to session context
- reminder refresh failures preserve the last successful snapshot instead of clearing visible tasks
- long conversations retain deterministic goals, scopes, confirmed constraints, successful action facts, and related IDs
- local fallback execution now consumes the same reminder snapshot, Agent documents, and structured preferences as the remote runtime
- saved long-term preferences can be reviewed and edited from the context privacy screen
- multiple transaction rules can coexist, and editing one rule no longer overwrites another
- read-only reminder detail queries now return final note and completion-state results from the privacy-filtered local snapshot

### Fixed

- fixed date-only reminders being assigned a hidden 09:00 time when no default-time preference exists
- fixed reminder cards omitting explicit times or disagreeing with the EventKit due date
- fixed natural reminder titles being truncated by field-label cleanup
- fixed delete keywords inside reminder titles being treated as destructive commands
- fixed unique exact titles being rejected when another reminder only contained the same text
- fixed sensitive-memory rejection and one-time reminder wording producing misleading save replies or malformed titles
- fixed additional transaction rules replacing previously saved rules
- fixed note and completion-state queries stopping after a generic “I will check” transition reply

### Safety

- explicit or stale Reminder IDs never silently fall back to fuzzy title matching
- duplicate-title actions stop when a unique target cannot be established
- stable IDs are cross-checked against explicit titles and references, and resolved actions execute by identifier
- saved delete-confirmation rules are enforced locally before EventKit mutation
- task notes and completed reminders remain excluded from remote context unless the user opts in
- ordinary chat, one-time tasks, emotions, credentials, contact details, addresses, health data, and financial data are not saved as long-term memory
- edited long-term preferences are rejected when they contain sensitive content

### Validation

- passed the expanded full iPhone suite with 96 tests and 0 failures
- retained the original 100-case conversation evaluation baseline
- added a separate 50-case context and memory evaluation fixture
- passed all nine manual iPhone acceptance groups for build `0.4.0 (17)`
- uploaded build `0.4.0 (17)` to App Store Connect for TestFlight processing

## 0.3.0 - Release Candidate

Stabilization release candidate validated on iPhone through build `0.3.0 (15)`; automated-test findings are addressed in final candidate `0.3.0 (16)`.

### Added

- redesigned the in-app Reminders browser with system-list ordering, empty-list visibility, latest-sync status, and direct completion / deletion actions
- added reminder browser states for permission missing, sync failure, empty store, and no remaining active tasks
- documented the structured AI action execution plan for chat-driven Reminders operations under `docs/ai-structured-action-execution.md`
- added structured `delete_reminder` chat intent execution so follow-up delete requests can remove reminders for real instead of only replying in text
- added a two-stage reminder rescheduling flow that prepares a deterministic schedule for review before applying it
- added the `AIGTDRemindersTests` unit-test target and an offline smoke test baseline

### Improved

- improved Reminders tab consistency with Apple Reminders by preserving the system list order instead of re-sorting list titles in app code
- updated microphone permission handling for newer iOS APIs in Agent settings
- aligned remote streaming text callbacks with `@MainActor` expectations to keep chat reply rendering safer on the UI thread
- improved voice session lifecycle handling when the Doubao ASR engine is not fully ready or disconnects during finalize
- kept reminder sync state metadata (`lastReminderSyncAt`) so the UI can show the latest refresh time more clearly
- switched the remote chat runtime to prefer structured JSON actions so the app can distinguish task execution from plain conversation more reliably
- updated chat execution flow to show pending wording first and only confirm success after local Reminders writes actually finish
- included a recent conversation window in remote model prompts so phrases like “刚才那条 / 你刚建的那个” can resolve against chat context more reliably
- aligned the project generation source and Xcode project on version `0.3.0 (5)`
- advanced the post-test repair candidate to build `0.3.0 (13)`
- normalized explicit create fields such as `标题是...，时间是...` before displaying or writing reminder titles
- strengthened delete matching so one exact result plus other plausible candidates requires clarification
- declared the app's non-exempt encryption usage in generated Info.plist to avoid repeated TestFlight export-compliance prompts
- advanced the TestFlight smoke-test hotfix candidate to build `0.3.0 (14)`
- advanced the time-qualified deletion hotfix candidate to build `0.3.0 (15)`
- advanced the fully automated-test-validated candidate to build `0.3.0 (16)`

### Fixed

- fixed single-reminder time changes being misclassified as batch rescheduling by adding an executable `update_reminder` action
- fixed generated reschedule plans being marked failed before the user could apply them
- fixed exact duplicate reminder titles bypassing ambiguity protection during destructive actions
- fixed explicit delete dates and times being discarded before duplicate-candidate resolution
- fixed weekday and Chinese time-only parsing in the local fallback
- fixed task titles containing “测试” being mistaken for casual probes
- fixed “未完成” queries being mistaken for completion commands
- fixed Authorization diagnostics redaction removing the Bearer scheme
- fixed plain conversation briefly showing an incorrect provisional Action card before the model intent was known
- fixed newly completed reminder syncs displaying as occurring “0 秒后”
- fixed Chinese relative-date updates retaining the current clock time instead of the requested hour, and corrected next-week weekday calculation
- fixed targetless follow-up time changes searching by duplicate titles instead of using the most recently created reminder ID
- fixed successful contextual time changes retaining a stale ambiguity follow-up in the completed Action card
- changed ambiguous deletion from a contradictory failure state to a non-destructive “待确认” state
- fixed the Reminders sync age label not advancing after its initial “刚刚同步” render
- added navigation from the Agent diagnostics summary to request and stage-level diagnostic details
- completed Chat trace lifecycle recording so finished requests no longer remain labeled as processing
- fixed Reminders sections disappearing when a list had no active tasks
- fixed stale reminder data remaining visible after reminders permission was revoked
- fixed speech session user ID generation to avoid depending on `identifierForVendor`
- fixed chat replies claiming a reminder was created even when no executable action had been produced or persisted
- fixed streaming chat rendering leaking raw structured JSON to the message bubble before the final reply was resolved
- fixed follow-up task deletion commands failing because relative references like “删除刚才这条任务” were not mapped back to the most recently created reminder

### Validation

- passed Debug and Release iOS builds
- compiled the offline unit-test target and 100-case Chinese conversation evaluation suite
- passed the documented iPhone acceptance flow for create, update, move, delete, reschedule, ambiguity protection, plain chat, sync display, and diagnostics
- verified local diagnostic retention and credential redaction behavior

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
