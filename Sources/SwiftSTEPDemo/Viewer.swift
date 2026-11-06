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

    private var loadTask: Task<Void, Never>?
    private var started = false

    static let stepTypes: [UTType] = ["step", "stp"].compactMap { UTType(filenameExtension: $0) }

    var title: String { document?.url.lastPathComponent ?? "SwiftSTEP Demo" }

    var subtitle: String {
        guard let geometry = document?.geometry else { return "" }
        let notes = geometry.edges.diagnostics.count + geometry.surfaces.diagnostics.count
        var text = "\(geometry.edges.edges.count) edges, \(geometry.surfaces.triangleCount) triangles"
        if notes > 0 { text += ", \(notes) notes" }
        return text
    }

    /// A path given on the command line, otherwise the bundled sample.
    func openInitialFile() {
        guard !started else { return }
        started = true
        if let path = CommandLine.arguments.dropFirst().first(where: { FileManager.default.fileExists(atPath: $0) }) {
            open(URL(fileURLWithPath: path))
        } else if let sample = Bundle.module.url(forResource: "die_cube", withExtension: "step") {
            open(sample)
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
                for note in geometry.edges.diagnostics + geometry.surfaces.diagnostics {
                    FileHandle.standardError.write(Data("#\(note.entityID.map(String.init) ?? "-"): \(note.message)\n".utf8))
                }
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
