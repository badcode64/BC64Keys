# Contributing to BC64Keys

Thanks for your interest in contributing!

## Project goals (important)
- **Keep it auditable:** the core app intentionally lives in a single file: [Sources/BC64Keys/BC64KeysApp.swift](Sources/BC64Keys/BC64KeysApp.swift)
- **No external dependencies:** prefer standard Swift/SwiftUI + system frameworks
- **Privacy-first:** no network features, no telemetry

## Dev setup
Requirements:
- macOS 13+
- Xcode Command Line Tools: `xcode-select --install`

Build & run:
- `./build.sh`
- `./run.sh`

## Where to change things
- UI + remapping engine: [Sources/BC64Keys/BC64KeysApp.swift](Sources/BC64Keys/BC64KeysApp.swift)
- Localization strings + language switching: [Sources/BC64Keys/Localization.swift](Sources/BC64Keys/Localization.swift)

## Testing changes
There are no unit tests.
- Use the **Monitor** tab to verify key codes/events.
- Watch logs while running: `tail -f ~/Library/Logs/BC64Keys/bc64keys-status.log`
- Verify Accessibility permission behavior: System Settings → Privacy & Security → Accessibility

## Pull request guidelines
- Keep changes minimal and focused.
- Don’t split the single-file design into a multi-file architecture unless discussed first.
- If you change key codes / modifier logic, include a short note in the PR description about how you verified it.
