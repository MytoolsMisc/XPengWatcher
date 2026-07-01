import AppKit
import ApplicationServices
import Combine
import Foundation

struct TelemetrySnapshot {
    let socPercent: Int?
    let rangeKm: Int?
    let odometerKm: Int?
    let charging: Bool?

    var soc: String { socPercent.map { "\($0) %" } ?? "—" }
    var range: String { rangeKm.map { "\($0) km" } ?? "—" }
    var odometer: String { odometerKm.map { "\($0) km" } ?? "—" }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var isCollecting = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var latestTelemetry: TelemetrySnapshot?
    @Published private(set) var analytics = AnalyticsSnapshot(latestTrip: nil, latestCharge: nil)
    @Published private(set) var summaryReport = String(localized: "No report available.")
    @Published private(set) var lastCollectionDate: Date?
    @Published private(set) var lastError: String?

    @Published var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: Keys.intervalMinutes); restartTimer() }
    }
    @Published var mqttEnabled: Bool {
        didSet { defaults.set(mqttEnabled, forKey: Keys.mqttEnabled) }
    }
    @Published var mqttHost: String {
        didSet { defaults.set(mqttHost, forKey: Keys.mqttHost) }
    }
    @Published var mqttPort: Int {
        didSet { defaults.set(mqttPort, forKey: Keys.mqttPort) }
    }
    @Published var mqttUser: String {
        didSet { defaults.set(mqttUser, forKey: Keys.mqttUser) }
    }
    @Published var mqttPassword: String = ""
    @Published var mqttTopic: String {
        didSet { defaults.set(mqttTopic, forKey: Keys.mqttTopic) }
    }
    @Published var batteryCapacityKWh: Double {
        didSet { defaults.set(batteryCapacityKWh, forKey: Keys.batteryCapacityKWh) }
    }
    @Published var sohPercent: Double {
        didSet { defaults.set(sohPercent, forKey: Keys.sohPercent) }
    }
    @Published var httpServerEnabled: Bool {
        didSet { defaults.set(httpServerEnabled, forKey: Keys.httpServerEnabled); updateHTTPServer() }
    }
    @Published var httpServerPort: Int {
        didSet { defaults.set(httpServerPort, forKey: Keys.httpServerPort); updateHTTPServer() }
    }

    private enum Keys {
        static let intervalMinutes = "intervalMinutes"
        static let mqttEnabled = "mqttEnabled"
        static let mqttHost = "mqttHost"
        static let mqttPort = "mqttPort"
        static let mqttUser = "mqttUser"
        static let mqttTopic = "mqttTopic"
        static let batteryCapacityKWh = "batteryCapacityKWh"
        static let sohPercent = "sohPercent"
        static let httpServerEnabled = "httpServerEnabled"
        static let httpServerPort = "httpServerPort"
    }

    private let defaults = UserDefaults.standard
    private var timer: AnyCancellable?
    private var hasStarted = false
    private let reportHTTPServer = ReportHTTPServer()

    init() {
        let savedInterval = defaults.integer(forKey: Keys.intervalMinutes)
        intervalMinutes = savedInterval > 0 ? savedInterval : 5
        mqttEnabled = defaults.bool(forKey: Keys.mqttEnabled)
        mqttHost = defaults.string(forKey: Keys.mqttHost) ?? ""
        let savedPort = defaults.integer(forKey: Keys.mqttPort)
        mqttPort = savedPort > 0 ? savedPort : 1883
        mqttUser = defaults.string(forKey: Keys.mqttUser) ?? ""
        mqttTopic = defaults.string(forKey: Keys.mqttTopic) ?? "xpeng/g6/telemetry"
        let savedCapacity = defaults.double(forKey: Keys.batteryCapacityKWh)
        batteryCapacityKWh = savedCapacity > 0 ? savedCapacity : 80
        let savedSOH = defaults.double(forKey: Keys.sohPercent)
        sohPercent = savedSOH > 0 ? savedSOH : 100
        httpServerEnabled = defaults.bool(forKey: Keys.httpServerEnabled)
        let savedHTTPPort = defaults.integer(forKey: Keys.httpServerPort)
        httpServerPort = savedHTTPPort > 0 ? savedHTTPPort : 8080
    }

    var menuBarTitle: String {
        guard let soc = latestTelemetry?.socPercent else { return "XPeng" }
        return "\(soc)%"
    }

    var menuBarSymbol: String {
        if isCollecting { return "arrow.triangle.2.circlepath" }
        if lastError != nil { return "exclamationmark.triangle.fill" }
        if latestTelemetry?.charging == true { return "bolt.car.fill" }
        return "car.fill"
    }

    var statusTitle: String {
        if isCollecting { return String(localized: "Reading XPeng…") }
        if let lastError { return lastError }
        return lastCollectionDate == nil
            ? String(localized: "Waiting for the first collection")
            : String(localized: "Last collection succeeded")
    }

    var statusDetail: String {
        guard let lastCollectionDate else {
            return String(format: String(localized: "Every %d minutes"), intervalMinutes)
        }
        return lastCollectionDate.formatted(date: .abbreviated, time: .standard)
    }

    var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("XPengWatcher", isDirectory: true)
            .appendingPathComponent("xpeng.db")
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        requestAccessibilityIfNeeded()
        refreshSummaryReport()
        updateHTTPServer()
        restartTimer()
        collectNow()
    }

    func collectNow() {
        guard !isCollecting else { return }
        accessibilityGranted = AXIsProcessTrusted()
        guard accessibilityGranted else {
            lastError = XPengCollectionError.accessibilityPermissionMissing.localizedDescription
            requestAccessibilityIfNeeded()
            return
        }
        isCollecting = true
        lastError = nil

        let settings = CollectionSettings(
            databaseURL: databaseURL,
            mqttEnabled: mqttEnabled,
            mqttHost: mqttHost,
            mqttPort: mqttPort,
            mqttUser: mqttUser,
            mqttPassword: mqttPassword,
            mqttTopic: mqttTopic,
            batteryCapacityKWh: batteryCapacityKWh,
            sohPercent: sohPercent
        )

        XPengCollectionCoordinator.collect(settings: settings) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isCollecting = false
                switch result {
                case .success(let snapshot):
                    self.latestTelemetry = snapshot
                    self.lastCollectionDate = Date()
                    self.analytics = (try? AnalyticsSnapshot.load(
                        from: self.databaseURL,
                        batteryCapacityKWh: self.batteryCapacityKWh,
                        sohPercent: self.sohPercent
                    )) ?? AnalyticsSnapshot(latestTrip: nil, latestCharge: nil)
                    self.refreshSummaryReport()
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func savePassword() {
        do {
            try KeychainPassword.save(mqttPassword)
        } catch {
            lastError = String(localized: "Unable to save the MQTT password")
        }
    }

    func revealDatabase() {
        let folder = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let selection = FileManager.default.fileExists(atPath: databaseURL.path) ? databaseURL : folder
        NSWorkspace.shared.activateFileViewerSelecting([selection])
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshSummaryReport() {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            let reports = Dictionary(uniqueKeysWithValues: ReportLanguage.allCases.map {
                ($0, missingDatabaseMessage(language: $0))
            })
            summaryReport = reports[ReportLanguage.application] ?? reports[.english]!
            reportHTTPServer.updateReports(reports)
            reportHTTPServer.updateDashboard(DashboardSnapshot(calendarByMonth: [:], dayByDate: [:]))
            return
        }
        do {
            var reports: [ReportLanguage: String] = [:]
            for language in ReportLanguage.allCases {
                reports[language] = try SummaryReportBuilder.make(
                    databaseURL: databaseURL,
                    batteryCapacityKWh: batteryCapacityKWh,
                    sohPercent: sohPercent,
                    language: language
                )
            }
            summaryReport = reports[ReportLanguage.application] ?? reports[.english]!
            reportHTTPServer.updateReports(reports)
            let dashboard = try DashboardDataBuilder.make(
                databaseURL: databaseURL,
                batteryCapacityKWh: batteryCapacityKWh,
                sohPercent: sohPercent
            )
            reportHTTPServer.updateDashboard(dashboard)
        } catch {
            let reports = Dictionary(uniqueKeysWithValues: ReportLanguage.allCases.map {
                ($0, reportFailureMessage(language: $0, error: error))
            })
            summaryReport = reports[ReportLanguage.application] ?? reports[.english]!
            reportHTTPServer.updateReports(reports)
        }
    }

    private func missingDatabaseMessage(language: ReportLanguage) -> String {
        let prefix: String
        switch language {
        case .english: prefix = "The database does not exist yet:"
        case .french: prefix = "La base de données n’existe pas encore :"
        case .portuguese: prefix = "A base de dados ainda não existe:"
        case .spanish: prefix = "La base de datos todavía no existe:"
        case .german: prefix = "Die Datenbank existiert noch nicht:"
        case .dutch: prefix = "De database bestaat nog niet:"
        case .italian: prefix = "Il database non esiste ancora:"
        case .danish: prefix = "Databasen findes ikke endnu:"
        }
        return "\(prefix)\n\(databaseURL.path)"
    }

    private func reportFailureMessage(language: ReportLanguage, error: Error) -> String {
        let prefix: String
        switch language {
        case .english: prefix = "Unable to generate the report:"
        case .french: prefix = "Impossible de générer le rapport :"
        case .portuguese: prefix = "Não foi possível gerar o relatório:"
        case .spanish: prefix = "No se pudo generar el informe:"
        case .german: prefix = "Der Bericht konnte nicht erstellt werden:"
        case .dutch: prefix = "Het rapport kon niet worden gegenereerd:"
        case .italian: prefix = "Impossibile generare il rapporto:"
        case .danish: prefix = "Rapporten kunne ikke genereres:"
        }
        return "\(prefix)\n\(error.localizedDescription)"
    }

    func openHTTPReport() {
        guard let url = URL(string: "http://localhost:\(httpServerPort)/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func updateHTTPServer() {
        guard hasStarted else { return }
        reportHTTPServer.stop()
        guard httpServerEnabled else { return }
        guard (1...65535).contains(httpServerPort) else {
            lastError = String(localized: "HTTP port must be between 1 and 65535")
            return
        }
        do {
            try reportHTTPServer.start(port: UInt16(httpServerPort))
        } catch {
            lastError = String(format: String(localized: "HTTP server: %@"), error.localizedDescription)
        }
    }

    private func restartTimer() {
        timer?.cancel()
        guard hasStarted else { return }
        timer = Timer.publish(
            every: TimeInterval(max(intervalMinutes, 1) * 60),
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in self?.collectNow() }
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

struct CollectionSettings: Sendable {
    let databaseURL: URL
    let mqttEnabled: Bool
    let mqttHost: String
    let mqttPort: Int
    let mqttUser: String
    let mqttPassword: String
    let mqttTopic: String
    let batteryCapacityKWh: Double
    let sohPercent: Double
}
