import Foundation

struct TripSnapshot {
    let date: Date
    let distanceKm: Int
    let durationSeconds: TimeInterval
    let startSOC: Int
    let endSOC: Int
    let consumption: Double?

    var title: String { "\(distanceKm) km · \(startSOC)% → \(endSOC)%" }
    var detail: String {
        if let consumption { return String(format: "%.1f kWh/100 km", consumption) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct ChargeSnapshot {
    let date: Date
    let startSOC: Int?
    let endSOC: Int?
    let addedKWh: Double?
    let type: String?

    var title: String {
        let soc = startSOC.flatMap { start in endSOC.map { "\(start)% → \($0)%" } } ?? String(localized: "Charge")
        return [type, soc].compactMap { $0 }.joined(separator: " · ")
    }
    var detail: String {
        if let addedKWh { return String(format: String(localized: "%.1f kWh added"), addedKWh) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct AnalyticsSnapshot {
    let latestTrip: TripSnapshot?
    let latestCharge: ChargeSnapshot?

    static func load(from databaseURL: URL, batteryCapacityKWh: Double, sohPercent: Double) throws -> AnalyticsSnapshot {
        let database = try Database(path: databaseURL.path)
        let config = AnalyticsConfig(
            databasePath: databaseURL.path,
            batteryCapacityKWh: batteryCapacityKWh,
            sohPercent: sohPercent,
            maxGapMinutes: 10,
            minDistanceKm: 1,
            limit: 1
        )
        let trips = buildTrips(rows: try database.loadTelemetryRows(), maxGapMinutes: 10, minDistanceKm: 1)
        let trip = trips.last.map {
            TripSnapshot(
                date: $0.start.timestamp,
                distanceKm: $0.distanceKm,
                durationSeconds: $0.durationSeconds,
                startSOC: $0.start.socPercent,
                endSOC: $0.end.socPercent,
                consumption: consumptionKWhPer100Km(trip: $0, config: config)
            )
        }
        let charge = try database.loadChargeSessions(limit: 1).first.map {
            ChargeSnapshot(
                date: $0.startTimestamp,
                startSOC: $0.startSocPercent,
                endSOC: $0.endSocPercent,
                addedKWh: $0.addedKWh,
                type: $0.chargeType
            )
        }
        return AnalyticsSnapshot(latestTrip: trip, latestCharge: charge)
    }
}
