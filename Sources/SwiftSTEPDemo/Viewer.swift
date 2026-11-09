import SwiftUI
import UniformTypeIdentifiers
import SwiftSTEP

/// A parsed file. `id` changes on every load so the renderer knows when to re-upload.
///
/// `assembly.bodies` is the array `STEP.readBodies` returns: one entry per solid per placement, with
/// the geometry already in assembly coordinates.
struct Document {
    let id = UUID()
    let url: URL
    let assembly: STEP.Assembly
    /// Palette index per body; placements of one part share an index.
    let colorIndex: [STEP.BodyID: Int]

    init(url: URL, assembly: STEP.Assembly) {
        self.url = url
        self.assembly = assembly
        var parts: [[Int]: Int] = [:]
        var colors: [STEP.BodyID: Int] = [:]
        for body in assembly.bodies {
            let part = [body.id.representationID, body.id.entityID]
            let index = parts[part] ?? parts.count
            parts[part] = index
            colors[body.id] = index
        }
        colorIndex = colors
    }
}

@MainActor
final class Viewer: ObservableObject {
    @Published private(set) var document: Document?
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published var isShowingReport = false
    /// Bodies switched off in the list; the renderer skips their faces and edges.
    @Published var hiddenBodies: Set<STEP.BodyID> = []
    @Published var selectedBody: STEP.BodyID?
    @Published var showsBodyList = true

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
        guard let assembly = document?.assembly else { return "" }
        let count = assembly.bodies.count
        var text = "\(count) bod\(count == 1 ? "y" : "ies"), \(assembly.edgeCount) edges, \(assembly.triangleCount) triangles"
        let unfilled = assembly.bodies.filter { $0.mesh == nil }.count
        if unfilled > 0 { text += ", \(unfilled) without faces" }
        let partial = assembly.bodies.filter { $0.mesh?.isPartial == true }.count
        if partial > 0 { text += ", \(partial) partly filled" }
        if !assembly.diagnostics.isEmpty { text += ", \(assembly.diagnostics.count) notes" }
        return text
    }

    /// The library's account of the import: what was filled and why anything was not.
    var report: String { document?.assembly.report ?? "No file loaded." }

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
                // The library's async entry point: parses on a detached worker, cancellable. An
                // assembly comes back as an array of bodies, each placed in assembly coordinates.
                let assembly = try await STEP.loadAssembly(contentsOf: url)
                try Task.checkCancellation()
                FileHandle.standardError.write(Data("SwiftSTEP: \(url.lastPathComponent)\n\(assembly.report)\n".utf8))
                hiddenBodies = []
                selectedBody = nil
                document = Document(url: url, assembly: assembly)
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
