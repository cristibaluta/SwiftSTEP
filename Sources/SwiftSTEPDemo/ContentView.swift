import SwiftUI

/// The window is just the model: no overlays on the canvas. File name and counts live in the
/// title bar, errors in an alert.
struct ContentView: View {
    @ObservedObject var viewer: Viewer

    var body: some View {
        ModelView(document: viewer.document)
            .navigationTitle(viewer.title)
            .navigationSubtitle(viewer.subtitle)
            .toolbar {
                ToolbarItem {
                    Button { viewer.isImporting = true } label: { Label("Open…", systemImage: "folder") }
                }
            }
            .fileImporter(isPresented: $viewer.isImporting, allowedContentTypes: Viewer.stepTypes) { result in
                if case .success(let url) = result { viewer.open(url) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                viewer.open(url)
                return true
            }
            .alert("Could not open file", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewer.errorMessage ?? "")
            }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewer.errorMessage != nil }, set: { if !$0 { viewer.errorMessage = nil } })
    }
}
