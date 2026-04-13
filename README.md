# AIGTD Reminders

AIGTD Reminders is an iOS app that brings a chat-first AIGTD workflow to Apple Reminders.

Instead of managing tasks in a separate database, the app uses:

- `SwiftUI` for the app UI
- `SwiftData` for local app state
- `EventKit` for real Reminders access
- a configurable AI model layer with local fallback

The current implementation is built around a simple principle:

- chat with AIGTD
- interpret the request
- execute the result in iOS Reminders

## Version

Current version: `0.2.0`

Latest release notes:

- [v0.2.0](/Users/wan/wancode/todo/aigtd-ios-app/docs/releases/v0.2.0.md)

## What 0.1 includes

- chat-first onboarding flow
- optional model setup with first-send prompt
- real Apple Reminders permission handling
- read Reminders lists and items from the system
- create starter lists in Chinese
- create reminders from natural language
- complete reminders from chat
- move reminders between lists
- OpenAI-compatible model configuration
- `chat_completions` and `responses` wire API support
- remote-model runtime with local rule fallback
- grouped Reminders view inside the app

## Product direction

This app is not trying to replace Apple Reminders.

It is a conversational AIGTD layer on top of Reminders:

- tasks live in Apple Reminders
- the app keeps local chat, settings, and agent state
- the AI layer interprets intent and turns it into reminder actions

## Reuse from gtd-tasks

This project intentionally reuses stable ideas from [`gtd-tasks`](https://github.com/wanxcode/gtd-tasks):

- natural-language parsing approach
- reminder mapping strategy
- GTD-style category semantics
- agent-oriented workflow design

The goal is to reuse proven rules and behavior where possible, while re-implementing the execution and UI layers in native iOS form.

## Docs

- [AIGTD interaction principles](/Users/wan/wancode/todo/aigtd-ios-app/docs/aigtd-interaction-principles.md)
- [AIGTD conversation rules](/Users/wan/wancode/todo/aigtd-ios-app/docs/aigtd-conversation-rules.md)

## Project structure

```text
Sources/
  App/
  Features/
    Agent/
    Chat/
    Onboarding/
    Reminders/
  Models/
  Services/
docs/
project.yml
```

## Run locally

### Requirements

- Xcode 17+
- iOS 18+
- `xcodegen`

### Generate the project

```bash
xcodegen generate
```

### Build

```bash
xcodebuild -project AIGTDReminders.xcodeproj \
  -scheme AIGTDReminders \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Current limitations

- no multi-turn task disambiguation UI yet
- rule coverage is still being expanded to match more of `gtd-tasks`

## Changelog

See [CHANGELOG.md](/Users/wan/wancode/todo/aigtd-ios-app/CHANGELOG.md).
