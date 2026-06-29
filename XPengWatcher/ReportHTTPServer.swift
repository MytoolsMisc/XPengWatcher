import Foundation
import Network

final class ReportHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.nopapers.XPengWatcher.http", qos: .utility)
    private let reportLock = NSLock()
    private var reports: [ReportLanguage: String] = [:]
    private var listener: NWListener?

    func updateReports(_ reports: [ReportLanguage: String]) {
        reportLock.lock()
        self.reports = reports
        reportLock.unlock()
    }

    func start(port: UInt16) throws {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw URLError(.badURL)
        }
        let listener = try NWListener(using: .tcp, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var requestData = accumulated
            if let data { requestData.append(data) }
            let headersComplete = requestData.range(of: Data("\r\n\r\n".utf8)) != nil
            if !headersComplete && !isComplete && error == nil && requestData.count < 65_536 {
                self.receiveRequest(connection, accumulated: requestData)
                return
            }
            let request = String(data: requestData, encoding: .utf8) ?? ""
            self.sendResponse(for: request, over: connection)
        }
    }

    private func sendResponse(for request: String, over connection: NWConnection) {
            let path = self.requestPath(request)
            let language = self.preferredLanguage(request)
            let report = self.currentReport(language: language)
            let response: Data
            if path == "/favicon.png" || path == "/favicon.ico" {
                let favicon = Bundle.main.url(forResource: "favicon", withExtension: "png")
                    .flatMap { try? Data(contentsOf: $0) } ?? Data()
                response = self.responseData(
                    status: favicon.isEmpty ? "404 Not Found" : "200 OK",
                    contentType: "image/png",
                    bodyData: favicon,
                    language: language
                )
            } else if path == "/report.txt" {
                response = self.response(
                    status: "200 OK",
                    contentType: "text/plain; charset=utf-8",
                    body: report,
                    language: language
                )
            } else if path == "/" {
                response = self.response(
                    status: "200 OK",
                    contentType: "text/html; charset=utf-8",
                    body: self.htmlPage(report: report, language: language),
                    language: language
                )
            } else {
                response = self.response(
                    status: "404 Not Found",
                    contentType: "text/plain; charset=utf-8",
                    body: httpLabels(language).notFound + "\n",
                    language: language
                )
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func requestPath(_ request: String) -> String {
        guard let firstLine = request.split(separator: "\n", maxSplits: 1).first else { return "/" }
        let fields = firstLine.split(separator: " ")
        return fields.count >= 2 ? String(fields[1].split(separator: "?", maxSplits: 1)[0]) : "/"
    }

    private func preferredLanguage(_ request: String) -> ReportLanguage {
        if let firstLine = request.split(separator: "\n", maxSplits: 1).first {
            let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if let language = ReportLanguage.allCases.first(where: { target.contains("lang=\($0.rawValue)") }) {
                return language
            }
        }
        guard let header = request.split(separator: "\n").first(where: {
            $0.lowercased().hasPrefix("accept-language:")
        }) else { return .english }
        let value = header.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        var best: (language: ReportLanguage, quality: Double, order: Int)?
        for (order, item) in value.split(separator: ",").enumerated() {
            let parts = item.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let tag = parts[0].lowercased()
            let language = ReportLanguage.allCases.first { tag.hasPrefix($0.rawValue) }
            guard let language else { continue }
            let quality = parts.dropFirst().first(where: { $0.hasPrefix("q=") })
                .flatMap { Double($0.dropFirst(2)) } ?? 1
            if best == nil || quality > best!.quality || (quality == best!.quality && order < best!.order) {
                best = (language, quality, order)
            }
        }
        return best?.language ?? .english
    }

    private func currentReport(language: ReportLanguage) -> String {
        reportLock.lock()
        defer { reportLock.unlock() }
        return reports[language] ?? reports[.english] ?? "No report available."
    }

    private func response(status: String, contentType: String, body: String, language: ReportLanguage) -> Data {
        let bodyData = Data(body.utf8)
        return responseData(status: status, contentType: contentType, bodyData: bodyData, language: language)
    }

    private func responseData(status: String, contentType: String, bodyData: Data, language: ReportLanguage) -> Data {
        let headers = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Language: \(language.rawValue)\r
        Content-Length: \(bodyData.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        return Data(headers.utf8) + bodyData
    }

    private func htmlPage(report: String, language: ReportLanguage) -> String {
        let labels = httpLabels(language)
        let languageCode = language.rawValue
        let escaped = report
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html lang="\(languageCode)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <link rel="icon" type="image/png" href="/favicon.png">
          <meta http-equiv="refresh" content="60">
          <title>\(labels.title)</title>
          <script>
            (() => {
              const browserLanguage = (navigator.languages?.[0] || navigator.language || "en").toLowerCase();
              const supported = ["en", "fr", "pt", "es", "de", "nl", "it", "da"];
              const shortCode = browserLanguage.split("-")[0];
              const wanted = supported.includes(shortCode) ? shortCode : "en";
              const query = new URLSearchParams(location.search);
              if (!query.has("lang") && wanted !== document.documentElement.lang) {
                location.replace("/?lang=" + wanted);
              }
            })();
          </script>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 0; background: #0b1220; color: #e8eef9; }
            header { padding: 32px max(24px, 6vw); background: linear-gradient(135deg, #111d35, #0e705f); }
            h1 { margin: 0 0 6px; font-size: clamp(26px, 4vw, 42px); letter-spacing: -.03em; }
            header p { margin: 0; color: #bcd8d1; }
            main { padding: 28px max(16px, 6vw) 48px; }
            .card { max-width: 1100px; margin: auto; padding: 24px; border: 1px solid #2a3a55;
                    border-radius: 16px; background: rgba(18, 28, 47, .92); box-shadow: 0 18px 50px #0006; overflow-x: auto; }
            pre { margin: 0; font: 14px/1.65 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre; }
            footer { max-width: 1100px; margin: 14px auto 0; color: #7f91ad; font-size: 12px; }
            a { color: #69dfc4; }
          </style>
        </head>
        <body>
          <header><h1>\(labels.title)</h1><p>\(labels.subtitle)</p></header>
          <main><section class="card"><pre>\(escaped)</pre></section>
          <footer>\(labels.footer) · <a href="/report.txt?lang=\(languageCode)">\(labels.plainText)</a></footer></main>
        </body>
        </html>
        """
    }

    private func httpLabels(_ language: ReportLanguage) -> (title: String, subtitle: String, footer: String, plainText: String, notFound: String) {
        switch language {
        case .english:
            return ("XPeng vehicle report", "Live summary from XPengWatcher", "Automatically refreshed every 60 seconds", "Plain text", "Not found")
        case .french:
            return ("Rapport du véhicule XPeng", "Synthèse actualisée par XPengWatcher", "Actualisation automatique toutes les 60 secondes", "Version texte", "Page introuvable")
        case .portuguese:
            return ("Relatório do veículo XPeng", "Resumo atualizado pelo XPengWatcher", "Atualização automática a cada 60 segundos", "Versão em texto", "Página não encontrada")
        case .spanish:
            return ("Informe del vehículo XPeng", "Resumen actualizado por XPengWatcher", "Actualización automática cada 60 segundos", "Versión de texto", "Página no encontrada")
        case .german:
            return ("XPeng-Fahrzeugbericht", "Aktuelle Übersicht von XPengWatcher", "Automatische Aktualisierung alle 60 Sekunden", "Textversion", "Seite nicht gefunden")
        case .dutch:
            return ("XPeng-voertuigrapport", "Actueel overzicht van XPengWatcher", "Automatisch vernieuwd om de 60 seconden", "Tekstversie", "Pagina niet gevonden")
        case .italian:
            return ("Rapporto del veicolo XPeng", "Riepilogo aggiornato da XPengWatcher", "Aggiornamento automatico ogni 60 secondi", "Versione testuale", "Pagina non trovata")
        case .danish:
            return ("XPeng-køretøjsrapport", "Aktuel oversigt fra XPengWatcher", "Opdateres automatisk hvert 60. sekund", "Tekstversion", "Siden blev ikke fundet")
        }
    }
}
