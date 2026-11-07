import Foundation

/// Reads STEP (ISO 10303-21) B-rep solids and shells.
///
/// ```swift
/// let model = try STEP.read(contentsOf: url)
/// for edge in model.edges { print(edge.kind, edge.points) }   // [SIMD3<Double>], mm
/// ```
///
/// Output is plain `simd` data: edge polylines are `[SIMD3<Double>]` in millimetres (source
/// coordinates), meshes are `[SIMD3<Float>]`. The polylines are display geometry, not machining
/// contours. Assembly placements are not applied (a warning says so); unsupported curves are skipped with a `Diagnostic`.
public enum STEP {

    // MARK: Synchronous (call from a background task, never the main actor)

    /// Stored edges of every supported body.
    public static func read(data: Data, importID: UUID = UUID(), options: Options = Options()) throws -> EdgeModel {
        try STEPEdgeImporter.parse(data: data, importID: importID, options: options)
    }

    public static func read(contentsOf url: URL, importID: UUID = UUID(), options: Options = Options()) throws -> EdgeModel {
        try read(data: Data(contentsOf: url, options: .mappedIfSafe), importID: importID, options: options)
    }

    /// Edges plus the per-body triangle mesh. If the surfaces cannot be built the edges still
    /// load and `surfaces.diagnostics` says why.
    public static func readGeometry(data: Data, importID: UUID = UUID(), options: Options = Options()) throws -> Geometry {
        try STEPEdgeImporter.parseGeometry(data: data, importID: importID, options: options)
    }

    public static func readGeometry(contentsOf url: URL, importID: UUID = UUID(), options: Options = Options()) throws -> Geometry {
        try readGeometry(data: Data(contentsOf: url, options: .mappedIfSafe), importID: importID, options: options)
    }

    /// Edges plus the faces of every body: surface, sense and boundary loops, without triangles.
    /// A face whose surface SwiftSTEP cannot read is still listed, with `surface == nil`.
    public static func readTopology(data: Data, importID: UUID = UUID(), options: Options = Options()) throws -> Topology {
        try STEPEdgeImporter.parseTopology(data: data, importID: importID, options: options)
    }

    public static func readTopology(contentsOf url: URL, importID: UUID = UUID(), options: Options = Options()) throws -> Topology {
        try readTopology(data: Data(contentsOf: url, options: .mappedIfSafe), importID: importID, options: options)
    }

    // MARK: Asynchronous (detached worker, cancellable)

    public static func load(contentsOf url: URL, importID: UUID = UUID(), options: Options = Options()) async throws -> EdgeModel {
        try await STEPEdgeImporter.detached { try read(contentsOf: url, importID: importID, options: options) }
    }

    public static func loadGeometry(contentsOf url: URL, importID: UUID = UUID(), options: Options = Options()) async throws -> Geometry {
        try await STEPEdgeImporter.detached { try readGeometry(contentsOf: url, importID: importID, options: options) }
    }

    public static func loadTopology(contentsOf url: URL, importID: UUID = UUID(), options: Options = Options()) async throws -> Topology {
        try await STEPEdgeImporter.detached { try readTopology(contentsOf: url, importID: importID, options: options) }
    }
}
