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
// - Rules are persisted in UserDefaults via KeyMappingManager
// - A CGEventTap (KeyRemapper) intercepts keyDown/keyUp events and either:
//   - blocks them (discard), or
//   - emits a replacement CGEvent (remap)
//
// Privacy note:
// - This app needs Accessibility permission to observe/modify keystrokes globally.
// - Keep logging conservative; anything written to stdout or /tmp can be readable by other local processes.

// MARK: - Main App
@main
struct BC64KeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView(mappingManager: appDelegate.mappingManager, statusManager: appDelegate.statusManager)
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
class AppDelegate: NSObject, NSApplicationDelegate {
    var keyRemapper: KeyRemapper?
    var statusCheckTimer: Timer?
    // Prefer a per-user log location instead of /tmp to reduce information exposure and
    // avoid symlink-related file clobbering risks.
    private lazy var logFileURL: URL = {
        let fm = FileManager.default
        let base = (fm.urls(for: .libraryDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library"))
            .appendingPathComponent("Logs/BC64Keys", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("bc64keys-status.log")
    }()
    let statusManager = StatusManager()
    let mappingManager = KeyMappingManager()

    // Writes operational status to both stdout and a per-user log file under ~/Library/Logs.
    // This avoids /tmp exposure and is a more standard location for macOS app logs.
    
    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"
        print(logMessage, terminator: "")
        
        // Also write to file
        if let data = logMessage.data(using: .utf8) {
            let path = logFileURL.path
            if FileManager.default.fileExists(atPath: path) {
                if let fileHandle = FileHandle(forWritingAtPath: path) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Clear old log
        try? FileManager.default.removeItem(at: logFileURL)
        
        log("==================================================")
        log("🚀 BC64Keys App Started!")
        log("📝 Status log: \(logFileURL.path)")
        log("==================================================")
        
        // Start periodic status check (1 second interval).
        // Reason: Accessibility permission can be granted/revoked while the app is running.
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAndReportStatus()
        }
        
        // Initial check
        checkAndReportStatus()
    }
    
    func checkAndReportStatus() {
        let hasAccessibility = AXIsProcessTrusted()
        
        // Update UI
        statusManager.update(accessibility: hasAccessibility, remapperRunning: keyRemapper != nil)
        
        log("")
        log("⏰ STATUS CHECK:")
        log("   🔐 Accessibility: \(hasAccessibility ? "✅ GRANTED" : "❌ NOT GRANTED")")
        
        if hasAccessibility {
            if keyRemapper == nil {
                log("   🎬 Starting key remapper...")
                startRemapping()
            } else {
                log("   ✅ Remapper is running")
            }
        } else {
            log("   ⚠️  MISSING PERMISSIONS!")
            log("   📋 Fix: System Settings > Privacy & Security > Accessibility")
            log("   📋 Add: BC64Keys (toggle it ON)")
            if keyRemapper != nil {
                log("   🛑 Stopping remapper (no permissions)")
                keyRemapper?.stopRemapping()
                keyRemapper = nil
            }
        }
    }
    
    func startRemapping() {
        log("")
        log("==================================================")
        log("🎬 startRemapping() CALLED")
        log("==================================================")
        keyRemapper = KeyRemapper(mappingManager: mappingManager)
        keyRemapper?.startRemapping()
        log("🔚 startRemapping() FINISHED")
        log("==================================================")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        log("👋 App terminating, stopping remapper...")
        statusCheckTimer?.invalidate()
        keyRemapper?.stopRemapping()
    }
}

// MARK: - Key Event Monitor
class KeyEventMonitor: ObservableObject {
    @Published var keyEvents: [KeyEvent] = []
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

        // Monitor keyDown/keyUp events:
        // - Global monitor: receives events system-wide (does not let us modify them).
        // - Local monitor: receives events inside our app (useful for the UI and capture workflows).
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        
        // Also monitor local events (within our app)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
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
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        let keyChar = event.charactersIgnoringModifiers ?? ""
        let modifiers = getModifierString(event.modifierFlags)
        let eventType = event.type == .keyDown ? "↓ DOWN" : "↑ UP"
        
        let keyName = getKeyName(keyCode: event.keyCode, char: keyChar)
        
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
                self.keyEvents.removeLast()
            }
        }
    }
    
    private func getModifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var mods: [String] = []
        if flags.contains(.command) { mods.append("⌘") }
        if flags.contains(.option) { mods.append("⌥") }
        if flags.contains(.control) { mods.append("⌃") }
        if flags.contains(.shift) { mods.append("⇧") }
        if flags.contains(.function) { mods.append("fn") }
        return mods.isEmpty ? "" : mods.joined(separator: " ")
    }
    
    private func getKeyName(keyCode: UInt16, char: String) -> String {
        // Special keys mapping
        let specialKeys: [UInt16: String] = [
            36: "Return",
            48: "Tab",
            49: "Space",
            51: "Delete",
            53: "Escape",
            115: "Home",
            119: "End",
            116: "PageUp",
            121: "PageDown",
            117: "Forward Delete",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        
        if let specialName = specialKeys[keyCode] {
            return specialName
        }
        
        return char.isEmpty ? "Key(\(keyCode))" : char.uppercased()
    }
    
    func clearEvents() {
        keyEvents.removeAll()
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - Key Mapping Model
struct KeyMapping: Identifiable, Codable {
    let id: UUID
    var fromKey: String
    var fromKeyCode: UInt16
    var toKey: String
    var toKeyCode: UInt16
    var appName: String // Empty = minden app
    var isEnabled: Bool
    
    init(id: UUID = UUID(), fromKey: String = "", fromKeyCode: UInt16 = 0, 
         toKey: String = "", toKeyCode: UInt16 = 0, appName: String = "", isEnabled: Bool = true) {
        self.id = id
        self.fromKey = fromKey
        self.fromKeyCode = fromKeyCode
        self.toKey = toKey
        self.toKeyCode = toKeyCode
        self.appName = appName
        self.isEnabled = isEnabled
    }
}

// MARK: - Mapping Rule Types
enum MappingType: String, Codable {
    case simpleKey // Billentyű csere (s -> o)
    case navigation // Vezérlő csere (Home -> Cmd+Left)
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

struct KeyMappingRule: Identifiable, Codable {
    let id: UUID
    var type: MappingType
    var sourceKeyCode: UInt16
    var sourceKeyName: String
    var sourceModifiers: CGEventFlags? // For matching Shift+Home etc
    var targetKeyCode: UInt16
    var targetKeyName: String
    var targetModifiers: CGEventFlags? // For navigation actions
    var isEnabled: Bool
    
    init(id: UUID = UUID(), type: MappingType, sourceKeyCode: UInt16, sourceKeyName: String,
         sourceModifiers: CGEventFlags? = nil, targetKeyCode: UInt16, targetKeyName: String, 
         targetModifiers: CGEventFlags? = nil, isEnabled: Bool = true) {
        self.id = id
        self.type = type
        self.sourceKeyCode = sourceKeyCode
        self.sourceKeyName = sourceKeyName
        self.sourceModifiers = sourceModifiers
        self.targetKeyCode = targetKeyCode
        self.targetKeyName = targetKeyName
        self.targetModifiers = targetModifiers
        self.isEnabled = isEnabled
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, sourceKeyCode, sourceKeyName, sourceModifiers, targetKeyCode, targetKeyName, targetModifiers, isEnabled
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
    
    // Predefined navigation actions - Windows-ról váltóknak optimalizálva
    static let navigationActions: [NavigationAction] = [
        // === SPECIÁLIS ===
        NavigationAction(name: "🚫 Eldobás (letiltás)", key: 0, modifiers: []),  // keyCode 0 + no modifiers = discard
        
        // === SOR NAVIGÁCIÓ (Home/End helyett) ===
        NavigationAction(name: "⌘← Sor elejére", key: 123, modifiers: .maskCommand),
        NavigationAction(name: "⌘→ Sor végére", key: 124, modifiers: .maskCommand),
        NavigationAction(name: "⇧⌘← Kijelölés sor elejéig", key: 123, modifiers: [.maskCommand, .maskShift]),
        NavigationAction(name: "⇧⌘→ Kijelölés sor végéig", key: 124, modifiers: [.maskCommand, .maskShift]),
        
        // === DOKUMENTUM NAVIGÁCIÓ (Ctrl+Home/End helyett) ===
        NavigationAction(name: "⌘↑ Dokumentum elejére", key: 126, modifiers: .maskCommand),
        NavigationAction(name: "⌘↓ Dokumentum végére", key: 125, modifiers: .maskCommand),
        NavigationAction(name: "⇧⌘↑ Kijelölés dok. elejéig", key: 126, modifiers: [.maskCommand, .maskShift]),
        NavigationAction(name: "⇧⌘↓ Kijelölés dok. végéig", key: 125, modifiers: [.maskCommand, .maskShift]),
        
        // === SZÓ NAVIGÁCIÓ (Ctrl+Left/Right helyett) ===
        NavigationAction(name: "⌥← Szó elejére", key: 123, modifiers: .maskAlternate),
        NavigationAction(name: "⌥→ Szó végére", key: 124, modifiers: .maskAlternate),
        NavigationAction(name: "⇧⌥← Kijelölés szó elejéig", key: 123, modifiers: [.maskAlternate, .maskShift]),
        NavigationAction(name: "⇧⌥→ Kijelölés szó végéig", key: 124, modifiers: [.maskAlternate, .maskShift]),
        
        // === TÖRLÉS (Ctrl+Backspace/Delete helyett) ===
        NavigationAction(name: "⌥⌫ Szó törlése (balra)", key: 51, modifiers: .maskAlternate),
        NavigationAction(name: "⌥Del Szó törlése (jobbra)", key: 117, modifiers: .maskAlternate),
        NavigationAction(name: "⌘⌫ Törlés sor elejéig", key: 51, modifiers: .maskCommand),
        
        // === OLDAL NAVIGÁCIÓ ===
        NavigationAction(name: "⌥↑ Oldal fel (Page Up)", key: 126, modifiers: .maskAlternate),
        NavigationAction(name: "⌥↓ Oldal le (Page Down)", key: 125, modifiers: .maskAlternate),
        
        // === UNDO/REDO (Ctrl+Z/Y helyett) ===
        NavigationAction(name: "⌘Z Visszavonás (Undo)", key: 6, modifiers: .maskCommand),
        NavigationAction(name: "⇧⌘Z Újra (Redo)", key: 6, modifiers: [.maskCommand, .maskShift]),
        
        // === VÁGÓLAP (Ctrl+X/C/V helyett) ===
        NavigationAction(name: "⌘X Kivágás (Cut)", key: 7, modifiers: .maskCommand),
        NavigationAction(name: "⌘C Másolás (Copy)", key: 8, modifiers: .maskCommand),
        NavigationAction(name: "⌘V Beillesztés (Paste)", key: 9, modifiers: .maskCommand),
        NavigationAction(name: "⌘A Összes kijelölése", key: 0, modifiers: .maskCommand),
        
        // === KERESÉS/MENTÉS ===
        NavigationAction(name: "⌘F Keresés (Find)", key: 3, modifiers: .maskCommand),
        NavigationAction(name: "⌘G Következő találat", key: 5, modifiers: .maskCommand),
        NavigationAction(name: "⌘S Mentés (Save)", key: 1, modifiers: .maskCommand),
        NavigationAction(name: "⇧⌘S Mentés másként", key: 1, modifiers: [.maskCommand, .maskShift]),
        
        // === ABLAK KEZELÉS ===
        NavigationAction(name: "⌘W Ablak/Tab bezárása", key: 13, modifiers: .maskCommand),
        NavigationAction(name: "⌘Q Kilépés (Quit)", key: 12, modifiers: .maskCommand),
        NavigationAction(name: "⌘N Új ablak/dokumentum", key: 45, modifiers: .maskCommand),
        NavigationAction(name: "⌘T Új tab", key: 17, modifiers: .maskCommand),
    ]
    
    init() {
        loadMappings()
    }
    
    func addMapping(_ mapping: KeyMappingRule) {
        mappings.append(mapping)
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
        if let encoded = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
            print("💾 Mentve \(mappings.count) szabály")
        }
    }
    
    private func loadMappings() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([KeyMappingRule].self, from: data) else {
            print("📂 Nincs mentett szabály")
            return
        }
        mappings = decoded
        print("📂 Betöltve \(mappings.count) szabály")
    }
}

// MARK: - Running Apps Manager
class RunningAppsManager: ObservableObject {
    @Published var runningApps: [String] = []
    
    func fetchRunningApps() {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
        
        DispatchQueue.main.async {
            self.runningApps = apps
        }
    }
}

// MARK: - Main Content View with Tabs
struct ContentView: View {
    @StateObject private var keyMonitor = KeyEventMonitor()
    @ObservedObject var mappingManager: KeyMappingManager
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var l10n = L10n.shared
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Status Bar at the top
            StatusBar(statusManager: statusManager)
            
            // Tabs
            TabView(selection: $selectedTab) {
                MonitorView(keyMonitor: keyMonitor)
                    .tabItem {
                        Label(L10n.current.tabMonitor, systemImage: "eye")
                    }
                    .tag(0)
                
                MappingView(mappingManager: mappingManager)
                    .tabItem {
                        Label(L10n.current.tabMapping, systemImage: "arrow.left.arrow.right")
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
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var l10n = L10n.shared
    @StateObject private var launchManager = LaunchAtLoginManager()
    @AppStorage("selectedLanguage") private var selectedLanguageRaw: String = AppLanguage.system.rawValue
    
    private var selectedLanguage: AppLanguage {
        get { AppLanguage(rawValue: selectedLanguageRaw) ?? .system }
        set { selectedLanguageRaw = newValue.rawValue }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L10n.current.settingsTitle)
                    .font(.title)
                    .fontWeight(.bold)
                
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Settings Content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Launch at Login Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L10n.current.launchAtLogin, systemImage: "power")
                            .font(.headline)
                        
                        Toggle(isOn: Binding(
                            get: { launchManager.isEnabled },
                            set: { _ in launchManager.toggle() }
                        )) {
                            Text(L10n.current.launchAtLoginDescription)
                        }
                        .toggleStyle(.switch)
                        
                        Text(L10n.current.launchAtLoginHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    
                    // Language Section
                    VStack(alignment: .leading, spacing: 12) {
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
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 400)
                        
                        Text(L10n.current.languageHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    
                    // About Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L10n.current.about, systemImage: "info.circle")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("BC64Keys")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("v1.0")
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(L10n.current.aboutDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    
                    Spacer()
                }
                .padding()
            }
        }
    }
}

// MARK: - Monitor View (Original functionality)
struct MonitorView: View {
    @ObservedObject var keyMonitor: KeyEventMonitor
    @State private var isMonitoring = false
    
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
                            Image(systemName: isMonitoring ? "stop.circle.fill" : "play.circle.fill")
                            Text(isMonitoring ? L10n.current.stopMonitoring : L10n.current.startMonitoring)
                        }
                        .frame(width: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isMonitoring ? .red : .green)
                    
                    Button(action: keyMonitor.clearEvents) {
                        HStack {
                            Image(systemName: "trash")
                            Text(L10n.current.clear)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                if !isMonitoring {
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
            keyMonitor.stopMonitoring()
        }
    }
    
    private func toggleMonitoring() {
        isMonitoring.toggle()
        if isMonitoring {
            keyMonitor.startMonitoring()
        } else {
            keyMonitor.stopMonitoring()
        }
    }
}

// MARK: - Mapping View
struct MappingView: View {
    @ObservedObject var mappingManager: KeyMappingManager
    @StateObject private var appsManager = RunningAppsManager()
    @State private var showAddSheet = false
    
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
                    VStack(spacing: 8) {
                        ForEach(mappingManager.mappings) { mapping in
                            MappingRow(mapping: mapping, manager: mappingManager)
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddMappingSheet(manager: mappingManager, appsManager: appsManager, isPresented: $showAddSheet)
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
    
    // Special keys lookup
    private let specialKeys: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 117: "Del→",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
    
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
            
            // Source key with modifiers
            HStack(spacing: 2) {
                if let mods = mapping.sourceModifiers {
                    Text(modifierSymbols(mods))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.orange)
                }
                Text(displayKeyName(mapping.sourceKeyName, keyCode: mapping.sourceKeyCode))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
                Text(displayKeyName(mapping.targetKeyName, keyCode: mapping.targetKeyCode))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.15))
            .cornerRadius(6)
            
            Spacer()
            
            // Type badge
            Text(mapping.type == .simpleKey ? "⌨️" : "🎯")
                .font(.body)
                .help(mapping.type == .simpleKey ? L10n.current.keySwap : L10n.current.controlAction)
            
            // Delete button
            Button(action: { manager.deleteMapping(mapping) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red.opacity(0.7))
                    .font(.body)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            return specialKeys[keyCode] ?? "(\(keyCode))"
        }
        // Strip modifier prefixes if present (old format)
        if name.contains(" + ") {
            return name.components(separatedBy: " + ").last ?? name
        }
        return name
    }
}

// MARK: - Add Mapping Sheet
struct AddMappingSheet: View {
    @ObservedObject var manager: KeyMappingManager
    @ObservedObject var appsManager: RunningAppsManager
    @Binding var isPresented: Bool
    
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
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(L10n.current.newKeyRule)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .padding(.vertical, 20)
            
            Divider()
            
            // Content
            VStack(spacing: 20) {
                // Mapping Type Selection
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.current.ruleType, systemImage: "switch.2")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $mappingType) {
                        Label(L10n.current.keySwap, systemImage: "arrow.left.arrow.right")
                            .tag(MappingType.simpleKey)
                        Label(L10n.current.controlAction, systemImage: "command")
                            .tag(MappingType.navigation)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mappingType) { _ in
                        toKey = ""
                        toKeyCode = 0
                        selectedNavigationAction = nil
                    }
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
                                        .font(.largeTitle)
                                        .foregroundColor(.secondary)
                                    Text(isCapturingFrom ? L10n.current.pressKey : L10n.current.clickHere)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(fromKey)
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundColor(.primary)
                                }
                            }
                            .padding()
                        }
                        .frame(height: 100)
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
                                            .font(.largeTitle)
                                            .foregroundColor(.secondary)
                                        Text(isCapturingTo ? L10n.current.pressKey : L10n.current.clickHere)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(toKey)
                                            .font(.system(size: 20, weight: .bold, design: .rounded))
                                            .foregroundColor(.primary)
                                    }
                                }
                                .padding()
                            }
                            .frame(height: 100)
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
                                            .font(.largeTitle)
                                            .foregroundColor(.secondary)
                                        Text(L10n.current.selectAction)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding()
                            }
                            .frame(height: 100)
                            
                            Picker("", selection: $selectedNavigationAction) {
                                Text(L10n.current.select).tag(nil as NavigationAction?)
                                ForEach(KeyMappingManager.navigationActions) { action in
                                    Text(action.name).tag(action as NavigationAction?)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity)
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
        .frame(width: 550, height: 480)
        .onAppear {
            startKeyCapture()
        }
        .onDisappear {
            stopKeyCapture()
        }
    }
    
    private var canSave: Bool {
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
                targetKeyName: toKey
            )
            manager.addMapping(mapping)
        } else if let action = selectedNavigationAction {
            let mapping = KeyMappingRule(
                type: .navigation,
                sourceKeyCode: fromKeyCode,
                sourceKeyName: fromKey,
                sourceModifiers: fromModifiers,
                targetKeyCode: action.key,
                targetKeyName: action.name,
                targetModifiers: action.modifiers
            )
            manager.addMapping(mapping)
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
                if let monitor = self.keyCaptureMonitor {
                    NSEvent.removeMonitor(monitor)
                    self.keyCaptureMonitor = nil
                }
                return nil
            } else if self.isCapturingTo {
                self.toKey = self.getKeyName(keyCode: event.keyCode, char: event.charactersIgnoringModifiers ?? "")
                self.toKeyCode = event.keyCode
                self.isCapturingTo = false
                if let monitor = self.keyCaptureMonitor {
                    NSEvent.removeMonitor(monitor)
                    self.keyCaptureMonitor = nil
                }
                return nil
            }
            return event
        }
    }
    
    private func getKeyName(keyCode: UInt16, char: String) -> String {
        let specialKeys: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 117: "Del→",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let name = specialKeys[keyCode] { return name }
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
    
    private func stopKeyCapture() {
        // Event monitors are automatically removed when view disappears
    }
}

// MARK: - Key Event Row
struct KeyEventRow: View {
    let event: KeyEventMonitor.KeyEvent
    
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - Key Remapper using CGEventTap
class KeyRemapper {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    weak var mappingManager: KeyMappingManager?
    
    init(mappingManager: KeyMappingManager) {
        self.mappingManager = mappingManager
    }
    
    func startRemapping() {
        print("🚀 Starting key remapping...")
        print("   Accessibility check: \(AXIsProcessTrusted())")
        
        // Create a session event tap:
        // - .cgSessionEventTap: observes events at the session level (system-wide for the user session)
        // - .headInsertEventTap: gets events early
        // This requires Accessibility permission.
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        
        print("📋 Event mask: \(eventMask)")
        print("📋 Trying to create CGEvent tap...")
        
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                #if DEBUG
                print("🎯 Callback triggered! Type: \(type.rawValue)")
                #endif
                let remapper = Unmanaged<KeyRemapper>.fromOpaque(refcon!).takeUnretainedValue()
                return remapper.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        if tap == nil {
            print("❌ CGEvent.tapCreate returned NIL!")
            print("❌ Possible reasons:")
            print("   1. Accessibility permissions not granted")
            print("   2. Another app is using the event tap")
            print("   3. System security settings blocking")
            print("")
            print("🔍 Current accessibility status: \(AXIsProcessTrusted())")
            return
        }
        
        guard let eventTap = tap else {
            print("❌ Failed to unwrap event tap!")
            return
        }
        
        print("✅ Event tap created successfully!")
        print("   Tap pointer: \(eventTap)")
        
        self.eventTap = eventTap
        
        // Create run loop source and add to current run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        print("✅ Run loop source created")
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        print("✅ Run loop source added to current run loop")
        
        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("✅ Event tap enabled and ready!")
        
        let enabledCount = mappingManager?.mappings.filter { $0.isEnabled }.count ?? 0
        print("🔑 Active mappings: \(enabledCount)")
    }
    
    func stopRemapping() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        
        print("🛑 Event tap disabled")
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("⚠️ Event tap was disabled, re-enabling...")
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }
        
        // Only process key events
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passRetained(event)
        }
        
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let eventFlags = event.flags
        
        // Get enabled mappings from manager
        guard let mappings = mappingManager?.mappings.filter({ $0.isEnabled }) else {
            return Unmanaged.passRetained(event)
        }
        
        // Matching strategy:
        // - Key code must match.
        // - If the rule specifies sourceModifiers: require an exact match for the user-controlled modifiers.
        // - If the rule has no sourceModifiers: reject events where the user is holding any modifiers.
        // This keeps rules unambiguous (e.g., a plain Home rule won't also trigger on Shift+Home).
        for mapping in mappings {
            if keyCode == mapping.sourceKeyCode {
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
                    keyDown: type == .keyDown
                ) else {
                    continue
                }
                
                // Set modifiers:
                // - For navigation actions, targetModifiers is usually set (e.g. ⌘ + ←).
                // - For simple key swaps, targetModifiers is nil and we preserve the original flags.
                if let modifiers = mapping.targetModifiers {
                    newEvent.flags = modifiers
                } else {
                    // Keep original modifiers if no target modifiers specified
                    newEvent.flags = event.flags
                }
                
                return Unmanaged.passRetained(newEvent)
            }
        }
        
        return Unmanaged.passRetained(event)
    }
}

// MARK: - Preview
// Preview csak Xcode-ban működik
// #Preview {
//     ContentView()
//         .frame(width: 600, height: 500)
// }
