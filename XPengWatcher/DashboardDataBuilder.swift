import Foundation

struct DashboardSnapshot {
    let calendarByMonth: [String: Data]
    let dayByDate: [String: Data]
}

private struct EnergyPointPayload: Codable {
    let minute: Double
    let kWh: Double
    let powerKW: Double?
}

private struct PowerPointPayload: Codable {
    let minute: Double
    let powerKW: Double
}

private struct TripPayload: Codable {
    let startMinute: Double
    let endMinute: Double
    let distanceKm: Int
    let durationSeconds: Double
    let energyKWh: Double
    let startSOC: Int
    let endSOC: Int
    let energyPoints: [EnergyPointPayload]
}

private struct ChargePayload: Codable {
    let startMinute: Double
    let endMinute: Double
    let durationSeconds: Double
    let energyKWh: Double
    let type: String?
    let maxPowerKW: Double?
    let startSOC: Int?
    let endSOC: Int?
    let powerPoints: [PowerPointPayload]
}

private struct DaySummaryPayload: Codable {
    let date: String
    var chargedKWh = 0.0
    var consumedKWh = 0.0
    var drivingSeconds = 0.0
    var chargingSeconds = 0.0
    var distanceKm = 0
    var tripCount = 0
    var chargeCount = 0
}

private struct DayDetailPayload: Codable {
    let date: String
    var summary: DaySummaryPayload
    var tripPoints: [EnergyPointPayload] = []
    var chargePoints: [EnergyPointPayload] = []
    var trips: [TripPayload] = []
    var charges: [ChargePayload] = []
}

private struct CalendarPayload: Codable {
    let month: String
    let days: [DaySummaryPayload]
}

enum DashboardDataBuilder {
    static func make(
        databaseURL: URL,
        batteryCapacityKWh: Double,
        sohPercent: Double
    ) throws -> DashboardSnapshot {
        let database = try Database(path: databaseURL.path)
        let rows = try database.loadTelemetryRows()
        let trips = buildTrips(rows: rows, maxGapMinutes: 10, minDistanceKm: 1)
        let sessions = try database.loadAllChargeSessions()
        let telemetryPoints = try database.loadDashboardTelemetryPoints()
        let pointsBySession = Dictionary(grouping: telemetryPoints.compactMap { point in
            point.chargeSessionId.map { ($0, point) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }

        let effectiveCapacity = batteryCapacityKWh * sohPercent / 100.0
        var details: [String: DayDetailPayload] = [:]

        for trip in trips {
            let key = dayKey(trip.start.timestamp)
            var detail = details[key] ?? emptyDay(key)
            let socUsed = max(0, trip.start.socPercent - trip.end.socPercent)
            let energy = effectiveCapacity * Double(socUsed) / 100.0
            var energyPoints = rows
                .filter { $0.timestamp >= trip.start.timestamp && $0.timestamp <= trip.end.timestamp && !$0.charging }
                .map { row in
                    EnergyPointPayload(
                        minute: minuteOfDay(row.timestamp),
                        kWh: effectiveCapacity * Double(max(0, trip.start.socPercent - row.socPercent)) / 100.0,
                        powerKW: nil
                    )
                }
            if energyPoints.isEmpty || energyPoints.first?.minute != minuteOfDay(trip.start.timestamp) {
                energyPoints.insert(EnergyPointPayload(minute: minuteOfDay(trip.start.timestamp), kWh: 0, powerKW: nil), at: 0)
            }
            if energyPoints.last?.minute != minuteOfDay(trip.end.timestamp) {
                energyPoints.append(EnergyPointPayload(minute: minuteOfDay(trip.end.timestamp), kWh: energy, powerKW: nil))
            }
            let payload = TripPayload(
                startMinute: minuteOfDay(trip.start.timestamp),
                endMinute: minuteOfDay(trip.end.timestamp),
                distanceKm: trip.distanceKm,
                durationSeconds: trip.durationSeconds,
                energyKWh: energy,
                startSOC: trip.start.socPercent,
                endSOC: trip.end.socPercent,
                energyPoints: energyPoints
            )
            detail.trips.append(payload)
            detail.summary.consumedKWh += energy
            detail.summary.drivingSeconds += trip.durationSeconds
            detail.summary.distanceKm += trip.distanceKm
            detail.summary.tripCount += 1
            details[key] = detail
        }

        for session in sessions {
            let key = dayKey(session.startTimestamp)
            var detail = details[key] ?? emptyDay(key)
            let energy = session.addedKWh ?? 0
            let rawPoints = pointsBySession[session.id, default: []]
                .filter { $0.charging }
                .sorted { $0.timestamp < $1.timestamp }
            var powerPoints = rawPoints.compactMap { point in
                point.chargePowerKW.map {
                    PowerPointPayload(minute: minuteOfDay(point.timestamp), powerKW: $0)
                }
            }
            if powerPoints.isEmpty, let maxPower = session.maxChargePowerKW {
                powerPoints = [
                    PowerPointPayload(minute: minuteOfDay(session.startTimestamp), powerKW: maxPower),
                    PowerPointPayload(minute: minuteOfDay(session.displayEndTimestamp), powerKW: maxPower)
                ]
            }
            let payload = ChargePayload(
                startMinute: minuteOfDay(session.startTimestamp),
                endMinute: minuteOfDay(session.displayEndTimestamp),
                durationSeconds: session.durationSeconds,
                energyKWh: energy,
                type: session.chargeType,
                maxPowerKW: session.maxChargePowerKW,
                startSOC: session.startSocPercent,
                endSOC: session.endSocPercent,
                powerPoints: powerPoints
            )
            detail.charges.append(payload)
            detail.summary.chargedKWh += energy
            detail.summary.chargingSeconds += session.durationSeconds
            detail.summary.chargeCount += 1

            let baseline = session.startKWhMissing ?? rawPoints.compactMap(\.kWhMissing).first
            if let baseline {
                detail.chargePoints.append(contentsOf: rawPoints.compactMap { point in
                    guard let missing = point.kWhMissing else { return nil }
                    return EnergyPointPayload(
                        minute: minuteOfDay(point.timestamp),
                        kWh: max(0, baseline - missing),
                        powerKW: point.chargePowerKW
                    )
                })
            }
            details[key] = detail
        }

        for key in details.keys {
            guard var detail = details[key] else { continue }
            detail.trips.sort { $0.startMinute < $1.startMinute }
            detail.charges.sort { $0.startMinute < $1.startMinute }
            detail.tripPoints = cumulativeTripPoints(detail.trips)
            detail.chargePoints = cumulativeChargePoints(detail.charges, raw: detail.chargePoints)
            details[key] = detail
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let dayData = try details.mapValues { try encoder.encode($0) }
        let summariesByMonth = Dictionary(grouping: details.values.map(\.summary), by: { String($0.date.prefix(7)) })
        let monthData = try summariesByMonth.mapValues { summaries in
            try encoder.encode(CalendarPayload(month: String(summaries.first?.date.prefix(7) ?? ""), days: summaries.sorted { $0.date < $1.date }))
        }
        return DashboardSnapshot(calendarByMonth: monthData, dayByDate: dayData)
    }

    private static func emptyDay(_ key: String) -> DayDetailPayload {
        DayDetailPayload(date: key, summary: DaySummaryPayload(date: key))
    }

    private static func cumulativeTripPoints(_ trips: [TripPayload]) -> [EnergyPointPayload] {
        var total = 0.0
        var points: [EnergyPointPayload] = []
        for trip in trips {
            points.append(EnergyPointPayload(minute: trip.startMinute, kWh: total, powerKW: nil))
            total += trip.energyKWh
            points.append(EnergyPointPayload(minute: trip.endMinute, kWh: total, powerKW: nil))
        }
        return points
    }

    private static func cumulativeChargePoints(_ charges: [ChargePayload], raw: [EnergyPointPayload]) -> [EnergyPointPayload] {
        var total = 0.0
        var output: [EnergyPointPayload] = []
        for charge in charges {
            let sessionPoints = raw.filter { $0.minute >= charge.startMinute && $0.minute <= charge.endMinute }
            output.append(EnergyPointPayload(minute: charge.startMinute, kWh: total, powerKW: sessionPoints.first?.powerKW))
            if sessionPoints.isEmpty {
                total += charge.energyKWh
                output.append(EnergyPointPayload(minute: charge.endMinute, kWh: total, powerKW: charge.maxPowerKW))
            } else {
                let rawStart = sessionPoints.first?.kWh ?? 0
                for point in sessionPoints {
                    output.append(EnergyPointPayload(minute: point.minute, kWh: total + max(0, point.kWh - rawStart), powerKW: point.powerKW))
                }
                total += charge.energyKWh
                output.append(EnergyPointPayload(minute: charge.endMinute, kWh: total, powerKW: charge.maxPowerKW))
            }
        }
        return output.sorted { $0.minute < $1.minute }
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func minuteOfDay(_ date: Date) -> Double {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60.0
    }
}
