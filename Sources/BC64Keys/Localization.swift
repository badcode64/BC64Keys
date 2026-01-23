import Foundation

// MARK: - Supported Languages
enum AppLanguage: String, CaseIterable, Codable {
    case system = "system"
    case english = "en"
    case hungarian = "hu"
    
    var displayName: String {
        switch self {
        case .system: return L10n.current.languageSystem
        case .english: return "English"
        case .hungarian: return "Magyar"
        }
    }
    
    static var current: AppLanguage {
        let saved = UserDefaults.standard.string(forKey: "bc64keys.language") ?? "system"
        return AppLanguage(rawValue: saved) ?? .system
    }
    
    static func save(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: "bc64keys.language")
        L10n.reload()
    }
    
    var effectiveLanguage: String {
        switch self {
        case .system:
            let systemLang = Locale.current.language.languageCode?.identifier ?? "en"
            return ["hu", "en"].contains(systemLang) ? systemLang : "en"
        case .english:
            return "en"
        case .hungarian:
            return "hu"
        }
    }
}

// MARK: - Localization Manager
class L10n: ObservableObject {
    static var shared = L10n()
    static var current: L10n { shared }
    
    @Published private(set) var lang: String
    
    init() {
        self.lang = AppLanguage.current.effectiveLanguage
    }
    
    func setLanguage(_ language: AppLanguage) {
        AppLanguage.save(language)
    }
    
    static func reload() {
        shared.lang = AppLanguage.current.effectiveLanguage
        shared.objectWillChange.send()
    }
    
    private var isHungarian: Bool { lang == "hu" }
    
    // MARK: - App General
    var appName: String { "BC64Keys" }
    
    // MARK: - Tabs
    var tabMonitor: String { isHungarian ? "Figyelő" : "Monitor" }
    var tabMapping: String { isHungarian ? "Módosítás" : "Mapping" }
    var tabSettings: String { isHungarian ? "Beállítások" : "Settings" }
    
    // MARK: - Status Bar
    var statusAccessibility: String { "Accessibility" }
    var statusNoPermission: String { isHungarian ? "Nincs engedély" : "No permission" }
    var statusEnabled: String { isHungarian ? "Engedélyezve" : "Enabled" }
    var statusRemapper: String { "Remapper" }
    var statusRunning: String { isHungarian ? "Fut" : "Running" }
    var statusStopped: String { isHungarian ? "Leállítva" : "Stopped" }
    var statusUpdated: String { isHungarian ? "Frissítve" : "Updated" }
    var statusAccessRequired: String { isHungarian ? "Hozzáférés megadása szükséges" : "Permission required" }
    var statusAppPath: String { isHungarian ? "App útvonal" : "App path" }
    var openSettings: String { isHungarian ? "Beállítások Megnyitása" : "Open Settings" }
    
    // MARK: - Monitor View
    var monitorTitle: String { isHungarian ? "Billentyű Figyelő" : "Key Monitor" }
    var startMonitoring: String { isHungarian ? "Figyelés Indítása" : "Start Monitoring" }
    var stopMonitoring: String { isHungarian ? "Figyelés Leállítása" : "Stop Monitoring" }
    var clear: String { isHungarian ? "Törlés" : "Clear" }
    var monitorHintStart: String { isHungarian ? "Kattints a 'Figyelés Indítása' gombra!" : "Click 'Start Monitoring' button!" }
    var monitorHintActive: String { isHungarian ? "Aktív figyelés - Nyomj le bármilyen billentyűt" : "Active monitoring - Press any key" }
    var noEvents: String { isHungarian ? "Még nincsenek események" : "No events yet" }
    var noEventsHint: String { isHungarian ? "Indítsd el a figyelést és nyomj le billentyűket" : "Start monitoring and press keys" }
    
    // MARK: - Mapping View
    var mappingTitle: String { isHungarian ? "Billentyű Módosítások" : "Key Mappings" }
    var newRule: String { isHungarian ? "Új Szabály" : "New Rule" }
    var noRules: String { isHungarian ? "Még nincsenek szabályok" : "No rules yet" }
    var noRulesHint: String { isHungarian ? "Kattints az 'Új Szabály' gombra" : "Click 'New Rule' button" }
    var keySwap: String { isHungarian ? "Billentyű csere" : "Key swap" }
    var controlAction: String { isHungarian ? "Vezérlő művelet" : "Control action" }
    
    // MARK: - Add Mapping Sheet
    var newKeyRule: String { isHungarian ? "Új Billentyű Szabály" : "New Key Mapping Rule" }
    var ruleType: String { isHungarian ? "Szabály típusa" : "Rule type" }
    var source: String { isHungarian ? "FORRÁS" : "SOURCE" }
    var target: String { isHungarian ? "CÉL" : "TARGET" }
    var pressKey: String { isHungarian ? "Nyomj egy billentyűt..." : "Press a key..." }
    var clickHere: String { isHungarian ? "Kattints ide" : "Click here" }
    var selectAction: String { isHungarian ? "Válassz műveletet" : "Select action" }
    var select: String { isHungarian ? "Válassz..." : "Select..." }
    var cancel: String { isHungarian ? "Mégse" : "Cancel" }
    var save: String { isHungarian ? "Mentés" : "Save" }
    
    // MARK: - Settings View
    var settingsTitle: String { isHungarian ? "Beállítások" : "Settings" }
    var launchAtLogin: String { isHungarian ? "Indítás bejelentkezéskor" : "Launch at login" }
    var launchAtLoginDescription: String { isHungarian ? "Automatikus indítás rendszerindításkor" : "Start automatically when you log in" }
    var launchAtLoginHint: String { isHungarian ? "Az alkalmazás automatikusan elindul a számítógép bekapcsolásakor." : "The app will start automatically when you turn on your computer." }
    var language: String { isHungarian ? "Nyelv" : "Language" }
    var languageHint: String { isHungarian ? "A nyelv azonnal változik." : "Language changes immediately." }
    var support: String { isHungarian ? "Támogatás" : "Support" }
    var supportDescription: String { isHungarian ? "Ha tetszik az app, támogass egy kávéval! ☕" : "If you like this app, buy me a coffee! ☕" }
    var supportButton: String { isHungarian ? "Támogatom" : "Buy Me a Coffee" }
    var about: String { isHungarian ? "Névjegy" : "About" }
    var aboutDescription: String { isHungarian ? "Billentyűzet módosító alkalmazás Windows-ról Mac-re váltók számára." : "Keyboard remapping application for Windows to Mac switchers." }
    
    // MARK: - Language Selection
    var languageSystem: String { isHungarian ? "Rendszer" : "System" }
}
