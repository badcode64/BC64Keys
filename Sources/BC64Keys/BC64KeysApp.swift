import SwiftUI
import AppKit
import Carbon
import ServiceManagement

// BC64Keys
// -------
// A minimal macOS keyboard remapper implemented in (mostly) a single Swift file on purpose.
// The goal is auditability: fewer moving parts, fewer dependencies, easier review.
//
// How it works (high level):
// - UI lets the user define KeyMappingRule items (source key + optional modifiers → target key/modifiers)
// - Rules are persisted in UserDefaults via KeyMappingManager (JSON encoded)
// - A CGEventTap (KeyRemapper) intercepts keyDown/keyUp/flagsChanged events and either:
//   - blocks them (discard), or
//   - emits a replacement CGEvent (remap)
//
// v1.9.2 Features:
// - Fix FlagsChanged NSEvent crash in Monitor (charactersIgnoringModifiers)
// - Reduce keyboard lag: no per-keystroke debug I/O / DispatchQueue.sync; stop Monitor on tab leave
//
// v1.9.1 Features:
// - Hide Dock Icon: temporarily become .regular when showing the window so it fronts / Cmd-Tab works
//
// v1.9.0 Features:
// - Optional Hide Dock Icon: run from the menu bar, click B to show the window
//
// v1.8.0 Features:
// - Window switching navigation actions: Switch App (⌘Tab) and Switch Window (⌘`)
// - Event pass-through: unmapped keys keep the original CGEvent
// - Navigation preset restore matches key code + modifiers
//
// v1.7.0 Features:
// - Visual Keyboard: Interactive on-screen keyboard for selecting target keys
// - Unicode Character Support: Send actual characters via keyboardSetUnicodeString()
// - Improved modifier handling for Cmd+Key → Plain Key mappings
//
// Privacy note:
// - This app needs Accessibility permission to observe/modify keystrokes globally.
// - Keep logging conservative; anything written to stdout or /tmp can be readable by other local processes.

// MARK: - Constants
/// Shared key code to name mapping used throughout the app
let kSpecialKeys: [UInt16: String] = [
    36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
    115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 117: "Del→",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    122: "F1", 120: "F2", 99: "F3", 118: "F4",
    96: "F5", 97: "F6", 98: "F7", 100: "F8",
    101: "F9", 109: "F10", 103: "F11", 111: "F12",
    // Modifier keys
    57: "⇪ CapsLock", 56: "⇧ LShift", 60: "⇧ RShift",
    59: "⌃ LCtrl", 62: "⌃ RCtrl", 58: "⌥ LOpt", 61: "⌥ ROpt",
    55: "⌘ LCmd", 54: "⌘ RCmd", 63: "fn"
]

// MARK: - Physical modifier keys
// Device-specific masks from IOKit/hidsystem/IOLLEvent.h distinguish each side.
struct PhysicalModifier {
    let keyCode: UInt16
    let flag: CGEventFlags
    let deviceMask: UInt64

    static let all: [PhysicalModifier] = [
        .init(keyCode: 56, flag: .maskShift, deviceMask: 0x02),
        .init(keyCode: 60, flag: .maskShift, deviceMask: 0x04),
        .init(keyCode: 59, flag: .maskControl, deviceMask: 0x01),
        .init(keyCode: 62, flag: .maskControl, deviceMask: 0x2000),
        .init(keyCode: 58, flag: .maskAlternate, deviceMask: 0x20),
        .init(keyCode: 61, flag: .maskAlternate, deviceMask: 0x40),
        .init(keyCode: 55, flag: .maskCommand, deviceMask: 0x08),
        .init(keyCode: 54, flag: .maskCommand, deviceMask: 0x10)
    ]
    static let userFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    static func key(_ keyCode: UInt16) -> PhysicalModifier? {
        all.first { $0.keyCode == keyCode }
    }

    func isDown(in flags: CGEventFlags) -> Bool {
        flags.rawValue & deviceMask != 0
    }

    func removing(from flags: CGEventFlags) -> CGEventFlags {
        var result = CGEventFlags(rawValue: flags.rawValue & ~deviceMask)
        if !Self.all.contains(where: { $0.flag == flag && $0.isDown(in: result) }) {
            result.remove(flag)
        }
        return result
    }

    func adding(to flags: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: flags.rawValue | deviceMask | flag.rawValue)
    }
}

// Capture the actual physical modifier immediately on press.
struct KeyCaptureState {
    struct Selection {
        let keyCode: UInt16
        let flags: CGEventFlags
    }

    func capture(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Selection? {
        if type == .keyDown {
            return Selection(keyCode: keyCode, flags: flags.intersection(PhysicalModifier.userFlags))
        }
        guard type == .flagsChanged else { return nil }
        if keyCode == 57 {
            return Selection(keyCode: keyCode, flags: flags.intersection(PhysicalModifier.userFlags))
        }
        guard let modifier = PhysicalModifier.key(keyCode), modifier.isDown(in: flags) else { return nil }
        return Selection(keyCode: keyCode, flags: modifier.removing(from: flags).intersection(PhysicalModifier.userFlags))
    }
}

// MARK: - Main App
@main
struct BC64KeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Window("BC64Keys", id: "main") {
            ContentView(mappingManager: appDelegate.mappingManager, statusManager: appDelegate.statusManager)
                .environmentObject(appDelegate)
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}

// MARK: - Status Manager (Observable)
class StatusManager: ObservableObject {
    @Published var hasAccessibility: Bool = false
    @Published var remapperRunning: Bool = false
    @Published var lastCheck: Date = Date()
    
    func update(accessibility: Bool, remapperRunning: Bool) {
        DispatchQueue.main.async {
            self.hasAccessibility = accessibility
            self.remapperRunning = remapperRunning
            self.lastCheck = Date()
        }
    }
}

// MARK: - Launch at Login Manager
class LaunchAtLoginManager: ObservableObject {
    @Published var isEnabled: Bool = false
    
    private let service = SMAppService.mainApp
    
    init() {
        updateStatus()
    }
    
    func updateStatus() {
        isEnabled = (service.status == .enabled)
    }
    
    func toggle() {
        do {
            if isEnabled {
                try service.unregister()
                print("✅ Launch at login disabled")
            } else {
                try service.register()
                print("✅ Launch at login enabled")
            }
            updateStatus()
        } catch {
            print("❌ Failed to toggle launch at login: \(error.localizedDescription)")
        }
    }
}

// MARK: - App Delegate for Accessibility Permissions
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, ObservableObject {
    var keyRemapper: KeyRemapper?
    var statusCheckTimer: Timer?
    var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var mainWindowRef: NSWindow?
    
    // Track previous state to avoid spamming logs
    private var previousAccessibilityState: Bool?
    private var previousRemapperState: Bool = false
    
    // Debug logging is now optional - only enabled if user explicitly turns it on in Settings.
    // This reduces SSD wear and avoids logging sensitive keystroke patterns by default.
    @AppStorage("bc64keys.debugLogging") var debugLoggingEnabled: Bool = false
    @AppStorage("bc64keys.hideDockIcon") var hideDockIcon: Bool = false
    
    // Prefer a per-user log location instead of /tmp to reduce information exposure and
    // avoid symlink-related file clobbering risks.
    private lazy var logFileURL: URL = {
        let fm = FileManager.default
        let base = (fm.urls(for: .libraryDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library"))
            .appendingPathComponent("Logs/BC64Keys", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700  // Only owner can read/write/execute
        ])
        return base.appendingPathComponent("bc64keys-status.log")
    }()
    let statusManager = StatusManager()
    let mappingManager = KeyMappingManager()
    
    // Cache DateFormatter for performance (DateFormatter creation is expensive)
    private lazy var logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // Writes operational status to both stdout (DEBUG mode) and optionally to a per-user log file.
    // File logging is OPTIONAL (controlled by debugLoggingEnabled toggle) to reduce SSD wear.
    // Log files are created with restricted permissions (0o600) to prevent unauthorized access.
    
    func log(_ message: String) {
        let timestamp = logDateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        
        // Always print to console for development/debugging
        #if DEBUG
        print(logMessage, terminator: "")
        #endif
        
        // Only write to file if debug logging is explicitly enabled by user
        guard debugLoggingEnabled else { return }
        
        if let data = logMessage.data(using: .utf8) {
            let path = logFileURL.path
            if FileManager.default.fileExists(atPath: path) {
                // Use modern FileHandle with automatic resource management
                do {
                    let fileHandle = try FileHandle(forWritingTo: logFileURL)
                    defer { try? fileHandle.close() }
                    try fileHandle.seekToEnd()
                    try fileHandle.write(contentsOf: data)
                } catch {
                    // Fallback: overwrite file if append fails
                    do {
                        try data.write(to: logFileURL, options: [.atomic, .completeFileProtection])
                        // Set secure permissions (0o600 - only owner can read/write)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
                    } catch {
                        // Silently fail - don't crash app if logging fails
                    }
                }
            } else {
                do {
                    try data.write(to: logFileURL, options: [.atomic, .completeFileProtection])
                    // Set secure permissions (0o600 - only owner can read/write)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
                } catch {
                    // Silently fail - don't crash app if logging fails
                }
            }
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Clear old log (only if debug logging is enabled)
        if debugLoggingEnabled {
            try? FileManager.default.removeItem(at: logFileURL)
        }
        
        log("==================================================")
        log("🚀 BC64Keys App Started!")
        if debugLoggingEnabled {
            log("📝 Status log: \(logFileURL.path)")
        }
        log("==================================================")
        
        applyActivationPolicy()
        
        // Setup menu bar icon (like Karabiner Elements)
        setupMenuBar()
        
        // Ensure the main window is visible and active on startup
        // This fixes the issue where the window doesn't show automatically
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if self.hideDockIcon && self.launchedAsLoginItem() {
                self.mainWindow()?.orderOut(nil)
            } else {
                self.showMainWindow()
            }
        }
        
        // Start frequent status check (2 second interval) until accessibility is granted.
        // Once granted, the timer will be stopped to avoid unnecessary overhead.
        // If permission is later revoked, frequent checking will resume automatically.
        startStatusCheckTimer(interval: 2.0)
        
        // Initial check
        checkAndReportStatus()
    }
    
    // MARK: - Menu Bar Icon (like Karabiner Elements)
    // Creates a status bar icon that shows remapper state and allows quick access to the app window.
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            // Create simple square icon with "B" letter
            let icon = createMenuBarIcon()
            icon.isTemplate = true  // Makes it white in menu bar
            button.image = icon
            button.target = self
            button.action = #selector(statusBarButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
    }
    
    // Hide Dock Icon only applies while the window is hidden.
    // While the window is open we stay .regular so activation / Cmd-Tab work.
    func applyActivationPolicy() {
        let hide = UserDefaults.standard.bool(forKey: "bc64keys.hideDockIcon")
        let windowVisible = mainWindow()?.isVisible == true
        let policy: NSApplication.ActivationPolicy =
            (hide && !windowVisible) ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
    
    private func hideMainWindow() {
        mainWindow()?.orderOut(nil)
        applyActivationPolicy()
    }
    
    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication &&
            event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
    
    // The single SwiftUI window is never closed, only ordered out, so it can always be shown again.
    @discardableResult
    private func mainWindow() -> NSWindow? {
        if let window = mainWindowRef { return window }
        guard let window = NSApp.windows.first(where: {
            $0.canBecomeMain && $0.styleMask.contains(.titled)
        }) else { return nil }
        window.isReleasedWhenClosed = false
        window.delegate = self
        mainWindowRef = window
        return window
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        let showHide = NSMenuItem(
            title: mainWindow()?.isVisible == true ? L10n.current.menuHideWindow : L10n.current.menuShowWindow,
            action: #selector(statusItemClicked),
            keyEquivalent: ""
        )
        showHide.target = self
        menu.addItem(showHide)
        menu.addItem(.separator())
        
        let quit = NSMenuItem(
            title: L10n.current.menuQuit,
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
    
    @objc func statusBarButtonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp,
           let button = statusItem?.button,
           let menu = statusMenu {
            menuNeedsUpdate(menu)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            return
        }
        showMainWindow()
    }
    
    func showMainWindow() {
        // Must be .regular before activate, or the window never becomes key
        // and the app stays out of Cmd-Tab (.accessory cannot front a window reliably).
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let window = mainWindow() else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
    
    // Create custom menu bar icon - simple square with "B" letter
    private func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        
        image.lockFocus()
        defer { image.unlockFocus() }  // CRITICAL: Always unlock, even if drawing fails
        
        // Draw rounded square background
        let rect = NSRect(x: 2, y: 2, width: 14, height: 14)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        NSColor.white.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        
        // Draw "B" letter in center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let letter = "B"
        let letterSize = letter.size(withAttributes: attrs)
        let letterRect = NSRect(
            x: (size.width - letterSize.width) / 2,
            y: (size.height - letterSize.height) / 2 - 1,
            width: letterSize.width,
            height: letterSize.height
        )
        letter.draw(in: letterRect, withAttributes: attrs)
        
        return image
    }
    
    // Menu bar icon uses template mode - automatically adapts to light/dark appearance
    
    // When status item is clicked, toggle window visibility
    @objc func statusItemClicked() {
        if let window = mainWindow(), window.isVisible, NSApp.isActive {
            hideMainWindow()
        } else {
            showMainWindow()
        }
    }
    
    // Intercept window close - just hide instead of destroying
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideMainWindow()
        return false  // Don't actually close/destroy the window
    }
    
    // Keep app running when window is hidden
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }
    
    func checkAndReportStatus() {
        let hasAccessibility = AXIsProcessTrusted()
        let remapperRunning = keyRemapper?.isRunning ?? false
        
        // Update UI
        statusManager.update(accessibility: hasAccessibility, remapperRunning: remapperRunning)
        
        // Only log if state changed to avoid spamming and performance impact
        let stateChanged = (previousAccessibilityState != hasAccessibility) || (previousRemapperState != remapperRunning)
        
        if stateChanged {
            log("")
            log("⏰ STATUS CHANGE DETECTED:")
            log("   🔐 Accessibility: \(hasAccessibility ? "✅ GRANTED" : "❌ NOT GRANTED")")
        }
        
        if hasAccessibility {
            if keyRemapper == nil {
                log("   🎬 Starting key remapper...")
                startRemapping()
            } else if !remapperRunning {
                // Remapper exists but not running - restart it
                log("   🔄 Restarting key remapper...")
                keyRemapper?.startRemapping()
            } else if stateChanged {
                log("   ✅ Remapper is running")
            }
            
            // Accessibility granted AND remapper running - stop frequent checking to save resources
            // Keep checking if remapper is not running to detect when it starts
            if statusCheckTimer != nil && remapperRunning {
                log("   ⏸️  Stopping status check timer (permission granted and remapper running)")
                statusCheckTimer?.invalidate()
                statusCheckTimer = nil
            }
        } else {
            if stateChanged {
                log("   ⚠️  MISSING PERMISSIONS!")
                log("   📋 Fix: System Settings > Privacy & Security > Accessibility")
                log("   📋 Add: BC64Keys (toggle it ON)")
            }
            if keyRemapper != nil {
                log("   🛑 Stopping remapper (no permissions)")
                keyRemapper?.stopRemapping()
                keyRemapper = nil
            }
            
            // Permission lost/missing - restart frequent checking if not already running
            if statusCheckTimer == nil {
                log("   ▶️  Restarting status check timer (checking every 2 seconds)")
                startStatusCheckTimer(interval: 2.0)
            }
        }
        
        // Update previous state
        previousAccessibilityState = hasAccessibility
        previousRemapperState = remapperRunning
    }
    
    // Helper to start the status check timer with specified interval
    private func startStatusCheckTimer(interval: TimeInterval) {
        statusCheckTimer?.invalidate() // Clear any existing timer
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkAndReportStatus()
        }
    }
    
    func startRemapping() {
        log("")
        log("==================================================")
        log("🎬 startRemapping() CALLED")
        log("==================================================")
        keyRemapper = KeyRemapper(mappingManager: mappingManager)
        keyRemapper?.debugLoggingEnabled = debugLoggingEnabled
        keyRemapper?.startRemapping()
        log("🔚 startRemapping() FINISHED")
        log("==================================================")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        log("👋 App terminating, stopping remapper...")
        statusCheckTimer?.invalidate()
        keyRemapper?.stopRemapping()
    }
    
    // MARK: - Temporary Remapper Suspension
    // Used when capturing keys for new/edited mappings to ensure we capture the original key,
    // not the already-remapped key.
    func suspendRemapping() {
        keyRemapper?.stopRemapping()
        log("⏸️  Remapper temporarily suspended for key capture")
        // Update status to reflect suspended state
        let hasAccessibility = AXIsProcessTrusted()
        statusManager.update(accessibility: hasAccessibility, remapperRunning: false)
    }
    
    func resumeRemapping() {
        if AXIsProcessTrusted(), keyRemapper != nil {
            keyRemapper?.startRemapping()
            log("▶️  Remapper resumed after key capture")
            // Update status to reflect running state
            statusManager.update(accessibility: true, remapperRunning: keyRemapper?.isRunning ?? false)
        }
    }
    
    deinit {
        // Cleanup resources (timer, status item, remapper)
        statusCheckTimer?.invalidate()
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        keyRemapper?.stopRemapping()
    }
}

// MARK: - Key Event Monitor
class KeyEventMonitor: ObservableObject {
    @Published var keyEvents: [KeyEvent] = []
    @Published var isMonitoring = false
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private let maxEvents = 100
    
    struct KeyEvent: Identifiable {
        let id = UUID()
        let timestamp: Date
        let keyCode: UInt16
        let keyChar: String
        let modifiers: String
        let eventType: String
    }
    
    func startMonitoring() {
        // Avoid stacking multiple monitors if the user clicks Start multiple times.
        if globalEventMonitor != nil || localEventMonitor != nil {
            return
        }

        // Monitor keyDown/keyUp events AND flagsChanged (for modifier keys and Caps Lock):
        // - Global monitor: receives events system-wide (does not let us modify them).
        // - Local monitor: receives events inside our app (useful for the UI and capture workflows).
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        
        // Also monitor local events (within our app)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        
        isMonitoring = true
    }
    
    func stopMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        isMonitoring = false
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        // charactersIgnoringModifiers is only valid for keyDown/keyUp; on flagsChanged
        // AppKit raises "Invalid message sent to event" (uncaught → UI freezes).
        let keyChar: String
        if event.type == .keyDown || event.type == .keyUp {
            keyChar = event.charactersIgnoringModifiers ?? ""
        } else {
            keyChar = ""
        }
        let modifiers = getModifierString(event.modifierFlags)
        
        // Determine event type
        let eventType: String
        if event.type == .keyDown {
            eventType = "↓ DOWN"
        } else if event.type == .keyUp {
            eventType = "↑ UP"
        } else if event.type == .flagsChanged {
            eventType = "⚑ FLAG"
        } else {
            eventType = "?"
        }
        
        let keyName = getKeyName(keyCode: event.keyCode, char: keyChar, flags: event.modifierFlags)
        
        let keyEvent = KeyEvent(
            timestamp: Date(),
            keyCode: event.keyCode,
            keyChar: keyName,
            modifiers: modifiers,
            eventType: eventType
        )
        
        DispatchQueue.main.async {
            self.keyEvents.insert(keyEvent, at: 0)
            if self.keyEvents.count > self.maxEvents {
                // Remove excess events and reclaim memory
                self.keyEvents.removeLast(self.keyEvents.count - self.maxEvents)
            }
        }
    }
    
    private func getModifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var mods: [String] = []
        if flags.contains(.capsLock) { mods.append("⇪") }
        if flags.contains(.command) { mods.append("⌘") }
        if flags.contains(.option) { mods.append("⌥") }
        if flags.contains(.control) { mods.append("⌃") }
        if flags.contains(.shift) { mods.append("⇧") }
        if flags.contains(.function) { mods.append("fn") }
        return mods.isEmpty ? "" : mods.joined(separator: " ")
    }
    
    private func getKeyName(keyCode: UInt16, char: String, flags: NSEvent.ModifierFlags) -> String {
        if let name = kSpecialKeys[keyCode] { return name }
        return char.isEmpty ? "Key(\(keyCode))" : char.uppercased()
    }
    
    func clearEvents() {
        keyEvents.removeAll(keepingCapacity: false) // Reclaim memory
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - Mapping Rule Types
enum MappingType: String, Codable {
    case simpleKey  // Key swap (e.g. A → B)
    case navigation // Navigation action (e.g. Home → ⌘←)
}

enum AppFilterMode: String, Codable {
    case all      // Apply to all apps
    case exclude  // Apply to all apps except...
    case include  // Apply only to these apps
}

struct NavigationAction: Identifiable, Codable, Hashable {
    let id = UUID()
    let name: String
    let key: UInt16
    let modifiers: CGEventFlags
    
    init(name: String, key: UInt16, modifiers: CGEventFlags) {
        self.name = name
        self.key = key
        self.modifiers = modifiers
    }
    
    // Localized display name for UI
    var localizedName: String {
        // Extract action type from English name for localization
        // Keep symbols (⌘, ⌥, ⇧, etc.) and only translate the text part
        if name.contains("Discard") {
            return L10n.current.actionDiscard
        } else if name.contains("Line start") {
            return "⌘← " + L10n.current.actionLineStart
        } else if name.contains("Line end") {
            return "⌘→ " + L10n.current.actionLineEnd
        } else if name.contains("Select to line start") {
            return "⇧⌘← " + L10n.current.actionSelectLineStart
        } else if name.contains("Select to line end") {
            return "⇧⌘→ " + L10n.current.actionSelectLineEnd
        } else if name.contains("Document start") {
            return "⌘↑ " + L10n.current.actionDocStart
        } else if name.contains("Document end") {
            return "⌘↓ " + L10n.current.actionDocEnd
        } else if name.contains("Select to doc start") {
            return "⇧⌘↑ " + L10n.current.actionSelectDocStart
        } else if name.contains("Select to doc end") {
            return "⇧⌘↓ " + L10n.current.actionSelectDocEnd
        } else if name.contains("Word start") && !name.contains("Select") {
            return "⌥← " + L10n.current.actionWordStart
        } else if name.contains("Word end") && !name.contains("Select") {
            return "⌥→ " + L10n.current.actionWordEnd
        } else if name.contains("Select to word start") {
            return "⇧⌥← " + L10n.current.actionSelectWordStart
        } else if name.contains("Select to word end") {
            return "⇧⌥→ " + L10n.current.actionSelectWordEnd
        } else if name.contains("Delete word left") {
            return "⌥⌫ " + L10n.current.actionDeleteWordLeft
        } else if name.contains("Delete word right") {
            return "⌥Del " + L10n.current.actionDeleteWordRight
        } else if name.contains("Delete to line start") {
            return "⌘⌫ " + L10n.current.actionDeleteLineStart
        } else if name.contains("Page Up") {
            return "⌥↑ " + L10n.current.actionPageUp
        } else if name.contains("Page Down") {
            return "⌥↓ " + L10n.current.actionPageDown
        } else if name.contains("Undo") {
            return "⌘Z " + L10n.current.actionUndo
        } else if name.contains("Redo") {
            return "⇧⌘Z " + L10n.current.actionRedo
        } else if name.contains("Cut") {
            return "⌘X " + L10n.current.actionCut
        } else if name.contains("Copy") {
            return "⌘C " + L10n.current.actionCopy
        } else if name.contains("Paste") {
            return "⌘V " + L10n.current.actionPaste
        } else if name.contains("Select All") {
            return "⌘A " + L10n.current.actionSelectAll
        } else if name.contains("Find Next") {
            return "⌘G " + L10n.current.actionFindNext
        } else if name.contains("Find") {
            return "⌘F " + L10n.current.actionFind
        } else if name.contains("Save As") {
            return "⇧⌘S " + L10n.current.actionSaveAs
        } else if name.contains("Save") {
            return "⌘S " + L10n.current.actionSave
        } else if name.contains("Close Window") {
            return "⌘W " + L10n.current.actionCloseWindow
        } else if name.contains("Quit") {
            return "⌘Q " + L10n.current.actionQuit
        } else if name.contains("New Window") {
            return "⌘N " + L10n.current.actionNewWindow
        } else if name.contains("New Tab") {
            return "⌘T " + L10n.current.actionNewTab
        } else if name.contains("Switch App (Reverse)") {
            return "⇧⌘Tab " + L10n.current.actionSwitchAppReverse
        } else if name.contains("Switch Window (Reverse)") {
            return "⇧⌘` " + L10n.current.actionSwitchWindowReverse
        } else if name.contains("Switch App") {
            return "⌘Tab " + L10n.current.actionSwitchApp
        } else if name.contains("Switch Window") {
            return "⌘` " + L10n.current.actionSwitchWindow
        }
        return name // Fallback to English name
    }
    
    // Hashable conformance
    static func == (lhs: NavigationAction, rhs: NavigationAction) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    enum CodingKeys: String, CodingKey {
        case name, key, modifiers
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        key = try container.decode(UInt16.self, forKey: .key)
        let rawModifiers = try container.decode(UInt64.self, forKey: .modifiers)
        modifiers = CGEventFlags(rawValue: rawModifiers)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
    }
}

// MARK: - NavigationAction Extension
extension NavigationAction {
    // Predefined navigation actions - optimized for Windows switchers
    static let all: [NavigationAction] = [
        // === SPECIAL (block key - targetKeyCode 0 with no modifiers means discard) ===
        NavigationAction(name: "🚫 Discard (block key)", key: 0, modifiers: []),
        
        // === LINE NAVIGATION (replaces Home/End) ===
        NavigationAction(name: "⌘← Line start", key: 123, modifiers: .maskCommand),
        NavigationAction(name: "⌘→ Line end", key: 124, modifiers: .maskCommand),
        NavigationAction(name: "⇧⌘← Select to line start", key: 123, modifiers: [.maskCommand, .maskShift]),
        NavigationAction(name: "⇧⌘→ Select to line end", key: 124, modifiers: [.maskCommand, .maskShift]),
        
        // === DOCUMENT NAVIGATION (replaces Ctrl+Home/End) ===
        NavigationAction(name: "⌘↑ Document start", key: 126, modifiers: .maskCommand),
        NavigationAction(name: "⌘↓ Document end", key: 125, modifiers: .maskCommand),
        NavigationAction(name: "⇧⌘↑ Select to doc start", key: 126, modifiers: [.maskCommand, .maskShift]),
        NavigationAction(name: "⇧⌘↓ Select to doc end", key: 125, modifiers: [.maskCommand, .maskShift]),
        
        // === WORD NAVIGATION (replaces Ctrl+Left/Right) ===
        NavigationAction(name: "⌥← Word start", key: 123, modifiers: .maskAlternate),
        NavigationAction(name: "⌥→ Word end", key: 124, modifiers: .maskAlternate),
        NavigationAction(name: "⇧⌥← Select to word start", key: 123, modifiers: [.maskAlternate, .maskShift]),
        NavigationAction(name: "⇧⌥→ Select to word end", key: 124, modifiers: [.maskAlternate, .maskShift]),
        
        // === DELETE (replaces Ctrl+Backspace/Delete) ===
        NavigationAction(name: "⌥⌫ Delete word left", key: 51, modifiers: .maskAlternate),
        NavigationAction(name: "⌥Del Delete word right", key: 117, modifiers: .maskAlternate),
        NavigationAction(name: "⌘⌫ Delete to line start", key: 51, modifiers: .maskCommand),
        
        // === PAGE NAVIGATION ===
        NavigationAction(name: "⌥↑ Page Up", key: 126, modifiers: .maskAlternate),
        NavigationAction(name: "⌥↓ Page Down", key: 125, modifiers: .maskAlternate),
        
        // === UNDO/REDO (replaces Ctrl+Z/Y) ===
        NavigationAction(name: "⌘Z Undo", key: 6, modifiers: .maskCommand),
        NavigationAction(name: "⇧⌘Z Redo", key: 6, modifiers: [.maskCommand, .maskShift]),
        
        // === CLIPBOARD (replaces Ctrl+X/C/V) ===
        NavigationAction(name: "⌘X Cut", key: 7, modifiers: .maskCommand),
        NavigationAction(name: "⌘C Copy", key: 8, modifiers: .maskCommand),
        NavigationAction(name: "⌘V Paste", key: 9, modifiers: .maskCommand),
        NavigationAction(name: "⌘A Select All", key: 0, modifiers: .maskCommand),
        
        // === FIND/SAVE ===
        NavigationAction(name: "⌘F Find", key: 3, modifiers: .maskCommand),
        NavigationAction(name: "⌘G Find Next", key: 5, modifiers: .maskCommand),
        NavigationAction(name: "⌘S Save", key: 1, modifiers: .maskCommand),
        NavigationAction(name: "⇧⌘S Save As", key: 1, modifiers: [.maskCommand, .maskShift]),
        
        // === WINDOW MANAGEMENT ===
        NavigationAction(name: "⌘W Close Window/Tab", key: 13, modifiers: .maskCommand),
        NavigationAction(name: "⌘Q Quit", key: 12, modifiers: .maskCommand),
        NavigationAction(name: "⌘N New Window/Document", key: 45, modifiers: .maskCommand),
        NavigationAction(name: "⌘T New Tab", key: 17, modifiers: .maskCommand),
        
        // === WINDOW SWITCHING (replaces Alt+Tab) ===
        NavigationAction(name: "⌘Tab Switch App", key: 48, modifiers: .maskCommand),
        NavigationAction(name: "⌘` Switch Window", key: 50, modifiers: .maskCommand),
        NavigationAction(name: "⇧⌘Tab Switch App (Reverse)", key: 48, modifiers: [.maskCommand, .maskShift]),
        NavigationAction(name: "⇧⌘` Switch Window (Reverse)", key: 50, modifiers: [.maskCommand, .maskShift]),
    ]
}

// MARK: - Visual Keyboard View
/// Interactive visual keyboard for selecting target keys
/// Makes it easy to find special characters like [], $, etc.
struct VisualKeyboardView: View {
    @Binding var selectedKeyCode: UInt16
    @Binding var selectedKeyName: String
    @Binding var selectedCharacter: String?
    var onKeySelected: (() -> Void)?
    
    // Compact Mac keyboard layout - each row is an array of (keyCode, display, character, width)
    // Character is what we'll send as Unicode (nil for special keys that should use keyCode)
    private let keyboardLayout: [[(UInt16, String, String?, CGFloat)]] = [
        // Row 1: Numbers row with esc and backspace
        [(53, "⎋", nil, 1.0), (50, "`", "`", 1.0), (18, "1", "1", 1.0), (19, "2", "2", 1.0), (20, "3", "3", 1.0), (21, "4", "4", 1.0),
         (23, "5", "5", 1.0), (22, "6", "6", 1.0), (26, "7", "7", 1.0), (28, "8", "8", 1.0), (25, "9", "9", 1.0),
         (29, "0", "0", 1.0), (27, "-", "-", 1.0), (24, "=", "=", 1.0), (51, "⌫", nil, 1.3)],
        
        // Row 2: QWERTY row
        [(48, "⇥", nil, 1.3), (12, "Q", "q", 1.0), (13, "W", "w", 1.0), (14, "E", "e", 1.0), (15, "R", "r", 1.0),
         (17, "T", "t", 1.0), (16, "Y", "y", 1.0), (32, "U", "u", 1.0), (34, "I", "i", 1.0), (31, "O", "o", 1.0),
         (35, "P", "p", 1.0), (33, "[", "[", 1.0), (30, "]", "]", 1.0), (42, "\\", "\\", 1.3)],
        
        // Row 3: ASDF row
        [(57, "⇪", nil, 1.5), (0, "A", "a", 1.0), (1, "S", "s", 1.0), (2, "D", "d", 1.0), (3, "F", "f", 1.0),
         (5, "G", "g", 1.0), (4, "H", "h", 1.0), (38, "J", "j", 1.0), (40, "K", "k", 1.0), (37, "L", "l", 1.0),
         (41, ";", ";", 1.0), (39, "'", "'", 1.0), (36, "↵", nil, 1.8)],
        
        // Row 4: ZXCV row
        [(56, "⇧", nil, 1.8), (6, "Z", "z", 1.0), (7, "X", "x", 1.0), (8, "C", "c", 1.0), (9, "V", "v", 1.0),
         (11, "B", "b", 1.0), (45, "N", "n", 1.0), (46, "M", "m", 1.0), (43, ",", ",", 1.0), (47, ".", ".", 1.0),
         (44, "/", "/", 1.0), (60, "⇧", nil, 1.5), (126, "↑", nil, 1.0)],
        
        // Row 5: Bottom row - modifiers, space, arrows
        [(63, "fn", nil, 1.0), (59, "⌃", nil, 1.0), (58, "⌥", nil, 1.0), (55, "⌘", nil, 1.2),
         (49, "␣", " ", 4.0),
         (54, "⌘", nil, 1.2), (61, "⌥", nil, 1.0), (123, "←", nil, 1.0), (125, "↓", nil, 1.0), (124, "→", nil, 1.0)]
    ]
    
    // Function keys row (separate) - no character, use keyCode
    private let functionKeys: [(UInt16, String)] = [
        (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"),
        (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
        (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12")
    ]
    
    // Navigation keys - no character, use keyCode
    private let navKeys: [(UInt16, String)] = [
        (117, "⌦"), (115, "↖"), (119, "↘"), (116, "⇞"), (121, "⇟")
    ]
    
    private let keySize: CGFloat = 26
    
    var body: some View {
        VStack(spacing: 2) {
            // Function keys row
            HStack(spacing: 2) {
                ForEach(functionKeys, id: \.0) { key in
                    CompactKeyButton(keyCode: key.0, label: key.1, width: 1.0, size: keySize,
                                    isSelected: selectedKeyCode == key.0) {
                        selectKey(keyCode: key.0, name: key.1, character: nil)
                    }
                }
                Spacer()
                // Nav keys inline
                ForEach(navKeys, id: \.0) { key in
                    CompactKeyButton(keyCode: key.0, label: key.1, width: 1.0, size: keySize,
                                    isSelected: selectedKeyCode == key.0) {
                        selectKey(keyCode: key.0, name: key.1, character: nil)
                    }
                }
            }
            
            Divider().padding(.vertical, 2)
            
            // Main keyboard rows
            ForEach(0..<keyboardLayout.count, id: \.self) { rowIndex in
                HStack(spacing: 2) {
                    ForEach(0..<keyboardLayout[rowIndex].count, id: \.self) { keyIndex in
                        let key = keyboardLayout[rowIndex][keyIndex]
                        CompactKeyButton(keyCode: key.0, label: key.1, width: key.3, size: keySize,
                                        isSelected: selectedKeyCode == key.0) {
                            selectKey(keyCode: key.0, name: key.1, character: key.2)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private func selectKey(keyCode: UInt16, name: String, character: String?) {
        selectedKeyCode = keyCode
        selectedCharacter = character
        if let specialName = kSpecialKeys[keyCode] {
            selectedKeyName = specialName
        } else {
            selectedKeyName = name.uppercased()
        }
        onKeySelected?()
    }
}

// MARK: - Compact Key Button
struct CompactKeyButton: View {
    let keyCode: UInt16
    let label: String
    let width: CGFloat
    let size: CGFloat
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: label.count > 2 ? 8 : 10, weight: .medium, design: .rounded))
                .frame(width: size * width - 2, height: size - 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.blue : Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: 0.5)
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .help("Key code: \(keyCode)")
    }
}

struct KeyMappingRule: Identifiable, Codable {
    var id: UUID
    var type: MappingType
    var sourceKeyCode: UInt16
    var sourceKeyName: String
    var sourceModifiers: CGEventFlags? // For matching Shift+Home etc
    var targetKeyCode: UInt16
    var targetKeyName: String
    var targetModifiers: CGEventFlags? // For navigation actions
    var targetCharacter: String? // Unicode character to send (from visual keyboard)
    var isEnabled: Bool
    
    // Per-app filtering
    var appFilterMode: AppFilterMode
    var filteredApps: [String] // Bundle IDs
    
    init(id: UUID = UUID(), type: MappingType, sourceKeyCode: UInt16, sourceKeyName: String,
         sourceModifiers: CGEventFlags? = nil, targetKeyCode: UInt16, targetKeyName: String, 
         targetModifiers: CGEventFlags? = nil, targetCharacter: String? = nil, isEnabled: Bool = true,
         appFilterMode: AppFilterMode = .all, filteredApps: [String] = []) {
        self.id = id
        self.type = type
        self.sourceKeyCode = sourceKeyCode
        self.sourceKeyName = sourceKeyName
        self.sourceModifiers = sourceModifiers
        self.targetKeyCode = targetKeyCode
        self.targetKeyName = targetKeyName
        self.targetModifiers = targetModifiers
        self.targetCharacter = targetCharacter
        self.isEnabled = isEnabled
        self.appFilterMode = appFilterMode
        self.filteredApps = filteredApps
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, sourceKeyCode, sourceKeyName, sourceModifiers, targetKeyCode, targetKeyName, targetModifiers, targetCharacter, isEnabled, appFilterMode, filteredApps
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(MappingType.self, forKey: .type)
        sourceKeyCode = try container.decode(UInt16.self, forKey: .sourceKeyCode)
        sourceKeyName = try container.decode(String.self, forKey: .sourceKeyName)
        if let rawModifiers = try container.decodeIfPresent(UInt64.self, forKey: .sourceModifiers) {
            sourceModifiers = CGEventFlags(rawValue: rawModifiers)
        } else {
            sourceModifiers = nil
        }
        targetKeyCode = try container.decode(UInt16.self, forKey: .targetKeyCode)
        targetKeyName = try container.decode(String.self, forKey: .targetKeyName)
        if let rawModifiers = try container.decodeIfPresent(UInt64.self, forKey: .targetModifiers) {
            targetModifiers = CGEventFlags(rawValue: rawModifiers)
        } else {
            targetModifiers = nil
        }
        targetCharacter = try container.decodeIfPresent(String.self, forKey: .targetCharacter)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        
        // Per-app filtering (with defaults for backward compatibility)
        appFilterMode = try container.decodeIfPresent(AppFilterMode.self, forKey: .appFilterMode) ?? .all
        filteredApps = try container.decodeIfPresent([String].self, forKey: .filteredApps) ?? []
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(sourceKeyCode, forKey: .sourceKeyCode)
        try container.encode(sourceKeyName, forKey: .sourceKeyName)
        try container.encodeIfPresent(sourceModifiers?.rawValue, forKey: .sourceModifiers)
        try container.encode(targetKeyCode, forKey: .targetKeyCode)
        try container.encode(targetKeyName, forKey: .targetKeyName)
        try container.encodeIfPresent(targetModifiers?.rawValue, forKey: .targetModifiers)
        try container.encodeIfPresent(targetCharacter, forKey: .targetCharacter)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(appFilterMode, forKey: .appFilterMode)
        try container.encode(filteredApps, forKey: .filteredApps)
    }
}

// MARK: - Key Mapping Manager
class KeyMappingManager: ObservableObject {
    @Published var mappings: [KeyMappingRule] = [] {
        didSet {
            saveMappings()
        }
    }
    
    private let userDefaultsKey = "bc64keys.mappings"

    // Persistence model:
    // - mappings[] is JSON-encoded into UserDefaults on every change (didSet)
    // - keep the structure stable for backwards compatibility (Codable)
    
    init() {
        loadMappings()
    }
    
    func addMapping(_ mapping: KeyMappingRule) {
        mappings.append(mapping)
    }
    
    func updateMapping(_ oldMapping: KeyMappingRule, with newMapping: KeyMappingRule) {
        if let index = mappings.firstIndex(where: { $0.id == oldMapping.id }) {
            var updated = newMapping
            updated.id = oldMapping.id  // Keep the same ID
            updated.isEnabled = oldMapping.isEnabled  // Keep enabled state
            mappings[index] = updated
        }
    }
    
    func deleteMapping(_ mapping: KeyMappingRule) {
        mappings.removeAll { $0.id == mapping.id }
    }
    
    func toggleMapping(_ mapping: KeyMappingRule) {
        if let index = mappings.firstIndex(where: { $0.id == mapping.id }) {
            mappings[index].isEnabled.toggle()
        }
    }
    
    private func saveMappings() {
        // JSON encoding for ~20 mappings is <1ms - no need for background queue
        // Background queue would add overhead and potential race conditions
        if let encoded = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
    
    private func loadMappings() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return
        }
        
        do {
            let decoded = try JSONDecoder().decode([KeyMappingRule].self, from: data)
            // Validate loaded mappings - filter out any corrupted entries
            let validMappings = decoded.filter { mapping in
                // Basic validation: key codes should be reasonable (0-255 for most keys)
                // and names should not be empty
                return !mapping.sourceKeyName.isEmpty && 
                       mapping.sourceKeyCode <= 255 &&
                       mapping.targetKeyCode <= 255
            }
            mappings = validMappings
            
            // Log if any mappings were filtered out
            if validMappings.count != decoded.count {
                #if DEBUG
                print("⚠️ Filtered out \(decoded.count - validMappings.count) invalid mapping(s) from UserDefaults")
                #endif
            }
        } catch {
            // Corrupted data - log and start fresh
            #if DEBUG
            print("❌ Failed to decode mappings from UserDefaults: \(error.localizedDescription)")
            #endif
            // Don't crash - just start with empty mappings
            mappings = []
        }
    }
}

// MARK: - Running Apps Manager
class RunningAppsManager: ObservableObject {
    struct RunningApp: Identifiable {
        let id = UUID()
        let name: String
        let bundleID: String
    }
    
    @Published var runningApps: [RunningApp] = []
    
    func fetchRunningApps() {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let name = app.localizedName,
                      let bundleID = app.bundleIdentifier else { return nil }
                return RunningApp(name: name, bundleID: bundleID)
            }
            .sorted { $0.name < $1.name }
        
        DispatchQueue.main.async {
            self.runningApps = apps
        }
    }
    
    deinit {
        // No resources to clean up currently, but good practice to have deinit
    }
}

// MARK: - Main Content View with Tabs
struct ContentView: View {
    @StateObject private var keyMonitor = KeyEventMonitor()
    @ObservedObject var mappingManager: KeyMappingManager
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var l10n = L10n.shared
    @State private var selectedTab = 0  // Start with Mapping tab (was Monitor)
    
    var body: some View {
        VStack(spacing: 0) {
            // Status Bar at the top
            StatusBar(statusManager: statusManager)
            
            // Tabs
            TabView(selection: $selectedTab) {
                MappingView(mappingManager: mappingManager)
                    .tabItem {
                        Label(L10n.current.tabMapping, systemImage: "arrow.left.arrow.right")
                    }
                    .tag(0)
                
                MonitorView(keyMonitor: keyMonitor)
                    .tabItem {
                        Label(L10n.current.tabMonitor, systemImage: "eye")
                    }
                    .tag(1)
                
                SettingsView()
                    .tabItem {
                        Label(L10n.current.tabSettings, systemImage: "gear")
                    }
                    .tag(2)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

// MARK: - Status Bar
struct StatusBar: View {
    @ObservedObject var statusManager: StatusManager
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                // Accessibility status
                Image(systemName: statusManager.hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(statusManager.hasAccessibility ? .green : .red)
                
                Text("Accessibility:")
                    .font(.caption)
                
                Text(statusManager.hasAccessibility ? "✅ \(L10n.current.statusEnabled)" : "❌ \(L10n.current.statusNoPermission)")
                    .font(.caption.bold())
                    .foregroundColor(statusManager.hasAccessibility ? .green : .red)
                
                Spacer()
                
                // Remapper status
                Image(systemName: statusManager.remapperRunning ? "play.circle.fill" : "stop.circle.fill")
                    .foregroundColor(statusManager.remapperRunning ? .green : .orange)
                
                Text("Remapper:")
                    .font(.caption)
                
                Text(statusManager.remapperRunning ? "✅ \(L10n.current.statusRunning)" : "⏸ \(L10n.current.statusStopped)")
                    .font(.caption.bold())
                    .foregroundColor(statusManager.remapperRunning ? .green : .orange)
                
                Spacer()
                
                Text("\(L10n.current.statusUpdated): \(statusManager.lastCheck, style: .time)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Show warning and action button if no permission
            if !statusManager.hasAccessibility {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("⚠️ \(L10n.current.statusAccessRequired):")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                        
                        Text("\(L10n.current.statusAppPath): \(Bundle.main.bundleURL.path)")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: openAccessibilitySettings) {
                        HStack {
                            Image(systemName: "gear")
                            Text(L10n.current.openSettings)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(statusManager.hasAccessibility ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
    }
    
    func openAccessibilitySettings() {
        // Open System Settings to Accessibility
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            // Fallback: try opening general Security & Privacy pane
            if let fallbackUrl = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                NSWorkspace.shared.open(fallbackUrl)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @ObservedObject var l10n = L10n.shared
    @StateObject private var launchManager = LaunchAtLoginManager()
    @AppStorage("selectedLanguage") private var selectedLanguageRaw: String = AppLanguage.system.rawValue
    @AppStorage("bc64keys.debugLogging") private var debugLoggingEnabled: Bool = false
    @AppStorage("bc64keys.hideDockIcon") private var hideDockIcon: Bool = false
    
    private var selectedLanguage: AppLanguage {
        get { AppLanguage(rawValue: selectedLanguageRaw) ?? .system }
        set { selectedLanguageRaw = newValue.rawValue }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L10n.current.settingsTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Settings Content - Compact but readable
            VStack(alignment: .leading, spacing: 16) {
                // Launch at Login + Language - Single row
                HStack(spacing: 20) {
                    // Launch at Login
                    Label(L10n.current.launchAtLogin, systemImage: "power")
                        .font(.headline)
                    
                    Toggle("", isOn: Binding(
                        get: { launchManager.isEnabled },
                        set: { _ in launchManager.toggle() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    
                    Spacer()
                    
                    // Language
                    Label(L10n.current.language, systemImage: "globe")
                        .font(.headline)
                    
                    Picker("", selection: Binding(
                        get: { selectedLanguage },
                        set: { newValue in
                            selectedLanguageRaw = newValue.rawValue
                            L10n.shared.setLanguage(newValue)
                        }
                    )) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(L10n.current.hideDockIcon, systemImage: "macwindow")
                            .font(.headline)
                        
                        Toggle("", isOn: Binding(
                            get: { hideDockIcon },
                            set: { newValue in
                                hideDockIcon = newValue
                                appDelegate.applyActivationPolicy()
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        
                        Spacer()
                    }
                    
                    Text(L10n.current.hideDockIconHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                // Support Section - Centered, prominent, no extra text
                VStack(spacing: 12) {
                    Button(action: {
                        guard let url = URL(string: "https://buymeacoffee.com/badcode64") else { return }
                        NSWorkspace.shared.open(url)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "cup.and.saucer.fill")
                            Text(L10n.current.supportButton)
                        }
                        .font(.body)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                Spacer()
                
                // Debug Logging Section - At the bottom (rarely used)
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.current.debugLogging, systemImage: "ladybug.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    
                    Toggle(isOn: $debugLoggingEnabled) {
                        Text(L10n.current.debugLoggingDescription)
                    }
                    .toggleStyle(.switch)
                    .onChange(of: debugLoggingEnabled) { newValue in
                        appDelegate.keyRemapper?.debugLoggingEnabled = newValue
                    }
                    
                    Text(L10n.current.debugLoggingHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding(16)
        }
    }
}

// MARK: - Monitor View (Original functionality)
struct MonitorView: View {
    @ObservedObject var keyMonitor: KeyEventMonitor
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                Text("BC64Keys - \(L10n.current.monitorTitle)")
                    .font(.title)
                    .fontWeight(.bold)
                
                HStack(spacing: 15) {
                    Button(action: toggleMonitoring) {
                        HStack {
                            Image(systemName: keyMonitor.isMonitoring ? "stop.circle.fill" : "play.circle.fill")
                            Text(keyMonitor.isMonitoring ? L10n.current.stopMonitoring : L10n.current.startMonitoring)
                        }
                        .frame(width: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(keyMonitor.isMonitoring ? .red : .green)
                    
                    Button(action: keyMonitor.clearEvents) {
                        HStack {
                            Image(systemName: "trash")
                            Text(L10n.current.clear)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                if !keyMonitor.isMonitoring {
                    Text("⚠️ \(L10n.current.monitorHintStart)")
                        .foregroundColor(.orange)
                        .font(.caption)
                } else {
                    Text("✓ \(L10n.current.monitorHintActive)")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Event List
            if keyMonitor.keyEvents.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "keyboard")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text(L10n.current.noEvents)
                        .foregroundColor(.gray)
                    Text(L10n.current.noEventsHint)
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(keyMonitor.keyEvents) { event in
                            KeyEventRow(event: event)
                        }
                    }
                }
            }
        }
        .onDisappear {
            // Global monitor runs on every system keystroke; leaving it on causes lag.
            if keyMonitor.isMonitoring {
                keyMonitor.stopMonitoring()
            }
        }
    }
    
    private func toggleMonitoring() {
        if keyMonitor.isMonitoring {
            keyMonitor.stopMonitoring()
        } else {
            keyMonitor.startMonitoring()
        }
    }
}

// MARK: - Mapping View
struct MappingView: View {
    @ObservedObject var mappingManager: KeyMappingManager
    @StateObject private var appsManager = RunningAppsManager()
    @State private var showAddSheet = false
    @State private var editingMapping: KeyMappingRule?
    @EnvironmentObject var appDelegate: AppDelegate
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L10n.current.mappingTitle)
                    .font(.title)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: { showAddSheet = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text(L10n.current.newRule)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Mappings Table
            if mappingManager.mappings.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "arrow.left.arrow.right.square")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text(L10n.current.noRules)
                        .foregroundColor(.gray)
                    Text(L10n.current.noRulesHint)
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(mappingManager.mappings) { mapping in
                            MappingRow(mapping: mapping, manager: mappingManager, editingMapping: $editingMapping)
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddMappingSheet(manager: mappingManager, appsManager: appsManager, isPresented: $showAddSheet)
                .environmentObject(appDelegate)
        }
        .sheet(item: $editingMapping) { mapping in
            AddMappingSheet(
                manager: mappingManager, 
                appsManager: appsManager, 
                isPresented: Binding(
                    get: { editingMapping != nil },
                    set: { if !$0 { editingMapping = nil } }
                ),
                editingMapping: mapping
            )
            .environmentObject(appDelegate)
        }
        .onAppear {
            appsManager.fetchRunningApps()
        }
    }
}

// MARK: - Mapping Row
struct MappingRow: View {
    let mapping: KeyMappingRule
    @ObservedObject var manager: KeyMappingManager
    @Binding var editingMapping: KeyMappingRule?
    @ObservedObject private var l10n = L10n.shared  // For language change updates
    
    var body: some View {
        HStack(spacing: 12) {
            // Enable/Disable toggle
            Toggle("", isOn: Binding(
                get: { mapping.isEnabled },
                set: { _ in manager.toggleMapping(mapping) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.8)
            .frame(width: 40)
            
            // Source key with modifiers - FIXED WIDTH
            HStack(spacing: 2) {
                if let mods = mapping.sourceModifiers {
                    Text(modifierSymbols(mods))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.orange)
                }
                Text(displayKeyName(mapping.sourceKeyName, keyCode: mapping.sourceKeyCode))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .frame(width: 140, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.15))
            .cornerRadius(6)
            
            Image(systemName: "arrow.right.circle.fill")
                .foregroundColor(.green)
                .font(.body)
            
            // Target key with modifiers
            HStack(spacing: 2) {
                if let mods = mapping.targetModifiers {
                    Text(modifierSymbols(mods))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.purple)
                }
                Text(localizedTargetName(mapping))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.15))
            .cornerRadius(6)
            
            Spacer()
            
            // Type badge
            Text(mapping.type == .simpleKey ? "⌨️" : "🎯")
                .font(.body)
                .help(mapping.type == .simpleKey ? L10n.current.keySwap : L10n.current.controlAction)
            
            // Edit button
            Button(action: { editingMapping = mapping }) {
                Image(systemName: "pencil.circle.fill")
                    .foregroundColor(.blue.opacity(0.7))
                    .font(.body)
            }
            .buttonStyle(.borderless)
            
            // Delete button
            Button(action: { manager.deleteMapping(mapping) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red.opacity(0.7))
                    .font(.body)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .opacity(mapping.isEnabled ? 1.0 : 0.5)
    }
    
    private func modifierSymbols(_ flags: CGEventFlags) -> String {
        var symbols = ""
        if flags.contains(.maskControl) { symbols += "⌃" }
        if flags.contains(.maskAlternate) { symbols += "⌥" }
        if flags.contains(.maskShift) { symbols += "⇧" }
        if flags.contains(.maskCommand) { symbols += "⌘" }
        return symbols
    }
    
    private func displayKeyName(_ name: String, keyCode: UInt16) -> String {
        // If name looks invalid, try to get from keyCode
        if name.isEmpty || name == "?" || name.hasPrefix("Key(") || name.contains("?") {
            return kSpecialKeys[keyCode] ?? "(\(keyCode))"
        }
        // Strip modifier prefixes if present (old format)
        if name.contains(" + ") {
            return name.components(separatedBy: " + ").last ?? name
        }
        return name
    }
    
    private func localizedTargetName(_ mapping: KeyMappingRule) -> String {
        // For navigation type, find action by keyCode and modifiers (language-independent)
        if mapping.type == .navigation {
            if let action = NavigationAction.all.first(where: { 
                $0.key == mapping.targetKeyCode && 
                $0.modifiers == mapping.targetModifiers 
            }) {
                return action.localizedName
            }
        }
        // Otherwise use standard display logic for simple key mappings
        return displayKeyName(mapping.targetKeyName, keyCode: mapping.targetKeyCode)
    }
}

// MARK: - Add Mapping Sheet
struct AddMappingSheet: View {
    @ObservedObject var manager: KeyMappingManager
    @ObservedObject var appsManager: RunningAppsManager
    @Binding var isPresented: Bool
    @EnvironmentObject var appDelegate: AppDelegate
    
    // Optional: if editing an existing mapping
    var editingMapping: KeyMappingRule?
    
    @State private var mappingType: MappingType = .navigation
    @State private var fromKey = ""
    @State private var fromKeyCode: UInt16 = 0
    @State private var fromModifiers: CGEventFlags?
    @State private var toKey = ""
    @State private var toKeyCode: UInt16 = 0
    @State private var toCharacter: String? = nil  // Unicode character from visual keyboard
    @State private var selectedNavigationAction: NavigationAction?
    @State private var selectedApp = ""
    @State private var isCapturingFrom = false
    @State private var isCapturingTo = false
    @State private var toKeyCodeText = ""
    @State private var keyCaptureMonitor: Any?
    @State private var isLoadingMapping = false
    @State private var showVisualKeyboard = false  // Visual keyboard toggle
    
    // Per-app filtering
    @State private var appFilterMode: AppFilterMode = .all
    @State private var selectedAppBundleIDs: Set<String> = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(editingMapping == nil ? L10n.current.newKeyRule : L10n.current.editKeyRule)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            
            Divider()
            
            // Main Content Area - HStack with form on left, keyboard on right
            HStack(alignment: .top, spacing: 0) {
                // LEFT SIDE: Form content
                ScrollView {
                    VStack(spacing: 16) {
                        // Mapping Type Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.current.ruleType)
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            Picker("", selection: $mappingType) {
                                Label(L10n.current.keySwap, systemImage: "arrow.left.arrow.right")
                                    .tag(MappingType.simpleKey)
                                Label(L10n.current.controlAction, systemImage: "command")
                                    .tag(MappingType.navigation)
                            }
                            .pickerStyle(.segmented)
                            .disabled(editingMapping != nil)
                        }
                        
                        // Key Mapping Area
                        HStack(spacing: 16) {
                            // FROM Key
                            VStack(spacing: 8) {
                                Text(L10n.current.source)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.secondary)
                                
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(isCapturingFrom ? Color.red.opacity(0.1) : Color.blue.opacity(0.1))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(isCapturingFrom ? Color.red : Color.blue, lineWidth: 2)
                                        )
                                    
                                    VStack(spacing: 4) {
                                        if fromKey.isEmpty {
                                            Image(systemName: "keyboard")
                                                .font(.title2)
                                                .foregroundColor(.secondary)
                                            Text(isCapturingFrom ? L10n.current.pressKey : L10n.current.clickHere)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        } else {
                                            Text(fromKey)
                                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                                .foregroundColor(.primary)
                                        }
                                    }
                                    .padding(8)
                                }
                                .frame(height: 60)
                                .onTapGesture {
                                    isCapturingFrom = true
                                    isCapturingTo = false
                                }
                                
                                if !fromKey.isEmpty {
                                    Button(action: { 
                                        fromKey = ""
                                        fromKeyCode = 0
                                        fromModifiers = nil
                                    }) {
                                        Label(L10n.current.clear, systemImage: "xmark.circle")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundColor(.red)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            
                            // Arrow
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                                .padding(.top, 20)
                            
                            // TO Key
                            VStack(spacing: 8) {
                                Text(L10n.current.target)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.secondary)
                                
                                if mappingType == .simpleKey {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(isCapturingTo ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .strokeBorder(isCapturingTo ? Color.red : Color.green, lineWidth: 2)
                                            )
                                        
                                        VStack(spacing: 4) {
                                            if toKey.isEmpty {
                                                Image(systemName: "keyboard")
                                                    .font(.title2)
                                                    .foregroundColor(.secondary)
                                                Text(isCapturingTo ? L10n.current.pressKey : L10n.current.clickHere)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            } else {
                                                Text(toKey)
                                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                                    .foregroundColor(.primary)
                                            }
                                        }
                                        .padding(8)
                                    }
                                    .frame(height: 60)
                                    .onTapGesture {
                                        isCapturingTo = true
                                        isCapturingFrom = false
                                    }
                                    
                                    HStack(spacing: 8) {
                                        // Visual Keyboard Toggle Button
                                        Button(action: { 
                                            showVisualKeyboard.toggle()
                                            isCapturingTo = false
                                            isCapturingFrom = false
                                        }) {
                                            Image(systemName: showVisualKeyboard ? "keyboard.fill" : "keyboard")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(showVisualKeyboard ? .blue : .gray)
                                        .help(L10n.current.showKeyboard)
                                        
                                        if !toKey.isEmpty {
                                            Button(action: { 
                                                toKey = ""
                                                toKeyCode = 0
                                            }) {
                                                Image(systemName: "xmark.circle")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.borderless)
                                            .foregroundColor(.red)
                                        }
                                    }
                                } else {
                                    // Navigation action picker
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.purple.opacity(0.1))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .strokeBorder(Color.purple, lineWidth: 2)
                                            )
                                        
                                        VStack(spacing: 4) {
                                            if let action = selectedNavigationAction {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.title2)
                                                    .foregroundColor(.green)
                                                Text(action.name)
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .multilineTextAlignment(.center)
                                                    .lineLimit(2)
                                            } else {
                                                Image(systemName: "list.bullet")
                                                    .font(.title2)
                                                    .foregroundColor(.secondary)
                                                Text(L10n.current.selectAction)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(8)
                                    }
                                    .frame(height: 60)
                                    
                                    Picker("", selection: $selectedNavigationAction) {
                                        Text(L10n.current.select).tag(nil as NavigationAction?)
                                        ForEach(NavigationAction.all) { action in
                                            Text(action.localizedName).tag(action as NavigationAction?)
                                        }
                                    }
                                    .labelsHidden()
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(10)
                        
                        // Per-App Filter Section
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.current.appFilter)
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            Picker("", selection: $appFilterMode) {
                                Label(L10n.current.filterAllApps, systemImage: "square.stack.3d.up").tag(AppFilterMode.all)
                                Label(L10n.current.filterExclude, systemImage: "minus.circle").tag(AppFilterMode.exclude)
                                Label(L10n.current.filterInclude, systemImage: "checkmark.circle").tag(AppFilterMode.include)
                            }
                            .pickerStyle(.segmented)
                            
                            if appFilterMode != .all {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(L10n.current.runningApps)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text("(\(appsManager.runningApps.count))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    if appsManager.runningApps.isEmpty {
                                        HStack {
                                            Image(systemName: "info.circle")
                                                .foregroundColor(.orange)
                                            Text(L10n.current.appNotRunningHint)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(6)
                                    } else {
                                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                                            ForEach(appsManager.runningApps) { app in
                                                HStack(spacing: 4) {
                                                    Text(app.name)
                                                        .font(.system(size: 10, weight: .medium))
                                                        .lineLimit(1)
                                                    Spacer(minLength: 2)
                                                    Toggle("", isOn: Binding(
                                                        get: { selectedAppBundleIDs.contains(app.bundleID) },
                                                        set: { isOn in
                                                            if isOn {
                                                                selectedAppBundleIDs.insert(app.bundleID)
                                                            } else {
                                                                selectedAppBundleIDs.remove(app.bundleID)
                                                            }
                                                        }
                                                    ))
                                                    .toggleStyle(.switch)
                                                    .scaleEffect(0.6)
                                                }
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(selectedAppBundleIDs.contains(app.bundleID) ? Color.blue.opacity(0.1) : Color.clear)
                                                .cornerRadius(4)
                                                .help(app.bundleID)
                                            }
                                        }
                                    }
                                }
                                .padding(8)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                                .cornerRadius(8)
                            }
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(10)
                    }
                    .padding(16)
                }
                .frame(minWidth: 400)
                
                // RIGHT SIDE: Visual Keyboard (only for simpleKey mode when toggled)
                if showVisualKeyboard && mappingType == .simpleKey {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.current.clickToSelect)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: { showVisualKeyboard = false }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        VisualKeyboardView(
                            selectedKeyCode: $toKeyCode,
                            selectedKeyName: $toKey,
                            selectedCharacter: $toCharacter,
                            onKeySelected: nil
                        )
                        
                        Spacer()
                    }
                    .padding(12)
                    .frame(width: 480)
                    .background(Color(NSColor.windowBackgroundColor))
                }
            }
            
            Divider()
            
            // Action Buttons
            HStack(spacing: 16) {
                Button(action: { isPresented = false }) {
                    Text(L10n.current.cancel)
                        .frame(width: 80)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                
                Button(action: saveMapping) {
                    Text(L10n.current.save)
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: showVisualKeyboard && mappingType == .simpleKey ? 920 : 500, height: 520)
        .animation(.easeInOut(duration: 0.2), value: showVisualKeyboard)
        .onAppear {
            // Suspend remapping to capture original keys, not remapped ones
            appDelegate.suspendRemapping()
            
            startKeyCapture()
            appsManager.fetchRunningApps()
            
            // Populate fields if editing
            if let mapping = editingMapping {
                isLoadingMapping = true
                
                fromKey = mapping.sourceKeyName
                fromKeyCode = mapping.sourceKeyCode
                fromModifiers = mapping.sourceModifiers
                toKey = mapping.targetKeyName
                toKeyCode = mapping.targetKeyCode
                toCharacter = mapping.targetCharacter
                mappingType = mapping.type
                appFilterMode = mapping.appFilterMode
                selectedAppBundleIDs = Set(mapping.filteredApps)
                
                if mapping.type == .navigation {
                    selectedNavigationAction = NavigationAction.all.first {
                        $0.key == mapping.targetKeyCode &&
                        $0.modifiers == mapping.targetModifiers
                    }
                }
                
                isLoadingMapping = false
            }
        }
        .onDisappear {
            // Clean up key capture monitor to prevent memory leak
            if let monitor = keyCaptureMonitor {
                NSEvent.removeMonitor(monitor)
                keyCaptureMonitor = nil
            }
            // Resume remapping when sheet closes
            appDelegate.resumeRemapping()
        }

    }
    
    private var canSave: Bool {
        // If editing, always allow save (just changing app filter for example)
        if editingMapping != nil {
            return !fromKey.isEmpty
        }
        
        // For new mappings, require both keys
        guard !fromKey.isEmpty else { return false }
        if mappingType == .simpleKey {
            return !toKey.isEmpty
        } else {
            return selectedNavigationAction != nil
        }
    }
    
    private func saveMapping() {
        if mappingType == .simpleKey {
            let mapping = KeyMappingRule(
                type: .simpleKey,
                sourceKeyCode: fromKeyCode,
                sourceKeyName: fromKey,
                sourceModifiers: fromModifiers,
                targetKeyCode: toKeyCode,
                targetKeyName: toKey,
                targetCharacter: toCharacter,
                appFilterMode: appFilterMode,
                filteredApps: Array(selectedAppBundleIDs)
            )
            if let editingMapping = editingMapping {
                manager.updateMapping(editingMapping, with: mapping)
            } else {
                manager.addMapping(mapping)
            }
        } else if let action = selectedNavigationAction {
            let mapping = KeyMappingRule(
                type: .navigation,
                sourceKeyCode: fromKeyCode,
                sourceKeyName: fromKey,
                sourceModifiers: fromModifiers,
                targetKeyCode: action.key,
                targetKeyName: action.name,
                targetModifiers: action.modifiers,
                appFilterMode: appFilterMode,
                filteredApps: Array(selectedAppBundleIDs)
            )
            if let editingMapping = editingMapping {
                manager.updateMapping(editingMapping, with: mapping)
            } else {
                manager.addMapping(mapping)
            }
        }
        isPresented = false
    }
    
    private func startKeyCapture() {
        if let monitor = keyCaptureMonitor {
            NSEvent.removeMonitor(monitor)
            keyCaptureMonitor = nil
        }
        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard self.isCapturingFrom || self.isCapturingTo else { return event }
            let type: CGEventType = event.type == .flagsChanged ? .flagsChanged : .keyDown
            guard let selection = KeyCaptureState().capture(type: type, keyCode: event.keyCode,
                                                               flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) else {
                return nil
            }
            let char = event.type == .flagsChanged ? "" : (event.charactersIgnoringModifiers ?? "")
            if self.isCapturingFrom {
                let baseKey = self.getKeyName(keyCode: selection.keyCode, char: char)
                let mods = self.getModifierString(NSEvent.ModifierFlags(rawValue: UInt(selection.flags.rawValue)))
                self.fromKey = mods.isEmpty ? baseKey : "\(mods)\(baseKey)"
                self.fromKeyCode = selection.keyCode
                self.fromModifiers = selection.flags.isEmpty ? nil : selection.flags
                self.isCapturingFrom = false
            } else {
                self.toKey = self.getKeyName(keyCode: selection.keyCode, char: char)
                self.toKeyCode = selection.keyCode
                self.toCharacter = nil
                self.isCapturingTo = false
            }
            return nil
        }
    }

    private func getKeyName(keyCode: UInt16, char: String) -> String {
        if let name = kSpecialKeys[keyCode] { return name }
        return char.isEmpty ? "(\(keyCode))" : char.uppercased()
    }
    
    private func getModifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var mods: [String] = []
        if flags.contains(.control) { mods.append("⌃") }
        if flags.contains(.option) { mods.append("⌥") }
        if flags.contains(.shift) { mods.append("⇧") }
        if flags.contains(.command) { mods.append("⌘") }
        return mods.joined(separator: "")
    }
    
    private func getCGEventFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags? {
        var cgFlags: CGEventFlags = []
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        return cgFlags.isEmpty ? nil : cgFlags
    }
}

// MARK: - Key Event Row
struct KeyEventRow: View {
    let event: KeyEventMonitor.KeyEvent
    
    // Cache DateFormatter for performance (expensive to create repeatedly)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    var body: some View {
        HStack(spacing: 15) {
            // Timestamp
            Text(formatTime(event.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            
            // Event Type
            Text(event.eventType)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 60, alignment: .leading)
                .foregroundColor(event.eventType.contains("DOWN") ? .green : .orange)
            
            // Modifiers
            Text(event.modifiers)
                .font(.system(.body, design: .rounded))
                .frame(width: 80, alignment: .leading)
                .foregroundColor(.blue)
            
            // Key
            Text(event.keyChar)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
                .frame(width: 100, alignment: .leading)
            
            // Key Code
            Text("(\(event.keyCode))")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
    
    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

// MARK: - Held mapping state
// A press owns its mapping until release, independent of later rule/app changes.
struct RemappingState {
    static let eventTag: Int64 = 0x424336344B657973
    private var activeMappings: [UInt16: KeyMappingRule] = [:]
    private var pressedKeys: Set<UInt16> = []
    private var capsLockPressed = false
    private var capsLockMapped = false
    private var lastFlags: CGEventFlags = []

    mutating func synchronize(flags: CGEventFlags, heldKeys: Set<UInt16>) {
        lastFlags = flags
        pressedKeys = heldKeys
        capsLockPressed = flags.contains(.maskAlphaShift)
        capsLockMapped = false
    }

    func effectiveFlags(_ flags: CGEventFlags) -> CGEventFlags {
        var result = flags
        for keyCode in activeMappings.keys {
            if let modifier = PhysicalModifier.key(keyCode) {
                result = modifier.removing(from: result)
            }
        }
        for mapping in activeMappings.values where !isDiscard(mapping) && (mapping.targetCharacter?.isEmpty ?? true) {
            if let modifier = PhysicalModifier.key(mapping.targetKeyCode) {
                result = modifier.adding(to: result)
            }
        }
        return result
    }

    private func isDiscard(_ mapping: KeyMappingRule) -> Bool {
        mapping.type == .navigation && mapping.targetKeyCode == 0 &&
            mapping.targetModifiers == nil && (mapping.targetCharacter?.isEmpty ?? true)
    }

    private func findMatchingMapping(keyCode: UInt16, eventFlags: CGEventFlags,
                                     mappings: [KeyMappingRule], bundleID: String) -> KeyMappingRule? {
        mappings.first { mapping in
            guard mapping.isEnabled && mapping.sourceKeyCode == keyCode else { return false }
            switch mapping.appFilterMode {
            case .all: break
            case .exclude:
                if mapping.filteredApps.contains(bundleID) { return false }
            case .include:
                if !mapping.filteredApps.contains(bundleID) { return false }
            }
            if let required = mapping.sourceModifiers {
                return eventFlags.intersection(PhysicalModifier.userFlags) == required.intersection(PhysicalModifier.userFlags)
            }
            // A standalone physical modifier remains usable while other modifiers are held.
            return PhysicalModifier.key(keyCode) != nil || eventFlags.intersection(PhysicalModifier.userFlags).isEmpty
        }
    }

    private func output(mapping: KeyMappingRule, isKeyDown: Bool, flags: CGEventFlags,
                        originalEvent: CGEvent? = nil) -> CGEvent? {
        guard !isDiscard(mapping) else { return nil }
        if let character = mapping.targetCharacter, !character.isEmpty {
            guard isKeyDown, let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return nil }
            var unicode = Array(character.utf16)
            event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
            event.flags = mapping.sourceModifiers == nil ? flags : []
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            return event
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: mapping.targetKeyCode, keyDown: isKeyDown) else { return nil }
        if PhysicalModifier.key(mapping.targetKeyCode) != nil {
            event.type = .flagsChanged
            event.flags = flags
        } else {
            event.type = isKeyDown ? .keyDown : .keyUp
            event.flags = mapping.targetModifiers ?? (mapping.sourceModifiers == nil ? flags : [])
        }
        if let originalEvent = originalEvent {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: originalEvent.getIntegerValueField(.keyboardEventAutorepeat))
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        return event
    }

    mutating func process(type: CGEventType, event: CGEvent, mappings: [KeyMappingRule], bundleID: String, debugLoggingEnabled: Bool = false) -> [CGEvent] {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.eventTag else { return [event] }
        let flags = event.flags
        lastFlags = flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifier = PhysicalModifier.key(keyCode)

        if type == .flagsChanged && keyCode == 57 {
            let active = flags.contains(.maskAlphaShift)
            defer { capsLockPressed = active }
            if active && !capsLockPressed {
                let matchingFlags = effectiveFlags(flags)
                if let mapping = findMatchingMapping(keyCode: 57, eventFlags: matchingFlags, mappings: mappings, bundleID: bundleID) {
                    capsLockMapped = true
                    activeMappings[57] = mapping
                    let down = output(mapping: mapping, isKeyDown: true, flags: effectiveFlags(flags))
                    activeMappings.removeValue(forKey: 57)
                    let up = output(mapping: mapping, isKeyDown: false, flags: effectiveFlags(flags))
                    return [down, up].compactMap { $0 }
                }
            } else if !active && capsLockPressed && capsLockMapped {
                capsLockMapped = false
                return []
            }
            event.flags = effectiveFlags(flags)
            return [event]
        }

        guard type == .keyDown || type == .keyUp || (type == .flagsChanged && modifier != nil) else {
            // Mouse/scroll flags must agree with keyboard flags while a modifier is remapped.
            event.flags = effectiveFlags(flags)
            return [event]
        }
        let isKeyDown = type == .flagsChanged ? modifier!.isDown(in: flags) : type == .keyDown
        let previousFlags = effectiveFlags(flags)
        if isKeyDown {
            let firstPress = pressedKeys.insert(keyCode).inserted
            if firstPress {
                let matchingFlags = modifier?.removing(from: previousFlags) ?? previousFlags
                if let mapping = findMatchingMapping(keyCode: keyCode, eventFlags: matchingFlags, mappings: mappings, bundleID: bundleID) {
                    activeMappings[keyCode] = mapping
                    if debugLoggingEnabled {
                        print("🔀 Remap \(keyCode) → \(mapping.targetKeyCode) [\(bundleID)]")
                    }
                }
            }
            if let mapping = activeMappings[keyCode] {
                if let target = PhysicalModifier.key(mapping.targetKeyCode), (mapping.targetCharacter?.isEmpty ?? true) {
                    // Don't repeat modifier presses or release a target still held by another source.
                    let beforePress = modifier?.removing(from: previousFlags) ?? previousFlags
                    if !firstPress || target.isDown(in: beforePress) { return [] }
                }
                return [output(mapping: mapping, isKeyDown: true, flags: effectiveFlags(flags), originalEvent: event)].compactMap { $0 }
            }
        } else {
            pressedKeys.remove(keyCode)
            if let mapping = activeMappings.removeValue(forKey: keyCode) {
                let outputFlags = effectiveFlags(flags)
                if let target = PhysicalModifier.key(mapping.targetKeyCode), (mapping.targetCharacter?.isEmpty ?? true),
                   target.isDown(in: outputFlags) {
                    return []
                }
                return [output(mapping: mapping, isKeyDown: false, flags: outputFlags, originalEvent: event)].compactMap { $0 }
            }
        }
        event.flags = effectiveFlags(flags)
        return [event]
    }

    // Balance emitted presses on stop, capture suspension, termination, or a disabled tap.
    mutating func releaseAll(physicalFlags: CGEventFlags? = nil) -> [CGEvent] {
        let events = releaseMappings(physicalFlags: physicalFlags)
        pressedKeys.removeAll()
        capsLockMapped = false
        return events
    }

    private mutating func releaseMappings(physicalFlags: CGEventFlags?) -> [CGEvent] {
        let flags = physicalFlags ?? lastFlags
        let keys = activeMappings.keys.sorted()
        let suppressed = keys.compactMap { PhysicalModifier.key($0) }
        var events: [CGEvent] = []
        for keyCode in keys {
            guard let mapping = activeMappings.removeValue(forKey: keyCode) else { continue }
            let outputFlags = effectiveFlags(flags)
            if let target = PhysicalModifier.key(mapping.targetKeyCode), target.isDown(in: outputFlags) { continue }
            if let event = output(mapping: mapping, isKeyDown: false, flags: outputFlags) {
                events.append(event)
            }
        }
        // Restore any physical modifiers still held when normal pass-through resumes.
        for modifier in suppressed where modifier.isDown(in: flags) {
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: modifier.keyCode, keyDown: true) {
                event.type = .flagsChanged
                event.flags = effectiveFlags(flags)
                event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
                events.append(event)
            }
        }
        return events
    }
}

// MARK: - Key Remapper using CGEventTap
class KeyRemapper {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    weak var mappingManager: KeyMappingManager?
    var debugLoggingEnabled: Bool = false
    
    private var state = RemappingState()
    
    // Cached frontmost bundle ID. Tap + workspace observer both run on the main
    // run loop, so a plain var is enough — DispatchQueue.sync per keystroke caused lag.
    private var cachedBundleID: String = ""
    private var workspaceObserver: Any?
    
    // Public property to check if remapper is actually running (has active event tap)
    var isRunning: Bool {
        return eventTap != nil
    }
    
    init(mappingManager: KeyMappingManager) {
        self.mappingManager = mappingManager
    }
    
    func startRemapping() {
        guard AXIsProcessTrusted() else {
            print("❌ Accessibility permission not granted")
            return
        }
        
        // Idempotent: drop any previous tap/observer before creating a new one
        stopRemapping()
        synchronizeState()
        
        // Initialize cached bundle ID
        cachedBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        
        // Observe app activation changes to update cached bundle ID
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.cachedBundleID = app.bundleIdentifier ?? ""
            }
        }
        
        // Include pointer events so suppressed/held modifiers also apply to clicks and scrolling.
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.leftMouseUp.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseUp.rawValue) |
                        (1 << CGEventType.otherMouseDown.rawValue) |
                        (1 << CGEventType.otherMouseUp.rawValue) |
                        (1 << CGEventType.mouseMoved.rawValue) |
                        (1 << CGEventType.leftMouseDragged.rawValue) |
                        (1 << CGEventType.rightMouseDragged.rawValue) |
                        (1 << CGEventType.otherMouseDragged.rawValue) |
                        (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                // Safety check: refcon should never be nil, but guard against it
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let remapper = Unmanaged<KeyRemapper>.fromOpaque(refcon).takeUnretainedValue()
                return remapper.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("❌ Failed to create event tap - check Accessibility permissions")
            return
        }
        
        self.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        #if DEBUG
        print("✅ Key remapper started with \(mappingManager?.mappings.filter { $0.isEnabled }.count ?? 0) active mappings")
        #endif
    }
    
    func stopRemapping() {
        for event in state.releaseAll(physicalFlags: CGEventSource.flagsState(.hidSystemState)) {
            event.post(tap: .cgSessionEventTap)
        }
        // Remove workspace observer
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
    }
    
    private func synchronizeState() {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let heldKeys = Set((0...127).compactMap { value -> UInt16? in
            let key = UInt16(value)
            return CGEventSource.keyState(.hidSystemState, key: key) ? key : nil
        })
        state.synchronize(flags: flags, heldKeys: heldKeys)
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            for released in state.releaseAll(physicalFlags: CGEventSource.flagsState(.hidSystemState)) {
                released.tapPostEvent(proxy)
            }
            synchronizeState()
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        let events = state.process(type: type, event: event, mappings: mappingManager?.mappings ?? [], bundleID: cachedBundleID, debugLoggingEnabled: debugLoggingEnabled)
        guard let last = events.last else { return nil }
        for extra in events.dropLast() {
            extra.tapPostEvent(proxy)
        }
        return last === event ? Unmanaged.passUnretained(event) : Unmanaged.passRetained(last)
    }

    deinit {
        // Ensure cleanup happens even if stopRemapping wasn't explicitly called
        stopRemapping()
    }
}

// MARK: - Preview
// Xcode preview (disabled - only works in Xcode)
// #Preview {
//     ContentView()
//         .frame(width: 600, height: 500)
// }
