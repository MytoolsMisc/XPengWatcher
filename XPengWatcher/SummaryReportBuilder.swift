import Foundation

enum ReportLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case french = "fr"
    case portuguese = "pt"
    case spanish = "es"
    case german = "de"
    case dutch = "nl"
    case italian = "it"
    case danish = "da"

    static var application: ReportLanguage {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return ReportLanguage.allCases.first { code.hasPrefix($0.rawValue) } ?? .english
    }
}

private struct ReportLabels {
    let vehicleStatus: String
    let noTelemetry: String
    let time: String
    let odometer: String
    let availableRange: String
    let lastTrips: String
    let noTrips: String
    let start: String
    let duration: String
    let consumption: String
    let lastCharges: String
    let noCharges: String
    let added: String
    let state: String
    let open: String
    let closed: String
    let noChargeRatio: String
    let chargeRatio: String
    let sessions: String
    let energy: String
    let noEnergy: String

    static func forLanguage(_ language: ReportLanguage) -> ReportLabels {
        switch language {
        case .english:
            return ReportLabels(
                vehicleStatus: "Vehicle status", noTelemetry: "no telemetry available",
                time: "Time", odometer: "Odometer", availableRange: "Available range",
                lastTrips: "Last trips", noTrips: "No trips found.", start: "Start",
                duration: "Duration", consumption: "Consumption",
                lastCharges: "Last charge sessions", noCharges: "No charge sessions found.",
                added: "Added", state: "State", open: "open", closed: "closed",
                noChargeRatio: "Charge ratio: no AC/DC charge sessions found.",
                chargeRatio: "Charge ratio (all sessions)", sessions: "Sessions",
                energy: "Energy", noEnergy: "no usable kWh data"
            )
        case .french:
            return ReportLabels(
                vehicleStatus: "État du véhicule", noTelemetry: "aucune télémétrie disponible",
                time: "Heure", odometer: "Odomètre", availableRange: "Autonomie disponible",
                lastTrips: "Derniers trajets", noTrips: "Aucun trajet trouvé.", start: "Départ",
                duration: "Durée", consumption: "Consommation",
                lastCharges: "Dernières recharges", noCharges: "Aucune recharge trouvée.",
                added: "Ajoutée", state: "État", open: "en cours", closed: "terminée",
                noChargeRatio: "Répartition des recharges : aucune session AC/DC trouvée.",
                chargeRatio: "Répartition des recharges (toutes sessions)", sessions: "Sessions",
                energy: "Énergie", noEnergy: "aucune donnée kWh exploitable"
            )
        case .portuguese:
            return ReportLabels(
                vehicleStatus: "Estado do veículo", noTelemetry: "sem telemetria disponível",
                time: "Hora", odometer: "Odómetro", availableRange: "Autonomia disponível",
                lastTrips: "Últimas viagens", noTrips: "Nenhuma viagem encontrada.", start: "Início",
                duration: "Duração", consumption: "Consumo",
                lastCharges: "Últimos carregamentos", noCharges: "Nenhum carregamento encontrado.",
                added: "Adicionada", state: "Estado", open: "em curso", closed: "concluído",
                noChargeRatio: "Distribuição dos carregamentos: nenhuma sessão AC/DC encontrada.",
                chargeRatio: "Distribuição dos carregamentos (todas as sessões)", sessions: "Sessões",
                energy: "Energia", noEnergy: "sem dados kWh utilizáveis"
            )
        case .spanish:
            return ReportLabels(
                vehicleStatus: "Estado del vehículo", noTelemetry: "sin telemetría disponible",
                time: "Hora", odometer: "Odómetro", availableRange: "Autonomía disponible",
                lastTrips: "Últimos trayectos", noTrips: "No se encontraron trayectos.", start: "Inicio",
                duration: "Duración", consumption: "Consumo",
                lastCharges: "Últimas sesiones de carga", noCharges: "No se encontraron sesiones de carga.",
                added: "Añadida", state: "Estado", open: "en curso", closed: "finalizada",
                noChargeRatio: "Distribución de carga: no se encontraron sesiones AC/DC.",
                chargeRatio: "Distribución de carga (todas las sesiones)", sessions: "Sesiones",
                energy: "Energía", noEnergy: "sin datos kWh utilizables"
            )
        case .german:
            return ReportLabels(
                vehicleStatus: "Fahrzeugstatus", noTelemetry: "keine Telemetriedaten verfügbar",
                time: "Uhrzeit", odometer: "Kilometerstand", availableRange: "Verfügbare Reichweite",
                lastTrips: "Letzte Fahrten", noTrips: "Keine Fahrten gefunden.", start: "Start",
                duration: "Dauer", consumption: "Verbrauch",
                lastCharges: "Letzte Ladevorgänge", noCharges: "Keine Ladevorgänge gefunden.",
                added: "Hinzugefügt", state: "Status", open: "aktiv", closed: "abgeschlossen",
                noChargeRatio: "Ladeverteilung: keine AC/DC-Ladevorgänge gefunden.",
                chargeRatio: "Ladeverteilung (alle Ladevorgänge)", sessions: "Vorgänge",
                energy: "Energie", noEnergy: "keine verwertbaren kWh-Daten"
            )
        case .dutch:
            return ReportLabels(
                vehicleStatus: "Voertuigstatus", noTelemetry: "geen telemetrie beschikbaar",
                time: "Tijd", odometer: "Kilometerstand", availableRange: "Beschikbaar bereik",
                lastTrips: "Laatste ritten", noTrips: "Geen ritten gevonden.", start: "Start",
                duration: "Duur", consumption: "Verbruik",
                lastCharges: "Laatste laadsessies", noCharges: "Geen laadsessies gevonden.",
                added: "Toegevoegd", state: "Status", open: "bezig", closed: "voltooid",
                noChargeRatio: "Laadverdeling: geen AC/DC-laadsessies gevonden.",
                chargeRatio: "Laadverdeling (alle sessies)", sessions: "Sessies",
                energy: "Energie", noEnergy: "geen bruikbare kWh-gegevens"
            )
        case .italian:
            return ReportLabels(
                vehicleStatus: "Stato del veicolo", noTelemetry: "nessun dato telemetrico disponibile",
                time: "Ora", odometer: "Contachilometri", availableRange: "Autonomia disponibile",
                lastTrips: "Ultimi viaggi", noTrips: "Nessun viaggio trovato.", start: "Inizio",
                duration: "Durata", consumption: "Consumo",
                lastCharges: "Ultime sessioni di ricarica", noCharges: "Nessuna sessione di ricarica trovata.",
                added: "Aggiunta", state: "Stato", open: "in corso", closed: "completata",
                noChargeRatio: "Distribuzione delle ricariche: nessuna sessione AC/DC trovata.",
                chargeRatio: "Distribuzione delle ricariche (tutte le sessioni)", sessions: "Sessioni",
                energy: "Energia", noEnergy: "nessun dato kWh utilizzabile"
            )
        case .danish:
            return ReportLabels(
                vehicleStatus: "Køretøjsstatus", noTelemetry: "ingen telemetri tilgængelig",
                time: "Tid", odometer: "Kilometertæller", availableRange: "Tilgængelig rækkevidde",
                lastTrips: "Seneste ture", noTrips: "Ingen ture fundet.", start: "Start",
                duration: "Varighed", consumption: "Forbrug",
                lastCharges: "Seneste opladninger", noCharges: "Ingen opladninger fundet.",
                added: "Tilføjet", state: "Status", open: "i gang", closed: "afsluttet",
                noChargeRatio: "Opladningsfordeling: ingen AC/DC-opladninger fundet.",
                chargeRatio: "Opladningsfordeling (alle opladninger)", sessions: "Opladninger",
                energy: "Energi", noEnergy: "ingen brugbare kWh-data"
            )
        }
    }
}

enum SummaryReportBuilder {
    static func make(
        databaseURL: URL,
        batteryCapacityKWh: Double,
        sohPercent: Double,
        language: ReportLanguage = .english,
        limit: Int = 10
    ) throws -> String {
        let labels = ReportLabels.forLanguage(language)
        let database = try Database(path: databaseURL.path)
        let config = AnalyticsConfig(
            databasePath: databaseURL.path,
            batteryCapacityKWh: batteryCapacityKWh,
            sohPercent: sohPercent,
            maxGapMinutes: 10,
            minDistanceKm: 1,
            limit: limit
        )
        let trips = buildTrips(
            rows: try database.loadTelemetryRows(),
            maxGapMinutes: config.maxGapMinutes,
            minDistanceKm: config.minDistanceKm
        )
        let sessions = try database.loadChargeSessions(limit: limit)
        let allSessions = try database.loadAllChargeSessions()
        let status = try database.loadLatestVehicleStatus()

        return [
            "XPengWatcher \(AppVersion.current)",
            "",
            statusHeader(status, labels: labels),
            "",
            labels.lastTrips,
            tripTable(latestTrips(trips, limit: limit), config: config, labels: labels),
            "",
            labels.lastCharges,
            chargeTable(sessions, labels: labels),
            "",
            chargeRatio(allSessions, labels: labels)
        ].joined(separator: "\n")
    }

    private static func statusHeader(_ status: VehicleStatusRow?, labels: ReportLabels) -> String {
        guard let status else { return "\(labels.vehicleStatus): \(labels.noTelemetry)" }
        let header = [
            padded("Date", width: 12),
            padded(labels.time, width: 8),
            padded(labels.odometer, width: 12, alignRight: true),
            padded("SOC", width: 8, alignRight: true),
            padded(labels.availableRange, width: 20, alignRight: true)
        ].joined(separator: " ")
        let row = [
            padded(formatDate(status.timestamp), width: 12),
            padded(formatTime(status.timestamp), width: 8),
            padded(status.odometerKm.map { "\($0) km" } ?? "-", width: 12, alignRight: true),
            padded(status.socPercent.map { "\($0)%" } ?? "-", width: 8, alignRight: true),
            padded(status.rangeKm.map { "\($0) km" } ?? "-", width: 20, alignRight: true)
        ].joined(separator: " ")
        return [labels.vehicleStatus, header, String(repeating: "-", count: header.count), row].joined(separator: "\n")
    }

    private static func tripTable(_ trips: [Trip], config: AnalyticsConfig, labels: ReportLabels) -> String {
        guard !trips.isEmpty else { return labels.noTrips }
        let header = [
            padded("Date", width: 12),
            padded(labels.start, width: 8),
            padded(labels.duration, width: 8),
            padded("Km", width: 8, alignRight: true),
            padded("SOC", width: 10, alignRight: true),
            padded(labels.consumption, width: 14, alignRight: true)
        ].joined(separator: " ")

        let rows = trips.map { trip in
            let consumption = consumptionKWhPer100Km(trip: trip, config: config)
                .map { String(format: "%.1f kWh/100", $0) } ?? "-"
            return [
                padded(formatDate(trip.start.timestamp), width: 12),
                padded(formatTime(trip.start.timestamp), width: 8),
                padded(formatDuration(trip.durationSeconds), width: 8),
                padded("\(trip.distanceKm)", width: 8, alignRight: true),
                padded("\(trip.start.socPercent)%→\(trip.end.socPercent)%", width: 10, alignRight: true),
                padded(consumption, width: 14, alignRight: true)
            ].joined(separator: " ")
        }
        return ([header, String(repeating: "-", count: header.count)] + rows).joined(separator: "\n")
    }

    private static func chargeTable(_ sessions: [ChargeSession], labels: ReportLabels) -> String {
        guard !sessions.isEmpty else { return labels.noCharges }
        let header = [
            padded("Date", width: 12),
            padded(labels.start, width: 8),
            padded(labels.duration, width: 8),
            padded(labels.odometer, width: 10, alignRight: true),
            padded("SOC", width: 10, alignRight: true),
            padded(labels.added, width: 12, alignRight: true),
            padded("Type", width: 6, alignRight: true),
            padded("Max", width: 10, alignRight: true),
            padded(labels.state, width: 8, alignRight: true)
        ].joined(separator: " ")

        let rows = sessions.map { session in
            let odometer = session.startOdometerKm.map(String.init) ?? "-"
            let soc = session.startSocPercent.flatMap { start in
                session.endSocPercent.map { "\(start)%→\($0)%" }
            } ?? "-"
            let added = session.addedKWh.map { String(format: "%.1f kWh", $0) } ?? "-"
            let maxPower = session.maxChargePowerKW.map { String(format: "%.1f kW", $0) } ?? "-"
            return [
                padded(formatDate(session.startTimestamp), width: 12),
                padded(formatTime(session.startTimestamp), width: 8),
                padded(formatDuration(session.durationSeconds), width: 8),
                padded(odometer, width: 10, alignRight: true),
                padded(soc, width: 10, alignRight: true),
                padded(added, width: 12, alignRight: true),
                padded(session.chargeType ?? "-", width: 6, alignRight: true),
                padded(maxPower, width: 10, alignRight: true),
                padded(session.endTimestamp == nil ? labels.open : labels.closed, width: 8, alignRight: true)
            ].joined(separator: " ")
        }
        return ([header, String(repeating: "-", count: header.count)] + rows).joined(separator: "\n")
    }

    private static func chargeRatio(_ sessions: [ChargeSession], labels: ReportLabels) -> String {
        let typed = sessions.filter {
            let type = $0.chargeType?.uppercased()
            return type == "AC" || type == "DC"
        }
        guard !typed.isEmpty else { return labels.noChargeRatio }

        let ac = typed.filter { $0.chargeType?.uppercased() == "AC" }
        let dc = typed.filter { $0.chargeType?.uppercased() == "DC" }
        let total = Double(typed.count)
        let sessionsLine = String(
            format: "\(labels.sessions): AC %d/%d %.1f%% | DC %d/%d %.1f%%",
            ac.count, typed.count, Double(ac.count) / total * 100,
            dc.count, typed.count, Double(dc.count) / total * 100
        )
        let acKWh = ac.compactMap(\.addedKWh).reduce(0, +)
        let dcKWh = dc.compactMap(\.addedKWh).reduce(0, +)
        let totalKWh = acKWh + dcKWh
        let energyLine = totalKWh > 0
            ? String(
                format: "\(labels.energy):   AC %.1f kWh %.1f%% | DC %.1f kWh %.1f%%",
                acKWh, acKWh / totalKWh * 100, dcKWh, dcKWh / totalKWh * 100
            )
            : "\(labels.energy):   \(labels.noEnergy)"
        return [labels.chargeRatio, sessionsLine, energyLine].joined(separator: "\n")
    }
}
