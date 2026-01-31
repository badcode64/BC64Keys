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
// - A CGEventTap (KeyRemapper) intercepts keyDown/keyUp events and either:
//   - blocks them (discard), or
//   - emits a replacement CGEvent (remap)
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

// MARK: - Main App
@main
struct BC64KeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
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
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    var keyRemapper: KeyRemapper?
    var statusCheckTimer: Timer?
    var statusItem: NSStatusItem?
    
    // Track previous state to avoid spamming logs
    private var previousAccessibilityState: Bool?
    private var previousRemapperState: Bool = false
    
    // Debug logging is now optional - only enabled if user explicitly turns it on in Settings.
    // This reduces SSD wear and avoids logging sensitive keystroke patterns by default.
    @AppStorage("bc64keys.debugLogging") var debugLoggingEnabled: Bool = false
    
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
        
        // Setup menu bar icon (like Karabiner Elements)
        setupMenuBar()
        
        // Ensure the main window is visible and active on startup
        // This fixes the issue where the window doesn't show automatically
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.ensureMainWindowVisible()
            self.setupWindowDelegates()
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
            button.action = #selector(statusItemClicked)
            button.target = self
        }
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
        let mainWindows = NSApp.windows.filter { window in
            !window.className.contains("Panel") && 
            !window.className.contains("Alert") &&
            !window.className.contains("Tooltip")
        }
        
        if let mainWindow = mainWindows.first {
            // Window exists - just toggle visibility
            if mainWindow.isVisible && NSApp.isActive {
                // Hide the window and app
                mainWindow.orderOut(nil)
                NSApp.hide(nil)
            } else {
                // Show the window
                NSApp.activate(ignoringOtherApps: true)
                mainWindow.makeKeyAndOrderFront(nil)
            }
        }
    }
    
    // Setup window delegates to intercept close button
    private func setupWindowDelegates() {
        for window in NSApp.windows {
            if !window.className.contains("Panel") && 
               !window.className.contains("Alert") &&
               !window.className.contains("Tooltip") {
                window.delegate = self
            }
        }
    }
    
    // Intercept window close - just hide instead of destroying
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.hide(nil)
        return false  // Don't actually close/destroy the window
    }
    
    // Helper method to ensure the main window is visible and active
    private func ensureMainWindowVisible() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
        
        // Bring existing windows to front
        for window in NSApp.windows {
            if !window.className.contains("Panel") && 
               !window.className.contains("Alert") &&
               !window.className.contains("Tooltip") {
                // Deminiaturize if minimized
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
    
    // Keep app running when window is hidden
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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
        let keyChar = event.charactersIgnoringModifiers ?? ""
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
    ]
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
    var isEnabled: Bool
    
    // Per-app filtering
    var appFilterMode: AppFilterMode
    var filteredApps: [String] // Bundle IDs
    
    init(id: UUID = UUID(), type: MappingType, sourceKeyCode: UInt16, sourceKeyName: String,
         sourceModifiers: CGEventFlags? = nil, targetKeyCode: UInt16, targetKeyName: String, 
         targetModifiers: CGEventFlags? = nil, isEnabled: Bool = true,
         appFilterMode: AppFilterMode = .all, filteredApps: [String] = []) {
        self.id = id
        self.type = type
        self.sourceKeyCode = sourceKeyCode
        self.sourceKeyName = sourceKeyName
        self.sourceModifiers = sourceModifiers
        self.targetKeyCode = targetKeyCode
        self.targetKeyName = targetKeyName
        self.targetModifiers = targetModifiers
        self.isEnabled = isEnabled
        self.appFilterMode = appFilterMode
        self.filteredApps = filteredApps
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, sourceKeyCode, sourceKeyName, sourceModifiers, targetKeyCode, targetKeyName, targetModifiers, isEnabled, appFilterMode, filteredApps
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
    @ObservedObject var l10n = L10n.shared
    @StateObject private var launchManager = LaunchAtLoginManager()
    @AppStorage("selectedLanguage") private var selectedLanguageRaw: String = AppLanguage.system.rawValue
    @AppStorage("bc64keys.debugLogging") private var debugLoggingEnabled: Bool = false
    
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
    @State private var selectedNavigationAction: NavigationAction?
    @State private var selectedApp = ""
    @State private var isCapturingFrom = false
    @State private var isCapturingTo = false
    @State private var toKeyCodeText = ""
    @State private var keyCaptureMonitor: Any?
    @State private var isLoadingMapping = false
    
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
            }
            .padding(.vertical, 20)
            
            Divider()
            
            // Content
            VStack(spacing: 20) {
                // Mapping Type Selection
                VStack(alignment: .leading, spacing: 10) {
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
                    .disabled(editingMapping != nil)  // Don't allow changing type when editing
                }
                
                // Key Mapping Area
                HStack(spacing: 20) {
                    // FROM Key
                    VStack(spacing: 12) {
                        Text(L10n.current.source)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isCapturingFrom ? Color.red.opacity(0.1) : Color.blue.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(isCapturingFrom ? Color.red : Color.blue, lineWidth: 2)
                                )
                            
                            VStack(spacing: 6) {
                                if fromKey.isEmpty {
                                    Image(systemName: "keyboard")
                                        .font(.title)
                                        .foregroundColor(.secondary)
                                    Text(isCapturingFrom ? L10n.current.pressKey : L10n.current.clickHere)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(fromKey)
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                        .foregroundColor(.primary)
                                }
                            }
                            .padding()
                        }
                        .frame(height: 80)
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
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Arrow
                    VStack {
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.green)
                        Spacer()
                    }
                    .frame(height: 100)
                    
                    // TO Key
                    VStack(spacing: 12) {
                        Text(L10n.current.target)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        
                        if mappingType == .simpleKey {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isCapturingTo ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(isCapturingTo ? Color.red : Color.green, lineWidth: 2)
                                    )
                                
                                VStack(spacing: 6) {
                                    if toKey.isEmpty {
                                        Image(systemName: "keyboard")
                                            .font(.title)
                                            .foregroundColor(.secondary)
                                        Text(isCapturingTo ? L10n.current.pressKey : L10n.current.clickHere)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(toKey)
                                            .font(.system(size: 18, weight: .bold, design: .rounded))
                                            .foregroundColor(.primary)
                                    }
                                }
                                .padding()
                            }
                            .frame(height: 80)
                            .onTapGesture {
                                isCapturingTo = true
                                isCapturingFrom = false
                            }
                            
                            if !toKey.isEmpty {
                                Button(action: { 
                                    toKey = ""
                                    toKeyCode = 0
                                }) {
                                    Label(L10n.current.clear, systemImage: "xmark.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.red)
                            }
                        } else {
                            // Navigation action picker
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.purple.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(Color.purple, lineWidth: 2)
                                    )
                                
                                VStack(spacing: 8) {
                                    if let action = selectedNavigationAction {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title)
                                            .foregroundColor(.green)
                                        Text(action.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .multilineTextAlignment(.center)
                                    } else {
                                        Image(systemName: "list.bullet")
                                            .font(.title)
                                            .foregroundColor(.secondary)
                                        Text(L10n.current.selectAction)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding()
                            }
                            .frame(height: 80)
                            
                            Picker("", selection: $selectedNavigationAction) {
                                Text(L10n.current.select).tag(nil as NavigationAction?)
                                ForEach(NavigationAction.all) { action in
                                    Text(action.localizedName).tag(action as NavigationAction?)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
                
                // Per-App Filter Section
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.current.appFilter)
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    // Filter Mode Selection
                    Picker("", selection: $appFilterMode) {
                        Label(L10n.current.filterAllApps, systemImage: "square.stack.3d.up").tag(AppFilterMode.all)
                        Label(L10n.current.filterExclude, systemImage: "minus.circle").tag(AppFilterMode.exclude)
                        Label(L10n.current.filterInclude, systemImage: "checkmark.circle").tag(AppFilterMode.include)
                    }
                    .pickerStyle(.segmented)
                    
                    // Running Apps List (only if not .all)
                    if appFilterMode != .all {
                        VStack(alignment: .leading, spacing: 8) {
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
                                .padding(8)
                            } else {
                                ScrollView {
                                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
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
                                                .scaleEffect(0.7)
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.05))
                                            .cornerRadius(5)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
                                            )
                                            .help(app.bundleID)
                                        }
                                    }
                                    .padding(8)
                                }
                                .frame(maxHeight: 420)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
            }
            .padding(20)
            
            Spacer()
            
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
            .padding(20)
        }
        .frame(width: 900, height: 650)
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
                mappingType = mapping.type
                appFilterMode = mapping.appFilterMode
                selectedAppBundleIDs = Set(mapping.filteredApps)
                
                if mapping.type == .navigation {
                    selectedNavigationAction = NavigationAction.all.first { 
                        $0.key == mapping.targetKeyCode 
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
        // Captures the next keyDown event when the user clicks “Source” or “Target”.
        // Returning nil consumes the event so it does not type into any focused control.
        if let monitor = keyCaptureMonitor {
            NSEvent.removeMonitor(monitor)
            keyCaptureMonitor = nil
        }

        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if self.isCapturingFrom {
                let baseKey = self.getKeyName(keyCode: event.keyCode, char: event.charactersIgnoringModifiers ?? "")
                let mods = self.getModifierString(event.modifierFlags)
                self.fromKey = mods.isEmpty ? baseKey : "\(mods)\(baseKey)"
                self.fromKeyCode = event.keyCode
                self.fromModifiers = self.getCGEventFlags(event.modifierFlags)
                self.isCapturingFrom = false
                return nil
            } else if self.isCapturingTo {
                self.toKey = self.getKeyName(keyCode: event.keyCode, char: event.charactersIgnoringModifiers ?? "")
                self.toKeyCode = event.keyCode
                self.isCapturingTo = false
                return nil
            }
            return event
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

// MARK: - Key Remapper using CGEventTap
class KeyRemapper {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    weak var mappingManager: KeyMappingManager?
    var debugLoggingEnabled: Bool = false
    
    // Track Caps Lock state to detect press/release
    private var capsLockPressed: Bool = false
    
    // Cache active app bundle ID to avoid frequent NSWorkspace calls
    // Updated periodically via notification observer
    // Thread-safe access via serial queue to prevent race conditions
    private let bundleIDQueue = DispatchQueue(label: "com.bc64keys.bundleIDQueue")
    private var _cachedBundleID: String = ""
    private var cachedBundleID: String {
        get { bundleIDQueue.sync { _cachedBundleID } }
        set { bundleIDQueue.sync { _cachedBundleID = newValue } }
    }
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
        
        // Create event tap for keyboard events
        let eventMask = (1 << CGEventType.keyDown.rawValue) | 
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                // Safety check: refcon should never be nil, but guard against it
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
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
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it was disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }
        
        // Process key events and flags changed (for Caps Lock and modifiers)
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }
        
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let eventFlags = event.flags
        
        // Special handling for Caps Lock via flagsChanged
        // Note: flagsChanged is triggered when ANY modifier key state changes (Shift, Cmd, Opt, Ctrl, Caps Lock),
        // but we only handle Caps Lock here by checking the .maskAlphaShift flag.
        // Other modifiers (Shift, Cmd, etc.) are handled via eventFlags matching in handleKeyMapping.
        if type == .flagsChanged {
            let capsLockActive = eventFlags.contains(.maskAlphaShift)
            
            // Detect Caps Lock press (transition from inactive to active)
            if capsLockActive && !capsLockPressed {
                capsLockPressed = true
                // Treat as "key down" for Caps Lock (use keyCode 57)
                return handleKeyMapping(keyCode: 57, eventFlags: eventFlags, isKeyDown: true)
            }
            // Detect Caps Lock release (transition from active to inactive)
            else if !capsLockActive && capsLockPressed {
                capsLockPressed = false
                // Treat as "key up" for Caps Lock (use keyCode 57)
                return handleKeyMapping(keyCode: 57, eventFlags: eventFlags, isKeyDown: false)
            }
            
            // No Caps Lock state change, pass through
            return Unmanaged.passRetained(event)
        }
        
        // Handle normal key events
        if type == .keyDown || type == .keyUp {
            return handleKeyMapping(keyCode: keyCode, eventFlags: eventFlags, isKeyDown: type == .keyDown)
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func handleKeyMapping(keyCode: UInt16, eventFlags: CGEventFlags, isKeyDown: Bool) -> Unmanaged<CGEvent>? {
        // Get enabled mappings from manager
        // IMPORTANT: Copy mappings array to avoid race conditions since CGEventTap callback
        // runs on a different thread than main thread where mappings may be modified.
        // The filter operation creates a new array, providing thread-safety for iteration.
        guard let manager = mappingManager else {
            // No manager - create pass-through event
            guard let passThroughEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isKeyDown) else {
                return nil
            }
            passThroughEvent.flags = eventFlags
            return Unmanaged.passRetained(passThroughEvent)
        }
        
        // Create a snapshot: filter() returns a new array, safe to iterate even if original changes
        let mappings = manager.mappings.filter({ $0.isEnabled })
        
        if mappings.isEmpty {
            // No enabled mappings - create pass-through event
            guard let passThroughEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isKeyDown) else {
                return nil
            }
            passThroughEvent.flags = eventFlags
            return Unmanaged.passRetained(passThroughEvent)
        }
        
        // Get active app bundle ID for per-app filtering (using cached value for performance)
        let activeBundleID = cachedBundleID
        
        // Debug: log active app info
        if debugLoggingEnabled && !activeBundleID.isEmpty {
            print("🎯 Active app: \(activeBundleID)")
        }
        
        // Matching strategy:
        // - Key code must match.
        // - Per-app filter must allow the mapping.
        // - If the rule specifies sourceModifiers: require an exact match for the user-controlled modifiers.
        // - If the rule has no sourceModifiers: reject events where the user is holding any modifiers.
        // This keeps rules unambiguous (e.g., a plain Home rule won't also trigger on Shift+Home).
        for mapping in mappings {
            if keyCode == mapping.sourceKeyCode {
                // Check per-app filter
                let shouldApply: Bool
                switch mapping.appFilterMode {
                case .all:
                    shouldApply = true
                case .exclude:
                    shouldApply = !mapping.filteredApps.contains(activeBundleID)
                case .include:
                    shouldApply = mapping.filteredApps.contains(activeBundleID)
                }
                
                if debugLoggingEnabled {
                    print("🔍 Filter: mode=\(mapping.appFilterMode), shouldApply=\(shouldApply), activeBundleID=\(activeBundleID), filtered=\(mapping.filteredApps)")
                }
                
                if !shouldApply {
                    continue // Skip this mapping for current app
                }
                
                // Check if source modifiers match (if specified)
                if let requiredMods = mapping.sourceModifiers {
                    // Only check user-controlled modifier keys
                    let shiftPressed = eventFlags.contains(.maskShift)
                    let cmdPressed = eventFlags.contains(.maskCommand)
                    let optPressed = eventFlags.contains(.maskAlternate)
                    let ctrlPressed = eventFlags.contains(.maskControl)
                    
                    let reqShift = requiredMods.contains(.maskShift)
                    let reqCmd = requiredMods.contains(.maskCommand)
                    let reqOpt = requiredMods.contains(.maskAlternate)
                    let reqCtrl = requiredMods.contains(.maskControl)
                    
                    if shiftPressed != reqShift || cmdPressed != reqCmd || optPressed != reqOpt || ctrlPressed != reqCtrl {
                        continue // Modifiers don't match, try next mapping
                    }
                } else {
                    // No source modifiers required - but make sure user isn't pressing any
                    let hasUserModifiers = eventFlags.contains(.maskShift) || 
                                          eventFlags.contains(.maskCommand) || 
                                          eventFlags.contains(.maskAlternate) || 
                                          eventFlags.contains(.maskControl)
                    if hasUserModifiers {
                        continue // User is pressing modifiers but rule doesn't want any
                    }
                }
                
                // Special case: discard / block.
                // Convention: targetKeyCode == 0 and targetModifiers == nil means “block the key entirely”.
                if mapping.targetKeyCode == 0 && mapping.targetModifiers == nil {
                    // Discard - return nil to block the key completely
                    return nil
                }
                
                // Create new event with target key
                guard let newEvent = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: CGKeyCode(mapping.targetKeyCode),
                    keyDown: isKeyDown
                ) else {
                    continue
                }
                
                // Set modifiers:
                // - For navigation actions, targetModifiers is usually set (e.g. ⌘ + ←).
                // - For simple key swaps, targetModifiers is nil and we preserve the original flags.
                // Memory management: Unmanaged.passRetained transfers ownership to caller (CGEventTap system)
                if let modifiers = mapping.targetModifiers {
                    newEvent.flags = modifiers
                } else {
                    // Keep original modifiers if no target modifiers specified
                    newEvent.flags = eventFlags
                }
                
                return Unmanaged.passRetained(newEvent)
            }
        }
        
        // No mapping found - create pass-through event
        guard let passThroughEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isKeyDown) else {
            return nil
        }
        passThroughEvent.flags = eventFlags
        return Unmanaged.passRetained(passThroughEvent)
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
