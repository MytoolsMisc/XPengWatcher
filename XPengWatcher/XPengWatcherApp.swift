//
//  XPengWatcherApp.swift
//  XPengWatcher
//
//  Created by Philippe Rigaux on 28/06/2026.
//

import SwiftUI

@main
struct XPengWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Label(model.menuBarTitle, systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        Window("XPeng report", id: "summaryReport") {
            SummaryReportView()
                .environmentObject(model)
        }
        .defaultSize(width: 920, height: 620)
    }
}
