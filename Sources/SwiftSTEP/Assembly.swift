import Foundation
import simd

extension STEP {

    /// One body of the file, placed: its edges and (when asked for) its triangles in the
    /// coordinates of the whole assembly, in millimetres.
    ///
    /// A plain file of several solids gives one `Body` per solid. An assembly gives one `Body` per
    /// solid *per placement*: a bolt the assembly uses four times is four bodies, each with its own
    /// `id` (`BodyID.instance` counts them), its own `transform` and the geometry already moved.
    public struct Body: Sendable, Identifiable {
        /// Unique within the import. `id.instance` is 0 for the first placement of a part.
        public let id: BodyID
        /// Units, declared accuracy and name from the file; `bounds` is the body's extent after placement.
        public let info: BodyInfo
        /// Part coordinates (millimetres) → assembly coordinates (millimetres), already applied to
        /// `edges` and `mesh`. The identity for a body that nothing places. Use it to recover the part's
        /// own coordinates, or to move something else the same way.
        public let transform: simd_double4x4
        /// The occurrence names from the top of the assembly down to this body's part (the
        /// `NEXT_ASSEMBLY_USAGE_OCCURRENCE` name, else the product name). Empty for a body that is
        /// not placed by an assembly.
        public let path: [String]
        /// Millimetres, assembly coordinates; deterministic order (by `EDGE_CURVE` entity ID).
        public let edges: [Edge]
        /// Triangles in assembly coordinates, relative to `Assembly.origin`. `nil` when the body
        /// could not be filled, when surfaces were not requested, or when the triangle cap was reached.
        public let mesh: BodyMesh?

        public init(id: BodyID, info: BodyInfo, transform: simd_double4x4 = matrix_identity_double4x4, path: [String] = [],
                    edges: [Edge], mesh: BodyMesh? = nil) {
            self.id = id
            self.info = info
            self.transform = transform
            self.path = path
            self.edges = edges
            self.mesh = mesh
        }

        /// The body entity's name string, as written in the file.
        public var name: String? { info.name }
        /// Min/max of the body's edge points after placement.
        public var bounds: Bounds? { info.bounds }
        /// A label for lists: the occurrence path and body name, e.g. `Gearbox / Shaft / Die`.
        public var displayName: String {
            let parts = path + (name.map { [$0] } ?? [])
            return parts.isEmpty ? "Body #\(id.entityID)" : parts.joined(separator: " / ")
        }
    }

    /// How long one stage of an import took (wall clock, on the worker thread).
    public struct StageTiming: Sendable {
        public let name: String
        public let seconds: Double
        public init(name: String, seconds: Double) { self.name = name; self.seconds = seconds }
    }

    /// Every body of a file in one coordinate system. This is the result of `STEP.readAssembly`;
    /// `STEP.readBodies` returns just `bodies`.
    ///
    /// A file with no assembly structure is an assembly of unplaced bodies: `bodies` holds each
    /// solid or shell as written, `placementCount` is 0, and nothing is moved.
    public struct Assembly: Sendable {
        public let importID: UUID
        public internal(set) var header = Header()
        /// Deterministic order: the assembly is walked from its top-level representations down, by
        /// entity ID; a part's bodies come in file order.
        public internal(set) var bodies: [Body] = []
        /// Min/max over every body's edges, mm, assembly coordinates. `nil` when there are no edges.
        public internal(set) var bounds: Bounds?
        /// What the bodies' `Float` mesh positions are relative to: `bounds.workpieceOrigin`, like `SurfaceModel.origin`.
        public internal(set) var origin: SIMD3<Double> = .zero
        /// Edge, assembly and surface notes together. Codes starting `assembly-` or `instance-` come from the
        /// assembly pass; see `ParseError`/`Diagnostic` for the rest.
        public internal(set) var diagnostics: [Diagnostic] = []
        /// Placements read from the file and used (assembly usages or mapped items).
        public internal(set) var placementCount = 0
        public internal(set) var indexedEntityCount = 0
        /// Where the import spent its time, in order: index the file, edges, surfaces, placements, placing bodies.
        public internal(set) var timings: [StageTiming] = []
        /// The parts before placement, for `report`.
        let prototype: Geometry?

        init(importID: UUID, prototype: Geometry?) {
            self.importID = importID
            self.prototype = prototype
        }

        public var triangleCount: Int { bodies.reduce(0) { $0 + ($1.mesh?.triangleCount ?? 0) } }
        public var edgeCount: Int { bodies.reduce(0) { $0 + $1.edges.count } }

        public func body(_ id: BodyID) -> Body? { bodies.first { $0.id == id } }

        /// The bodies that are placements of one part (same representation and body entity).
        public func instances(of id: BodyID) -> [Body] {
            bodies.filter { $0.id.representationID == id.representationID && $0.id.entityID == id.entityID }
        }

        /// A readable account of the import: bodies, parts, placements, and the part-level report
        /// of faces that could not be filled.
        public var report: String {
            let parts = Set(bodies.map { [$0.id.representationID, $0.id.entityID] }).count
            var lines = ["Bodies: \(bodies.count) (\(parts) distinct part\(parts == 1 ? "" : "s"), "
                         + "\(placementCount) placement\(placementCount == 1 ? "" : "s")), "
                         + "\(edgeCount) edges, \(triangleCount) triangles"]
            for note in diagnostics where note.code.hasPrefix("assembly-") || note.code.hasPrefix("instance-") {
                lines.append("  assembly note \(note)")
            }
            if let prototype {
                lines.append("Parts before placement:")
                lines.append(prototype.report)
            }
            return lines.joined(separator: "\n")
        }
    }
}

// MARK: - Building the result

extension STEP.Assembly {

    /// Moves every prototype body to where `resolution` places it. The prototypes (edges, and meshes
    /// when `surfaces` is given) are the untransformed import; a part placed several times is
    /// tessellated once and its mesh copied through each placement.
    static func assemble(edges: STEP.EdgeModel, surfaces: STEP.SurfaceModel?,
                         resolution: STEPAssemblyResolver.Resolution, options: STEP.Options) throws -> STEP.Assembly {
        var assembly = STEP.Assembly(importID: edges.importID,
                                     prototype: surfaces.map { STEP.Geometry(edges: edges, surfaces: $0) })
        assembly.header = edges.header
        assembly.indexedEntityCount = edges.indexedEntityCount
        assembly.placementCount = resolution.placementCount
        var diagnostics = edges.diagnostics + resolution.diagnostics + (surfaces?.diagnostics ?? [])

        let edgesByBody = Dictionary(grouping: edges.edges, by: { $0.id.bodyID })
        let infoByBody = Dictionary(edges.bodies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let meshByBody = Dictionary((surfaces?.bodies ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Pass 1: edges and bounds, which fix the origin the meshes are measured from.
        struct Placed {
            let id: STEP.BodyID
            let prototype: STEP.BodyID
            let info: STEP.BodyInfo
            let placement: STEPPlacement
            let path: [String]
            let edges: [STEP.Edge]
        }
        var placed: [Placed] = []
        var bounds: STEP.Bounds?
        for instance in resolution.instances {
            try Task.checkCancellation()
            guard let info = infoByBody[instance.prototype] else { continue }
            guard let placement = STEPPlacement(instance.matrix) else {
                diagnostics.append(STEP.Diagnostic(entityID: instance.prototype.entityID,
                                                   message: "A placement of body #\(instance.prototype.entityID) is not a rotation with a uniform scale; the body is left out",
                                                   severity: .skipped, code: "assembly-placement-skipped"))
                continue
            }
            let id = STEP.BodyID(representationID: instance.prototype.representationID,
                                 entityID: instance.prototype.entityID, instance: instance.index)
            let source = edgesByBody[instance.prototype] ?? []
            let moved = placement.isIdentity && instance.index == 0
                ? source
                : source.map { $0.placed(by: placement, body: id) }
            var own: STEP.Bounds?
            for edge in moved {
                for point in edge.points {
                    if own == nil { own = STEP.Bounds(min: point, max: point) } else { own?.include(point) }
                }
            }
            if let own {
                if bounds == nil { bounds = own } else {
                    bounds?.include(own.min)
                    bounds?.include(own.max)
                }
            }
            placed.append(Placed(id: id, prototype: instance.prototype,
                                 info: STEP.BodyInfo(id: id, contextID: info.contextID, unitScaleToMM: info.unitScaleToMM,
                                                     unitsAssumed: info.unitsAssumed,
                                                     uncertaintyMM: info.uncertaintyMM.map { $0 * placement.scale },
                                                     bounds: own, name: info.name),
                                 placement: placement, path: instance.path, edges: moved))
        }

        let origin = bounds?.workpieceOrigin ?? .zero
        let oldOrigin = surfaces?.origin ?? .zero
        assembly.bounds = bounds
        assembly.origin = origin

        // Pass 2: meshes, within the triangle budget shared by all instances.
        var budget = max(0, options.maximumTriangleCount)
        var overBudget = 0
        var bodies: [STEP.Body] = []
        bodies.reserveCapacity(placed.count)
        for item in placed {
            try Task.checkCancellation()
            var mesh: STEP.BodyMesh?
            if let prototypeMesh = meshByBody[item.prototype] {
                if prototypeMesh.triangleCount <= budget {
                    budget -= prototypeMesh.triangleCount
                    let unchanged = item.placement.isIdentity && item.id == item.prototype && origin == oldOrigin
                    mesh = unchanged ? prototypeMesh
                        : prototypeMesh.placed(by: item.placement, as: item.id, from: oldOrigin, to: origin)
                } else {
                    overBudget += 1
                }
            }
            bodies.append(STEP.Body(id: item.id, info: item.info, transform: item.placement.matrix,
                                    path: item.path, edges: item.edges, mesh: mesh))
        }
        if overBudget > 0 {
            diagnostics.append(STEP.Diagnostic(entityID: nil,
                                               message: "\(overBudget) body instance\(overBudget == 1 ? "" : "s") would take the assembly over \(options.maximumTriangleCount) triangles and have no mesh (their edges are still drawn)",
                                               severity: .skipped, code: "instance-triangle-limit"))
        }
        assembly.bodies = bodies
        assembly.diagnostics = diagnostics
        return assembly
    }
}

// MARK: - Moving geometry

extension STEP.Edge {
    /// The edge after `placement`, as an edge of body `body`.
    func placed(by placement: STEPPlacement, body: STEP.BodyID) -> STEP.Edge {
        let scale = placement.scale
        let movedCurve: Curve
        switch curve {
            case .line:
                movedCurve = .line
            case .circle(let frame, let radius, let startAngle, let sweep):
                movedCurve = .circle(frame: placement.frame(frame), radius: radius * scale, startAngle: startAngle, sweep: sweep)
            case .ellipse(let frame, let semiAxisX, let semiAxisY, let startAngle, let sweep):
                movedCurve = .ellipse(frame: placement.frame(frame), semiAxisX: semiAxisX * scale,
                                      semiAxisY: semiAxisY * scale, startAngle: startAngle, sweep: sweep)
            case .other:
                movedCurve = .other
        }
        return STEP.Edge(id: STEP.EdgeID(importID: id.importID, bodyID: body, entityID: id.entityID),
                         kind: kind,
                         points: points.map { placement.point($0) },
                         startVertexID: startVertexID,
                         endVertexID: endVertexID,
                         adjacentFaceIDs: adjacentFaceIDs,
                         chordError: chordError * scale,
                         isSeam: isSeam,
                         curve: movedCurve)
    }
}

extension STEP.BodyMesh {
    /// The mesh after `placement`, as the mesh of body `body`. Positions are relative to
    /// `oldOrigin` going in and to `newOrigin` coming out; normals only rotate.
    func placed(by placement: STEPPlacement, as body: STEP.BodyID,
                from oldOrigin: SIMD3<Double>, to newOrigin: SIMD3<Double>) -> STEP.BodyMesh {
        var result = STEP.BodyMesh(id: body)
        result.positions = positions.map { position in
            SIMD3<Float>(placement.point(SIMD3<Double>(position) + oldOrigin) - newOrigin)
        }
        result.normals = normals.map { SIMD3<Float>(placement.direction(SIMD3<Double>($0))) }
        result.indices = indices
        result.faces = faces.map {
            STEP.FaceMesh(faceID: $0.faceID, surface: $0.surface.transformed(by: placement),
                          sameSense: $0.sameSense, triangles: $0.triangles)
        }
        result.failedFaceIDs = failedFaceIDs
        return result
    }
}
