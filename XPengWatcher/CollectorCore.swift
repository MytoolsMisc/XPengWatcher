import Foundation
import AppKit
import ApplicationServices
import Darwin
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let CHARGE_SESSION_GRACE_PERIOD_MINUTES = 20.0

struct Telemetry: Encodable {
    let source: String
    let timestamp: String
    let online: Bool
    let rangeKm: Int?
    let socPercent: Int?
    let theoreticalRangeAt100Km: Int?
    let theoreticalRangeAtChargeLimitKm: Int?
    let locked: Bool?
    let chargeLimitPercent: Int?
    let interiorTempC: Int?
    let odometerKm: Int?
    let kwhMissing: Double?
    let charging: Bool?
    let chargeRemainingMinutes: Int?
    let chargeCurrentA: Double?
    let chargeVoltageV: Double?
    let chargePowerKW: Double?
    let chargeType: String?
    let chargeSessionId: Int?
}

struct Config {
    let mqttHost: String?
    let mqttPort: Int
    let mqttUser: String?
    let mqttPassword: String?
    let mqttTopic: String
    let publishToMqtt: Bool
    let loopIntervalSeconds: UInt32?
    let verbose: Bool
    let readOdometerWithForeground: Bool
    let batteryCapacityKWh: Double?
    let sohPercent: Double?
    let databasePath: String?
}

func printUsageAndExit() -> Never {
    print("Usage: dump_xpeng_ax -h host[:port] [-u username] [-p password] [-t topic] [-l seconds] [-bc battery_kwh] [-soh percent] [-db sqlite_path] [-v]")
    print("Example: dump_xpeng_ax -h mqtt.example.local:1883 -u username -p password -t xpeng/g6/telemetry -bc 80.0 -soh 100 -db xpeng.db -l 60 -v")
    print("Default topic: xpeng/g6/telemetry")
    print("MQTT topics are published under: <topic>/<field>")
    print("Use -l / --loop to read and publish every N seconds")
    print("Use -bc / --battery-capacity to set nominal battery capacity in kWh")
    print("Use -soh / --soh to set battery state of health percentage")
    print("Use -db / --database to store telemetry changes in a SQLite database")
    print("Create a file named 'noodometer' next to this binary to skip foreground Settings/odometer reading")
    print("Use -v / --verbose to print JSON and diagnostic messages")
    exit(1)
}

func logVerbose(_ message: String, config: Config) {
    if config.verbose {
        fputs("\(message)\n", stderr)
    }
}

func parseConfig(arguments: [String]) -> Config {
    var mqttHost: String?
    var mqttPort = 1883
    var mqttUser: String?
    var mqttPassword: String?
    var mqttTopic = "xpeng/g6/telemetry"
    var loopIntervalSeconds: UInt32?
    var verbose = false
    var batteryCapacityKWh: Double?
    var sohPercent: Double?
    var databasePath: String?

    if arguments.count == 1 {
        printUsageAndExit()
    }

    var index = 1
    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "-h", "--host":
            index += 1
            guard index < arguments.count else { printUsageAndExit() }
            let hostValue = arguments[index]
            let parts = hostValue.split(separator: ":", maxSplits: 1).map(String.init)
            mqttHost = parts[0]
            if parts.count == 2 {
                guard let port = Int(parts[1]) else { printUsageAndExit() }
                mqttPort = port
            }

        case "-u", "--user":
            index += 1
            guard index < arguments.count else { printUsageAndExit() }
            mqttUser = arguments[index]

        case "-p", "--password":
            index += 1
            guard index < arguments.count else { printUsageAndExit() }
            mqttPassword = arguments[index]

        case "-t", "--topic":
            index += 1
            guard index < arguments.count else { printUsageAndExit() }
            mqttTopic = arguments[index]

        case "-l", "--loop":
            index += 1
            guard index < arguments.count else { printUsageAndExit() }
            guard let interval = UInt32(arguments[index]), interval > 0 else { printUsageAndExit() }
            loopIntervalSeconds = interval

        case "-bc", "--battery-capacity":
            index += 1
            guard index < arguments.count else { printUsageAndExit() }
            guard let capacity = Double(arguments[index]), capacity > 0 else { printUsageAndExit() }
            batteryCapacityKWh = capacity

        case "-soh", "--soh":
            index += 1
            guard index < arguments.count else { printUsageAndExit() }
            guard let soh = Double(arguments[index]), soh > 0, soh <= 100 else { printUsageAndExit() }
            sohPercent = soh

        case "-db", "--database":
            index += 1
            guard index < arguments.count else { printUsageAndExit() }
            databasePath = arguments[index]

        case "-v", "--verbose":
            verbose = true

        case "--help":
            printUsageAndExit()

        default:
            print("Unknown argument: \(argument)")
            printUsageAndExit()
        }

        index += 1
    }

    let executableURL = URL(
        fileURLWithPath: arguments[0],
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
    let noOdometerPath = executableURL
        .deletingLastPathComponent()
        .appendingPathComponent("noodometer")
        .path
    let readOdometerWithForeground = !FileManager.default.fileExists(atPath: noOdometerPath)

    return Config(
        mqttHost: mqttHost,
        mqttPort: mqttPort,
        mqttUser: mqttUser,
        mqttPassword: mqttPassword,
        mqttTopic: mqttTopic,
        publishToMqtt: mqttHost != nil,
        loopIntervalSeconds: loopIntervalSeconds,
        verbose: verbose,
        readOdometerWithForeground: readOdometerWithForeground,
        batteryCapacityKWh: batteryCapacityKWh,
        sohPercent: sohPercent,
        databasePath: databasePath
    )
}
struct StoredTelemetry: Equatable {
    let chargeLimitPercent: Int?
    let interiorTempC: Int?
    let kwhMissing: Double?
    let locked: Bool?
    let odometerKm: Int?
    let rangeKm: Int?
    let socPercent: Int?
    let theoreticalRangeAt100Km: Int?
    let theoreticalRangeAtChargeLimitKm: Int?
    let charging: Bool?
    let chargeRemainingMinutes: Int?
    let chargeCurrentA: Double?
    let chargeVoltageV: Double?
    let chargePowerKW: Double?
    let chargeType: String?
    let chargeSessionId: Int?
}

enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return String(format: String(localized: "SQLite open failed: %@"), message)
        case .prepareFailed(let message):
            return String(format: String(localized: "SQLite prepare failed: %@"), message)
        case .stepFailed(let message):
            return String(format: String(localized: "SQLite step failed: %@"), message)
        case .bindFailed(let message):
            return String(format: String(localized: "SQLite bind failed: %@"), message)
        }
    }
}

func sqliteErrorMessage(_ database: OpaquePointer?) -> String {
    guard let database = database,
          let message = sqlite3_errmsg(database) else {
        return "Unknown SQLite error"
    }
    return String(cString: message)
}

func sqliteTimestamp(from isoTimestamp: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]

    guard let date = parser.date(from: isoTimestamp) else {
        return isoTimestamp
    }

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

func telemetryComparable(_ telemetry: Telemetry) -> StoredTelemetry {
    return StoredTelemetry(
        chargeLimitPercent: telemetry.chargeLimitPercent,
        interiorTempC: telemetry.interiorTempC,
        kwhMissing: telemetry.kwhMissing,
        locked: telemetry.locked,
        odometerKm: telemetry.odometerKm,
        rangeKm: telemetry.rangeKm,
        socPercent: telemetry.socPercent,
        theoreticalRangeAt100Km: telemetry.theoreticalRangeAt100Km,
        theoreticalRangeAtChargeLimitKm: telemetry.theoreticalRangeAtChargeLimitKm,
        charging: telemetry.charging,
        chargeRemainingMinutes: telemetry.chargeRemainingMinutes,
        chargeCurrentA: telemetry.chargeCurrentA,
        chargeVoltageV: telemetry.chargeVoltageV,
        chargePowerKW: telemetry.chargePowerKW,
        chargeType: telemetry.chargeType,
        chargeSessionId: telemetry.chargeSessionId
    )
}

func telemetryWithOdometer(_ telemetry: Telemetry, odometerKm: Int?) -> Telemetry {
    return Telemetry(
        source: telemetry.source,
        timestamp: telemetry.timestamp,
        online: telemetry.online,
        rangeKm: telemetry.rangeKm,
        socPercent: telemetry.socPercent,
        theoreticalRangeAt100Km: telemetry.theoreticalRangeAt100Km,
        theoreticalRangeAtChargeLimitKm: telemetry.theoreticalRangeAtChargeLimitKm,
        locked: telemetry.locked,
        chargeLimitPercent: telemetry.chargeLimitPercent,
        interiorTempC: telemetry.interiorTempC,
        odometerKm: odometerKm,
        kwhMissing: telemetry.kwhMissing,
        charging: telemetry.charging,
        chargeRemainingMinutes: telemetry.chargeRemainingMinutes,
        chargeCurrentA: telemetry.chargeCurrentA,
        chargeVoltageV: telemetry.chargeVoltageV,
        chargePowerKW: telemetry.chargePowerKW,
        chargeType: telemetry.chargeType,
        chargeSessionId: telemetry.chargeSessionId
    )
}

func telemetryWithChargeSession(_ telemetry: Telemetry, chargeSessionId: Int?) -> Telemetry {
    return Telemetry(
        source: telemetry.source,
        timestamp: telemetry.timestamp,
        online: telemetry.online,
        rangeKm: telemetry.rangeKm,
        socPercent: telemetry.socPercent,
        theoreticalRangeAt100Km: telemetry.theoreticalRangeAt100Km,
        theoreticalRangeAtChargeLimitKm: telemetry.theoreticalRangeAtChargeLimitKm,
        locked: telemetry.locked,
        chargeLimitPercent: telemetry.chargeLimitPercent,
        interiorTempC: telemetry.interiorTempC,
        odometerKm: telemetry.odometerKm,
        kwhMissing: telemetry.kwhMissing,
        charging: telemetry.charging,
        chargeRemainingMinutes: telemetry.chargeRemainingMinutes,
        chargeCurrentA: telemetry.chargeCurrentA,
        chargeVoltageV: telemetry.chargeVoltageV,
        chargePowerKW: telemetry.chargePowerKW,
        chargeType: telemetry.chargeType,
        chargeSessionId: chargeSessionId
    )
}

func calculatedRangeAtChargeLimit(rangeKm: Int?, socPercent: Int?, chargeLimitPercent: Int?) -> Int? {
    guard let rangeKm = rangeKm,
          let socPercent = socPercent,
          let chargeLimitPercent = chargeLimitPercent,
          socPercent > 0 else {
        return nil
    }

    return Int((Double(rangeKm) / Double(socPercent) * Double(chargeLimitPercent)).rounded())
}

func telemetryWithChargeLimit(_ telemetry: Telemetry, chargeLimitPercent: Int?) -> Telemetry {
    let updatedRangeAtChargeLimit = calculatedRangeAtChargeLimit(
        rangeKm: telemetry.rangeKm,
        socPercent: telemetry.socPercent,
        chargeLimitPercent: chargeLimitPercent
    )

    return Telemetry(
        source: telemetry.source,
        timestamp: telemetry.timestamp,
        online: telemetry.online,
        rangeKm: telemetry.rangeKm,
        socPercent: telemetry.socPercent,
        theoreticalRangeAt100Km: telemetry.theoreticalRangeAt100Km,
        theoreticalRangeAtChargeLimitKm: updatedRangeAtChargeLimit,
        locked: telemetry.locked,
        chargeLimitPercent: chargeLimitPercent,
        interiorTempC: telemetry.interiorTempC,
        odometerKm: telemetry.odometerKm,
        kwhMissing: telemetry.kwhMissing,
        charging: telemetry.charging,
        chargeRemainingMinutes: telemetry.chargeRemainingMinutes,
        chargeCurrentA: telemetry.chargeCurrentA,
        chargeVoltageV: telemetry.chargeVoltageV,
        chargePowerKW: telemetry.chargePowerKW,
        chargeType: telemetry.chargeType,
        chargeSessionId: telemetry.chargeSessionId
    )
}

final class TelemetryDatabase {
    private let database: OpaquePointer?

    init(path: String) throws {
        var databasePointer: OpaquePointer?
        if sqlite3_open(path, &databasePointer) != SQLITE_OK {
            let message = sqliteErrorMessage(databasePointer)
            sqlite3_close(databasePointer)
            throw DatabaseError.openFailed(message)
        }
        database = databasePointer
        try createTableIfNeeded()
    }

    deinit {
        sqlite3_close(database)
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(database, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? sqliteErrorMessage(database)
            sqlite3_free(errorMessage)
            throw DatabaseError.stepFailed(message)
        }
    }

    private func createTableIfNeeded() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS telemetry (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            charge_limit_percent INTEGER,
            interior_temp_c INTEGER,
            kwh_missing REAL,
            locked INTEGER,
            odometer_km INTEGER,
            range_km INTEGER,
            soc_percent INTEGER,
            theoretical_range_at_100_km INTEGER,
            theoretical_range_at_charge_limit_km INTEGER,
            charging INTEGER,
            charge_remaining_minutes INTEGER,
            charge_current_a REAL,
            charge_voltage_v REAL,
            charge_power_kw REAL,
            charge_type TEXT,
            charge_session_id INTEGER
        );
        """)

        try execute("""
        CREATE INDEX IF NOT EXISTS idx_telemetry_timestamp
        ON telemetry(timestamp);
        """)

        try addTelemetryColumnIfMissing(name: "charging", definition: "INTEGER")
        try addTelemetryColumnIfMissing(name: "charge_remaining_minutes", definition: "INTEGER")
        try addTelemetryColumnIfMissing(name: "charge_current_a", definition: "REAL")
        try addTelemetryColumnIfMissing(name: "charge_voltage_v", definition: "REAL")
        try addTelemetryColumnIfMissing(name: "charge_power_kw", definition: "REAL")
        try addTelemetryColumnIfMissing(name: "charge_type", definition: "TEXT")
        try addTelemetryColumnIfMissing(name: "charge_session_id", definition: "INTEGER")

        try execute("""
        CREATE TABLE IF NOT EXISTS charge_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_timestamp TEXT NOT NULL,
            end_timestamp TEXT,
            last_timestamp TEXT NOT NULL,
            start_soc_percent INTEGER,
            end_soc_percent INTEGER,
            start_kwh_missing REAL,
            end_kwh_missing REAL,
            start_odometer_km INTEGER,
            end_odometer_km INTEGER,
            last_charge_current_a REAL,
            last_charge_voltage_v REAL,
            last_charge_power_kw REAL,
            max_charge_power_kw REAL,
            charge_type TEXT,
            last_remaining_minutes INTEGER
        );
        """)

        try execute("""
        CREATE INDEX IF NOT EXISTS idx_charge_sessions_open
        ON charge_sessions(end_timestamp);
        """)

        try addChargeSessionColumnIfMissing(name: "max_charge_power_kw", definition: "REAL")
        try addChargeSessionColumnIfMissing(name: "charge_type", definition: "TEXT")
    }
    private func chargeSessionColumnExists(_ name: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(charge_sessions);")
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let columnNamePointer = sqlite3_column_text(statement, 1) {
                let columnName = String(cString: columnNamePointer)
                if columnName == name {
                    return true
                }
            }
        }

        return false
    }

    private func addChargeSessionColumnIfMissing(name: String, definition: String) throws {
        if try !chargeSessionColumnExists(name) {
            try execute("ALTER TABLE charge_sessions ADD COLUMN \(name) \(definition);")
        }
    }
    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, at index: Int32) throws {
        if let value = value {
            try bindText(value, to: statement, at: index)
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw DatabaseError.bindFailed(sqliteErrorMessage(database))
        }
    }
    private func optionalTextColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        guard let textPointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: textPointer)
    }

    private func telemetryColumnExists(_ name: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(telemetry);")
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let columnNamePointer = sqlite3_column_text(statement, 1) {
                let columnName = String(cString: columnNamePointer)
                if columnName == name {
                    return true
                }
            }
        }

        return false
    }

    private func addTelemetryColumnIfMissing(name: String, definition: String) throws {
        if try !telemetryColumnExists(name) {
            try execute("ALTER TABLE telemetry ADD COLUMN \(name) \(definition);")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) != SQLITE_OK {
            throw DatabaseError.prepareFailed(sqliteErrorMessage(database))
        }
        return statement
    }

    private func bindInt(_ value: Int?, to statement: OpaquePointer?, at index: Int32) throws {
        let result: Int32
        if let value = value {
            result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        if result != SQLITE_OK {
            throw DatabaseError.bindFailed(sqliteErrorMessage(database))
        }
    }

    private func bindDouble(_ value: Double?, to statement: OpaquePointer?, at index: Int32) throws {
        let result: Int32
        if let value = value {
            result = sqlite3_bind_double(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        if result != SQLITE_OK {
            throw DatabaseError.bindFailed(sqliteErrorMessage(database))
        }
    }

    private func bindBool(_ value: Bool?, to statement: OpaquePointer?, at index: Int32) throws {
        let intValue = value.map { $0 ? 1 : 0 }
        try bindInt(intValue, to: statement, at: index)
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        if sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
            throw DatabaseError.bindFailed(sqliteErrorMessage(database))
        }
    }

    private func optionalIntColumn(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func optionalDoubleColumn(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    private func optionalBoolColumn(_ statement: OpaquePointer?, _ index: Int32) -> Bool? {
        guard let value = optionalIntColumn(statement, index) else {
            return nil
        }
        return value != 0
    }

    func latestTelemetry() throws -> StoredTelemetry? {
        let sql = """
        SELECT
            charge_limit_percent,
            interior_temp_c,
            kwh_missing,
            locked,
            odometer_km,
            range_km,
            soc_percent,
            theoretical_range_at_100_km,
            theoretical_range_at_charge_limit_km,
            charging,
            charge_remaining_minutes,
            charge_current_a,
            charge_voltage_v,
            charge_power_kw,
            charge_type,
            charge_session_id
        FROM telemetry
        ORDER BY id DESC
        LIMIT 1;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return StoredTelemetry(
                chargeLimitPercent: optionalIntColumn(statement, 0),
                interiorTempC: optionalIntColumn(statement, 1),
                kwhMissing: optionalDoubleColumn(statement, 2),
                locked: optionalBoolColumn(statement, 3),
                odometerKm: optionalIntColumn(statement, 4),
                rangeKm: optionalIntColumn(statement, 5),
                socPercent: optionalIntColumn(statement, 6),
                theoreticalRangeAt100Km: optionalIntColumn(statement, 7),
                theoreticalRangeAtChargeLimitKm: optionalIntColumn(statement, 8),
                charging: optionalBoolColumn(statement, 9),
                chargeRemainingMinutes: optionalIntColumn(statement, 10),
                chargeCurrentA: optionalDoubleColumn(statement, 11),
                chargeVoltageV: optionalDoubleColumn(statement, 12),
                chargePowerKW: optionalDoubleColumn(statement, 13),
                chargeType: optionalTextColumn(statement, 14),
                chargeSessionId: optionalIntColumn(statement, 15)
            )
        }

        if result == SQLITE_DONE {
            return nil
        }

        throw DatabaseError.stepFailed(sqliteErrorMessage(database))
    }

    func insertTelemetry(_ telemetry: Telemetry) throws {
        let sql = """
        INSERT INTO telemetry (
            timestamp,
            charge_limit_percent,
            interior_temp_c,
            kwh_missing,
            locked,
            odometer_km,
            range_km,
            soc_percent,
            theoretical_range_at_100_km,
            theoretical_range_at_charge_limit_km,
            charging,
            charge_remaining_minutes,
            charge_current_a,
            charge_voltage_v,
            charge_power_kw,
            charge_type,
            charge_session_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bindText(sqliteTimestamp(from: telemetry.timestamp), to: statement, at: 1)
        try bindInt(telemetry.chargeLimitPercent, to: statement, at: 2)
        try bindInt(telemetry.interiorTempC, to: statement, at: 3)
        try bindDouble(telemetry.kwhMissing, to: statement, at: 4)
        try bindBool(telemetry.locked, to: statement, at: 5)
        try bindInt(telemetry.odometerKm, to: statement, at: 6)
        try bindInt(telemetry.rangeKm, to: statement, at: 7)
        try bindInt(telemetry.socPercent, to: statement, at: 8)
        try bindInt(telemetry.theoreticalRangeAt100Km, to: statement, at: 9)
        try bindInt(telemetry.theoreticalRangeAtChargeLimitKm, to: statement, at: 10)
        try bindBool(telemetry.charging, to: statement, at: 11)
        try bindInt(telemetry.chargeRemainingMinutes, to: statement, at: 12)
        try bindDouble(telemetry.chargeCurrentA, to: statement, at: 13)
        try bindDouble(telemetry.chargeVoltageV, to: statement, at: 14)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 15)
        try bindOptionalText(telemetry.chargeType, to: statement, at: 16)
        try bindInt(telemetry.chargeSessionId, to: statement, at: 17)

        if sqlite3_step(statement) != SQLITE_DONE {
            throw DatabaseError.stepFailed(sqliteErrorMessage(database))
        }
    }

    func openChargeSessionId() throws -> Int? {
        let statement = try prepare("SELECT id FROM charge_sessions WHERE end_timestamp IS NULL ORDER BY id DESC LIMIT 1;")
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return optionalIntColumn(statement, 0)
        }
        if result == SQLITE_DONE {
            return nil
        }
        throw DatabaseError.stepFailed(sqliteErrorMessage(database))
    }

    func shouldCloseOpenChargeSession(id: Int, telemetry: Telemetry) throws -> Bool {
        let sql = """
        SELECT ((julianday(?) - julianday(last_timestamp)) * 24.0 * 60.0) AS elapsed_minutes
        FROM charge_sessions
        WHERE id = ?
          AND end_timestamp IS NULL
        LIMIT 1;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bindText(sqliteTimestamp(from: telemetry.timestamp), to: statement, at: 1)
        try bindInt(id, to: statement, at: 2)

        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            guard let elapsedMinutes = optionalDoubleColumn(statement, 0) else {
                return false
            }
            return elapsedMinutes >= CHARGE_SESSION_GRACE_PERIOD_MINUTES
        }

        if result == SQLITE_DONE {
            return false
        }

        throw DatabaseError.stepFailed(sqliteErrorMessage(database))
    }

    func startChargeSession(_ telemetry: Telemetry) throws {
        let sql = """
        INSERT INTO charge_sessions (
            start_timestamp,
            last_timestamp,
            start_soc_percent,
            end_soc_percent,
            start_kwh_missing,
            end_kwh_missing,
            start_odometer_km,
            end_odometer_km,
            last_charge_current_a,
            last_charge_voltage_v,
            last_charge_power_kw,
            max_charge_power_kw,
            charge_type,
            last_remaining_minutes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let timestamp = sqliteTimestamp(from: telemetry.timestamp)
        try bindText(timestamp, to: statement, at: 1)
        try bindText(timestamp, to: statement, at: 2)
        try bindInt(telemetry.socPercent, to: statement, at: 3)
        try bindInt(telemetry.socPercent, to: statement, at: 4)
        try bindDouble(telemetry.kwhMissing, to: statement, at: 5)
        try bindDouble(telemetry.kwhMissing, to: statement, at: 6)
        try bindInt(telemetry.odometerKm, to: statement, at: 7)
        try bindInt(telemetry.odometerKm, to: statement, at: 8)
        try bindDouble(telemetry.chargeCurrentA, to: statement, at: 9)
        try bindDouble(telemetry.chargeVoltageV, to: statement, at: 10)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 11)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 12)
        try bindOptionalText(telemetry.chargeType, to: statement, at: 13)
        try bindInt(telemetry.chargeRemainingMinutes, to: statement, at: 14)

        if sqlite3_step(statement) != SQLITE_DONE {
            throw DatabaseError.stepFailed(sqliteErrorMessage(database))
        }
    }

    func promoteTelemetryRowsForChargeSessionToDC(id: Int) throws {
        try execute("""
        UPDATE telemetry
        SET charge_type = 'DC'
        WHERE charge_session_id = \(id)
          AND charging = 1;
        """)
    }

    func updateOpenChargeSession(id: Int, telemetry: Telemetry) throws {
        let sql = """
        UPDATE charge_sessions
        SET last_timestamp = ?,
            end_soc_percent = ?,
            end_kwh_missing = ?,
            end_odometer_km = ?,
            last_charge_current_a = ?,
            last_charge_voltage_v = ?,
            last_charge_power_kw = ?,
            max_charge_power_kw = CASE
                WHEN max_charge_power_kw IS NULL THEN ?
                WHEN ? IS NULL THEN max_charge_power_kw
                WHEN ? > max_charge_power_kw THEN ?
                ELSE max_charge_power_kw
            END,
            charge_type = CASE
                WHEN charge_type = 'DC' THEN 'DC'
                WHEN ? = 'DC' THEN 'DC'
                WHEN charge_type IS NULL THEN ?
                ELSE charge_type
            END,
            last_remaining_minutes = ?
        WHERE id = ?;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bindText(sqliteTimestamp(from: telemetry.timestamp), to: statement, at: 1)
        try bindInt(telemetry.socPercent, to: statement, at: 2)
        try bindDouble(telemetry.kwhMissing, to: statement, at: 3)
        try bindInt(telemetry.odometerKm, to: statement, at: 4)
        try bindDouble(telemetry.chargeCurrentA, to: statement, at: 5)
        try bindDouble(telemetry.chargeVoltageV, to: statement, at: 6)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 7)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 8)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 9)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 10)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 11)
        try bindOptionalText(telemetry.chargeType, to: statement, at: 12)
        try bindOptionalText(telemetry.chargeType, to: statement, at: 13)
        try bindInt(telemetry.chargeRemainingMinutes, to: statement, at: 14)
        try bindInt(id, to: statement, at: 15)

        if sqlite3_step(statement) != SQLITE_DONE {
            throw DatabaseError.stepFailed(sqliteErrorMessage(database))
        }

        if telemetry.chargeType == "DC" {
            try promoteTelemetryRowsForChargeSessionToDC(id: id)
        }
    }

    func closeOpenChargeSession(id: Int, telemetry: Telemetry) throws {
        let sql = """
        UPDATE charge_sessions
        SET end_timestamp = ?,
            last_timestamp = ?,
            end_soc_percent = ?,
            end_kwh_missing = ?,
            end_odometer_km = ?,
            last_charge_current_a = ?,
            last_charge_voltage_v = ?,
            last_charge_power_kw = ?,
            max_charge_power_kw = CASE
                WHEN max_charge_power_kw IS NULL THEN ?
                WHEN ? IS NULL THEN max_charge_power_kw
                WHEN ? > max_charge_power_kw THEN ?
                ELSE max_charge_power_kw
            END,
            charge_type = CASE
                WHEN charge_type = 'DC' THEN 'DC'
                WHEN ? = 'DC' THEN 'DC'
                WHEN charge_type IS NULL THEN ?
                ELSE charge_type
            END,
            last_remaining_minutes = ?
        WHERE id = ?;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let timestamp = sqliteTimestamp(from: telemetry.timestamp)
        try bindText(timestamp, to: statement, at: 1)
        try bindText(timestamp, to: statement, at: 2)
        try bindInt(telemetry.socPercent, to: statement, at: 3)
        try bindDouble(telemetry.kwhMissing, to: statement, at: 4)
        try bindInt(telemetry.odometerKm, to: statement, at: 5)
        try bindDouble(telemetry.chargeCurrentA, to: statement, at: 6)
        try bindDouble(telemetry.chargeVoltageV, to: statement, at: 7)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 8)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 9)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 10)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 11)
        try bindDouble(telemetry.chargePowerKW, to: statement, at: 12)
        try bindOptionalText(telemetry.chargeType, to: statement, at: 13)
        try bindOptionalText(telemetry.chargeType, to: statement, at: 14)
        try bindInt(telemetry.chargeRemainingMinutes, to: statement, at: 15)
        try bindInt(id, to: statement, at: 16)

        if sqlite3_step(statement) != SQLITE_DONE {
            throw DatabaseError.stepFailed(sqliteErrorMessage(database))
        }

        if telemetry.chargeType == "DC" {
            try promoteTelemetryRowsForChargeSessionToDC(id: id)
        }
    }

    func updateChargeSession(_ telemetry: Telemetry) throws -> Int? {
        guard let isCharging = telemetry.charging else {
            return nil
        }

        let openId = try openChargeSessionId()
        if isCharging {
            if let openId = openId {
                try updateOpenChargeSession(id: openId, telemetry: telemetry)
                return openId
            }

            try startChargeSession(telemetry)
            return try openChargeSessionId()
        }

        if let openId = openId {
            if try shouldCloseOpenChargeSession(id: openId, telemetry: telemetry) {
                try closeOpenChargeSession(id: openId, telemetry: telemetry)
                return nil
            }

            return nil
        }

        return nil
    }

    func latestOdometerKm() throws -> Int? {
        let sql = """
        SELECT odometer_km
        FROM telemetry
        WHERE odometer_km IS NOT NULL
        ORDER BY id DESC
        LIMIT 1;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return optionalIntColumn(statement, 0)
        }

        if result == SQLITE_DONE {
            return nil
        }

        throw DatabaseError.stepFailed(sqliteErrorMessage(database))
    }

func latestChargeLimitPercent() throws -> Int? {
    let sql = """
    SELECT charge_limit_percent
    FROM telemetry
    WHERE charge_limit_percent IS NOT NULL
    ORDER BY id DESC
    LIMIT 1;
    """

    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }

    let result = sqlite3_step(statement)
    if result == SQLITE_ROW {
        return optionalIntColumn(statement, 0)
    }

    if result == SQLITE_DONE {
        return nil
    }

    throw DatabaseError.stepFailed(sqliteErrorMessage(database))
}

    func insertIfChanged(_ telemetry: Telemetry) throws -> Bool {
        let telemetryToStore: Telemetry
        if telemetry.odometerKm == nil, let latestOdometerKm = try latestOdometerKm() {
            telemetryToStore = telemetryWithOdometer(telemetry, odometerKm: latestOdometerKm)
        } else {
            telemetryToStore = telemetry
        }

        let current = telemetryComparable(telemetryToStore)
        if let latest = try latestTelemetry(), latest == current {
            return false
        }

        try insertTelemetry(telemetryToStore)
        return true
    }
}

func saveTelemetryToDatabaseIfNeeded(_ telemetry: Telemetry, config: Config) -> Telemetry {
    guard let databasePath = config.databasePath else {
        return telemetry
    }

    do {
        let database = try TelemetryDatabase(path: databasePath)
        let chargeSessionId = try database.updateChargeSession(telemetry)
        let telemetryToStore = telemetryWithChargeSession(
            telemetry,
            chargeSessionId: telemetry.charging == true ? chargeSessionId : nil
        )
        let inserted = try database.insertIfChanged(telemetryToStore)
        if inserted {
            logVerbose("Inserted telemetry row into SQLite database: \(databasePath)", config: config)
        } else {
            logVerbose("Telemetry unchanged, SQLite insert skipped", config: config)
        }
        return telemetryToStore
    } catch {
        logVerbose("Failed to write telemetry to SQLite database: \(error.localizedDescription)", config: config)
        return telemetry
    }
}

func telemetryFilledWithLatestDatabaseValuesIfNeeded(_ telemetry: Telemetry, config: Config) -> Telemetry {
    guard let databasePath = config.databasePath else {
        return telemetry
    }

    var updatedTelemetry = telemetry

    do {
        let database = try TelemetryDatabase(path: databasePath)

        if updatedTelemetry.odometerKm == nil,
           let latestOdometerKm = try database.latestOdometerKm() {
            logVerbose("Using latest SQLite odometer value: \(latestOdometerKm)", config: config)
            updatedTelemetry = telemetryWithOdometer(updatedTelemetry, odometerKm: latestOdometerKm)
        }

        if updatedTelemetry.chargeLimitPercent == nil,
           let latestChargeLimitPercent = try database.latestChargeLimitPercent() {
            logVerbose("Using latest SQLite charge limit value: \(latestChargeLimitPercent)", config: config)
            updatedTelemetry = telemetryWithChargeLimit(
                updatedTelemetry,
                chargeLimitPercent: latestChargeLimitPercent
            )
        } else if updatedTelemetry.chargeLimitPercent != nil {
            updatedTelemetry = telemetryWithChargeLimit(
                updatedTelemetry,
                chargeLimitPercent: updatedTelemetry.chargeLimitPercent
            )
        }
    } catch {
        logVerbose("Failed to read latest SQLite fallback values: \(error.localizedDescription)", config: config)
    }

    return updatedTelemetry
}

enum MQTTError: Error, LocalizedError {
    case socketCreationFailed
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case invalidConnack
    case brokerRejected(UInt8)
    case stringEncodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return String(localized: "Failed to create TCP socket")
        case .connectionFailed(let message):
            return String(format: String(localized: "MQTT connection failed: %@"), message)
        case .sendFailed(let message):
            return String(format: String(localized: "MQTT send failed: %@"), message)
        case .receiveFailed(let message):
            return String(format: String(localized: "MQTT receive failed: %@"), message)
        case .invalidConnack:
            return String(localized: "Invalid MQTT CONNACK packet")
        case .brokerRejected(let code):
            return String(format: String(localized: "MQTT broker rejected connection with code %d"), code)
        case .stringEncodingFailed(let value):
            return String(format: String(localized: "Failed to encode MQTT string: %@"), value)
        }
    }
}

func mqttEncodeString(_ value: String) throws -> [UInt8] {
    guard let data = value.data(using: .utf8), data.count <= 65535 else {
        throw MQTTError.stringEncodingFailed(value)
    }

    return [UInt8((data.count >> 8) & 0xFF), UInt8(data.count & 0xFF)] + [UInt8](data)
}

func mqttEncodeRemainingLength(_ length: Int) -> [UInt8] {
    var value = length
    var encoded: [UInt8] = []

    repeat {
        var digit = UInt8(value % 128)
        value = value / 128
        if value > 0 {
            digit = digit | 0x80
        }
        encoded.append(digit)
    } while value > 0

    return encoded
}

func mqttBuildPacket(packetType: UInt8, payload: [UInt8]) -> [UInt8] {
    return [packetType] + mqttEncodeRemainingLength(payload.count) + payload
}

final class MQTTPublisher {
    private let socketFD: Int32

    init(host: String, port: Int, username: String?, password: String?, clientId: String) throws {
        self.socketFD = try MQTTPublisher.openSocket(host: host, port: port)
        try connect(username: username, password: password, clientId: clientId)
    }

    deinit {
        close(socketFD)
    }

    private static func openSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let firstResult = result else {
            throw MQTTError.connectionFailed(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(firstResult) }

        var pointer: UnsafeMutablePointer<addrinfo>? = firstResult
        var lastConnectionError: Int32 = 0
        while pointer != nil {
            let info = pointer!.pointee
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0 {
                    return fd
                }
                lastConnectionError = errno
                close(fd)
            } else {
                lastConnectionError = errno
            }
            pointer = info.ai_next
        }

        let message = lastConnectionError == 0
            ? "No compatible address"
            : String(cString: strerror(lastConnectionError))
        throw MQTTError.connectionFailed(message)
    }

    private func sendAll(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let count = bytes.count - sent
            let result = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return -1
                }
                return Darwin.send(socketFD, baseAddress.advanced(by: sent), count, 0)
            }

            if result <= 0 {
                throw MQTTError.sendFailed(String(cString: strerror(errno)))
            }

            sent += result
        }
    }

    private func readExact(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0

        while received < count {
            let result = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return -1
                }
                return Darwin.recv(socketFD, baseAddress.advanced(by: received), count - received, 0)
            }

            if result <= 0 {
                throw MQTTError.receiveFailed(String(cString: strerror(errno)))
            }

            received += result
        }

        return buffer
    }

    private func connect(username: String?, password: String?, clientId: String) throws {
        var variableHeader: [UInt8] = []
        variableHeader += try mqttEncodeString("MQTT")
        variableHeader.append(0x04) // MQTT 3.1.1

        var connectFlags: UInt8 = 0x02 // Clean session
        if username != nil {
            connectFlags |= 0x80
        }
        if password != nil {
            connectFlags |= 0x40
        }
        variableHeader.append(connectFlags)
        variableHeader.append(0x00)
        variableHeader.append(0x3C) // Keep alive: 60 seconds

        var payload: [UInt8] = []
        payload += try mqttEncodeString(clientId)
        if let username = username {
            payload += try mqttEncodeString(username)
        }
        if let password = password {
            payload += try mqttEncodeString(password)
        }

        let packet = mqttBuildPacket(packetType: 0x10, payload: variableHeader + payload)
        try sendAll(packet)

        let connack = try readExact(4)
        guard connack.count == 4, connack[0] == 0x20, connack[1] == 0x02 else {
            throw MQTTError.invalidConnack
        }
        guard connack[3] == 0x00 else {
            throw MQTTError.brokerRejected(connack[3])
        }
    }

    func publish(topic: String, value: String, retain: Bool = true) throws {
        guard let payloadData = value.data(using: .utf8) else {
            throw MQTTError.stringEncodingFailed(value)
        }

        let variableHeader = try mqttEncodeString(topic)
        let packetType: UInt8 = retain ? 0x31 : 0x30 // PUBLISH QoS 0, optionally retained
        let packet = mqttBuildPacket(packetType: packetType, payload: variableHeader + [UInt8](payloadData))
        try sendAll(packet)
    }

    func disconnect() throws {
        try sendAll([0xE0, 0x00])
    }
}

func withMqttPublisher<T>(config: Config, _ body: (MQTTPublisher) throws -> T) throws -> T {
    guard let mqttHost = config.mqttHost else {
        throw MQTTError.connectionFailed("MQTT host is missing")
    }

    let clientId = "xpeng-ios-mac-ax-\(getpid())-\(Int(Date().timeIntervalSince1970))"
    var publisher: MQTTPublisher?
    var lastConnectionError: Error?

    for attempt in 1...4 {
        do {
            publisher = try MQTTPublisher(
                host: mqttHost,
                port: config.mqttPort,
                username: config.mqttUser,
                password: config.mqttPassword,
                clientId: clientId
            )
            break
        } catch let error as MQTTError {
            switch error {
            case .connectionFailed, .socketCreationFailed:
                lastConnectionError = error
                if attempt < 4 { Thread.sleep(forTimeInterval: 3) }
            default:
                throw error
            }
        }
    }

    guard let publisher else {
        throw lastConnectionError ?? MQTTError.connectionFailed("Unknown error")
    }
    let result = try body(publisher)
    try? publisher.disconnect()
    return result
}

func publishOnlineStatus(_ online: Bool, config: Config) {
    guard config.mqttHost != nil else {
        return
    }

    do {
        try withMqttPublisher(config: config) { publisher in
            try publisher.publish(
                topic: "\(config.mqttTopic)/online",
                value: online ? "true" : "false"
            )
        }
    } catch {
        logVerbose("Failed to publish MQTT online status: \(error.localizedDescription)", config: config)
    }
}

func publishTelemetryToMqtt(telemetry: Telemetry, config: Config) throws {
    guard config.mqttHost != nil else {
        return
    }

    let baseTopic = config.mqttTopic
    var values: [(String, String)] = [
        ("source", telemetry.source),
        ("timestamp", telemetry.timestamp),
        ("online", telemetry.online ? "true" : "false")
    ]

    if let rangeKm = telemetry.rangeKm {
        values.append(("range", String(rangeKm)))
    }

    if let socPercent = telemetry.socPercent {
        values.append(("soc", String(socPercent)))
    }

    if let theoreticalRangeAt100Km = telemetry.theoreticalRangeAt100Km {
        values.append(("range_at_100", String(theoreticalRangeAt100Km)))
    }

    if let theoreticalRangeAtChargeLimitKm = telemetry.theoreticalRangeAtChargeLimitKm {
        values.append(("range_at_charge_limit", String(theoreticalRangeAtChargeLimitKm)))
    }

    if let locked = telemetry.locked {
        values.append(("locked", locked ? "true" : "false"))
    }

    if let chargeLimitPercent = telemetry.chargeLimitPercent {
        values.append(("charge_limit", String(chargeLimitPercent)))
    }

    if let interiorTempC = telemetry.interiorTempC {
        values.append(("interior_temp", String(interiorTempC)))
    }

    if let odometerKm = telemetry.odometerKm {
        values.append(("odometer", String(odometerKm)))
    }

    if let kwhMissing = telemetry.kwhMissing {
        values.append(("kwh_missing", String(format: "%.2f", kwhMissing)))
    }

    let isCharging = telemetry.charging ?? false
    values.append(("charging", isCharging ? "true" : "false"))

    if isCharging {
        if let chargeRemainingMinutes = telemetry.chargeRemainingMinutes {
            values.append(("charge_remaining_minutes", String(chargeRemainingMinutes)))
        }

        if let chargeCurrentA = telemetry.chargeCurrentA {
            values.append(("charge_current_a", String(format: "%.1f", chargeCurrentA)))
        }

        if let chargeVoltageV = telemetry.chargeVoltageV {
            values.append(("charge_voltage_v", String(format: "%.1f", chargeVoltageV)))
        }

        if let chargePowerKW = telemetry.chargePowerKW {
            values.append(("charge_power_kw", String(format: "%.1f", chargePowerKW)))
        }

        if let chargeType = telemetry.chargeType {
            values.append(("charge_type", chargeType))
        }
    } else {
        values.append(("charge_remaining_minutes", "0"))
        values.append(("charge_current_a", "0.0"))
        values.append(("charge_voltage_v", "0.0"))
        values.append(("charge_power_kw", "0.0"))
        values.append(("charge_type", "none"))
    }

    // charge_session_id block removed

    try withMqttPublisher(config: config) { publisher in
        for (field, value) in values {
            try publisher.publish(topic: "\(baseTopic)/\(field)", value: value)
        }
    }

    logVerbose("Published \(values.count) MQTT values", config: config)
}
func getAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return result == .success ? value : nil
}

func getChildren(_ element: AXUIElement) -> [AXUIElement] {
    if let children = getAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        return children
    }
    return []
}

func getWindows(_ appElement: AXUIElement) -> [AXUIElement] {
    if let windows = getAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] {
        return windows
    }
    return []
}

func restoreXpangWindow(app: NSRunningApplication, appElement: AXUIElement, config: Config) {
    logVerbose("Restoring XPENG window before odometer read", config: config)

    app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.5)

    let windows = getWindows(appElement)
    for window in windows {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    Thread.sleep(forTimeInterval: 0.5)
}


func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    if let value = getAttribute(element, attribute) as? String, !value.isEmpty {
        return value
    }
    return nil
}

func cgPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let value = getAttribute(element, attribute) else {
        return nil
    }

    var point = CGPoint.zero
    if AXValueGetType(value as! AXValue) == .cgPoint,
       AXValueGetValue(value as! AXValue, .cgPoint, &point) {
        return point
    }

    return nil
}

func cgSizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let value = getAttribute(element, attribute) else {
        return nil
    }

    var size = CGSize.zero
    if AXValueGetType(value as! AXValue) == .cgSize,
       AXValueGetValue(value as! AXValue, .cgSize, &size) {
        return size
    }

    return nil
}

func collectStaticTexts(_ element: AXUIElement, texts: inout [String]) {
    let role = stringAttribute(element, kAXRoleAttribute)

    if role == kAXStaticTextRole {
        if let description = stringAttribute(element, kAXDescriptionAttribute) {
            texts.append(description)
        } else if let value = stringAttribute(element, kAXValueAttribute) {
            texts.append(value)
        } else if let title = stringAttribute(element, kAXTitleAttribute) {
            texts.append(title)
        } else if let label = stringAttribute(element, "AXLabel") {
            texts.append(label)
        }
    }

    for child in getChildren(element) {
        collectStaticTexts(child, texts: &texts)
    }
}

func collectAllElements(_ element: AXUIElement, elements: inout [AXUIElement]) {
    elements.append(element)

    for child in getChildren(element) {
        collectAllElements(child, elements: &elements)
    }
}

func elementTexts(_ element: AXUIElement) -> [String] {
    var values: [String] = []

    for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, "AXLabel"] {
        if let value = stringAttribute(element, attribute) {
            values.append(value)
        }
    }

    return values
}



func pressElement(_ element: AXUIElement) -> Bool {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    return result == .success
}

func clickAndDrag(from startPoint: CGPoint, to endPoint: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)

    let mouseDown = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseDown,
        mouseCursorPosition: startPoint,
        mouseButton: .left
    )
    mouseDown?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.15)

    let steps = 18
    for step in 1...steps {
        let ratio = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(
            x: startPoint.x + (endPoint.x - startPoint.x) * ratio,
            y: startPoint.y + (endPoint.y - startPoint.y) * ratio
        )

        let drag = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        drag?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
    }

    let mouseUp = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseUp,
        mouseCursorPosition: endPoint,
        mouseButton: .left
    )
    mouseUp?.post(tap: .cghidEventTap)
}

func scrollWindowDown(in window: AXUIElement, config: Config) {
    logVerbose("Scrolling settings page down with drag gesture", config: config)

    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    Thread.sleep(forTimeInterval: 0.3)

    guard let position = cgPointAttribute(window, kAXPositionAttribute),
          let size = cgSizeAttribute(window, kAXSizeAttribute) else {
        logVerbose("Cannot get XPENG window geometry for drag scroll", config: config)
        return
    }

    let x = position.x + size.width * 0.5
    let startPoint = CGPoint(x: x, y: position.y + size.height * 0.88)
    let endPoint = CGPoint(x: x, y: position.y + size.height * 0.15)

    let moveEvent = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: startPoint,
        mouseButton: .left
    )
    moveEvent?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.2)

    clickAndDrag(from: startPoint, to: endPoint)
}

func pressSettingsButton(in window: AXUIElement, config: Config) -> Bool {
    var elements: [AXUIElement] = []
    collectAllElements(window, elements: &elements)

    for element in elements {
        let role = stringAttribute(element, kAXRoleAttribute)
        guard role == kAXButtonRole else {
            continue
        }

        let labels = elementTexts(element)
        let joinedLabels = labels.joined(separator: " ")

        if joinedLabels.localizedCaseInsensitiveContains("coh ic setting") ||
           joinedLabels.localizedCaseInsensitiveContains("setting") {
            logVerbose("Pressing settings button: \(joinedLabels)", config: config)
            return pressElement(element)
        }
    }

    logVerbose("Settings button was not found", config: config)
    return false
}

func pressBackButton(in window: AXUIElement, config: Config) -> Bool {
    var elements: [AXUIElement] = []
    collectAllElements(window, elements: &elements)

    for element in elements {
        let role = stringAttribute(element, kAXRoleAttribute)
        guard role == kAXButtonRole else {
            continue
        }

        let labels = elementTexts(element)
        let joinedLabels = labels.joined(separator: " ")

        if joinedLabels.localizedCaseInsensitiveContains("navigation back") {
            logVerbose("Pressing back button: \(joinedLabels)", config: config)
            return pressElement(element)
        }
    }

    logVerbose("Back button was not found", config: config)
    return false
}

func isSettingsPage(texts: [String]) -> Bool {
    return texts.contains { $0.localizedCaseInsensitiveContains("Settings") } &&
           texts.contains { $0.localizedCaseInsensitiveContains("Total Distance") || $0.localizedCaseInsensitiveContains("System version") }
}

func firstInteger(in text: String) -> Int? {
    let pattern = "\\d+"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let matchRange = Range(match.range, in: text) else {
        return nil
    }

    return Int(text[matchRange])
}

func normalizedDecimal(_ value: String) -> Double? {
    return Double(value.replacingOccurrences(of: ",", with: "."))
}

func firstDecimal(before suffix: String, in text: String) -> Double? {
    let escapedSuffix = NSRegularExpression.escapedPattern(for: suffix)
    let pattern = "([0-9]+(?:[,.][0-9]+)?)\\s*" + escapedSuffix
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          match.numberOfRanges >= 2,
          let matchRange = Range(match.range(at: 1), in: text) else {
        return nil
    }

    return normalizedDecimal(String(text[matchRange]))
}

func parseChargeRemainingMinutes(from text: String) -> Int? {
    let lower = text.lowercased()
    guard lower.contains("remaining") || lower.contains("reste") || lower.contains("restant") else {
        return nil
    }

    var totalMinutes = 0
    if let hourRegex = try? NSRegularExpression(pattern: "([0-9]+)\\s*h", options: [.caseInsensitive]) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = hourRegex.firstMatch(in: text, range: range),
           let matchRange = Range(match.range(at: 1), in: text),
           let hours = Int(text[matchRange]) {
            totalMinutes += hours * 60
        }
    }

    if let minuteRegex = try? NSRegularExpression(pattern: "([0-9]+)\\s*min", options: [.caseInsensitive]) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = minuteRegex.firstMatch(in: text, range: range),
           let matchRange = Range(match.range(at: 1), in: text),
           let minutes = Int(text[matchRange]) {
            totalMinutes += minutes
        }
    }

    return totalMinutes > 0 ? totalMinutes : nil
}

func chargeType(from chargePowerKW: Double?) -> String? {
    guard let chargePowerKW = chargePowerKW else {
        return nil
    }

    return chargePowerKW < 12.0 ? "AC" : "DC"
}

func parseTelemetry(from texts: [String], config: Config) -> Telemetry {
    var rangeKm: Int?
    var socPercent: Int?
    var locked: Bool?
    var chargeLimitPercent: Int?
    var interiorTempC: Int?
    var odometerKm: Int?
    var charging: Bool?
    var chargeRemainingMinutes: Int?
    var chargeCurrentA: Double?
    var chargeVoltageV: Double?
    var chargePowerKW: Double?

    for (index, text) in texts.enumerated() {
        if text == "km", rangeKm == nil {
            for previousText in texts[..<index].reversed() {
                if let value = firstInteger(in: previousText) {
                    rangeKm = value
                    break
                }
            }
        }

        if text.hasSuffix("%"), socPercent == nil {
            let previousText = index > 0 ? texts[index - 1] : ""
            if !previousText.localizedCaseInsensitiveContains("Limit") &&
               !previousText.localizedCaseInsensitiveContains("Limite") &&
               !text.localizedCaseInsensitiveContains("Limit") &&
               !text.localizedCaseInsensitiveContains("Limite") {
                socPercent = firstInteger(in: text)
            }
        }

        if text.localizedCaseInsensitiveContains("Door Locked") ||
           text.localizedCaseInsensitiveContains("Porte verrouillée") {
            locked = true
        }

        if text.localizedCaseInsensitiveContains("Door(s) not locked") ||
           text.localizedCaseInsensitiveContains("Door not locked") ||
           text.localizedCaseInsensitiveContains("Porte déverrouillée") ||
           text.localizedCaseInsensitiveContains("Porte non verrouillée") {
            locked = false
        }

        if text.localizedCaseInsensitiveContains("Limit") ||
           text.localizedCaseInsensitiveContains("Limite") {
            chargeLimitPercent = firstInteger(in: text)
        }

        if text == "℃", index > 0 {
            interiorTempC = firstInteger(in: texts[index - 1])
        }

        // Charging detection and charge data parsing
        if text.localizedCaseInsensitiveContains("Charging") ||
           text.localizedCaseInsensitiveContains("Charge en cours") ||
           text.localizedCaseInsensitiveContains("En charge") {
            charging = true
            if chargeRemainingMinutes == nil {
                chargeRemainingMinutes = parseChargeRemainingMinutes(from: text)
            }
        }

        if text.localizedCaseInsensitiveContains("Remaining"), chargeRemainingMinutes == nil {
            chargeRemainingMinutes = parseChargeRemainingMinutes(from: text)
        }

        if text.localizedCaseInsensitiveContains("kW") ||
           text.localizedCaseInsensitiveContains("kwh") ||
           text.localizedCaseInsensitiveContains("A") ||
           text.localizedCaseInsensitiveContains("V") {
            if chargeCurrentA == nil {
                chargeCurrentA = firstDecimal(before: "A", in: text)
            }
            if chargeVoltageV == nil {
                chargeVoltageV = firstDecimal(before: "V", in: text)
            }
            if chargePowerKW == nil {
                chargePowerKW = firstDecimal(before: "kW", in: text)
            }
        }

        if text.localizedCaseInsensitiveContains("Total Distance"), odometerKm == nil {
            if text.localizedCaseInsensitiveContains("km"),
               let value = firstInteger(in: text) {
                odometerKm = value
            } else {
                for followingText in texts.dropFirst(index + 1) {
                    if followingText.localizedCaseInsensitiveContains("km"),
                       let value = firstInteger(in: followingText) {
                        odometerKm = value
                        break
                    }
                }
            }
        }
    }

    let chargeTypeValue = chargeType(from: chargePowerKW)

    if let power = chargePowerKW, power > 0.0, chargeTypeValue != nil {
        charging = true
    } else {
        charging = false
        chargeRemainingMinutes = nil
        chargeCurrentA = nil
        chargeVoltageV = nil
        chargePowerKW = nil
    }

    let theoreticalRangeAt100Km: Int?
    if let rangeKm = rangeKm, let socPercent = socPercent, socPercent > 0 {
        theoreticalRangeAt100Km = Int((Double(rangeKm) / Double(socPercent) * 100.0).rounded())
    } else {
        theoreticalRangeAt100Km = nil
    }

    let theoreticalRangeAtChargeLimitKm = calculatedRangeAtChargeLimit(
        rangeKm: rangeKm,
        socPercent: socPercent,
        chargeLimitPercent: chargeLimitPercent
    )
    
    let kwhMissing: Double?
    if let socPercent = socPercent,
       let batteryCapacityKWh = config.batteryCapacityKWh,
       let sohPercent = config.sohPercent,
       socPercent >= 0,
       socPercent <= 100 {
        let effectiveCapacityKWh = batteryCapacityKWh * (sohPercent / 100.0)
        kwhMissing = effectiveCapacityKWh * ((100.0 - Double(socPercent)) / 100.0)
    } else {
        kwhMissing = nil
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    let online = rangeKm != nil && socPercent != nil

    return Telemetry(
        source: "xpeng_ios_mac_ax",
        timestamp: formatter.string(from: Date()),
        online: online,
        rangeKm: rangeKm,
        socPercent: socPercent,
        theoreticalRangeAt100Km: theoreticalRangeAt100Km,
        theoreticalRangeAtChargeLimitKm: theoreticalRangeAtChargeLimitKm,
        locked: locked,
        chargeLimitPercent: chargeLimitPercent,
        interiorTempC: interiorTempC,
        odometerKm: odometerKm,
        kwhMissing: kwhMissing,
        charging: charging,
        chargeRemainingMinutes: chargeRemainingMinutes,
        chargeCurrentA: chargeCurrentA,
        chargeVoltageV: chargeVoltageV,
        chargePowerKW: chargePowerKW,
        chargeType: charging == true ? chargeTypeValue : nil,
        chargeSessionId: nil
    )
}

func readAndPublishTelemetry(config: Config, onError: ((Error) -> Void)? = nil) -> Bool {
    let appName = "XPENG"
    let runningApps = NSWorkspace.shared.runningApplications
    let matchingApps = runningApps.filter { $0.localizedName == appName }

    guard let app = matchingApps.first else {
        logVerbose("XPENG app is not running", config: config)
        publishOnlineStatus(false, config: config)
        return false
    }

    let appElement = AXUIElementCreateApplication(app.processIdentifier)

    if config.readOdometerWithForeground {
        restoreXpangWindow(app: app, appElement: appElement, config: config)
    }

    let windows = getWindows(appElement)

    guard let mainWindow = windows.first else {
        logVerbose("XPENG window was not found", config: config)
        publishOnlineStatus(false, config: config)
        return false
    }

    var texts: [String] = []
    collectStaticTexts(mainWindow, texts: &texts)

    var combinedTexts = texts
    var settingsWasOpened = false

    if config.readOdometerWithForeground {
        if !isSettingsPage(texts: texts) {
            if pressSettingsButton(in: mainWindow, config: config) {
                settingsWasOpened = true
                Thread.sleep(forTimeInterval: 3.0)

                var settingsTexts: [String] = []
                collectStaticTexts(mainWindow, texts: &settingsTexts)
                combinedTexts.append(contentsOf: settingsTexts)

                var settingsTelemetry = parseTelemetry(from: settingsTexts, config: config)
                if settingsTelemetry.odometerKm == nil {
                    scrollWindowDown(in: mainWindow, config: config)
                    Thread.sleep(forTimeInterval: 1.0)

                    var scrolledSettingsTexts: [String] = []
                    collectStaticTexts(mainWindow, texts: &scrolledSettingsTexts)
                    combinedTexts.append(contentsOf: scrolledSettingsTexts)

                    settingsTelemetry = parseTelemetry(from: scrolledSettingsTexts, config: config)
                    if settingsTelemetry.odometerKm == nil {
                        scrollWindowDown(in: mainWindow, config: config)
                        Thread.sleep(forTimeInterval: 1.0)

                        var secondScrolledSettingsTexts: [String] = []
                        collectStaticTexts(mainWindow, texts: &secondScrolledSettingsTexts)
                        combinedTexts.append(contentsOf: secondScrolledSettingsTexts)
                    }
                }
            }
        }
    } else {
        logVerbose("Skipping Settings/odometer because the noodometer marker file exists", config: config)
    }

    let parsedTelemetry = parseTelemetry(from: combinedTexts, config: config)
    let telemetry = telemetryFilledWithLatestDatabaseValuesIfNeeded(parsedTelemetry, config: config)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    do {
        let data = try encoder.encode(telemetry)
        if let json = String(data: data, encoding: .utf8) {
            if config.verbose {
                print(json)
            }

            let telemetryToPublish = saveTelemetryToDatabaseIfNeeded(telemetry, config: config)

            if config.publishToMqtt {
                try publishTelemetryToMqtt(telemetry: telemetryToPublish, config: config)
            }
        }

        if settingsWasOpened {
            _ = pressBackButton(in: mainWindow, config: config)
        }
    } catch {
        logVerbose("Failed to encode or publish telemetry: \(error.localizedDescription)", config: config)
        onError?(error)
        if settingsWasOpened {
            _ = pressBackButton(in: mainWindow, config: config)
        }
        publishOnlineStatus(false, config: config)
        return false
    }

    return telemetry.online
}
