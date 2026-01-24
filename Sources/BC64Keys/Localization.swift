import Foundation

// MARK: - Supported Languages
enum AppLanguage: String, CaseIterable, Codable {
    case system = "system"
    case english = "en"
    case hungarian = "hu"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case japanese = "ja"
    case chinese = "zh"
    case dutch = "nl"
    case portuguese = "pt"
    case swedish = "sv"
    case danish = "da"
    case finnish = "fi"
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case romanian = "ro"
    case greek = "el"
    case korean = "ko"
    case arabic = "ar"
    case hebrew = "he"
    case turkish = "tr"
    
    var displayName: String {
        switch self {
        case .system: return L10n.current.languageSystem
        case .english: return "English"
        case .hungarian: return "Magyar"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        case .japanese: return "日本語"
        case .chinese: return "中文"
        case .dutch: return "Nederlands"
        case .portuguese: return "Português"
        case .swedish: return "Svenska"
        case .danish: return "Dansk"
        case .finnish: return "Suomi"
        case .polish: return "Polski"
        case .czech: return "Čeština"
        case .slovak: return "Slovenčina"
        case .romanian: return "Română"
        case .greek: return "Ελληνικά"
        case .korean: return "한국어"
        case .arabic: return "العربية"
        case .hebrew: return "עברית"
        case .turkish: return "Türkçe"
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
            // Compatible with macOS 11+
            let systemLang: String
            if #available(macOS 13, *) {
                systemLang = Locale.current.language.languageCode?.identifier ?? "en"
            } else {
                systemLang = Locale.current.languageCode ?? "en"
            }
            // Support all major macOS markets
            let supported = ["hu", "en", "de", "fr", "es", "it", "ja", "zh", "nl", "pt", "sv", "da", "fi", "pl", "cs", "sk", "ro", "el", "ko", "ar", "he", "tr"]
            return supported.contains(systemLang) ? systemLang : "en"
        case .english: return "en"
        case .hungarian: return "hu"
        case .german: return "de"
        case .french: return "fr"
        case .spanish: return "es"
        case .italian: return "it"
        case .japanese: return "ja"
        case .chinese: return "zh"
        case .dutch: return "nl"
        case .portuguese: return "pt"
        case .swedish: return "sv"
        case .danish: return "da"
        case .finnish: return "fi"
        case .polish: return "pl"
        case .czech: return "cs"
        case .slovak: return "sk"
        case .romanian: return "ro"
        case .greek: return "el"
        case .korean: return "ko"
        case .arabic: return "ar"
        case .hebrew: return "he"
        case .turkish: return "tr"
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
    
    // Helper function for multi-language strings
    // Falls back to English if translation is missing for a language
    private func tr(_ translations: [String: String]) -> String {
        // Try current language first
        if let translation = translations[lang], !translation.isEmpty {
            return translation
        }
        // Fallback to English
        return translations["en"] ?? ""
    }
    
    // MARK: - App General
    var appName: String { "BC64Keys" }
    
    // MARK: - Tabs
    var tabMonitor: String {
        tr(["en": "Monitor", "hu": "Figyelő", "de": "Monitor", "fr": "Moniteur", 
            "es": "Monitor", "it": "Monitor", "ja": "モニター", "zh": "监视器",
            "nl": "Monitor", "pt": "Monitor", "sv": "Övervakare", "pl": "Monitor",
            "ko": "모니터", "ar": "مراقب", "tr": "İzleyici"])
    }
    var tabMapping: String {
        tr(["en": "Mapping", "hu": "Módosítás", "de": "Zuordnung", "fr": "Mappage",
            "es": "Mapeo", "it": "Mappatura", "ja": "マッピング", "zh": "映射",
            "nl": "Mapping", "pt": "Mapeamento", "sv": "Mappning", "pl": "Mapowanie",
            "ko": "매핑", "ar": "تعيين", "tr": "Eşleme"])
    }
    var tabSettings: String {
        tr(["en": "Settings", "hu": "Beállítások", "de": "Einstellungen", "fr": "Paramètres",
            "es": "Ajustes", "it": "Impostazioni", "ja": "設定", "zh": "设置",
            "nl": "Instellingen", "pt": "Configurações", "sv": "Inställningar", "pl": "Ustawienia",
            "ko": "설정", "ar": "الإعدادات", "tr": "Ayarlar"])
    }
    
    // MARK: - Status Bar
    var statusAccessibility: String { "Accessibility" }
    var statusNoPermission: String {
        tr(["en": "No permission", "hu": "Nincs engedély", "de": "Keine Berechtigung", "fr": "Pas de permission",
            "es": "Sin permiso", "it": "Nessun permesso", "ja": "権限なし", "zh": "无权限"])
    }
    var statusEnabled: String {
        tr(["en": "Enabled", "hu": "Engedélyezve", "de": "Aktiviert", "fr": "Activé",
            "es": "Habilitado", "it": "Abilitato", "ja": "有効", "zh": "已启用"])
    }
    var statusRemapper: String { "Remapper" }
    var statusRunning: String {
        tr(["en": "Running", "hu": "Fut", "de": "Läuft", "fr": "En cours",
            "es": "Ejecutando", "it": "In esecuzione", "ja": "実行中", "zh": "运行中"])
    }
    var statusStopped: String {
        tr(["en": "Stopped", "hu": "Leállítva", "de": "Gestoppt", "fr": "Arrêté",
            "es": "Detenido", "it": "Fermato", "ja": "停止", "zh": "已停止"])
    }
    var statusUpdated: String {
        tr(["en": "Updated", "hu": "Frissítve", "de": "Aktualisiert", "fr": "Mis à jour",
            "es": "Actualizado", "it": "Aggiornato", "ja": "更新済み", "zh": "已更新"])
    }
    var statusAccessRequired: String {
        tr(["en": "Permission required", "hu": "Hozzáférés megadása szükséges", "de": "Berechtigung erforderlich", "fr": "Permission requise",
            "es": "Permiso requerido", "it": "Permesso richiesto", "ja": "権限が必要", "zh": "需要权限"])
    }
    var statusAppPath: String {
        tr(["en": "App path", "hu": "App útvonal", "de": "App-Pfad", "fr": "Chemin de l'app",
            "es": "Ruta de la app", "it": "Percorso app", "ja": "アプリパス", "zh": "应用路径"])
    }
    var openSettings: String {
        tr(["en": "Open Settings", "hu": "Beállítások Megnyitása", "de": "Einstellungen öffnen", "fr": "Ouvrir les paramètres",
            "es": "Abrir ajustes", "it": "Apri impostazioni", "ja": "設定を開く", "zh": "打开设置"])
    }
    
    // MARK: - Monitor View
    var monitorTitle: String {
        tr(["en": "Key Monitor", "hu": "Billentyű Figyelő", "de": "Tastaturmonitor", "fr": "Moniteur de clavier",
            "es": "Monitor de teclado", "it": "Monitor tastiera", "ja": "キーモニター", "zh": "键盘监视器"])
    }
    var startMonitoring: String {
        tr(["en": "Start Monitoring", "hu": "Figyelés Indítása", "de": "Überwachung starten", "fr": "Démarrer la surveillance",
            "es": "Iniciar monitoreo", "it": "Avvia monitoraggio", "ja": "監視開始", "zh": "开始监视"])
    }
    var stopMonitoring: String {
        tr(["en": "Stop Monitoring", "hu": "Figyelés Leállítása", "de": "Überwachung stoppen", "fr": "Arrêter la surveillance",
            "es": "Detener monitoreo", "it": "Ferma monitoraggio", "ja": "監視停止", "zh": "停止监视"])
    }
    var clear: String {
        tr(["en": "Clear", "hu": "Törlés", "de": "Löschen", "fr": "Effacer",
            "es": "Limpiar", "it": "Cancella", "ja": "クリア", "zh": "清除"])
    }
    var monitorHintStart: String {
        tr(["en": "Click 'Start Monitoring' button!", "hu": "Kattints a 'Figyelés Indítása' gombra!", "de": "Klicken Sie auf 'Überwachung starten'!", "fr": "Cliquez sur 'Démarrer la surveillance'!",
            "es": "¡Haz clic en 'Iniciar monitoreo'!", "it": "Clicca su 'Avvia monitoraggio'!", "ja": "「監視開始」ボタンをクリック！", "zh": "点击'开始监视'按钮！"])
    }
    var monitorHintActive: String {
        tr(["en": "Active monitoring - Press any key", "hu": "Aktív figyelés - Nyomj le bármilyen billentyűt", "de": "Aktive Überwachung - Drücken Sie eine Taste", "fr": "Surveillance active - Appuyez sur une touche",
            "es": "Monitoreo activo - Presione cualquier tecla", "it": "Monitoraggio attivo - Premi un tasto", "ja": "監視中 - 任意のキーを押してください", "zh": "监视中 - 按任意键"])
    }
    var noEvents: String {
        tr(["en": "No events yet", "hu": "Még nincsenek események", "de": "Noch keine Ereignisse", "fr": "Aucun événement",
            "es": "Sin eventos aún", "it": "Nessun evento", "ja": "イベントなし", "zh": "暂无事件"])
    }
    var noEventsHint: String {
        tr(["en": "Start monitoring and press keys", "hu": "Indítsd el a figyelést és nyomj le billentyűket", "de": "Überwachung starten und Tasten drücken", "fr": "Démarrez la surveillance et appuyez sur des touches",
            "es": "Inicie el monitoreo y presione teclas", "it": "Avvia il monitoraggio e premi i tasti", "ja": "監視を開始してキーを押してください", "zh": "开始监视并按键"])
    }
    
    // MARK: - Mapping View
    var mappingTitle: String {
        tr(["en": "Key Mappings", "hu": "Billentyű Módosítások", "de": "Tastenzuordnungen", "fr": "Mappages de touches",
            "es": "Mapeos de teclas", "it": "Mappature dei tasti", "ja": "キーマッピング", "zh": "键映射"])
    }
    var newRule: String {
        tr(["en": "New Rule", "hu": "Új Szabály", "de": "Neue Regel", "fr": "Nouvelle règle",
            "es": "Nueva regla", "it": "Nuova regola", "ja": "新規ルール", "zh": "新规则"])
    }
    var noRules: String {
        tr(["en": "No rules yet", "hu": "Még nincsenek szabályok", "de": "Noch keine Regeln", "fr": "Aucune règle",
            "es": "Sin reglas aún", "it": "Nessuna regola", "ja": "ルールなし", "zh": "暂无规则"])
    }
    var noRulesHint: String {
        tr(["en": "Click 'New Rule' button", "hu": "Kattints az 'Új Szabály' gombra", "de": "Klicken Sie auf 'Neue Regel'", "fr": "Cliquez sur 'Nouvelle règle'",
            "es": "Haz clic en 'Nueva regla'", "it": "Clicca su 'Nuova regola'", "ja": "「新規ルール」をクリック", "zh": "点击'新规则'"])
    }
    var keySwap: String {
        tr(["en": "Key swap", "hu": "Billentyű csere", "de": "Tastentausch", "fr": "Échange de touches",
            "es": "Intercambio de teclas", "it": "Scambio tasti", "ja": "キー交換", "zh": "键交换"])
    }
    var controlAction: String {
        tr(["en": "Control action", "hu": "Vezérlő művelet", "de": "Steuerungsaktion", "fr": "Action de contrôle",
            "es": "Acción de control", "it": "Azione di controllo", "ja": "制御アクション", "zh": "控制操作"])
    }
    
    // MARK: - Add Mapping Sheet
    var newKeyRule: String {
        tr(["en": "New Key Mapping Rule", "hu": "Új Billentyű Szabály", "de": "Neue Tastenzuordnungsregel", "fr": "Nouvelle règle de mappage",
            "es": "Nueva regla de mapeo", "it": "Nuova regola di mappatura", "ja": "新しいキーマッピングルール", "zh": "新建键映射规则"])
    }
    var ruleType: String {
        tr(["en": "Rule type", "hu": "Szabály típusa", "de": "Regeltyp", "fr": "Type de règle",
            "es": "Tipo de regla", "it": "Tipo di regola", "ja": "ルールタイプ", "zh": "规则类型"])
    }
    var source: String {
        tr(["en": "SOURCE", "hu": "FORRÁS", "de": "QUELLE", "fr": "SOURCE",
            "es": "ORIGEN", "it": "SORGENTE", "ja": "ソース", "zh": "源"])
    }
    var target: String {
        tr(["en": "TARGET", "hu": "CÉL", "de": "ZIEL", "fr": "CIBLE",
            "es": "DESTINO", "it": "DESTINAZIONE", "ja": "ターゲット", "zh": "目标"])
    }
    var pressKey: String {
        tr(["en": "Press a key...", "hu": "Nyomj egy billentyűt...", "de": "Taste drücken...", "fr": "Appuyez sur une touche...",
            "es": "Presione una tecla...", "it": "Premi un tasto...", "ja": "キーを押してください...", "zh": "按任意键..."])
    }
    var clickHere: String {
        tr(["en": "Click here", "hu": "Kattints ide", "de": "Hier klicken", "fr": "Cliquez ici",
            "es": "Haz clic aquí", "it": "Clicca qui", "ja": "ここをクリック", "zh": "点击此处"])
    }
    var selectAction: String {
        tr(["en": "Select action", "hu": "Válassz műveletet", "de": "Aktion wählen", "fr": "Sélectionner une action",
            "es": "Seleccionar acción", "it": "Seleziona azione", "ja": "アクションを選択", "zh": "选择操作"])
    }
    var select: String {
        tr(["en": "Select...", "hu": "Válassz...", "de": "Wählen...", "fr": "Sélectionner...",
            "es": "Seleccionar...", "it": "Seleziona...", "ja": "選択...", "zh": "选择..."])
    }
    var cancel: String {
        tr(["en": "Cancel", "hu": "Mégse", "de": "Abbrechen", "fr": "Annuler",
            "es": "Cancelar", "it": "Annulla", "ja": "キャンセル", "zh": "取消",
            "nl": "Annuleren", "pt": "Cancelar", "sv": "Avbryt", "pl": "Anuluj",
            "ko": "취소", "ar": "إلغاء", "tr": "İptal"])
    }
    var save: String {
        tr(["en": "Save", "hu": "Mentés", "de": "Speichern", "fr": "Enregistrer",
            "es": "Guardar", "it": "Salva", "ja": "保存", "zh": "保存",
            "nl": "Opslaan", "pt": "Salvar", "sv": "Spara", "pl": "Zapisz",
            "ko": "저장", "ar": "حفظ", "tr": "Kaydet"])
    }
    
    // MARK: - Settings View
    var settingsTitle: String {
        tr(["en": "Settings", "hu": "Beállítások", "de": "Einstellungen", "fr": "Paramètres",
            "es": "Ajustes", "it": "Impostazioni", "ja": "設定", "zh": "设置"])
    }
    var launchAtLogin: String {
        tr(["en": "Launch at login", "hu": "Indítás bejelentkezéskor", "de": "Bei Anmeldung starten", "fr": "Lancer à la connexion",
            "es": "Iniciar al iniciar sesión", "it": "Avvia all'accesso", "ja": "ログイン時に起動", "zh": "登录时启动"])
    }
    var launchAtLoginDescription: String {
        tr(["en": "Start automatically when you log in", "hu": "Automatikus indítás rendszerindításkor", "de": "Automatisch starten bei Anmeldung", "fr": "Démarrer automatiquement à la connexion",
            "es": "Iniciar automáticamente al iniciar sesión", "it": "Avvia automaticamente all'accesso", "ja": "ログイン時に自動起動", "zh": "登录时自动启动"])
    }
    var launchAtLoginHint: String {
        tr(["en": "The app will start automatically when you turn on your computer.", "hu": "Az alkalmazás automatikusan elindul a számítógép bekapcsolásakor.", "de": "Die App startet automatisch beim Einschalten des Computers.", "fr": "L'application démarre automatiquement au démarrage de l'ordinateur.",
            "es": "La aplicación se iniciará automáticamente al encender la computadora.", "it": "L'app si avvierà automaticamente all'accensione del computer.", "ja": "コンピュータの起動時にアプリが自動的に起動します。", "zh": "打开计算机时应用将自动启动。"])
    }
    var language: String {
        tr(["en": "Language", "hu": "Nyelv", "de": "Sprache", "fr": "Langue",
            "es": "Idioma", "it": "Lingua", "ja": "言語", "zh": "语言",
            "nl": "Taal", "pt": "Idioma", "sv": "Språk", "pl": "Język",
            "ko": "언어", "ar": "اللغة", "tr": "Dil"])
    }
    var languageHint: String {
        tr(["en": "Language changes immediately.", "hu": "A nyelv azonnal változik.", "de": "Sprache ändert sich sofort.", "fr": "La langue change immédiatement.",
            "es": "El idioma cambia inmediatamente.", "it": "La lingua cambia immediatamente.", "ja": "言語はすぐに変更されます。", "zh": "语言立即更改。"])
    }
    var debugLogging: String {
        tr(["en": "Debug logging", "hu": "Hibakeresési napló", "de": "Debug-Protokollierung", "fr": "Journalisation de débogage",
            "es": "Registro de depuración", "it": "Registrazione debug", "ja": "デバッグログ", "zh": "调试日志"])
    }
    var debugLoggingDescription: String {
        tr(["en": "Enable detailed logging", "hu": "Részletes naplózás engedélyezése", "de": "Detaillierte Protokollierung aktivieren", "fr": "Activer la journalisation détaillée",
            "es": "Habilitar registro detallado", "it": "Abilita registrazione dettagliata", "ja": "詳細ログを有効化", "zh": "启用详细日志"])
    }
    var debugLoggingHint: String {
        tr(["en": "⚠️ For debugging only! Log file: ~/Library/Logs/BC64Keys/", "hu": "⚠️ Csak hibakereséshez! Naplófájl helye: ~/Library/Logs/BC64Keys/", "de": "⚠️ Nur zum Debuggen! Protokolldatei: ~/Library/Logs/BC64Keys/", "fr": "⚠️ Pour le débogage uniquement! Fichier journal: ~/Library/Logs/BC64Keys/",
            "es": "⚠️ ¡Solo para depuración! Archivo de registro: ~/Library/Logs/BC64Keys/", "it": "⚠️ Solo per debug! File di log: ~/Library/Logs/BC64Keys/", "ja": "⚠️ デバッグ専用！ログファイル: ~/Library/Logs/BC64Keys/", "zh": "⚠️ 仅用于调试！日志文件：~/Library/Logs/BC64Keys/"])
    }
    var support: String {
        tr(["en": "Support", "hu": "Támogatás", "de": "Unterstützung", "fr": "Soutien",
            "es": "Soporte", "it": "Supporto", "ja": "サポート", "zh": "支持"])
    }
    var supportDescription: String {
        tr(["en": "If you like this app, buy me a coffee! ☕", "hu": "Ha tetszik az app, támogass egy kávéval! ☕", "de": "Wenn Ihnen diese App gefällt, spendieren Sie mir einen Kaffee! ☕", "fr": "Si vous aimez cette app, offrez-moi un café! ☕",
            "es": "¡Si te gusta esta app, cómprame un café! ☕", "it": "Se ti piace questa app, offrimi un caffè! ☕", "ja": "このアプリが気に入ったら、コーヒーをおごってください！ ☕", "zh": "如果您喜欢这个应用，请给我买杯咖啡！ ☕"])
    }
    var supportButton: String {
        tr(["en": "Buy Me a Coffee", "hu": "Támogatom", "de": "Spendiere einen Kaffee", "fr": "Offrir un café",
            "es": "Cómprame un café", "it": "Offrimi un caffè", "ja": "コーヒーをおごる", "zh": "给我买杯咖啡"])
    }
    var about: String {
        tr(["en": "About", "hu": "Névjegy", "de": "Über", "fr": "À propos",
            "es": "Acerca de", "it": "Informazioni", "ja": "について", "zh": "关于"])
    }
    var aboutDescription: String {
        tr(["en": "Keyboard remapping application for Windows to Mac switchers.", "hu": "Billentyűzet módosító alkalmazás Windows-ról Mac-re váltók számára.", "de": "Tastaturumlegungs-App für Umsteiger von Windows zu Mac.", "fr": "Application de remappage de clavier pour les utilisateurs passant de Windows à Mac.",
            "es": "Aplicación de remapeo de teclado para usuarios que cambian de Windows a Mac.", "it": "Applicazione di rimappatura della tastiera per chi passa da Windows a Mac.", "ja": "WindowsからMacに移行する人のためのキーボードリマッピングアプリ。", "zh": "为从Windows切换到Mac的用户提供的键盘重映射应用程序。"])
    }
    
    // MARK: - Language Selection
    var languageSystem: String {
        tr(["en": "System", "hu": "Rendszer", "de": "System", "fr": "Système",
            "es": "Sistema", "it": "Sistema", "ja": "システム", "zh": "系统",
            "nl": "Systeem", "pt": "Sistema", "sv": "System", "pl": "System",
            "ko": "시스템", "ar": "النظام", "tr": "Sistem"])
    }
}
