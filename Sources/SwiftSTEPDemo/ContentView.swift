import SwiftUI
import AppKit

/// The window is just the model: no overlays on the canvas. File name and counts live in the
/// title bar, errors in an alert.
struct ContentView: View {
    @ObservedObject var viewer: Viewer

    var body: some View {
        HSplitView {
            ModelView(document: viewer.document, hidden: viewer.hiddenBodies, selected: viewer.selectedBody)
            if viewer.showsBodyList {
                BodyListView(viewer: viewer)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 420)
            }
        }
            .navigationTitle(viewer.title)
            .navigationSubtitle(viewer.subtitle)
            .toolbar {
                ToolbarItem {
                    Picker("Sample", selection: sampleSelection) {
                        Text("Samples…").tag(URL?.none)
                        ForEach(viewer.samples, id: \.self) { url in
                            Text(url.deletingPathExtension().lastPathComponent).tag(URL?.some(url))
                        }
                    }
                    .help("Switch between the bundled test models")
                }
                ToolbarItem {
                    Button { viewer.showsBodyList.toggle() } label: { Label("Bodies", systemImage: "sidebar.right") }
                        .help("Show or hide the list of bodies")
                }
                ToolbarItem {
                    Button { viewer.isShowingReport = true } label: { Label("Import report", systemImage: "info.circle") }
                        .disabled(viewer.document == nil)
                }
                ToolbarItem {
                    Button { viewer.isImporting = true } label: { Label("Open…", systemImage: "folder") }
                }
            }
            .fileImporter(isPresented: $viewer.isImporting, allowedContentTypes: Viewer.supportedTypes) { result in
                if case .success(let url) = result { viewer.selectedSample = nil; viewer.open(url) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                viewer.open(url)
                return true
            }
            .sheet(isPresented: $viewer.isShowingReport) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Import report").font(.headline)
                    ScrollView([.vertical, .horizontal]) {
                        Text(viewer.report)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(viewer.report, forType: .string)
                        }
                        Spacer()
                        Button("Done") { viewer.isShowingReport = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
                .frame(minWidth: 560, minHeight: 320)
            }
            .alert("Could not open file", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewer.errorMessage ?? "")
            }
    }

    private var sampleSelection: Binding<URL?> {
        Binding(get: { viewer.selectedSample },
                set: { if let url = $0 { viewer.openSample(url) } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewer.errorMessage != nil }, set: { if !$0 { viewer.errorMessage = nil } })
    }
}
