# BC64Keys - AI Coding Assistant Guide

## Project Overview
BC64Keys is a **single-file macOS keyboard remapper** (~1,500 lines) designed as a simple, auditable alternative to Karabiner Elements. The entire app logic lives in `BC64KeysApp.swift` - there is no multi-file architecture.

**Core Philosophy**: Simplicity and security through minimal codebase size. The single-file design is intentional for easy auditing.

## Architecture (Single-File Structure)

All code in [Sources/BC64Keys/BC64KeysApp.swift](Sources/BC64Keys/BC64KeysApp.swift):

1. **App Entry** (`BC64KeysApp`) - SwiftUI app with `AppDelegate` adaptor
2. **AppDelegate** - Manages accessibility permissions, starts/stops `KeyRemapper`, 1-second status polling
3. **KeyRemapper** - CGEventTap-based key interception engine
4. **KeyMappingManager** - Stores/loads mapping rules to UserDefaults, provides 30+ predefined `NavigationAction`s
5. **UI Components** - `ContentView` with tabs: Monitor, Mapping, Settings
6. **L10n** (in [Localization.swift](Sources/BC64Keys/Localization.swift)) - Multi-language support (EN, HU)

**Data Flow**: User creates rule → `KeyMappingRule` → `KeyMappingManager` saves to UserDefaults → `KeyRemapper` applies via CGEventTap → Modified key event

## Critical Build & Run Workflow

**Build**: 
```bash
./build.sh  # Compiles with swiftc, creates .app bundle, code signs with ad-hoc signature
```
- Uses `swiftc` directly (NOT Xcode)
- Compiles `Localization.swift` + `BC64KeysApp.swift` together
- Creates full `.app` bundle with Info.plist
- Ad-hoc code signing with `com.bc64.BC64Keys` identifier

**Run**: 
```bash
./run.sh  # Launches: open ./BC64Keys.app
```

**Testing Mappings**: Use Monitor tab in-app to verify key codes before creating rules.

## macOS-Specific Patterns

### Accessibility Permissions (Core Requirement)
- **Required**: `AXIsProcessTrusted()` must return true for CGEventTap to work
- **Status Checking**: 1-second timer in AppDelegate continuously polls and logs to `~/Library/Logs/BC64Keys/bc64keys-status.log`
- **UI Indicator**: `StatusManager` (Observable) updates status bar in real-time
- If permissions revoked mid-session, remapper auto-stops

### CGEventTap Architecture
- Created in `KeyRemapper.startRemapping()` with `.cgSessionEventTap` and `.headInsertEventTap`
- Intercepts `.keyDown` + `.keyUp` events globally
- Returns `nil` to block keys (discard action), or new `CGEvent` to remap
- **Modifier Matching**: Exact matching on Cmd/Opt/Ctrl/Shift - if source rule has no modifiers, user can't press any

### Navigation Actions (Predefined)
30+ actions in `KeyMappingManager.navigationActions` for Windows→Mac switchers:
- Home → `⌘←` (line start), End → `⌘→` (line end)
- Ctrl+Home → `⌘↑` (doc start), Ctrl+End → `⌘↓` (doc end)
- Ctrl+Z → `⌘Z` (undo), Ctrl+C/V → `⌘C/V`
- Special: `keyCode: 0, modifiers: []` = discard/block key

## Key Code Conventions

**Special Key Mapping** (consistent across codebase):
```swift
115: "Home", 119: "End", 116: "PageUp", 121: "PageDown"
123: "←", 124: "→", 125: "↓", 126: "↑"
36: "Return", 48: "Tab", 49: "Space", 51: "Delete"
122-111: F1-F12
```

**Key Code Sources**: 
1. Press key in Monitor tab to capture
2. Look up in `specialKeys` dict (appears 3 times in file)
3. Carbon framework's virtual key codes

## Data Persistence

**Mappings**: UserDefaults key `"bc64keys.mappings"`, JSON-encoded `[KeyMappingRule]`
- Auto-saves on any change via `didSet` observer
- Structure: `sourceKeyCode`, `targetKeyCode`, optional `sourceModifiers`/`targetModifiers`, `type` (.simpleKey or .navigation)

**Language**: UserDefaults key `"bc64keys.language"`, triggers `L10n.reload()` on change

## Localization Pattern

**File**: [Sources/BC64Keys/Localization.swift](Sources/BC64Keys/Localization.swift)
- Singleton `L10n.shared`, used as `@ObservedObject` in views
- Computed properties return strings based on `lang` property
- Languages: `.system` (auto-detect), `.english`, `.hungarian`
- **Adding Language**: Add case to `AppLanguage` enum, extend computed properties in `L10n` class

**Usage**: `Text(L10n.current.tabMonitor)` - NOT string literals or NSLocalizedString

## UI Patterns

**Key Capture**: 
- Click button → sets `isCapturingFrom`/`isCapturingTo` state
- `NSEvent.addLocalMonitorForEvents` intercepts next keypress
- Returns `nil` to consume event (prevent typing in text field)

**Status Indicators**: 
- Color-coded: Blue (source key), Green (target key), Red (delete)
- Disabled rules: 50% opacity
- Modifier symbols: `⌘⌥⇧⌃` prefixed to key names

## Code Style & Conventions

**Comments**: MARK comments organize single file into logical sections
**Logging**: `print()` + file writes to `/tmp/bc64keys-status.log` with timestamps
**View Structure**: VStack/HStack with `.padding()`, `.background()`, `.cornerRadius()` - no custom view modifiers
**Error Handling**: Minimal - fails gracefully (e.g., `try?` for file writes, nil checks for event tap)

## Important Gotchas

1. **Build must include both files**: `Localization.swift` + `BC64KeysApp.swift` in swiftc command
2. **CGEventTap returns nil on permission failure** - check logs in `/tmp/bc64keys-status.log`
3. **Modifier matching is exact** - `Shift+Home` rule won't match bare `Home` press
4. **Bundle ID must match**: `com.bc64.BC64Keys` in Info.plist and codesign command
5. **No Xcode project** - this is a script-built app, don't expect .xcodeproj
6. **Backup files** (.bak, .backup-*) are manual saves, not part of build

## Testing Approach

- **Manual testing**: Monitor tab shows real-time key events
- **Permission testing**: System Settings > Privacy & Security > Accessibility
- **Log inspection**: `tail -f /tmp/bc64keys-status.log` during runtime
- **No unit tests** - app is simple enough for manual verification

## When Modifying

**Adding Navigation Action**: Edit `KeyMappingManager.navigationActions` array
**Changing UI**: Edit view structs in main file (search for `struct ContentView`)
**Adding Language**: Extend `AppLanguage` enum + all `L10n` computed properties
**Debugging Remapping**: Add print statements in `KeyRemapper.handleEvent()` callback
