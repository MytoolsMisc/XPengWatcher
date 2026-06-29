import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Collection") {
                Stepper(value: $model.intervalMinutes, in: 1...60) {
                    Text(String(format: String(localized: "Every %d minutes"), model.intervalMinutes))
                }
                LabeledContent("SQLite database") {
                    Text(model.databaseURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Show in Finder") { model.revealDatabase() }
            }

            Section("Battery") {
                TextField("Usable capacity (kWh)", value: $model.batteryCapacityKWh, format: .number)
                TextField("SOH (%)", value: $model.sohPercent, format: .number)
            }

            Section("MQTT") {
                Toggle("Publish telemetry", isOn: $model.mqttEnabled)
                TextField("Server", text: $model.mqttHost)
                TextField("Port", value: $model.mqttPort, format: .number)
                TextField("Username", text: $model.mqttUser)
                SecureField("Password", text: $model.mqttPassword)
                TextField("Topic", text: $model.mqttTopic)
                Button("Save password in Keychain") { model.savePassword() }
            }

            Section("HTTP report") {
                Toggle("Enable HTTP server", isOn: $model.httpServerEnabled)
                TextField("Port", value: $model.httpServerPort, format: .number)
                Text("http://localhost:\(model.httpServerPort)/")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Open report in browser") { model.openHTTPReport() }
                    .disabled(!model.httpServerEnabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 650)
        .onAppear {
            NSApplication.shared.activate()
        }
        .task {
            if model.mqttPassword.isEmpty {
                model.mqttPassword = (try? KeychainPassword.load()) ?? ""
            }
        }
    }
}
