import Foundation

/// Internal drivers behind the public `STEP.read…` / `STEP.load…` entry points.
enum STEPEdgeImporter {
    /// Inflates gzip data (`.stpz`), then indexes the file.
    private static func openFile(_ data: Data, _ options: STEP.Options) throws -> STEPFile {
        try STEPFile(data: try STEPGzip.inflateIfGzip(data), maximumEntityCount: options.maximumEntityCount)
    }

    static func parse(data: Data, importID: UUID = UUID(), options: STEP.Options = STEP.Options()) throws -> STEP.EdgeModel {
        try Task.checkCancellation()
        let file = try openFile(data, options)
        return try STEPEdgeExtractor(file: file, importID: importID, options: options).extract()
    }

    /// Edges plus the surface mesh that lets a viewer draw hidden edges dotted. Parses the file
    /// once and shares it between both stages. Synchronous: call it from a background task.
    static func parseGeometry(data: Data, importID: UUID = UUID(), options: STEP.Options = STEP.Options()) throws -> STEP.Geometry {
        try Task.checkCancellation()
        let file = try openFile(data, options)
        let edges = try STEPEdgeExtractor(file: file, importID: importID, options: options).extract()
        // Surfaces only add hidden-edge display: if they cannot be built the wireframe still loads.
        // Cancellation is not a failure to degrade from, so it propagates.
        let surfaces: STEP.SurfaceModel
        do {
            surfaces = try STEPTessellator(file: file, model: edges, options: options).tessellate()
        } catch let error as STEP.ParseError {
            var unavailable = STEP.SurfaceModel()
            unavailable.diagnostics = [STEP.Diagnostic(entityID: nil, message: "Surfaces unavailable: \(error.description)",
                                                      severity: .warning, code: "surfaces-unavailable")]
            surfaces = unavailable
        }
        return STEP.Geometry(edges: edges, surfaces: surfaces)
    }

    /// Edges plus the faces of every body (surface and boundary loops, no triangles). Parses the
    /// file once and shares it between both stages. Synchronous: call it from a background task.
    static func parseTopology(data: Data, importID: UUID = UUID(), options: STEP.Options = STEP.Options()) throws -> STEP.Topology {
        try Task.checkCancellation()
        let file = try openFile(data, options)
        let edges = try STEPEdgeExtractor(file: file, importID: importID, options: options).extract()
        return try STEPTopologyExtractor(file: file, model: edges, options: options).extract()
    }

    /// Every body placed in assembly coordinates. Parses the file once; each distinct part is read (and
    /// tessellated, when `includeSurfaces`) once and then copied through its placements.
    /// Synchronous: call it from a background task.
    static func parseAssembly(data: Data, importID: UUID = UUID(), options: STEP.Options = STEP.Options(),
                              includeSurfaces: Bool = true) throws -> STEP.Assembly {
        try Task.checkCancellation()
        let file = try openFile(data, options)
        let edges = try STEPEdgeExtractor(file: file, importID: importID, options: options,
                                          reportsAssembly: false).extract()
        var surfaces: STEP.SurfaceModel?
        if includeSurfaces {
            do {
                surfaces = try STEPTessellator(file: file, model: edges, options: options).tessellate()
            } catch let error as STEP.ParseError {
                var unavailable = STEP.SurfaceModel()
                unavailable.diagnostics = [STEP.Diagnostic(entityID: nil, message: "Surfaces unavailable: \(error.description)",
                                                          severity: .warning, code: "surfaces-unavailable")]
                surfaces = unavailable
            }
        }
        let resolution = try STEPAssemblyResolver(file: file, model: edges, options: options).resolve()
        return try STEP.Assembly.assemble(edges: edges, surfaces: surfaces, resolution: resolution, options: options)
    }

    /// Runs `work` on a detached task so it never inherits an actor, and forwards cancellation.
    /// The parser and its cache are created inside the worker and never cross actors.
    static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try work()
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}
