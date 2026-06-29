import AppKit
import SwiftUI

struct SummaryReportView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("XPeng report")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshSummaryReport()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.summaryReport, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .padding()

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(model.summaryReport)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear {
            NSApplication.shared.activate()
            model.refreshSummaryReport()
        }
    }
}
