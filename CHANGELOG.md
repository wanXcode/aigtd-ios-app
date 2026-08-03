# Changelog

## 0.7.0 (23) - TestFlight Candidate

`0.7.0` upgrades the existing reliable task capabilities into a public-facing product experience without expanding the smart-planning scope.

### Experience updates

- introduce Xiaoman as the default AIGTD assistant and add a one-time welcome experience
- reduce the public navigation to AIGTD and Tasks
- rebuild chat viewport ownership, keyboard interaction, growing input, streaming rendering, and in-place action-card transitions
- add press-and-hold voice input with live transcription, slide-up cancellation, and editable drafts that never auto-send
- redesign Tasks as a read-only AIGTD overview that remains visually distinct from Apple Reminders
- preserve system list ordering where EventKit exposes it and keep empty lists visible
- remove model, endpoint, API key, prompt, and diagnostics controls from public Release builds
- add the warm AIGTD visual system, Dynamic Type, VoiceOver, Reduce Motion, and interruption-safe draft recovery

### Fixed

- fixed a launch crash in TestFlight build 21 by restoring the CocoaPods framework embedding phase so `TTNetworkManager.framework` ships inside the app
- fixed a second launch crash in TestFlight build 22 by moving EventKit reminder fetching outside `AppModel`'s main-actor isolation before returning sendable reminder values to the UI
- made `xcodegen generate` run `pod install` automatically and added an archive dependency check to prevent linked dynamic frameworks from being omitted again
- fixed voice permission, cancellation, interruption, and late-finalization races so cancelled recordings cannot overwrite the draft
- fixed same-title reminder lists being merged in the read-only overview and kept each list's session order stable
- fixed stale reminder context leaking into unrelated Chat turns after returning from task details
- fixed denied Reminders permission advancing onboarding as if access had succeeded
- fixed stale cached tasks appearing current after a reminder refresh failure

### Safety

- removed local secret resources and developer-facing model, endpoint, API key, prompt, and diagnostics controls from the Release product
- kept voice transcription as an editable draft after release; voice input never auto-sends or bypasses task confirmation
- retained ambiguity, stale-state, confirmation, partial-failure, and undo protections from `0.6.0`

### Validation

- generic iOS Simulator and generic iOS `build-for-testing` succeed for the app and 374 XCTest methods
- generic iOS Release build and static analysis succeed
- `git diff --check`, Release developer-copy scan, and sensitive-resource scan succeed
- full XCTest execution remains pending because Xcode 26.2 cannot run the installed iOS 26.3 simulator and the third-party speech Pods exclude arm64 simulator builds
- the signed Build 23 development app launches on iPhone 15 Pro Max, remains running after the initial Reminders refresh, and produces no new crash report
- the signed `0.7.0 (23)` archive succeeds and its team, bundle ID, version, architecture, packaged resources, and embedded dynamic dependencies pass inspection
- uploaded `0.7.0 (23)` to App Store Connect on 2026-08-03; Apple returned `Upload succeeded` and began processing the package
- TestFlight upload and in-place upgrade acceptance are recorded in `docs/releases/v0.7.0-test-plan.md`

## 0.6.0 - 2026-08-02

`0.6.0 (20)` completes the natural confirmation, recovery, and reversible-action development scope. Final iPhone and TestFlight upgrade acceptance passed.

### Added

- added versioned pending interactions that survive app restarts and invalidate superseded or expired plans
- added exact local text confirmation and cancellation for the current session's active plan
- added a unified local execution policy that prevents model confirmation fields from bypassing safety rules
- added failed-item-only recovery with original run and call identity reuse
- added persisted inverse operations for task creation, field updates, moves, completion changes, and schedule application
- added card and natural-language undo with ten-minute availability, reverse-order execution, and external-change conflict protection
- expanded the multi-tool safety fixture from 40 to 70 cases across confirmation, plan editing, recovery, and undo

### Improved

- pending cards now provide execute, adjust, and cancel actions through the same deterministic interaction state
- pending, result, retry, and undo states update the original card instead of adding replacement cards
- partial failures expose retry only when retryable failed items remain and never repeat successful or unchanged writes
- undo snapshots retain only required values; task notes are compared using SHA-256 rather than copied into general snapshots
- semantically identical writes are deduplicated locally across model turns even when the model changes `call_id`
- undo cards now use explicit restored, partial, conflict, and failed terminal copy instead of retaining pending text

### Fixed

- fixed a high-risk loop where one create intent could execute four times with different model call IDs before exhausting the orchestration budget
- fixed restored cards showing an “in progress” title after undo had already completed

### Safety

- ambiguous targets, missing stable IDs, stale preconditions, and externally changed tasks remain non-executable
- long-term transaction rules may tighten confirmation but cannot weaken local uniqueness and precondition checks
- delete operations remain non-reversible and never advertise a false undo action
- old persisted undo snapshots decode safely and missing new snapshot fields default to conservative behavior

### Validation

- generic iOS build and `build-for-testing` succeed
- 334/334 XCTest methods pass on iPhone 15 Pro Max with 0 failures
- 70 multi-tool evaluation fixtures pass structural and safety validation
- all 15 iPhone experience cases pass, including the duplicate-write and undo-copy fixes discovered during acceptance
- uploaded `0.6.0 (20)` to App Store Connect on 2026-08-02; Apple finished processing it and assigned it to the internal `test` group
- passed the TestFlight in-place upgrade data-safety check and the focused multi-action, natural confirmation, undo, and external-conflict regression

## 0.5.0 - 2026-07-31

`0.5.0 (19)` completes structured tool calling, multi-action execution, and the final TestFlight upgrade acceptance.

### Added

- added a strict structured model protocol and `AgentOrchestrator` loop that feeds real tool results back into model decisions
- added ten typed Reminders tools for search, details, list creation, task creation, update, move, completion, deletion, schedule proposal, and schedule application
- added stable `run_id` / `call_id` idempotency with a persistent 24-hour execution ledger
- added persisted schedule plans, write preconditions, dependency-aware `depends_on` execution, partial-failure aggregation, and safe confirmation recovery after app restart
- added privacy-redacted run diagnostics, 111 focused tool/orchestration tests, and a 40-case multi-tool evaluation fixture
- added visible app and Agent engine version information to the Agent page

### Improved

- Chat now routes configured remote-model requests through the structured Agent before using the 0.4 compatibility path
- multi-action cards remain in place and show each operation's pending, success, unchanged, skipped, timeout, or failure state
- final failure and partial-success replies are generated from verified local tool results instead of trusting model completion claims
- tool execution is bounded to four model turns, eight total calls, five calls per turn, and 8/12/30-second read/write/schedule timeouts
- new list creation now preserves the existing confirmation policy and strictly reuses an exact existing list instead of creating duplicates
- the Agent now receives the complete Reminders list catalog, including empty lists, so explicit destinations resolve by stable list ID
- missing explicit lists are created first and dependent task writes execute only after list creation succeeds
- follow-up details for a newly created task no longer produce a redundant equivalent update or a misleading “无需修改” result

### Safety

- multiple writes, list creation, schedule application, and deletion are blocked until local confirmation policy allows execution
- failed or missing dependencies skip downstream writes instead of continuing a broken plan
- a run that has already started using tools never falls back into the legacy executor after a network or protocol failure
- EventKit writes re-read stable IDs and reject stale list, date, completion, or existence preconditions
- EventKit gateway failures retain specific categories such as missing list, missing reminder, permission, conflict, or store failure instead of collapsing into a generic tool error
- default run diagnostics store structure and hashes rather than raw titles, notes, model context, or credentials

### Validation

- simulator `build-for-testing` passes for the app and all test targets
- 222 XCTest methods compile; the existing 220-test baseline passed on `QI的iPhone`, and the 2 hotfix regressions compile in Build 19
- the 40-case multi-tool fixture passes JSON count and category-distribution checks
- passed the core manual experience cases 1-11 plus empty-list and missing-list creation scenarios
- uploaded `0.5.0 (18)` to App Store Connect for TestFlight processing on 2026-07-31
- uploaded `0.5.0 (19)` after Build 18 exposed a redundant create-then-update interaction
- passed the Build 19 follow-up creation regression without an extra update result
- passed the TestFlight upgrade data-safety acceptance for chat, settings, long-term memory, and Reminders data

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
- passed the final TestFlight upgrade-install smoke test without losing chat, settings, or Reminders data

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
