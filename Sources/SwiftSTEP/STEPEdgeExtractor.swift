import Foundation

/// Task-confined extraction state; no UI, renderer or 2D path dependencies.
final class STEPEdgeExtractor {
    private let file: STEPFile
    private let options: STEP.Options
    private var model: STEP.EdgeModel
    private static let representationTypes: Set<String> = [
        "SHAPE_REPRESENTATION",
        "ADVANCED_BREP_SHAPE_REPRESENTATION",
        "MANIFOLD_SURFACE_SHAPE_REPRESENTATION",
        "GEOMETRICALLY_BOUNDED_SURFACE_SHAPE_REPRESENTATION"
    ]
    private static let bodyTypes: Set<String> = ["MANIFOLD_SOLID_BREP",
                                                 "BREP_WITH_VOIDS",
                                                 "SHELL_BASED_SURFACE_MODEL"]

    init(file: STEPFile, importID: UUID, options: STEP.Options) {
        self.file = file
        self.options = options
        model = STEP.EdgeModel(importID: importID)
    }

    func extract() throws -> STEP.EdgeModel {
        try Task.checkCancellation()
        if let scale = options.assumedUnitScaleToMM, !scale.isFinite || scale <= 0 {
            throw STEP.ParseError("Assumed unit scale must be finite and positive", kind: .invalidOptions)
        }
        guard options.chordToleranceMM.isFinite, options.chordToleranceMM > 0 else {
            throw STEP.ParseError("Chord tolerance must be finite and positive", kind: .invalidOptions)
        }
        model.header = file.header()
        let assemblies = file.entities(ofTypes: ["MAPPED_ITEM",
                                                 "NEXT_ASSEMBLY_USAGE_OCCURRENCE",
                                                 "REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION"])
        guard assemblies.isEmpty else {
            throw STEP.ParseError("Assembly placement is not supported yet (entity #\(assemblies[0]))", kind: .assembly)
        }
        model.indexedEntityCount = file.index.count

        for representationID in file.entities(ofTypes: Self.representationTypes) {
            try Task.checkCancellation()
            let parts = try file.components(representationID)

            guard let representation = parts.first(where: { $0.type == "REPRESENTATION" })
                ?? parts.first(where: { Self.representationTypes.contains($0.type) }) else {
                continue
            }
            let items = try representation.parameters.references(at: 1)
            let bodyIDs = Set(items.filter { id in Self.bodyTypes.contains { file.hasType(id, $0) } }).sorted()

            guard !bodyIDs.isEmpty else {
                continue
            }
            let contextID = try representation.parameters.reference(at: 2)
            let scale: Double
            let assumed: Bool
            do {
                scale = try STEPUnits(file: file).scaleToMM(contextID: contextID)
                assumed = false
            } catch let error as STEP.ParseError {
                guard let fallback = options.assumedUnitScaleToMM else {
                    throw STEP.ParseError(error.description, kind: .unresolvedUnits(contextID: contextID))
                }
                scale = fallback
                assumed = true
                diagnose(contextID, "\(error); explicitly assuming \(fallback) mm per source unit",
                         .warning, code: "assumed-units")
            }
            // The accuracy is optional: a context whose uncertainty cannot be read declares none.
            let uncertainty = (try? STEPUnits(file: file).uncertaintyMM(contextID: contextID)) ?? nil
            let tolerances = STEPTolerances(chord: options.chordToleranceMM, declaredUncertainty: uncertainty)
            let resolver = STEPCurveResolver(file: file, scaleToMM: scale, chordTolerance: options.chordToleranceMM,
                                             tolerances: tolerances,
                                             angleScaleToRadians: { try self.angleScale(context: contextID) })
            for bodyID in bodyIDs {
                let identity = STEP.BodyID(representationID: representationID, entityID: bodyID)
                let uses = try collectEdges(bodyID: bodyID)
                model.reachableEdgeCount += uses.count
                var bodyBounds: STEP.Bounds?
                for edgeID in uses.keys.sorted() {
                    try Task.checkCancellation()
                    let faceUses = uses[edgeID]!
                    do {
                        let edge = try edge(edgeID, body: identity, resolver: resolver, faces: faceUses.keys.sorted(),
                                            isSeam: faceUses.values.contains { $0 >= 2 })
                        model.edges.append(edge)
                        for point in edge.points {
                            if bodyBounds == nil { bodyBounds = STEP.Bounds(min: point, max: point) }
                            else { bodyBounds?.include(point) }
                        }
                    } catch let error as STEP.ParseError {
                        diagnose(edgeID, error.description, .skipped, code: Self.code(forEdgeFailure: error.description))
                    }
                }
                if let bodyBounds {
                    if model.bounds == nil { model.bounds = bodyBounds }
                    else {
                        model.bounds?.include(bodyBounds.min)
                        model.bounds?.include(bodyBounds.max)
                    }
                }
                model.bodies.append(STEP.BodyInfo(id: identity, contextID: contextID, unitScaleToMM: scale,
                                                     unitsAssumed: assumed, uncertaintyMM: tolerances.declaredUncertainty,
                                                     bounds: bodyBounds, name: bodyName(bodyID)))
            }
        }
        if model.bodies.isEmpty {
            diagnose(nil, "No supported solid/shell bodies in shape representations", .warning, code: "no-bodies")
        }
        if model.edges.isEmpty { diagnose(nil, "No supported edges were extracted", .warning, code: "no-edges") }

        return model
    }

    private func diagnose(_ id: Int?, _ message: String, _ severity: STEP.Diagnostic.Severity, code: String) {
        model.diagnostics.append(STEP.Diagnostic(entityID: id, message: message, severity: severity, code: code))
    }

    /// The code for an edge that was skipped, from the reason the curve resolver gave.
    private static func code(forEdgeFailure message: String) -> String {
        if message.contains("Unsupported curve") { return "unsupported-curve" }
        if message.contains("is not on its") { return "vertex-off-curve" }
        return "edge-skipped"
    }

    private struct Visit: Hashable { let id: Int; let face: Int? }

    /// For every edge reachable from the body: how many times each face uses it. A face that
    /// uses an edge twice has it as a seam. An edge reached without a face has no entries.
    private func collectEdges(bodyID: Int) throws -> [Int: [Int: Int]] {
        var uses: [Int: [Int: Int]] = [:]
        var visited: Set<Visit> = []
        func walk(_ id: Int, face: Int?, ancestors: Set<Int>) throws {
            try Task.checkCancellation()
            guard ancestors.count < 128, !ancestors.contains(id) else {
                diagnose(id, "Cyclic/deep topology reference", .warning, code: "topology-cycle")
                return
            }
            // Each ORIENTED_EDGE is walked once per face (below), so every arrival here is one use.
            // Counting must come before the visited check, which would hide the second use of a seam.
            if file.hasType(id, "EDGE_CURVE") {
                if uses[id] == nil { uses[id] = [:] }
                if let face { uses[id]![face, default: 0] += 1 }
                return
            }
            guard visited.insert(Visit(id: id, face: face)).inserted else { return }
            var ancestors = ancestors
            ancestors.insert(id)
            do {
                let components = try file.components(id)
                // Prefer the most derived body type for simple records.
                let supported = Self.bodyTypes.union([
                    "CLOSED_SHELL", "OPEN_SHELL", "ORIENTED_CLOSED_SHELL",
                    "ADVANCED_FACE", "FACE_SURFACE", "FACE_BOUND", "FACE_OUTER_BOUND",
                    "EDGE_LOOP", "ORIENTED_EDGE"
                ])
                guard let part = components.first(where: { supported.contains($0.type) }) else {
                    throw STEP.ParseError("Unsupported topology at #\(id)")
                }
                let p = part.parameters
                let children: [Int]
                var nextFace = face
                switch part.type {
                    case "MANIFOLD_SOLID_BREP": children = [try p.reference(at: 1)]
                    case "BREP_WITH_VOIDS": children = [try p.reference(at: 1)] + (try p.references(at: 2))
                    case "SHELL_BASED_SURFACE_MODEL", "CLOSED_SHELL", "OPEN_SHELL", "EDGE_LOOP":
                        children = try p.references(at: 1)
                    case "ADVANCED_FACE", "FACE_SURFACE":
                        children = try p.references(at: 1)
                        nextFace = id
                    case "FACE_BOUND", "FACE_OUTER_BOUND": children = [try p.reference(at: 1)]
                    case "ORIENTED_CLOSED_SHELL": children = [try p.reference(at: 2)]
                    case "ORIENTED_EDGE": children = [try p.reference(at: 3)]
                    default: children = []
                }
                for child in children { try walk(child, face: nextFace, ancestors: ancestors) }
            } catch let error as STEP.ParseError {
                diagnose(id, error.description, .skipped, code: "unsupported-topology")
            }
        }
        try walk(bodyID, face: nil, ancestors: [])
        return uses
    }

    /// The name string of a body entity (its first parameter), or `nil` when it is `$` or empty.
    private func bodyName(_ bodyID: Int) -> String? {
        guard let part = try? file.components(bodyID).first(where: { Self.bodyTypes.contains($0.type) }),
              case .string(let name)? = part.parameters.first, !name.isEmpty else { return nil }
        return name
    }

    private func edge(_ id: Int, body: STEP.BodyID, resolver: STEPCurveResolver, faces: [Int],
                      isSeam: Bool) throws -> STEP.Edge {
        let p = try file.parameters(id, type: "EDGE_CURVE")
        let start = try p.reference(at: 1)
        let end = try p.reference(at: 2)
        guard let sense = try p.argument(4).enumeration, sense == "T" || sense == "F" else {
            throw STEP.ParseError("Invalid EDGE_CURVE same_sense")
        }
        // Vertex order is canonical EDGE_CURVE order, independent of ORIENTED_EDGE uses.
        let resolved = try resolver.resolve(curveID: p.reference(at: 3), startVertexID: start, endVertexID: end,
                                            sameSense: sense == "T")
        if let warning = resolved.warning { diagnose(id, warning, .warning, code: "chord-cap") }
        return STEP.Edge(id: STEP.EdgeID(importID: model.importID, bodyID: body, entityID: id),
                        kind: resolved.kind,
                        points: resolved.points,
                        startVertexID: start,
                        endVertexID: end,
                        adjacentFaceIDs: faces,
                        chordError: resolved.chordError,
                        isSeam: isSeam,
                        curve: resolved.curve)
    }

    private var angleScales: [Int: Result<Double, STEP.ParseError>] = [:]

    /// Radians per context angle unit, resolved once per context and only if some edge needs it.
    private func angleScale(context: Int) throws -> Double {
        if let cached = angleScales[context] { return try cached.get() }
        do {
            let scale = try STEPUnits(file: file).angleScaleToRadians(contextID: context)
            angleScales[context] = .success(scale)
            return scale
        } catch let error as STEP.ParseError {
            angleScales[context] = .failure(error)
            throw error
        }
    }
}
