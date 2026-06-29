//
//  ContentView.swift
//  XPengWatcher
//
//  Created by Philippe Rigaux on 28/06/2026.
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.menuBarSymbol)
                    .font(.title2)
                    .foregroundStyle(model.isCollecting ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusTitle).font(.headline)
                    Text(model.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let telemetry = model.latestTelemetry {
                Divider()
                LabeledContent("Battery", value: telemetry.soc)
                LabeledContent("Range", value: telemetry.range)
                LabeledContent("Odometer", value: telemetry.odometer)
            }

            if let trip = model.analytics.latestTrip {
                Divider()
                Text("Last trip").font(.caption).foregroundStyle(.secondary)
                Text(trip.title).font(.headline)
                Text(trip.detail).font(.caption).foregroundStyle(.secondary)
            }

            if let charge = model.analytics.latestCharge {
                Divider()
                Text("Last charge").font(.caption).foregroundStyle(.secondary)
                Text(charge.title).font(.headline)
                Text(charge.detail).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Button {
                model.collectNow()
            } label: {
                Label(
                    model.isCollecting ? String(localized: "Collection in progress…") : String(localized: "Collect now"),
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(model.isCollecting)

            if !model.accessibilityGranted {
                Button {
                    model.openAccessibilitySettings()
                } label: {
                    Label("Grant access…", systemImage: "hand.raised.fill")
                }
            }

            Button {
                model.refreshSummaryReport()
                NSApplication.shared.activate()
                openWindow(id: "summaryReport")
            } label: {
                Label("Show report…", systemImage: "doc.text.magnifyingglass")
            }

            Button {
                NSApplication.shared.activate()
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }

            Button("Quit XPengWatcher") {
                NSApplication.shared.terminate(nil)
            }

            Text(String(format: String(localized: "Version %@"), AppVersion.current))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.start() }
    }
}
