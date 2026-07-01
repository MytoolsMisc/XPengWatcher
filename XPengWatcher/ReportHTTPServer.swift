import Foundation
import Network

final class ReportHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.nopapers.XPengWatcher.http", qos: .utility)
    private let reportLock = NSLock()
    private var reports: [ReportLanguage: String] = [:]
    private var calendarByMonth: [String: Data] = [:]
    private var dayByDate: [String: Data] = [:]
    private var listener: NWListener?

    func updateReports(_ reports: [ReportLanguage: String]) {
        reportLock.lock()
        self.reports = reports
        reportLock.unlock()
    }

    func updateDashboard(_ snapshot: DashboardSnapshot) {
        reportLock.lock()
        calendarByMonth = snapshot.calendarByMonth
        dayByDate = snapshot.dayByDate
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
            if path == "/api/calendar" {
                let month = queryValue("month", request: request) ?? currentMonthKey()
                let data = dashboardData(month: month) ?? Data("{\"month\":\"\(jsonEscaped(month))\",\"days\":[]}".utf8)
                response = self.responseData(
                    status: "200 OK", contentType: "application/json; charset=utf-8",
                    bodyData: data, language: language
                )
            } else if path == "/api/day" {
                let date = queryValue("date", request: request) ?? ""
                let data = dashboardData(date: date) ?? Data("{\"date\":\"\(jsonEscaped(date))\",\"summary\":{\"date\":\"\(jsonEscaped(date))\",\"chargedKWh\":0,\"consumedKWh\":0,\"drivingSeconds\":0,\"chargingSeconds\":0,\"distanceKm\":0,\"tripCount\":0,\"chargeCount\":0},\"tripPoints\":[],\"chargePoints\":[],\"trips\":[],\"charges\":[]}".utf8)
                response = self.responseData(
                    status: "200 OK", contentType: "application/json; charset=utf-8",
                    bodyData: data, language: language
                )
            } else if path == "/favicon.png" || path == "/favicon.ico" {
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

    private func queryValue(_ name: String, request: String) -> String? {
        guard let firstLine = request.split(separator: "\n", maxSplits: 1).first else { return nil }
        let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let components = URLComponents(string: "http://localhost\(target)") else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func currentMonthKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private func dashboardData(month: String) -> Data? {
        reportLock.lock()
        defer { reportLock.unlock() }
        return calendarByMonth[month]
    }

    private func dashboardData(date: String) -> Data? {
        reportLock.lock()
        defer { reportLock.unlock() }
        return dayByDate[date]
    }

    private func jsonEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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
            button { font: inherit; }
            main { padding: 28px max(16px, 6vw) 48px; max-width: 1180px; margin: auto; }
            .card { margin: 0 0 22px; padding: 24px; border: 1px solid #2a3a55; border-radius: 16px;
                    background: rgba(18, 28, 47, .92); box-shadow: 0 18px 50px #0006; overflow-x: auto; }
            .toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 18px; }
            .toolbar h2, .card h2, .card h3 { margin: 0; }
            .nav { border: 1px solid #3b516f; background: #162740; color: #e8eef9; border-radius: 9px; padding: 8px 12px; cursor: pointer; }
            .nav:hover { background: #214063; }
            .weekdays, .calendar { display: grid; grid-template-columns: repeat(7, minmax(95px, 1fr)) minmax(120px, 1.15fr); gap: 7px; min-width: 860px; }
            .weekdays div { text-align: center; color: #8da1bd; font-size: 12px; padding: 4px; }
            .day { min-height: 106px; padding: 9px; text-align: left; color: inherit; border: 1px solid #263c59;
                   border-radius: 11px; background: #101d31; cursor: pointer; }
            .day:hover { border-color: #4fd6bd; transform: translateY(-1px); }
            .day.empty { visibility: hidden; }
            .day .number { font-weight: 700; margin-bottom: 7px; }
            .day .metric { display: block; font-size: 11px; line-height: 1.45; color: #b9c8dc; white-space: nowrap; }
            .day.active { background: linear-gradient(145deg, #122844, #12362f); }
            .week-total { min-height: 106px; padding: 9px; border: 1px solid #446075; border-radius: 11px;
                          background: linear-gradient(145deg, #17263a, #243249); }
            .week-total .number { color: #8de5d3; font-size: 11px; font-weight: 700; margin-bottom: 7px; text-transform: uppercase; letter-spacing: .04em; }
            .week-total .metric { display: block; font-size: 11px; line-height: 1.5; color: #d2dceb; white-space: nowrap; }
            .week-total .average { color: #8de5d3; font-weight: 700; margin-top: 4px; }
            .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(145px, 1fr)); gap: 10px; margin: 16px 0 22px; }
            .stat { padding: 13px; border-radius: 11px; background: #0d192a; border: 1px solid #263a55; }
            .stat small { color: #8fa3bd; display: block; margin-bottom: 5px; }
            .stat strong { font-size: 19px; }
            .charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 14px; }
            .chart { background: #0b1626; border: 1px solid #263a55; border-radius: 12px; padding: 12px; min-height: 260px; }
            .chart h3 { font-size: 14px; margin-bottom: 8px; }
            .chart svg { width: 100%; height: auto; display: block; }
            .axis { stroke: #526681; stroke-width: 1; } .gridline { stroke: #26374d; stroke-width: 1; }
            .axis-label { fill: #8fa3bd; font: 11px -apple-system, sans-serif; }
            .events { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin-top: 18px; }
            .event { padding: 10px 12px; margin-top: 7px; border-radius: 9px; background: #101e31; color: #c5d2e4; font-size: 13px; }
            .event-button { display: block; width: 100%; border: 1px solid transparent; text-align: left; cursor: pointer; }
            .event-button:hover, .event-button:focus-visible { border-color: #55a8ff; background: #152b45; outline: none; }
            .power-panel { margin-top: 18px; min-height: 0; }
            .power-panel .toolbar { margin-bottom: 8px; }
            .graph-tooltip { position: fixed; z-index: 100; pointer-events: none; padding: 7px 9px; border: 1px solid #526b89;
                             border-radius: 7px; background: #07111fee; color: #edf5ff; font-size: 12px;
                             box-shadow: 0 7px 20px #0008; transform: translate(12px, 12px); white-space: nowrap; }
            details summary { cursor: pointer; font-weight: 700; }
            pre { margin: 0; font: 14px/1.65 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre; }
            details pre { margin-top: 18px; }
            footer { margin: 14px auto 0; color: #7f91ad; font-size: 12px; }
            a { color: #69dfc4; }
            @media (max-width: 700px) { .events { grid-template-columns: 1fr; } .charts { grid-template-columns: 1fr; } }
          </style>
        </head>
        <body>
          <header><h1>\(labels.title)</h1><p>\(labels.subtitle) \(AppVersion.current)</p></header>
          <main>
            <section class="card">
              <div class="toolbar"><button class="nav" id="previousMonth">←</button><h2 id="monthTitle"></h2><button class="nav" id="nextMonth">→</button></div>
              <div class="weekdays" id="weekdays"></div><div class="calendar" id="calendar"></div>
            </section>
            <section class="card" id="dayPanel" hidden>
              <div class="toolbar"><h2 id="dayTitle"></h2><button class="nav" id="closeDay">×</button></div>
              <div class="summary-grid" id="daySummary"></div>
              <div class="charts"><div class="chart"><h3 id="tripChartTitle"></h3><div id="tripChart"></div></div>
              <div class="chart"><h3 id="chargeChartTitle"></h3><div id="chargeChart"></div></div></div>
              <div class="events"><div><h3 id="tripsTitle"></h3><div id="tripList"></div></div>
              <div><h3 id="chargesTitle"></h3><div id="chargeList"></div></div></div>
              <div class="chart power-panel" id="tripDetailPanel" hidden>
                <div class="toolbar"><h3 id="tripDetailTitle"></h3><button class="nav" id="closeTripDetail">×</button></div>
                <div id="tripDetailChart"></div>
              </div>
              <div class="chart power-panel" id="powerPanel" hidden>
                <div class="toolbar"><h3 id="powerChartTitle"></h3><button class="nav" id="closePower">×</button></div>
                <div id="powerChart"></div>
              </div>
            </section>
            <details class="card"><summary id="textReportTitle"></summary><pre>\(escaped)</pre></details>
            <footer>\(labels.footer) · <a href="/report.txt?lang=\(languageCode)">\(labels.plainText)</a></footer>
          </main>
          <div class="graph-tooltip" id="graphTooltip" hidden></div>
          <script>
          (() => {
            const lang = document.documentElement.lang;
            const words = {
              en:{charged:"Charged",consumed:"Consumed",driving:"Driving",charging:"Charging",distance:"Distance",trips:"Trips",charges:"Charges",tripEnergy:"Driving energy",chargeEnergy:"Charging energy",chargePower:"Charging power",textReport:"Text summary",noActivity:"No activity",week:"Week",kwh:"kWh"},
              fr:{charged:"Chargé",consumed:"Consommé",driving:"Conduite",charging:"Recharge",distance:"Distance",trips:"Trajets",charges:"Recharges",tripEnergy:"Énergie consommée",chargeEnergy:"Énergie rechargée",chargePower:"Puissance de recharge",textReport:"Résumé texte",noActivity:"Aucune activité",week:"Semaine",kwh:"kWh"},
              pt:{charged:"Carregado",consumed:"Consumido",driving:"Condução",charging:"Carregamento",distance:"Distância",trips:"Viagens",charges:"Carregamentos",tripEnergy:"Energia de condução",chargeEnergy:"Energia carregada",chargePower:"Potência de carregamento",textReport:"Resumo em texto",noActivity:"Sem atividade",week:"Semana",kwh:"kWh"},
              es:{charged:"Cargado",consumed:"Consumido",driving:"Conducción",charging:"Carga",distance:"Distancia",trips:"Trayectos",charges:"Cargas",tripEnergy:"Energía consumida",chargeEnergy:"Energía cargada",chargePower:"Potencia de carga",textReport:"Resumen de texto",noActivity:"Sin actividad",week:"Semana",kwh:"kWh"},
              de:{charged:"Geladen",consumed:"Verbraucht",driving:"Fahrzeit",charging:"Ladezeit",distance:"Strecke",trips:"Fahrten",charges:"Ladevorgänge",tripEnergy:"Fahrenergie",chargeEnergy:"Ladeenergie",chargePower:"Ladeleistung",textReport:"Textübersicht",noActivity:"Keine Aktivität",week:"Woche",kwh:"kWh"},
              nl:{charged:"Geladen",consumed:"Verbruikt",driving:"Rijtijd",charging:"Laadtijd",distance:"Afstand",trips:"Ritten",charges:"Laadsessies",tripEnergy:"Rij-energie",chargeEnergy:"Laadenergie",chargePower:"Laadvermogen",textReport:"Tekstoverzicht",noActivity:"Geen activiteit",week:"Week",kwh:"kWh"},
              it:{charged:"Caricata",consumed:"Consumata",driving:"Guida",charging:"Ricarica",distance:"Distanza",trips:"Viaggi",charges:"Ricariche",tripEnergy:"Energia consumata",chargeEnergy:"Energia ricaricata",chargePower:"Potenza di ricarica",textReport:"Riepilogo testuale",noActivity:"Nessuna attività",week:"Settimana",kwh:"kWh"},
              da:{charged:"Opladet",consumed:"Forbrugt",driving:"Kørsel",charging:"Opladning",distance:"Distance",trips:"Ture",charges:"Opladninger",tripEnergy:"Køreenergi",chargeEnergy:"Opladningsenergi",chargePower:"Ladeeffekt",textReport:"Tekstoversigt",noActivity:"Ingen aktivitet",week:"Uge",kwh:"kWh"}
            };
            const t = words[lang] || words.en;
            let month = new Date(); month.setDate(1); let selectedDate = null, selectedChargeKey = null, selectedTripKey = null;
            const pad = n => String(n).padStart(2,"0");
            const monthKey = () => `${month.getFullYear()}-${pad(month.getMonth()+1)}`;
            const dateKey = d => `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
            const duration = s => { const m=Math.round(s/60), h=Math.floor(m/60); return h ? `${h}h ${m%60}m` : `${m}m`; };
            const time = m => `${pad(Math.floor(m/60))}:${pad(Math.floor(m%60))}`;
            const number = n => new Intl.NumberFormat(lang,{maximumFractionDigits:1}).format(n||0);
            const escapeHTML = s => String(s??"").replace(/[&<>\"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

            function renderWeekdays(){
              const base=new Date(2024,0,1), f=new Intl.DateTimeFormat(lang,{weekday:"short"});
              document.getElementById("weekdays").innerHTML=Array.from({length:7},(_,i)=>`<div>${f.format(new Date(2024,0,1+i))}</div>`).join("")+`<div>${t.week}</div>`;
            }
            async function loadCalendar(){
              const key=monthKey(), data=await fetch(`/api/calendar?month=${key}&lang=${lang}`).then(r=>r.json());
              document.getElementById("monthTitle").textContent=new Intl.DateTimeFormat(lang,{month:"long",year:"numeric"}).format(month);
              const map=new Map(data.days.map(d=>[d.date,d])), slots=[];
              const offset=(new Date(month.getFullYear(),month.getMonth(),1).getDay()+6)%7;
              for(let i=0;i<offset;i++) slots.push(null);
              const count=new Date(month.getFullYear(),month.getMonth()+1,0).getDate();
              for(let day=1;day<=count;day++){
                const d=new Date(month.getFullYear(),month.getMonth(),day), key=dateKey(d); slots.push({day,key,data:map.get(key)});
              }
              while(slots.length%7) slots.push(null);
              const cells=[];
              for(let i=0;i<slots.length;i+=7){
                const week=slots.slice(i,i+7);
                for(const entry of week){
                  if(!entry){ cells.push('<div class="day empty"></div>'); continue; }
                  const x=entry.data, active=x&&(x.tripCount||x.chargeCount);
                  const metrics=x?`<span class="metric">⚡ +${number(x.chargedKWh)} ${t.kwh} · ${duration(x.chargingSeconds)}</span><span class="metric">🚗 −${number(x.consumedKWh)} ${t.kwh} · ${duration(x.drivingSeconds)}</span><span class="metric">${x.distanceKm} km</span>`:"";
                  cells.push(`<button class="day ${active?'active':''}" data-date="${entry.key}"><div class="number">${entry.day}</div>${metrics}</button>`);
                }
                const totals=week.reduce((a,e)=>{const x=e?.data;if(x){a.charged+=x.chargedKWh;a.consumed+=x.consumedKWh;a.distance+=x.distanceKm;}return a;},{charged:0,consumed:0,distance:0});
                const average=totals.distance>0?`${number(totals.consumed/totals.distance*100)} kWh/100 km`:"—";
                cells.push(`<div class="week-total"><div class="number">${t.week}</div><span class="metric">⚡ +${number(totals.charged)} ${t.kwh}</span><span class="metric">🚗 −${number(totals.consumed)} ${t.kwh}</span><span class="metric">${totals.distance} km</span><span class="metric average">${average}</span></div>`);
              }
              const calendar=document.getElementById("calendar"); calendar.innerHTML=cells.join("");
              calendar.querySelectorAll("[data-date]").forEach(el=>el.onclick=()=>loadDay(el.dataset.date));
            }
            function stat(label,value){ return `<div class="stat"><small>${label}</small><strong>${value}</strong></div>`; }
            async function loadDay(date,shouldScroll=true){
              if(selectedDate!==date){ selectedChargeKey=null; selectedTripKey=null; }
              selectedDate=date; const data=await fetch(`/api/day?date=${date}&lang=${lang}`).then(r=>r.json()), s=data.summary;
              document.getElementById("dayPanel").hidden=false;
              document.getElementById("dayTitle").textContent=new Intl.DateTimeFormat(lang,{dateStyle:"full"}).format(new Date(`${date}T12:00:00`));
              document.getElementById("daySummary").innerHTML=stat(t.charged,`+${number(s.chargedKWh)} ${t.kwh}`)+stat(t.consumed,`−${number(s.consumedKWh)} ${t.kwh}`)+stat(t.driving,duration(s.drivingSeconds))+stat(t.charging,duration(s.chargingSeconds))+stat(t.distance,`${s.distanceKm} km`);
              document.getElementById("tripChartTitle").textContent=t.tripEnergy; document.getElementById("chargeChartTitle").textContent=t.chargeEnergy;
              chart(document.getElementById("tripChart"),data.tripPoints,"#48d8c0"); chart(document.getElementById("chargeChart"),data.chargePoints,"#55a8ff");
              document.getElementById("tripsTitle").textContent=`${t.trips} (${data.trips.length})`; document.getElementById("chargesTitle").textContent=`${t.charges} (${data.charges.length})`;
              const tripList=document.getElementById("tripList");
              tripList.innerHTML=data.trips.length?data.trips.map((x,i)=>`<button class="event event-button" data-trip-index="${i}">${time(x.startMinute)}–${time(x.endMinute)} · ${x.distanceKm} km · ${number(x.energyKWh)} ${t.kwh} · ${x.startSOC}%→${x.endSOC}%</button>`).join(""):`<div class="event">${t.noActivity}</div>`;
              tripList.querySelectorAll("[data-trip-index]").forEach(el=>el.onclick=()=>showTripDetail(data.trips[Number(el.dataset.tripIndex)]));
              const chargeList=document.getElementById("chargeList");
              chargeList.innerHTML=data.charges.length?data.charges.map((x,i)=>`<button class="event event-button" data-charge-index="${i}">${time(x.startMinute)}–${time(x.endMinute)} · ${number(x.energyKWh)} ${t.kwh} · ${escapeHTML(x.type||"")} ${x.maxPowerKW?`· ${number(x.maxPowerKW)} kW`:""}</button>`).join(""):`<div class="event">${t.noActivity}</div>`;
              chargeList.querySelectorAll("[data-charge-index]").forEach(el=>el.onclick=()=>showChargePower(data.charges[Number(el.dataset.chargeIndex)]));
              const selectedCharge=data.charges.find(x=>chargeKey(x)===selectedChargeKey);
              if(selectedCharge) showChargePower(selectedCharge,false); else document.getElementById("powerPanel").hidden=true;
              const selectedTrip=data.trips.find(x=>tripKey(x)===selectedTripKey);
              if(selectedTrip) showTripDetail(selectedTrip,false); else document.getElementById("tripDetailPanel").hidden=true;
              if(shouldScroll) document.getElementById("dayPanel").scrollIntoView({behavior:"smooth",block:"start"});
            }
            const tripKey = trip => `${trip.startMinute}-${trip.endMinute}`;
            function showTripDetail(trip,shouldScroll=true){
              const panel=document.getElementById("tripDetailPanel");
              selectedTripKey=tripKey(trip);
              document.getElementById("tripDetailTitle").textContent=`${t.tripEnergy} · ${time(trip.startMinute)}–${time(trip.endMinute)}`;
              energyDetailChart(document.getElementById("tripDetailChart"),trip.energyPoints||[],trip.startMinute,trip.endMinute);
              panel.hidden=false;
              if(shouldScroll) panel.scrollIntoView({behavior:"smooth",block:"nearest"});
            }
            const chargeKey = charge => `${charge.startMinute}-${charge.endMinute}`;
            function showChargePower(charge,shouldScroll=true){
              const panel=document.getElementById("powerPanel");
              selectedChargeKey=chargeKey(charge);
              document.getElementById("powerChartTitle").textContent=`${t.chargePower} · ${time(charge.startMinute)}–${time(charge.endMinute)}`;
              powerChart(document.getElementById("powerChart"),charge.powerPoints||[],charge.startMinute,charge.endMinute);
              panel.hidden=false;
              if(shouldScroll) panel.scrollIntoView({behavior:"smooth",block:"nearest"});
            }
            function powerChart(host,points,startMinute,endMinute){
              if(!points.length){ host.innerHTML=`<div class="event">${t.noActivity}</div>`; return; }
              const W=760,H=260,L=54,R=16,T=14,B=34;
              const minX=Math.min(startMinute,...points.map(p=>p.minute)), maxX=Math.max(endMinute,...points.map(p=>p.minute),minX+1);
              const maxY=Math.max(1,...points.map(p=>p.powerKW));
              const x=m=>L+((m-minX)/(maxX-minX))*(W-L-R), y=v=>T+(1-v/maxY)*(H-T-B);
              const xGrid=Array.from({length:5},(_,i)=>{const m=minX+(maxX-minX)*i/4;return `<line class="gridline" x1="${x(m)}" y1="${T}" x2="${x(m)}" y2="${H-B}"/><text class="axis-label" x="${x(m)}" y="${H-10}" text-anchor="middle">${time(m)}</text>`}).join("");
              const yGrid=Array.from({length:5},(_,i)=>{const v=maxY*i/4;return `<line class="gridline" x1="${L}" y1="${y(v)}" x2="${W-R}" y2="${y(v)}"/><text class="axis-label" x="${L-7}" y="${y(v)+4}" text-anchor="end">${number(v)}</text>`}).join("");
              const path=points.map(p=>`${x(p.minute)},${y(p.powerKW)}`).join(" ");
              const dots=points.map(p=>`<circle cx="${x(p.minute)}" cy="${y(p.powerKW)}" r="3" fill="#ffb454"/><circle class="tooltip-target" cx="${x(p.minute)}" cy="${y(p.powerKW)}" r="11" fill="transparent" tabindex="0" data-tip="${escapeHTML(`${time(p.minute)} · ${number(p.powerKW)} kW`)}"/>`).join("");
              host.innerHTML=`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${escapeHTML(t.chargePower)}">${xGrid}${yGrid}<line class="axis" x1="${L}" y1="${T}" x2="${L}" y2="${H-B}"/><line class="axis" x1="${L}" y1="${H-B}" x2="${W-R}" y2="${H-B}"/><text class="axis-label" x="6" y="${T+5}">kW</text><polyline fill="none" stroke="#ffb454" stroke-width="3" stroke-linejoin="round" points="${path}"/>${dots}</svg>`;
              wireTooltips(host);
            }
            function energyDetailChart(host,points,startMinute,endMinute){
              if(!points.length){ host.innerHTML=`<div class="event">${t.noActivity}</div>`; return; }
              const W=760,H=260,L=54,R=16,T=14,B=34;
              const minX=Math.min(startMinute,...points.map(p=>p.minute)), maxX=Math.max(endMinute,...points.map(p=>p.minute),minX+1);
              const maxY=Math.max(0.1,...points.map(p=>p.kWh));
              const x=m=>L+((m-minX)/(maxX-minX))*(W-L-R), y=v=>T+(1-v/maxY)*(H-T-B);
              const xGrid=Array.from({length:5},(_,i)=>{const m=minX+(maxX-minX)*i/4;return `<line class="gridline" x1="${x(m)}" y1="${T}" x2="${x(m)}" y2="${H-B}"/><text class="axis-label" x="${x(m)}" y="${H-10}" text-anchor="middle">${time(m)}</text>`}).join("");
              const yGrid=Array.from({length:5},(_,i)=>{const v=maxY*i/4;return `<line class="gridline" x1="${L}" y1="${y(v)}" x2="${W-R}" y2="${y(v)}"/><text class="axis-label" x="${L-7}" y="${y(v)+4}" text-anchor="end">${number(v)}</text>`}).join("");
              const path=points.map(p=>`${x(p.minute)},${y(p.kWh)}`).join(" ");
              const dots=points.map(p=>`<circle cx="${x(p.minute)}" cy="${y(p.kWh)}" r="3" fill="#48d8c0"/><circle class="tooltip-target" cx="${x(p.minute)}" cy="${y(p.kWh)}" r="11" fill="transparent" tabindex="0" data-tip="${escapeHTML(`${time(p.minute)} · ${number(p.kWh)} ${t.kwh}`)}"/>`).join("");
              host.innerHTML=`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${escapeHTML(t.tripEnergy)}">${xGrid}${yGrid}<line class="axis" x1="${L}" y1="${T}" x2="${L}" y2="${H-B}"/><line class="axis" x1="${L}" y1="${H-B}" x2="${W-R}" y2="${H-B}"/><text class="axis-label" x="4" y="${T+5}">${t.kwh}</text><polyline fill="none" stroke="#48d8c0" stroke-width="3" stroke-linejoin="round" points="${path}"/>${dots}</svg>`;
              wireTooltips(host);
            }
            function chart(host,points,color){
              if(!points.length){ host.innerHTML=`<div class="event">${t.noActivity}</div>`; return; }
              const W=760,H=235,L=48,R=16,T=14,B=32,maxY=Math.max(1,...points.map(p=>p.kWh));
              const x=m=>L+(m/1440)*(W-L-R), y=v=>T+(1-v/maxY)*(H-T-B);
              const grid=Array.from({length:7},(_,i)=>{const m=i*240;return `<line class="gridline" x1="${x(m)}" y1="${T}" x2="${x(m)}" y2="${H-B}"/><text class="axis-label" x="${x(m)}" y="${H-10}" text-anchor="middle">${pad(m/60)}:00</text>`}).join("");
              const path=points.map(p=>`${x(p.minute)},${y(p.kWh)}`).join(" ");
              const dots=points.map(p=>{const tip=`${time(p.minute)} · ${number(p.kWh)} ${t.kwh}${p.powerKW?` · ${number(p.powerKW)} kW`:""}`;return `<circle cx="${x(p.minute)}" cy="${y(p.kWh)}" r="3" fill="${color}"/><circle class="tooltip-target" cx="${x(p.minute)}" cy="${y(p.kWh)}" r="11" fill="transparent" tabindex="0" data-tip="${escapeHTML(tip)}"/>`;}).join("");
              host.innerHTML=`<svg viewBox="0 0 ${W} ${H}" role="img">${grid}<line class="axis" x1="${L}" y1="${T}" x2="${L}" y2="${H-B}"/><line class="axis" x1="${L}" y1="${H-B}" x2="${W-R}" y2="${H-B}"/><text class="axis-label" x="4" y="${T+5}">${number(maxY)} ${t.kwh}</text><text class="axis-label" x="24" y="${H-B}">0</text><polyline fill="none" stroke="${color}" stroke-width="3" points="${path}"/>${dots}</svg>`;
              wireTooltips(host);
            }
            function wireTooltips(host){
              const tooltip=document.getElementById("graphTooltip");
              const show=(el,event)=>{tooltip.textContent=el.dataset.tip;tooltip.hidden=false;move(event,el);};
              const move=(event,el)=>{const r=el.getBoundingClientRect();tooltip.style.left=`${event?.clientX??r.left+r.width/2}px`;tooltip.style.top=`${event?.clientY??r.top+r.height/2}px`;};
              host.querySelectorAll(".tooltip-target").forEach(el=>{
                el.addEventListener("mouseenter",event=>show(el,event)); el.addEventListener("mousemove",event=>move(event,el));
                el.addEventListener("mouseleave",()=>tooltip.hidden=true); el.addEventListener("focus",()=>show(el)); el.addEventListener("blur",()=>tooltip.hidden=true);
              });
            }
            document.getElementById("previousMonth").onclick=()=>{month.setMonth(month.getMonth()-1);loadCalendar();};
            document.getElementById("nextMonth").onclick=()=>{month.setMonth(month.getMonth()+1);loadCalendar();};
            document.getElementById("closeDay").onclick=()=>{selectedDate=null;selectedChargeKey=null;selectedTripKey=null;document.getElementById("dayPanel").hidden=true;};
            document.getElementById("closeTripDetail").onclick=()=>{selectedTripKey=null;document.getElementById("tripDetailPanel").hidden=true;};
            document.getElementById("closePower").onclick=()=>{selectedChargeKey=null;document.getElementById("powerPanel").hidden=true;};
            document.getElementById("textReportTitle").textContent=t.textReport;
            renderWeekdays(); loadCalendar(); setInterval(()=>{loadCalendar();if(selectedDate)loadDay(selectedDate,false);},60000);
          })();
          </script>
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
