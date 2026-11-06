import Foundation
import simd

// MARK: - Tessellator

/// Turns the faces of each body into triangles, reusing the wireframe's sampled edges as
/// face boundaries so faces and edges agree exactly.
///
/// Supported: planes (outer loop with holes) and cylinders, cones, spheres and tori trimmed
/// by their loops, including faces that wrap the whole axis (a cylinder between two
/// circles) and the seam-edge form of the same, and freeform faces on a
/// B_SPLINE_SURFACE_WITH_KNOTS (rational or not, simple or complex record). Not yet: swept
/// surfaces (revolution, linear extrusion), B-splines without explicit knots or that close on
/// themselves or have a collapsed side, faces that reach a sphere's pole or a cone's apex,
/// vertex or polyline loops, oriented faces. Any such face drops the whole body's surface,
/// with a diagnostic.
///
/// Task-confined like `STEPFile`; use through `STEPEdgeImporter.parseGeometry`.
final class STEPTessellator {
    /// Cap for the whole import. The renderer keeps a CPU and a GPU copy of every triangle,
    /// roughly 150 bytes each, so this bounds the extra memory to a few hundred MB.
    static let maximumTriangles = 1_000_000

    private let file: STEPFile
    private let model: STEP.EdgeModel
    private let tolerance: Double
    private var surfaces: STEP.SurfaceModel
    private var triangleBudget = STEPTessellator.maximumTriangles

    private static let bodyTypes: Set<String> = ["MANIFOLD_SOLID_BREP", "BREP_WITH_VOIDS", "SHELL_BASED_SURFACE_MODEL"]
    private static let surfaceTypes: Set<String> = ["PLANE", "CYLINDRICAL_SURFACE", "CONICAL_SURFACE",
                                                    "SPHERICAL_SURFACE", "TOROIDAL_SURFACE"]
    /// Two boundary edges meet when their end points are this close (mm).
    private static let connectionTolerance = 1e-6

    init(file: STEPFile, model: STEP.EdgeModel, options: STEP.Options) {
        self.file = file
        self.model = model
        tolerance = options.chordToleranceMM
        surfaces = STEP.SurfaceModel(origin: model.bounds?.workpieceOrigin ?? .zero)
    }

    func tessellate() throws -> STEP.SurfaceModel {
        try Task.checkCancellation()
        guard tolerance.isFinite, tolerance > 0 else {
            throw STEP.ParseError("Chord tolerance must be finite and positive")
        }
        if model.bodies.isEmpty {
            diagnose(nil, "No bodies to tessellate: the edge pass found no supported solid or shell (see the edge notes)")
        }
        let edgesByBody = Dictionary(grouping: model.edges, by: { $0.id.bodyID })
        for body in model.bodies {
            try Task.checkCancellation()
            try tessellate(body: body, edges: edgesByBody[body.id] ?? [])
        }
        return surfaces
    }

    private func diagnose(_ id: Int?, _ message: String) {
        surfaces.diagnostics.append(STEP.Diagnostic(entityID: id, message: message))
    }

    // MARK: Bodies

    private func tessellate(body: STEP.BodyInfo, edges: [STEP.Edge]) throws {
        let faces: [(id: Int, flipped: Bool)]
        do {
            faces = try collectFaces(bodyID: body.id.entityID)
        } catch let error as STEP.ParseError {
            surfaces.unsurfacedBodies.append(body.id)
            surfaces.faceFailures.append(STEP.FaceFailure(bodyID: body.id, faceID: nil, surfaceID: nil,
                                                          surfaceType: nil, reason: error.description))
            diagnose(body.id.entityID, "No surface for body #\(body.id.entityID): \(error.description)")
            return
        }
        surfaces.reachableFaceCount += faces.count
        if faces.isEmpty {
            diagnose(body.id.entityID, "Body #\(body.id.entityID) has no faces, so there is nothing to fill")
            return
        }
        let edgeByID = Dictionary(edges.map { ($0.id.entityID, $0) }, uniquingKeysWith: { first, _ in first })
        let contextID = body.contextID
        let scale = body.unitScaleToMM
        var mesh = STEP.BodyMesh(id: body.id)
        var surfaceCache: [Int: STEP.Surface] = [:]
        var failed = 0

        for face in faces {
            try Task.checkCancellation()
            var surfaceID: Int?
            do {
                let parsed = try parseFace(face.id)
                surfaceID = parsed.surfaceID
                let surface: STEP.Surface
                if let cached = surfaceCache[parsed.surfaceID] {
                    surface = cached
                } else {
                    surface = try parseSurface(parsed.surfaceID, scale: scale, contextID: contextID)
                    surfaceCache[parsed.surfaceID] = surface
                }
                try tessellateFace(face.id, parsed: parsed, surface: surface, shellFlipped: face.flipped,
                                   edges: edgeByID, into: &mesh)
                if failed > 0 {
                    // The body is already lost. Faces are still run so that every problem is
                    // reported, not just the first, but their triangles are thrown away at once.
                    triangleBudget += mesh.triangleCount
                    mesh = STEP.BodyMesh(id: body.id)
                }
            } catch let error as STEP.ParseError {
                if failed == 0 {
                    // First failure: give back what this body already took from the budget.
                    triangleBudget += mesh.triangleCount
                    mesh = STEP.BodyMesh(id: body.id)
                }
                failed += 1
                let type = surfaceID.flatMap { surfaceTypeName($0) }
                let reason = explain(error.description, edges: edges)
                surfaces.faceFailures.append(STEP.FaceFailure(bodyID: body.id, faceID: face.id, surfaceID: surfaceID,
                                                              surfaceType: type, reason: reason))
                let on = type.map { " on \($0)" + (surfaceID.map { " #\($0)" } ?? "") } ?? ""
                diagnose(face.id, "Face #\(face.id)\(on) not tessellated: \(reason)")
            }
        }

        if failed > 0 {
            surfaces.failedFaceCount += failed
            surfaces.unsurfacedBodies.append(body.id)
            diagnose(body.id.entityID,
                     "No filled faces for body #\(body.id.entityID): \(failed) of \(faces.count) faces could not be tessellated, so the whole body is left unfilled (edges are still drawn)")
        } else if mesh.triangleCount > 0 {
            surfaces.tessellatedFaceCount += faces.count
            surfaces.bodies.append(mesh)
        } else {
            diagnose(body.id.entityID, "Body #\(body.id.entityID): all \(faces.count) faces tessellated to zero triangles")
        }
    }

    /// The STEP type name of a surface entity, for messages ("CYLINDRICAL_SURFACE", "SURFACE_OF_REVOLUTION").
    private func surfaceTypeName(_ id: Int) -> String? {
        guard let components = try? file.components(id) else { return nil }
        return components.map { $0.type }.first(where: { !Self.surfaceMixins.contains($0) }) ?? components.first?.type
    }

    /// Adds the reason an edge was skipped when a face fails only because that edge has no geometry:
    /// "has no extracted geometry" alone sends the reader looking in the wrong place.
    private func explain(_ message: String, edges: [STEP.Edge]) -> String {
        guard message.contains("has no extracted geometry"),
              let range = message.range(of: #"#\d+"#, options: .regularExpression),
              let edgeID = Int(message[range].dropFirst()),
              let note = model.diagnostics.first(where: { $0.entityID == edgeID }) else { return message }
        return "\(message) (edge note: \(note.message))"
    }

    /// Faces of the body's shells, each with whether its shell is reversed (the void shells of
    /// a BREP_WITH_VOIDS are ORIENTED_CLOSED_SHELL with orientation .F). Sorted by face ID.
    private func collectFaces(bodyID: Int) throws -> [(id: Int, flipped: Bool)] {
        var faces: [Int: Bool] = [:]

        func addShell(_ id: Int, flipped: Bool, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 8 else { throw STEP.ParseError("Shell nesting is too deep at #\(id)") }
            let components = try file.components(id)
            if let oriented = components.first(where: { $0.type == "ORIENTED_CLOSED_SHELL" }) {
                guard let orientation = try oriented.parameters.argument(3).enumeration,
                      orientation == "T" || orientation == "F" else {
                    throw STEP.ParseError("Invalid ORIENTED_CLOSED_SHELL orientation at #\(id)")
                }
                try addShell(try oriented.parameters.reference(at: 2),
                             flipped: flipped != (orientation == "F"), depth: depth + 1)
                return
            }
            guard let shell = components.first(where: { $0.type == "CLOSED_SHELL" || $0.type == "OPEN_SHELL" }) else {
                throw STEP.ParseError("Unsupported shell at #\(id)")
            }
            for face in try shell.parameters.references(at: 1) {
                guard file.hasType(face, "ADVANCED_FACE") || file.hasType(face, "FACE_SURFACE") else {
                    throw STEP.ParseError("Unsupported face type at #\(face)")
                }
                if faces[face] == nil { faces[face] = flipped }
            }
        }

        let components = try file.components(bodyID)
        guard let body = components.first(where: { Self.bodyTypes.contains($0.type) }) else {
            throw STEP.ParseError("Unsupported body at #\(bodyID)")
        }
        let p = body.parameters
        switch body.type {
            case "MANIFOLD_SOLID_BREP":
                try addShell(try p.reference(at: 1), flipped: false, depth: 0)
            case "BREP_WITH_VOIDS":
                try addShell(try p.reference(at: 1), flipped: false, depth: 0)
                for void in try p.references(at: 2) { try addShell(void, flipped: false, depth: 0) }
            default:
                for shell in try p.references(at: 1) { try addShell(shell, flipped: false, depth: 0) }
        }
        return faces.keys.sorted().map { (id: $0, flipped: faces[$0] ?? false) }
    }

    // MARK: Faces and surfaces

    private struct ParsedFace {
        let boundIDs: [Int]
        let surfaceID: Int
        let sameSense: Bool
    }

    private func parseFace(_ id: Int) throws -> ParsedFace {
        let components = try file.components(id)
        guard let part = components.first(where: { $0.type == "ADVANCED_FACE" || $0.type == "FACE_SURFACE" }) else {
            throw STEP.ParseError("Unsupported face type")
        }
        let p = part.parameters
        guard let sense = try p.argument(3).enumeration, sense == "T" || sense == "F" else {
            throw STEP.ParseError("Invalid face same_sense")
        }
        return ParsedFace(boundIDs: try p.references(at: 1), surfaceID: try p.reference(at: 2), sameSense: sense == "T")
    }

    /// Mixin types of a complex record that say nothing about which surface it is.
    private static let surfaceMixins: Set<String> = ["BOUNDED_SURFACE", "SURFACE", "GEOMETRIC_REPRESENTATION_ITEM",
                                                     "REPRESENTATION_ITEM"]

    private func parseSurface(_ id: Int, scale: Double, contextID: Int) throws -> STEP.Surface {
        let components = try file.components(id)
        if components.contains(where: { $0.type == "B_SPLINE_SURFACE_WITH_KNOTS" }) {
            return try parseBSplineSurface(id, components: components, scale: scale)
        }
        guard let part = components.first(where: { Self.surfaceTypes.contains($0.type) }) else {
            // A complex record starts with mixins such as BOUNDED_SURFACE; name the real kind.
            let kind = components.map { $0.type }.first(where: { !Self.surfaceMixins.contains($0) })
                ?? components.first?.type ?? "unknown"
            throw STEP.ParseError("Unsupported surface type \(kind) at #\(id)")
        }
        let p = part.parameters
        // Only the frame helper is used: the resolver scales the placement's origin.
        let resolver = STEPCurveResolver(file: file, scaleToMM: scale, chordTolerance: tolerance,
                                         angleScaleToRadians: { 1 })
        let frame = try resolver.frame(try p.reference(at: 1))

        func length(_ index: Int, allowZero: Bool = false) throws -> Double {
            guard let value = try p.argument(index).number, value.isFinite,
                  allowZero ? value >= 0 : value > 0, (value * scale).isFinite else {
                throw STEP.ParseError("Invalid \(part.type) dimension at #\(id)")
            }
            return value * scale
        }

        switch part.type {
            case "PLANE":
                return .plane(frame)
            case "CYLINDRICAL_SURFACE":
                return .cylinder(frame, radius: try length(2))
            case "CONICAL_SURFACE":
                let radius = try length(2, allowZero: true)
                guard let angle = try p.argument(3).number, angle.isFinite else {
                    throw STEP.ParseError("Invalid CONICAL_SURFACE semi-angle at #\(id)")
                }
                let radiansPerUnit = try STEPUnits(file: file).angleScaleToRadians(contextID: contextID)
                let halfAngle = angle * radiansPerUnit
                guard halfAngle.isFinite, abs(halfAngle) < Double.pi / 2 - 1e-6 else {
                    throw STEP.ParseError("Invalid CONICAL_SURFACE semi-angle at #\(id)")
                }
                return .cone(frame, radius: radius, halfAngle: halfAngle)
            case "SPHERICAL_SURFACE":
                return .sphere(frame, radius: try length(2))
            default:
                let major = try length(2)
                let minor = try length(3)
                guard major > minor else { throw STEP.ParseError("Self-intersecting torus at #\(id) is not supported") }
                return .torus(frame, major: major, minor: minor)
        }
    }

    // MARK: B-spline surfaces

    /// Both file layouts: the simple 13-parameter B_SPLINE_SURFACE_WITH_KNOTS record, and the
    /// complex record of B_SPLINE_SURFACE + B_SPLINE_SURFACE_WITH_KNOTS (+ RATIONAL_B_SPLINE_SURFACE
    /// for weights) that CAD systems write for NURBS patches.
    private func parseBSplineSurface(_ id: Int, components: [STEPComponent], scale: Double) throws -> STEP.Surface {
        let uDegree: Int
        let vDegree: Int
        let netIDs: [[STEPValue]]
        let uMultiplicities: [Int]
        let vMultiplicities: [Int]
        let uKnots: [Double]
        let vKnots: [Double]
        var weights: [[Double]]?
        if let base = components.first(where: { $0.type == "B_SPLINE_SURFACE" }),
           let withKnots = components.first(where: { $0.type == "B_SPLINE_SURFACE_WITH_KNOTS" }) {
            uDegree = try Self.integer(base.parameters.argument(0))
            vDegree = try Self.integer(base.parameters.argument(1))
            netIDs = try Self.grid(base.parameters.argument(2))
            uMultiplicities = try Self.integers(withKnots.parameters.argument(0))
            vMultiplicities = try Self.integers(withKnots.parameters.argument(1))
            uKnots = try Self.numbers(withKnots.parameters.argument(2))
            vKnots = try Self.numbers(withKnots.parameters.argument(3))
            if let rational = components.first(where: { $0.type == "RATIONAL_B_SPLINE_SURFACE" }) {
                weights = try Self.grid(rational.parameters.argument(0)).map { try Self.numbers(.list($0)) }
            }
        } else if let simple = components.first(where: { $0.type == "B_SPLINE_SURFACE_WITH_KNOTS" }),
                  simple.parameters.count == 13 {
            uDegree = try Self.integer(simple.parameters.argument(1))
            vDegree = try Self.integer(simple.parameters.argument(2))
            netIDs = try Self.grid(simple.parameters.argument(3))
            uMultiplicities = try Self.integers(simple.parameters.argument(8))
            vMultiplicities = try Self.integers(simple.parameters.argument(9))
            uKnots = try Self.numbers(simple.parameters.argument(10))
            vKnots = try Self.numbers(simple.parameters.argument(11))
        } else {
            throw STEP.ParseError("Unsupported B-spline surface layout at #\(id)")
        }
        // Bound the work before resolving every control point.
        let pointCount = netIDs.reduce(0) { $0 + $1.count }
        guard pointCount <= STEP.BSplineSurface.maximumControlPoints else {
            throw STEP.ParseError("B-spline surface #\(id) has too many control points")
        }
        let controlPoints: [[SIMD3<Double>]] = try netIDs.map { row in
            try row.map { value in
                guard let pointID = value.reference else { throw STEP.ParseError("Expected a control point reference in B-spline surface #\(id)") }
                return try cartesianPoint(pointID, scale: scale)
            }
        }
        let spline = try STEP.BSplineSurface(uDegree: uDegree, vDegree: vDegree, controlPoints: controlPoints,
                                            weights: weights, uMultiplicities: uMultiplicities, uKnotValues: uKnots,
                                            vMultiplicities: vMultiplicities, vKnotValues: vKnots)
        if let limitation = spline.limitation {
            throw STEP.ParseError("B-spline surface #\(id) \(limitation); not supported yet")
        }
        return .bspline(spline)
    }

    /// Scaled to millimetres, like every other point.
    private func cartesianPoint(_ id: Int, scale: Double) throws -> SIMD3<Double> {
        let point = try file.parameters(id, type: "CARTESIAN_POINT")
        guard let coordinates = try point.argument(1).list, coordinates.count == 3 else {
            throw STEP.ParseError("Expected 3D coordinates at #\(id)")
        }
        var result = SIMD3<Double>.zero
        for axis in 0..<3 {
            guard let value = coordinates[axis].number, value.isFinite, (value * scale).isFinite else {
                throw STEP.ParseError("Nonfinite/invalid point #\(id)")
            }
            result[axis] = value * scale
        }
        return result
    }

    private static func integer(_ value: STEPValue) throws -> Int {
        guard case .integer(let result) = value else { throw STEP.ParseError("Expected an integer in B-spline surface data") }
        return result
    }

    private static func integers(_ value: STEPValue) throws -> [Int] {
        guard let items = value.list else { throw STEP.ParseError("Expected a list of integers in B-spline surface data") }
        return try items.map { try integer($0) }
    }

    private static func numbers(_ value: STEPValue) throws -> [Double] {
        guard let items = value.list else { throw STEP.ParseError("Expected a list of numbers in B-spline surface data") }
        return try items.map { item in
            guard let number = item.number, number.isFinite else { throw STEP.ParseError("Nonfinite B-spline surface number") }
            return number
        }
    }

    /// A list of lists, as the control point net and the weights are written.
    private static func grid(_ value: STEPValue) throws -> [[STEPValue]] {
        guard let rows = value.list else { throw STEP.ParseError("Expected a grid in B-spline surface data") }
        return try rows.map { row in
            guard let items = row.list else { throw STEP.ParseError("Expected a grid in B-spline surface data") }
            return items
        }
    }

    // MARK: Boundary loops

    /// The loop's sampled points in the face bound's direction, built from the wireframe's own
    /// edge polylines. Closed, without a repeated end point.
    private func loopPoints(bound id: Int, edges: [Int: STEP.Edge]) throws -> [SIMD3<Double>] {
        let components = try file.components(id)
        guard let bound = components.first(where: { $0.type == "FACE_BOUND" || $0.type == "FACE_OUTER_BOUND" }) else {
            throw STEP.ParseError("Unsupported face bound #\(id)")
        }
        let loopID = try bound.parameters.reference(at: 1)
        guard let boundOrientation = try bound.parameters.argument(2).enumeration,
              boundOrientation == "T" || boundOrientation == "F" else {
            throw STEP.ParseError("Invalid face bound orientation at #\(id)")
        }
        guard file.hasType(loopID, "EDGE_LOOP") else {
            throw STEP.ParseError("Unsupported loop type at #\(loopID)")
        }
        var points: [SIMD3<Double>] = []
        for use in try file.parameters(loopID, type: "EDGE_LOOP").references(at: 1) {
            try Task.checkCancellation()
            let oriented = try file.parameters(use, type: "ORIENTED_EDGE")
            let edgeID = try oriented.reference(at: 3)
            guard let orientation = try oriented.argument(4).enumeration, orientation == "T" || orientation == "F" else {
                throw STEP.ParseError("Invalid ORIENTED_EDGE orientation at #\(use)")
            }
            guard let edge = edges[edgeID] else {
                throw STEP.ParseError("Boundary edge #\(edgeID) has no extracted geometry")
            }
            let piece = orientation == "T" ? edge.points : Array(edge.points.reversed())
            guard let first = piece.first else { continue }
            if let last = points.last {
                guard simd_distance(last, first) <= Self.connectionTolerance else {
                    throw STEP.ParseError("Face loop is not connected at edge #\(edgeID)")
                }
                for point in piece.dropFirst() {
                    if simd_distance(point, points[points.count - 1]) > 1e-12 { points.append(point) }
                }
            } else {
                points = piece
            }
        }
        guard points.count >= 2, simd_distance(points[0], points[points.count - 1]) <= Self.connectionTolerance else {
            throw STEP.ParseError("Face loop is not closed")
        }
        points.removeLast()
        guard points.count >= 3 else {
            throw STEP.ParseError("Face loop is degenerate: only \(points.count) distinct sample points (every edge in the loop was sampled as a single chord)")
        }
        // A bound with orientation .F runs against its loop.
        return boundOrientation == "T" ? points : points.reversed()
    }

    /// A boundary loop in the surface's (u, v) plane.
    private struct ParamLoop {
        typealias Vertex = STEPSlabTriangulator.Vertex
        typealias Segment = STEPSlabTriangulator.Segment

        var vertices: [Vertex]
        /// The first vertex again, moved by the loop's winding: where the last vertex connects.
        var closing: Vertex
        /// Whole turns the loop makes round the surface's axis (u) or tube (v).
        var windingU: Int
        var windingV: Int

        var uRange: ClosedRange<Double> { range(\.u) }
        var vRange: ClosedRange<Double> { range(\.v) }

        private func range(_ key: KeyPath<Vertex, Double>) -> ClosedRange<Double> {
            var low = closing[keyPath: key]
            var high = low
            for vertex in vertices {
                low = min(low, vertex[keyPath: key])
                high = max(high, vertex[keyPath: key])
            }
            return low...high
        }

        var segments: [Segment] {
            var result: [Segment] = []
            result.reserveCapacity(vertices.count)
            for i in vertices.indices {
                result.append(Segment(a: vertices[i], b: i + 1 < vertices.count ? vertices[i + 1] : closing))
            }
            return result
        }

        func shifted(du: Double, dv: Double) -> ParamLoop {
            var copy = self
            for i in copy.vertices.indices {
                copy.vertices[i].u += du
                copy.vertices[i].v += dv
            }
            copy.closing.u += du
            copy.closing.v += dv
            return copy
        }
    }

    /// Unwraps the loop's angles so neighbouring points stay within half a turn, and counts how
    /// many turns it makes.
    private func parametrize(_ points: [SIMD3<Double>], on surface: STEP.Surface) throws -> ParamLoop {
        let raw = points.map { surface.parameters(of: $0) }
        // Analytic surfaces project exactly. A B-spline's inverse is searched for, and a boundary
        // that does not lie on it (a damaged file, or a search that missed) would be meshed
        // somewhere else, so it fails with the distance instead.
        if let worst = raw.map({ $0.distance }).max(), worst > tolerance {
            throw STEP.ParseError("Face boundary lies \((worst * 1000).rounded() / 1000) mm off its \(surface.kindName)")
        }
        if raw.contains(where: { $0.isPole }) {
            throw STEP.ParseError("Face reaches a pole or apex of its \(surface.kindName); not supported yet")
        }
        let twoPi = STEPAngle.twoPi
        var u = raw.map { $0.u }
        var v = raw.map { $0.v }
        for i in 1..<raw.count {
            if surface.isPeriodicU { u[i] += twoPi * ((u[i - 1] - u[i]) / twoPi).rounded() }
            if surface.isPeriodicV { v[i] += twoPi * ((v[i - 1] - v[i]) / twoPi).rounded() }
        }
        var closingU = u[0]
        var closingV = v[0]
        if surface.isPeriodicU { closingU += twoPi * ((u[u.count - 1] - u[0]) / twoPi).rounded() }
        if surface.isPeriodicV { closingV += twoPi * ((v[v.count - 1] - v[0]) / twoPi).rounded() }
        guard (u + v + [closingU, closingV]).allSatisfy({ $0.isFinite }) else {
            throw STEP.ParseError("Face loop has nonfinite parameters")
        }
        var vertices: [STEPSlabTriangulator.Vertex] = []
        vertices.reserveCapacity(points.count)
        for i in points.indices {
            vertices.append(STEPSlabTriangulator.Vertex(u: u[i], v: v[i], position: points[i]))
        }
        return ParamLoop(vertices: vertices,
                         closing: STEPSlabTriangulator.Vertex(u: closingU, v: closingV, position: points[0]),
                         windingU: Int(((closingU - u[0]) / twoPi).rounded()),
                         windingV: Int(((closingV - v[0]) / twoPi).rounded()))
    }

    // MARK: Face geometry

    private func tessellateFace(_ id: Int, parsed: ParsedFace, surface: STEP.Surface, shellFlipped: Bool,
                                edges: [Int: STEP.Edge], into mesh: inout STEP.BodyMesh) throws {
        guard !parsed.boundIDs.isEmpty else { throw STEP.ParseError("Face has no boundary") }
        var loops: [ParamLoop] = []
        for bound in parsed.boundIDs {
            loops.append(try parametrize(try loopPoints(bound: bound, edges: edges), on: surface))
        }
        let segments = try boundarySegments(loops, surface: surface)
        let vValues = segments.flatMap { [$0.a.v, $0.b.v] }
        guard let vLow = vValues.min(), let vHigh = vValues.max() else { throw STEP.ParseError("Face has no boundary") }

        let result = try STEPSlabTriangulator.triangulate(segments,
                                                          sampling: sampling(for: surface, vRange: vLow...vHigh),
                                                          triangleLimit: triangleBudget)
        triangleBudget -= result.triangles.count

        // The surface normal is a face's front unless same_sense is false; a reversed shell
        // (a void) turns every face the other way again.
        let flip = (!parsed.sameSense) != shellFlipped
        let base = mesh.positions.count
        let origin = surfaces.origin
        mesh.positions.reserveCapacity(base + result.vertices.count)
        mesh.normals.reserveCapacity(base + result.vertices.count)
        for vertex in result.vertices {
            mesh.positions.append(SIMD3<Float>(vertex.position - origin))
            let normal = surface.normal(u: vertex.u, v: vertex.v)
            mesh.normals.append(SIMD3<Float>(flip ? -normal : normal))
        }
        let firstTriangle = mesh.indices.count / 3
        for triangle in result.triangles {
            let a = UInt32(base + triangle.x)
            let b = UInt32(base + triangle.y)
            let c = UInt32(base + triangle.z)
            if flip {
                mesh.indices.append(contentsOf: [a, c, b])
            } else {
                mesh.indices.append(contentsOf: [a, b, c])
            }
        }
        mesh.faces.append(STEP.FaceMesh(faceID: id, surface: surface, sameSense: parsed.sameSense,
                                       triangles: firstTriangle..<(firstTriangle + result.triangles.count)))
    }

    /// The face's region as plain segments in (u, v): every closed loop as it is, or, for a face
    /// that goes all the way round its axis, the two wrapping loops cut to one period.
    private func boundarySegments(_ loops: [ParamLoop], surface: STEP.Surface) throws -> [STEPSlabTriangulator.Segment] {
        guard loops.allSatisfy({ $0.windingV == 0 }) else {
            throw STEP.ParseError("Face wraps round the \(surface.kindName)'s tube; not supported yet")
        }
        let wrapping = loops.filter { $0.windingU != 0 }
        let plain = loops.filter { $0.windingU == 0 }

        if wrapping.isEmpty {
            // Closed polygons. For a periodic surface, bring every loop into the outermost
            // loop's turn; a loop that then falls outside it straddles the seam.
            guard let reference = plain.indices.max(by: { Self.area(plain[$0]) < Self.area(plain[$1]) }) else {
                throw STEP.ParseError("Face has no boundary")
            }
            var segments: [STEPSlabTriangulator.Segment] = []
            for (index, loop) in plain.enumerated() {
                if index == reference {
                    segments.append(contentsOf: loop.segments)
                } else {
                    let aligned = try align(loop, surface: surface,
                                            referenceU: plain[reference].uRange, referenceV: plain[reference].vRange)
                    segments.append(contentsOf: aligned.segments)
                }
            }
            return segments
        }

        // Two loops that each go once round, in opposite directions: a band such as a
        // cylinder between two circles with no seam edge. Both are cut to one period.
        guard wrapping.count == 2, wrapping[0].windingU + wrapping[1].windingU == 0,
              abs(wrapping[0].windingU) == 1 else {
            throw STEP.ParseError("Face wraps round the \(surface.kindName)'s axis in a way that is not supported yet")
        }
        let twoPi = STEPAngle.twoPi
        let start = wrapping[0].vertices[0].u
        let window = start...(start + twoPi)
        let vLow = min(wrapping[0].vRange.lowerBound, wrapping[1].vRange.lowerBound)
        let vHigh = max(wrapping[0].vRange.upperBound, wrapping[1].vRange.upperBound)
        var segments: [STEPSlabTriangulator.Segment] = []
        for loop in wrapping { segments.append(contentsOf: Self.cut(loop, to: window)) }
        for loop in plain {
            segments.append(contentsOf: try align(loop, surface: surface, referenceU: window, referenceV: vLow...vHigh).segments)
        }
        return segments
    }

    private static func area(_ loop: ParamLoop) -> Double {
        let u = loop.uRange
        let v = loop.vRange
        return (u.upperBound - u.lowerBound) * (v.upperBound - v.lowerBound)
    }

    /// Moves a closed loop by whole turns into the reference's range and checks it fits.
    private func align(_ loop: ParamLoop, surface: STEP.Surface, referenceU: ClosedRange<Double>,
                       referenceV: ClosedRange<Double>) throws -> ParamLoop {
        let twoPi = STEPAngle.twoPi
        func mid(_ range: ClosedRange<Double>) -> Double { (range.lowerBound + range.upperBound) / 2 }
        var du = 0.0
        var dv = 0.0
        if surface.isPeriodicU { du = twoPi * ((mid(referenceU) - mid(loop.uRange)) / twoPi).rounded() }
        if surface.isPeriodicV { dv = twoPi * ((mid(referenceV) - mid(loop.vRange)) / twoPi).rounded() }
        let moved = loop.shifted(du: du, dv: dv)
        let slack = 1e-6
        if surface.isPeriodicU,
           moved.uRange.lowerBound < referenceU.lowerBound - slack || moved.uRange.upperBound > referenceU.upperBound + slack {
            throw STEP.ParseError("Face loop straddles the periodic seam of its \(surface.kindName)")
        }
        if surface.isPeriodicV,
           moved.vRange.lowerBound < referenceV.lowerBound - slack || moved.vRange.upperBound > referenceV.upperBound + slack {
            throw STEP.ParseError("Face loop straddles the periodic seam of its \(surface.kindName)")
        }
        return moved
    }

    /// One period of a wrapping loop: the loop and its copies one turn up or down, each
    /// segment clipped to the window. Every vertical line crosses the loop once.
    private static func cut(_ loop: ParamLoop, to window: ClosedRange<Double>) -> [STEPSlabTriangulator.Segment] {
        let twoPi = STEPAngle.twoPi
        let range = loop.uRange
        let first = Int(((window.lowerBound - range.upperBound) / twoPi).rounded(.up))
        let last = Int(((window.upperBound - range.lowerBound) / twoPi).rounded(.down))
        guard first <= last else { return [] }
        let base = loop.segments
        var result: [STEPSlabTriangulator.Segment] = []
        for k in first...last {
            let shift = Double(k) * twoPi
            for segment in base {
                var a = segment.a
                var b = segment.b
                a.u += shift
                b.u += shift
                let low = min(a.u, b.u)
                let high = max(a.u, b.u)
                guard high > window.lowerBound, low < window.upperBound, high > low else { continue }
                let from = max(low, window.lowerBound)
                let to = min(high, window.upperBound)
                func vertex(at u: Double) -> STEPSlabTriangulator.Vertex {
                    if u == a.u { return a }
                    if u == b.u { return b }
                    let t = (u - a.u) / (b.u - a.u)
                    return STEPSlabTriangulator.Vertex(u: u, v: a.v + (b.v - a.v) * t,
                                                       position: a.position + (b.position - a.position) * t)
                }
                result.append(STEPSlabTriangulator.Segment(a: vertex(at: from), b: vertex(at: to)))
            }
        }
        return result
    }

    // MARK: Resolution

    /// Largest angle between neighbouring samples on a circle of `radius` so the chord's
    /// sagitta stays within `tolerance`; the same rule the wireframe's circles use.
    private static func angularStep(radius: Double, tolerance: Double) -> Double {
        let ratio = min(2, tolerance / radius)
        let toleranceStep = 4 * asin(min(1, (ratio / 2).squareRoot()))
        return max(min(toleranceStep, STEPArcSampler.maximumAngularStep),
                   STEPAngle.twoPi / Double(STEPArcSampler.maximumSegments))
    }

    private func sampling(for surface: STEP.Surface, vRange: ClosedRange<Double>) -> STEPSlabTriangulator.Sampling {
        if case .bspline(let spline) = surface {
            // Freeform: curved along both u and v, so subdivide both from the chord tolerance.
            // The lattice and the rows are uniform in parameter space, which is what the
            // spline's own knots make roughly uniform in space; the counts come from probing it.
            let divisions = spline.divisions(tolerance: tolerance)
            let uLength = spline.uDomain.upperBound - spline.uDomain.lowerBound
            let vLength = spline.vDomain.upperBound - spline.vDomain.lowerBound
            var rows: ((Double, Double, Double) -> Int)?
            if divisions.v > 1 {
                let perDomain = Double(divisions.v)
                rows = { _, low, high in Int((abs(high - low) / vLength * perDomain).rounded(.up)) }
            }
            return STEPSlabTriangulator.Sampling(evaluate: { u, v in spline.point(u: u, v: v) },
                                                 rows: rows,
                                                 latticeStep: divisions.u > 1 ? uLength / Double(divisions.u) : nil)
        }
        var lattice: Double?
        if let radius = surface.widestRadius(vRange: vRange), radius > 0 {
            lattice = Self.angularStep(radius: radius, tolerance: tolerance)
        }
        var rows: ((Double, Double, Double) -> Int)?
        if let radius = surface.radiusAlongV, radius > 0 {
            let step = Self.angularStep(radius: radius, tolerance: tolerance)
            rows = { _, low, high in Int((abs(high - low) / step).rounded(.up)) }
        }
        return STEPSlabTriangulator.Sampling(evaluate: { u, v in surface.point(u: u, v: v) },
                                             rows: rows, latticeStep: lattice)
    }
}
