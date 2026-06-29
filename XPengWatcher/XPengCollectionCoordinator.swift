import AppKit
import Foundation

enum XPengCollectionError: LocalizedError {
    case accessibilityPermissionMissing
    case appNotFound
    case appDidNotLaunch
    case windowDidNotAppear
    case telemetryUnavailable
    case database(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing: String(localized: "Accessibility permission is required")
        case .appNotFound: String(localized: "The XPENG application could not be found")
        case .appDidNotLaunch: String(localized: "XPENG could not be launched")
        case .windowDidNotAppear: String(localized: "The XPENG window did not appear")
        case .telemetryUnavailable: String(localized: "XPENG did not provide any data")
        case .database(let message): String(format: String(localized: "Database error: %@"), message)
        }
    }
}

enum XPengCollectionCoordinator {
    private static let xpengBundleIdentifier = "com.xiaopeng.XiaoPengQiChe.International"

    static func collect(settings: CollectionSettings, completion: @escaping (Result<TelemetrySnapshot, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                guard AXIsProcessTrusted() else { throw XPengCollectionError.accessibilityPermissionMissing }
                try FileManager.default.createDirectory(
                    at: settings.databaseURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let app = try launchXPeng()
                defer { quitXPeng(app) }

                guard waitForWindow(of: app, timeout: 60) else {
                    throw XPengCollectionError.windowDidNotAppear
                }

                // The window can exist before the vehicle data has finished refreshing.
                Thread.sleep(forTimeInterval: 5)

                let password = settings.mqttPassword.isEmpty ? (try? KeychainPassword.load()) ?? "" : settings.mqttPassword
                let noOdometerURL = settings.databaseURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("noodometer")
                let readOdometerWithForeground = !FileManager.default.fileExists(atPath: noOdometerURL.path)
                let config = Config(
                    mqttHost: settings.mqttEnabled && !settings.mqttHost.isEmpty ? settings.mqttHost : nil,
                    mqttPort: settings.mqttPort,
                    mqttUser: settings.mqttUser.isEmpty ? nil : settings.mqttUser,
                    mqttPassword: password.isEmpty ? nil : password,
                    mqttTopic: settings.mqttTopic,
                    publishToMqtt: settings.mqttEnabled && !settings.mqttHost.isEmpty,
                    loopIntervalSeconds: nil,
                    verbose: false,
                    readOdometerWithForeground: readOdometerWithForeground,
                    batteryCapacityKWh: settings.batteryCapacityKWh,
                    sohPercent: settings.sohPercent,
                    databasePath: settings.databaseURL.path
                )

                var collectionError: Error?
                let succeeded = readAndPublishTelemetry(config: config) { collectionError = $0 }
                guard succeeded else { throw collectionError ?? XPengCollectionError.telemetryUnavailable }

                let database = try TelemetryDatabase(path: settings.databaseURL.path)
                guard let telemetry = try database.latestTelemetry() else {
                    throw XPengCollectionError.telemetryUnavailable
                }

                completion(.success(TelemetrySnapshot(
                    socPercent: telemetry.socPercent,
                    rangeKm: telemetry.rangeKm,
                    odometerKm: telemetry.odometerKm,
                    charging: telemetry.charging
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func launchXPeng() throws -> NSRunningApplication {
        if let running = runningXPeng() {
            return running
        }

        let standardURL = URL(fileURLWithPath: "/Applications/XPENG.app", isDirectory: true)
        let applicationURL: URL?
        if FileManager.default.fileExists(atPath: standardURL.path) {
            applicationURL = standardURL
        } else {
            let userURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/XPENG.app", isDirectory: true)
            applicationURL = FileManager.default.fileExists(atPath: userURL.path) ? userURL : nil
        }

        guard let applicationURL else {
            throw XPengCollectionError.appNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let semaphore = DispatchSemaphore(value: 0)
        var launchedApp: NSRunningApplication?
        var launchError: Error?

        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { app, error in
            launchedApp = app
            launchError = error
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw XPengCollectionError.appDidNotLaunch
        }
        if let launchError { throw launchError }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let running = runningXPeng() { return running }
            if let launchedApp, !launchedApp.isTerminated { return launchedApp }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw XPengCollectionError.appDidNotLaunch
    }

    private static func runningXPeng() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == xpengBundleIdentifier || $0.localizedName?.caseInsensitiveCompare("XPENG") == .orderedSame
        }
    }

    private static func waitForWindow(of app: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let currentApp = runningXPeng() ?? app
            if !currentApp.isTerminated {
                let element = AXUIElementCreateApplication(currentApp.processIdentifier)
                if !getWindows(element).isEmpty { return true }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private static func quitXPeng(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        app.terminate()
        let deadline = Date().addingTimeInterval(5)
        while !app.isTerminated && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !app.isTerminated { app.forceTerminate() }
    }
}
