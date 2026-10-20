import AppKit
import SwiftUI

/// QR results window (`QRCodeResultsPanel` / `QRCodeResultsModel`).
@MainActor
enum QRCodeResultsPresenter {
    private static var windows: [NSWindow] = []

    static func present(_ results: [FileToolRunner.QRResult]) {
        let panel = ToolPanel(size: NSSize(width: 400, height: results.isEmpty ? 200 : 420))
        var closeAction: () -> Void = {}
        panel.contentView = NSHostingView(rootView: QRCodeResultsView(results: results, close: { closeAction() }))
        closeAction = { [weak panel] in
            panel?.close()
            windows.removeAll { $0 === panel }
        }
        windows.append(panel)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

struct QRCodeResultsView: View {
    let results: [FileToolRunner.QRResult]
    let close: () -> Void
    @State private var copied: Int?
    @State private var copiedAll = false

    var body: some View {
        ToolScaffold(title: "QR Codes", onClose: close) {
            VStack(alignment: .leading, spacing: 10) {
                if results.isEmpty {
                    Text("No QR codes found").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.source + (result.page.map { " · page \($0)" } ?? "")).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(result.text).font(.system(size: 13)).textSelection(.enabled).lineLimit(4)
                        }
                        Spacer()
                        Button(copied == index ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.text, forType: .string)
                            copied = index
                        }
                        .help("Copy QR code text from \(result.source)")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                }
            }
        } footer: {
            Spacer()
            if results.count > 1 {
                ToolButton(title: copiedAll ? "Copied" : "Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(results.map(\.text).joined(separator: "\n"), forType: .string)
                    copiedAll = true
                }
            }
            ToolButton(title: "Done", action: close)
        }
    }
}
