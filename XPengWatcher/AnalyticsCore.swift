import Foundation
import SQLite3

struct AnalyticsConfig {
    let databasePath: String
    let batteryCapacityKWh: Double
    let sohPercent: Double
    let maxGapMinutes: Double
    let minDistanceKm: Int
    let limit: Int
}

struct TelemetryRow {
    let timestamp: Date
    let timestampText: String
    let odometerKm: Int
    let socPercent: Int
    let charging: Bool
}

struct VehicleStatusRow {
    let timestamp: Date
    let odometerKm: Int?
    let socPercent: Int?
    let rangeKm: Int?
}

struct Trip {
    let start: TelemetryRow
    let end: TelemetryRow

    var distanceKm: Int {
        return end.odometerKm - start.odometerKm
    }

    var durationSeconds: TimeInterval {
        return end.timestamp.timeIntervalSince(start.timestamp)
    }
}

struct ChargeSession {
    let id: Int
    let startTimestamp: Date
    let endTimestamp: Date?
    let lastTimestamp: Date?
    let startSocPercent: Int?
    let endSocPercent: Int?
    let startKWhMissing: Double?
    let startOdometerKm: Int?
    let endKWhMissing: Double?
    let chargeType: String?
    let maxChargePowerKW: Double?

    var displayEndTimestamp: Date {
        return endTimestamp ?? lastTimestamp ?? startTimestamp
    }

    var durationSeconds: TimeInterval {
        return displayEndTimestamp.timeIntervalSince(startTimestamp)
    }

    var addedKWh: Double? {
        guard let startKWhMissing = startKWhMissing,
              let endKWhMissing = endKWhMissing else {
            return nil
        }

        let added = startKWhMissing - endKWhMissing
        if added <= 0.0 {
            return nil
        }

        return added
    }
}

enum AppError: Error, LocalizedError {
    case sqliteOpenFailed(String)
    case sqlitePrepareFailed(String)
    case sqliteStepFailed(String)
    case invalidTimestamp(String)

    var errorDescription: String? {
        switch self {
        case .sqliteOpenFailed(let message):
            return "SQLite open failed: \(message)"
        case .sqlitePrepareFailed(let message):
            return "SQLite prepare failed: \(message)"
        case .sqliteStepFailed(let message):
            return "SQLite step failed: \(message)"
        case .invalidTimestamp(let value):
            return "Invalid timestamp: \(value)"
        }
    }
}

func analyticsPrintUsageAndExit() -> Never {
    print("""
    Usage:
      xpeng_db summary [-db xpeng.db] [-bc 80.0] [-soh 100] [--max-gap 10] [--min-km 1] [--limit 10]

    Commands:
      summary               Show last trips and last charge sessions
      trips                 Show last trips only
      charges               Show last charge sessions only

    Options:
      -db, --database       SQLite database path. Default: xpeng.db
      -bc, --battery-capacity
                           Net battery capacity in kWh. Default: 80.0
      -soh, --soh           Battery SOH percent. Default: 100.0
      --max-gap             Max stationary minutes before splitting trips. Default: 10
      --min-km              Minimum trip distance in km. Default: 1
      --limit               Number of items to display. Default: 10
      Times are displayed in the system time zone.

    Example:
      ./xpeng_db summary -db xpeng.db -bc 80 -soh 100
    """)
    exit(1)
}

func parseAnalyticsConfig(arguments: [String]) -> (command: String, config: AnalyticsConfig) {
    guard arguments.count >= 2 else {
        analyticsPrintUsageAndExit()
    }

    let command = arguments[1]

    var databasePath = "xpeng.db"
    var batteryCapacityKWh = 80.0
    var sohPercent = 100.0
    var maxGapMinutes = 10.0
    var minDistanceKm = 1
    var limit = 10

    var index = 2
    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "-db", "--database":
            index += 1
            guard index < arguments.count else { analyticsPrintUsageAndExit() }
            databasePath = arguments[index]

        case "-bc", "--battery-capacity":
            index += 1
            guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                analyticsPrintUsageAndExit()
            }
            batteryCapacityKWh = value

        case "-soh", "--soh":
            index += 1
            guard index < arguments.count, let value = Double(arguments[index]), value > 0, value <= 100 else {
                analyticsPrintUsageAndExit()
            }
            sohPercent = value

        case "--max-gap":
            index += 1
            guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                analyticsPrintUsageAndExit()
            }
            maxGapMinutes = value

        case "--min-km":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else {
                analyticsPrintUsageAndExit()
            }
            minDistanceKm = value

        case "--limit":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                analyticsPrintUsageAndExit()
            }
            limit = value

        case "-h", "--help":
            analyticsPrintUsageAndExit()

        default:
            print("Unknown argument: \(argument)")
            analyticsPrintUsageAndExit()
        }

        index += 1
    }

    let config = AnalyticsConfig(
        databasePath: databasePath,
        batteryCapacityKWh: batteryCapacityKWh,
        sohPercent: sohPercent,
        maxGapMinutes: maxGapMinutes,
        minDistanceKm: minDistanceKm,
        limit: limit
    )

    return (command, config)
}

func analyticsSQLiteErrorMessage(_ database: OpaquePointer?) -> String {
    guard let database = database, let message = sqlite3_errmsg(database) else {
        return "Unknown SQLite error"
    }
    return String(cString: message)
}

func sqliteTextColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, index) else {
        return nil
    }

    return String(cString: pointer)
}

func sqliteOptionalIntColumn(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
    if sqlite3_column_type(statement, index) == SQLITE_NULL {
        return nil
    }

    return Int(sqlite3_column_int64(statement, index))
}

func sqliteOptionalDoubleColumn(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
    if sqlite3_column_type(statement, index) == SQLITE_NULL {
        return nil
    }

    return sqlite3_column_double(statement, index)
}

final class Database {
    private let database: OpaquePointer?

    init(path: String) throws {
        var pointer: OpaquePointer?
        if sqlite3_open(path, &pointer) != SQLITE_OK {
            let message = analyticsSQLiteErrorMessage(pointer)
            sqlite3_close(pointer)
            throw AppError.sqliteOpenFailed(message)
        }
        database = pointer
    }

    deinit {
        sqlite3_close(database)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) != SQLITE_OK {
            throw AppError.sqlitePrepareFailed(analyticsSQLiteErrorMessage(database))
        }
        return statement
    }

    func loadLatestVehicleStatus() throws -> VehicleStatusRow? {
        let sql = """
        SELECT timestamp, odometer_km, soc_percent, range_km
        FROM telemetry
        ORDER BY id DESC
        LIMIT 1;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw AppError.sqliteStepFailed(analyticsSQLiteErrorMessage(database))
        }
        guard let timestampText = sqliteTextColumn(statement, 0) else { return nil }
        return VehicleStatusRow(
            timestamp: try parseTimestamp(timestampText),
            odometerKm: sqliteOptionalIntColumn(statement, 1),
            socPercent: sqliteOptionalIntColumn(statement, 2),
            rangeKm: sqliteOptionalIntColumn(statement, 3)
        )
    }

    func loadTelemetryRows() throws -> [TelemetryRow] {
        let sql = """
        SELECT timestamp, odometer_km, soc_percent, COALESCE(charging, 0) AS charging
        FROM telemetry
        WHERE odometer_km IS NOT NULL
          AND soc_percent IS NOT NULL
        ORDER BY timestamp ASC;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var rows: [TelemetryRow] = []

        while true {
            let result = sqlite3_step(statement)

            if result == SQLITE_ROW {
                guard let timestampPointer = sqlite3_column_text(statement, 0) else {
                    continue
                }

                let timestampText = String(cString: timestampPointer)
                let odometerKm = Int(sqlite3_column_int64(statement, 1))
                let socPercent = Int(sqlite3_column_int64(statement, 2))
                let charging = sqlite3_column_int64(statement, 3) != 0

                rows.append(
                    TelemetryRow(
                        timestamp: try parseTimestamp(timestampText),
                        timestampText: timestampText,
                        odometerKm: odometerKm,
                        socPercent: socPercent,
                        charging: charging
                    )
                )
            } else if result == SQLITE_DONE {
                break
            } else {
                throw AppError.sqliteStepFailed(analyticsSQLiteErrorMessage(database))
            }
        }

        return rows
    }

    func loadChargeSessions(limit: Int) throws -> [ChargeSession] {
        let sql = """
        SELECT id,
               start_timestamp,
               end_timestamp,
               last_timestamp,
               start_soc_percent,
               end_soc_percent,
               start_kwh_missing,
               start_odometer_km,
               end_kwh_missing,
               charge_type,
               max_charge_power_kw
        FROM charge_sessions
        ORDER BY id DESC
        LIMIT ?;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var sessions: [ChargeSession] = []

        while true {
            let result = sqlite3_step(statement)

            if result == SQLITE_ROW {
                guard let startTimestampText = sqliteTextColumn(statement, 1) else {
                    continue
                }

                let endTimestampText = sqliteTextColumn(statement, 2)
                let lastTimestampText = sqliteTextColumn(statement, 3)

                sessions.append(
                    ChargeSession(
                        id: Int(sqlite3_column_int64(statement, 0)),
                        startTimestamp: try parseTimestamp(startTimestampText),
                        endTimestamp: try parseOptionalTimestamp(endTimestampText),
                        lastTimestamp: try parseOptionalTimestamp(lastTimestampText),
                        startSocPercent: sqliteOptionalIntColumn(statement, 4),
                        endSocPercent: sqliteOptionalIntColumn(statement, 5),
                        startKWhMissing: sqliteOptionalDoubleColumn(statement, 6),
                        startOdometerKm: sqliteOptionalIntColumn(statement, 7),
                        endKWhMissing: sqliteOptionalDoubleColumn(statement, 8),
                        chargeType: sqliteTextColumn(statement, 9),
                        maxChargePowerKW: sqliteOptionalDoubleColumn(statement, 10)
                    )
                )
            } else if result == SQLITE_DONE {
                break
            } else {
                throw AppError.sqliteStepFailed(analyticsSQLiteErrorMessage(database))
            }
        }

        return sessions
    }

    func loadAllChargeSessions() throws -> [ChargeSession] {
        let sql = """
        SELECT id,
               start_timestamp,
               end_timestamp,
               last_timestamp,
               start_soc_percent,
               end_soc_percent,
               start_kwh_missing,
               start_odometer_km,
               end_kwh_missing,
               charge_type,
               max_charge_power_kw
        FROM charge_sessions
        ORDER BY id DESC;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var sessions: [ChargeSession] = []

        while true {
            let result = sqlite3_step(statement)

            if result == SQLITE_ROW {
                guard let startTimestampText = sqliteTextColumn(statement, 1) else {
                    continue
                }

                let endTimestampText = sqliteTextColumn(statement, 2)
                let lastTimestampText = sqliteTextColumn(statement, 3)

                sessions.append(
                    ChargeSession(
                        id: Int(sqlite3_column_int64(statement, 0)),
                        startTimestamp: try parseTimestamp(startTimestampText),
                        endTimestamp: try parseOptionalTimestamp(endTimestampText),
                        lastTimestamp: try parseOptionalTimestamp(lastTimestampText),
                        startSocPercent: sqliteOptionalIntColumn(statement, 4),
                        endSocPercent: sqliteOptionalIntColumn(statement, 5),
                        startKWhMissing: sqliteOptionalDoubleColumn(statement, 6),
                        startOdometerKm: sqliteOptionalIntColumn(statement, 7),
                        endKWhMissing: sqliteOptionalDoubleColumn(statement, 8),
                        chargeType: sqliteTextColumn(statement, 9),
                        maxChargePowerKW: sqliteOptionalDoubleColumn(statement, 10)
                    )
                )
            } else if result == SQLITE_DONE {
                break
            } else {
                throw AppError.sqliteStepFailed(analyticsSQLiteErrorMessage(database))
            }
        }

        return sessions
    }
}

func parseTimestamp(_ value: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    guard let date = formatter.date(from: value) else {
        throw AppError.invalidTimestamp(value)
    }

    return date
}

func parseOptionalTimestamp(_ value: String?) throws -> Date? {
    guard let value = value else {
        return nil
    }

    return try parseTimestamp(value)
}

func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(0, Int(seconds / 60.0))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 {
        return String(format: "%dh%02d", hours, minutes)
    }

    return "\(minutes)min"
}

func padded(_ value: String, width: Int, alignRight: Bool = false) -> String {
    if value.count >= width {
        return value
    }

    let padding = String(repeating: " ", count: width - value.count)
    if alignRight {
        return padding + value
    }

    return value + padding
}

func appendTripIfValid(_ trips: inout [Trip], start: TelemetryRow?, end: TelemetryRow?, minDistanceKm: Int) {
    guard let start = start,
          let end = end else {
        return
    }

    let trip = Trip(start: start, end: end)
    if trip.distanceKm >= minDistanceKm {
        trips.append(trip)
    }
}

func buildTrips(rows: [TelemetryRow], maxGapMinutes: Double, minDistanceKm: Int) -> [Trip] {
    guard rows.count >= 2 else {
        return []
    }

    var trips: [Trip] = []
    var currentStart: TelemetryRow?
    var currentEnd: TelemetryRow?
    var previous = rows[0]

    for row in rows.dropFirst() {
        let odometerDelta = row.odometerKm - previous.odometerKm
        let socDelta = row.socPercent - previous.socPercent
        let gapMinutes = row.timestamp.timeIntervalSince(previous.timestamp) / 60.0

        // Charging rows, or a SOC increase between two rows, always split trips.
        if previous.charging || row.charging || socDelta > 0 {
            appendTripIfValid(
                &trips,
                start: currentStart,
                end: currentEnd,
                minDistanceKm: minDistanceKm
            )
            currentStart = nil
            currentEnd = nil
            previous = row
            continue
        }

        // If telemetry itself has a long gap, close the current trip.
        // Do not use the old reading as the start of the next trip, otherwise a charge/pause
        // with no telemetry updates gets counted inside the next trip duration.
        if gapMinutes > maxGapMinutes {
            appendTripIfValid(
                &trips,
                start: currentStart,
                end: currentEnd,
                minDistanceKm: minDistanceKm
            )
            currentStart = nil
            currentEnd = nil
            previous = row
            continue
        }

        if odometerDelta > 0 {
            // Driving segment: odometer increases.
            // Start from the previous reading, which is the closest known point before movement.
            if currentStart == nil {
                currentStart = previous
            }
            currentEnd = row
        } else if odometerDelta == 0 {
            // Stationary segment: do not extend currentEnd.
            // If the car has not moved for maxGapMinutes since the last movement,
            // close the current trip and do not count stationary rows in its duration.
            if let lastMovingRow = currentEnd {
                let stationaryMinutes = row.timestamp.timeIntervalSince(lastMovingRow.timestamp) / 60.0
                if stationaryMinutes > maxGapMinutes {
                    appendTripIfValid(
                        &trips,
                        start: currentStart,
                        end: currentEnd,
                        minDistanceKm: minDistanceKm
                    )
                    currentStart = nil
                    currentEnd = nil
                }
            }
        } else {
            // Odometer went backwards. Ignore this weird segment and close any open trip.
            appendTripIfValid(
                &trips,
                start: currentStart,
                end: currentEnd,
                minDistanceKm: minDistanceKm
            )
            currentStart = nil
            currentEnd = nil
        }

        previous = row
    }

    appendTripIfValid(
        &trips,
        start: currentStart,
        end: currentEnd,
        minDistanceKm: minDistanceKm
    )

    return trips
}

func consumptionKWhPer100Km(trip: Trip, config: AnalyticsConfig) -> Double? {
    let socDelta = trip.start.socPercent - trip.end.socPercent

    guard trip.distanceKm > 0, socDelta > 0 else {
        return nil
    }

    let effectiveCapacityKWh = config.batteryCapacityKWh * (config.sohPercent / 100.0)
    let energyUsedKWh = effectiveCapacityKWh * (Double(socDelta) / 100.0)

    return energyUsedKWh / Double(trip.distanceKm) * 100.0
}

func printTrips(_ trips: [Trip], config: AnalyticsConfig) {
    if trips.isEmpty {
        print("No trips found.")
        return
    }

    let header = [
        padded("Date", width: 12),
        padded("Start", width: 8),
        padded("Duration", width: 8),
        padded("Km", width: 8, alignRight: true),
        padded("SOC", width: 10, alignRight: true),
        padded("Consumption", width: 14, alignRight: true)
    ].joined(separator: " ")

    print(header)
    print(String(repeating: "-", count: header.count))

    for trip in trips {
        let dateText = formatDate(trip.start.timestamp)
        let startText = formatTime(trip.start.timestamp)
        let durationText = formatDuration(trip.durationSeconds)
        let kmText = "\(trip.distanceKm)"
        let socText = "\(trip.start.socPercent)%→\(trip.end.socPercent)%"

        let consumptionText: String
        if let consumption = consumptionKWhPer100Km(trip: trip, config: config) {
            consumptionText = String(format: "%.1f kWh/100", consumption)
        } else {
            consumptionText = "-"
        }

        let line = [
            padded(dateText, width: 12),
            padded(startText, width: 8),
            padded(durationText, width: 8),
            padded(kmText, width: 8, alignRight: true),
            padded(socText, width: 10, alignRight: true),
            padded(consumptionText, width: 14, alignRight: true)
        ].joined(separator: " ")

        print(line)
    }
}


func printChargeSessions(_ sessions: [ChargeSession]) {
    if sessions.isEmpty {
        print("No charge sessions found.")
        return
    }

    let header = [
        padded("Date", width: 12),
        padded("Start", width: 8),
        padded("Duration", width: 8),
        padded("Odometer", width: 10, alignRight: true),
        padded("SOC", width: 10, alignRight: true),
        padded("Added", width: 12, alignRight: true),
        padded("Type", width: 6, alignRight: true),
        padded("Max", width: 10, alignRight: true),
        padded("State", width: 8, alignRight: true)
    ].joined(separator: " ")

    print(header)
    print(String(repeating: "-", count: header.count))

    for session in sessions {
        let dateText = formatDate(session.startTimestamp)
        let startText = formatTime(session.startTimestamp)
        let durationText = formatDuration(session.durationSeconds)

        let odometerText: String
        if let startOdometerKm = session.startOdometerKm {
            odometerText = "\(startOdometerKm)"
        } else {
            odometerText = "-"
        }

        let socText: String
        if let startSoc = session.startSocPercent,
           let endSoc = session.endSocPercent {
            socText = "\(startSoc)%→\(endSoc)%"
        } else {
            socText = "-"
        }

        let addedText: String
        if let addedKWh = session.addedKWh {
            addedText = String(format: "%.1f kWh", addedKWh)
        } else {
            addedText = "-"
        }

        let typeText = session.chargeType ?? "-"

        let maxPowerText: String
        if let maxChargePowerKW = session.maxChargePowerKW {
            maxPowerText = String(format: "%.1f kW", maxChargePowerKW)
        } else {
            maxPowerText = "-"
        }

        let stateText = session.endTimestamp == nil ? "open" : "closed"

        let line = [
            padded(dateText, width: 12),
            padded(startText, width: 8),
            padded(durationText, width: 8),
            padded(odometerText, width: 10, alignRight: true),
            padded(socText, width: 10, alignRight: true),
            padded(addedText, width: 12, alignRight: true),
            padded(typeText, width: 6, alignRight: true),
            padded(maxPowerText, width: 10, alignRight: true),
            padded(stateText, width: 8, alignRight: true)
        ].joined(separator: " ")

        print(line)
    }
}

func printChargeRatio(_ sessions: [ChargeSession]) {
    let typedSessions = sessions.filter { session in
        guard let chargeType = session.chargeType?.uppercased() else {
            return false
        }

        return chargeType == "AC" || chargeType == "DC"
    }

    if typedSessions.isEmpty {
        print("Charge ratio: no AC/DC charge sessions found.")
        return
    }

    let acSessions = typedSessions.filter { $0.chargeType?.uppercased() == "AC" }
    let dcSessions = typedSessions.filter { $0.chargeType?.uppercased() == "DC" }

    let totalCount = typedSessions.count
    let acCount = acSessions.count
    let dcCount = dcSessions.count

    let acPercent = Double(acCount) / Double(totalCount) * 100.0
    let dcPercent = Double(dcCount) / Double(totalCount) * 100.0

    let acKWh = acSessions.compactMap { $0.addedKWh }.reduce(0.0, +)
    let dcKWh = dcSessions.compactMap { $0.addedKWh }.reduce(0.0, +)
    let totalKWh = acKWh + dcKWh

    print("")
    print("Charge ratio (all sessions)")
    print(
        String(
            format: "Sessions: AC %d/%d %.1f%% | DC %d/%d %.1f%%",
            acCount,
            totalCount,
            acPercent,
            dcCount,
            totalCount,
            dcPercent
        )
    )

    if totalKWh > 0.0 {
        let acKWhPercent = acKWh / totalKWh * 100.0
        let dcKWhPercent = dcKWh / totalKWh * 100.0

        print(
            String(
                format: "Energy:   AC %.1f kWh %.1f%% | DC %.1f kWh %.1f%%",
                acKWh,
                acKWhPercent,
                dcKWh,
                dcKWhPercent
            )
        )
    } else {
        print("Energy:   no usable kWh data")
    }
}

func latestTrips(_ trips: [Trip], limit: Int) -> [Trip] {
    return Array(trips.suffix(limit).reversed())
}

func runTrips(config: AnalyticsConfig) throws {
    let database = try Database(path: config.databasePath)
    let rows = try database.loadTelemetryRows()
    let trips = buildTrips(
        rows: rows,
        maxGapMinutes: config.maxGapMinutes,
        minDistanceKm: config.minDistanceKm
    )

    printTrips(latestTrips(trips, limit: config.limit), config: config)
}

func runCharges(config: AnalyticsConfig) throws {
    let database = try Database(path: config.databasePath)
    let sessions = try database.loadChargeSessions(limit: config.limit)
    let allSessions = try database.loadAllChargeSessions()

    printChargeSessions(sessions)
    printChargeRatio(allSessions)
}

func runSummary(config: AnalyticsConfig) throws {
    let database = try Database(path: config.databasePath)
    let rows = try database.loadTelemetryRows()
    let trips = buildTrips(
        rows: rows,
        maxGapMinutes: config.maxGapMinutes,
        minDistanceKm: config.minDistanceKm
    )
    let sessions = try database.loadChargeSessions(limit: config.limit)
    let allSessions = try database.loadAllChargeSessions()

    print("Last trips")
    printTrips(latestTrips(trips, limit: config.limit), config: config)
    print("")
    print("Last charge sessions")
    printChargeSessions(sessions)
    printChargeRatio(allSessions)
}
