import SwiftUI
import UniformTypeIdentifiers
import SwiftSTEP

/// A parsed file. `id` changes on every load so the renderer knows when to re-upload.
struct Document {
    let id = UUID()
    let url: URL
    let geometry: STEP.Geometry
}

@MainActor
final class Viewer: ObservableObject {
    @Published private(set) var document: Document?
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published var isShowingReport = false

    /// The sample being shown, when it came from the bundled list (nil for files opened by hand).
    @Published var selectedSample: URL?

    /// Bundled models: the die cube plus the hard cases in `Samples/`, sorted by name.
    let samples: [URL] = {
        var urls = Bundle.module.urls(forResourcesWithExtension: "step", subdirectory: "Samples") ?? []
        if let die = Bundle.module.url(forResource: "die_cube", withExtension: "step") { urls.append(die) }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    func openSample(_ url: URL) {
        selectedSample = url
        open(url)
    }

    private var loadTask: Task<Void, Never>?
    private var started = false

    static let stepTypes: [UTType] = ["step", "stp"].compactMap { UTType(filenameExtension: $0) }

    var title: String { document?.url.lastPathComponent ?? "SwiftSTEP Demo" }

    var subtitle: String {
        guard let geometry = document?.geometry else { return "" }
        let notes = geometry.edges.diagnostics.count + geometry.surfaces.diagnostics.count
        var text = "\(geometry.edges.edges.count) edges, \(geometry.surfaces.triangleCount) triangles"
        let unfilled = geometry.surfaces.unsurfacedBodies.count
        if unfilled > 0 { text += ", \(unfilled) unfilled bod\(unfilled == 1 ? "y" : "ies")" }
        let partial = geometry.surfaces.partialBodies.count
        if partial > 0 { text += ", \(partial) partly filled" }
        if notes > 0 { text += ", \(notes) notes" }
        return text
    }

    /// The library's account of the import: what was filled and why anything was not.
    var report: String { document?.geometry.report ?? "No file loaded." }

    /// A path given on the command line, otherwise the bundled sample.
    func openInitialFile() {
        guard !started else { return }
        started = true
        if let path = CommandLine.arguments.dropFirst().first(where: { FileManager.default.fileExists(atPath: $0) }) {
            open(URL(fileURLWithPath: path))
        } else if let sample = samples.first(where: { $0.lastPathComponent == "die_cube.step" }) ?? samples.first {
            openSample(sample)
        } else {
            let message = "The bundled sample die_cube.step is missing from the resource bundle "
                + "(\(Bundle.module.bundlePath)). Check that Package.swift lists it under `resources:`."
            FileHandle.standardError.write(Data("SwiftSTEPDemo: \(message)\n".utf8))
            errorMessage = message
        }
    }

    func open(_ url: URL) {
        loadTask?.cancel()
        loadTask = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // The library's async entry point: parses on a detached worker, cancellable.
                let geometry = try await STEP.loadGeometry(contentsOf: url)
                try Task.checkCancellation()
                FileHandle.standardError.write(Data("SwiftSTEP: \(url.lastPathComponent)\n\(geometry.report)\n".utf8))
                document = Document(url: url, geometry: geometry)
            } catch is CancellationError {
                // Superseded by a newer open.
            } catch let error as STEP.ParseError {
                errorMessage = "\(url.lastPathComponent): \(error.description)"
            } catch {
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}
