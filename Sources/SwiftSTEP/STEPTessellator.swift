import Foundation
import simd

// MARK: - Tessellator

/// Turns the faces of each body into triangles, reusing the wireframe's sampled edges as
/// face boundaries so faces and edges agree exactly.
///
/// Planes (outer loop with holes) go through `STEPPolygonTriangulator`, which adds no points; every
/// curved surface goes through the slab sweep, which has to.
///
/// Supported: planes (outer loop with holes) and cylinders, cones, spheres and tori trimmed
/// by their loops, including faces that wrap the whole axis (a cylinder between two
/// circles) and the seam-edge form of the same, and freeform faces on a
/// B_SPLINE_SURFACE_WITH_KNOTS (rational or not, simple or complex record). Not yet: swept
/// surfaces (revolution, linear extrusion), B-splines without explicit knots or that close on
/// themselves or have a collapsed side, vertex or polyline loops, oriented faces. A face may
/// contain a sphere's pole or a cone's apex when its seam edge runs out to it and back (a
/// hemisphere, say), or touch it at a loop vertex. A cap written as one circle with no seam
/// (a dome, a cone's tip) is read as containing the pole on the side the loop's direction and
/// the face's sense point to. Several loops that wind round a pole with no seam edge are not
/// supported yet. A face that fails drops only itself unless `Options.keepPartialSurfaces` is
/// off, with a diagnostic.
///
/// Task-confined like `STEPFile`; use through `STEPEdgeImporter.parseGeometry`.
final class STEPTessellator {
    /// Default cap for the whole import (`Options.maximumTriangleCount`). The renderer keeps a CPU
    /// and a GPU copy of every triangle, roughly 150 bytes each, so this bounds the extra memory to a
    /// few hundred MB.
    static let maximumTriangles = 1_000_000

    private let file: STEPFile
    /// Finds a body's faces and reads their surfaces; shared with the topology output.
    private let reader: STEPFaceReader
    private let model: STEP.EdgeModel
    private let tolerance: Double
    private let keepPartial: Bool
    /// Rebuilt for each body from the accuracy its context declares.
    private var tolerances: STEPTolerances
    private var surfaces: STEP.SurfaceModel
    private var triangleBudget: Int

    init(file: STEPFile, model: STEP.EdgeModel, options: STEP.Options) {
        self.file = file
        reader = STEPFaceReader(file: file, chordTolerance: options.chordToleranceMM)
        self.model = model
        tolerance = options.chordToleranceMM
        keepPartial = options.keepPartialSurfaces
        tolerances = STEPTolerances(chord: options.chordToleranceMM)
        surfaces = STEP.SurfaceModel(origin: model.bounds?.workpieceOrigin ?? .zero)
        triangleBudget = max(0, options.maximumTriangleCount)
    }

    func tessellate() throws -> STEP.SurfaceModel {
        try Task.checkCancellation()
        guard tolerance.isFinite, tolerance > 0 else {
            throw STEP.ParseError("Chord tolerance must be finite and positive", kind: .invalidOptions)
        }
        if model.bodies.isEmpty {
            diagnose(nil, "No bodies to tessellate: the edge pass found no supported solid or shell (see the edge notes)",
                     .warning, code: "no-bodies")
        }
        let edgesByBody = Dictionary(grouping: model.edges, by: { $0.id.bodyID })
        for body in model.bodies {
            try Task.checkCancellation()
            try tessellate(body: body, edges: edgesByBody[body.id] ?? [])
        }
        return surfaces
    }

    private func diagnose(_ id: Int?, _ message: String, _ severity: STEP.Diagnostic.Severity, code: String) {
        surfaces.diagnostics.append(STEP.Diagnostic(entityID: id, message: message, severity: severity, code: code))
    }

    // MARK: Bodies

    private func tessellate(body: STEP.BodyInfo, edges: [STEP.Edge]) throws {
        if reader.isWireframe(body.id.entityID) { return }
        tolerances = STEPTolerances(chord: tolerance, declaredUncertainty: body.uncertaintyMM)
        let faces: [(id: Int, flipped: Bool)]
        do {
            faces = try reader.collectFaces(bodyID: body.id.entityID)
        } catch let error as STEP.ParseError {
            surfaces.unsurfacedBodies.append(body.id)
            surfaces.faceFailures.append(STEP.FaceFailure(bodyID: body.id, faceID: nil, surfaceID: nil,
                                                          surfaceType: nil, reason: error.description))
            diagnose(body.id.entityID, "No surface for body #\(body.id.entityID): \(error.description)",
                     .skipped, code: "body-unsurfaced")
            return
        }
        surfaces.reachableFaceCount += faces.count
        if faces.isEmpty {
            diagnose(body.id.entityID, "Body #\(body.id.entityID) has no faces, so there is nothing to fill",
                     .warning, code: "no-faces")
            return
        }
        let edgeByID = Dictionary(edges.map { ($0.id.entityID, $0) }, uniquingKeysWith: { first, _ in first })
        let contextID = body.contextID
        let scale = body.unitScaleToMM
        var mesh = STEP.BodyMesh(id: body.id)
        var surfaceCache: [Int: STEP.Surface] = [:]
        var failed = 0
        var failedIDs: [Int] = []

        for face in faces {
            try Task.checkCancellation()
            var surfaceID: Int?
            do {
                let parsed = try reader.parseFace(face.id)
                surfaceID = parsed.surfaceID
                let surface: STEP.Surface
                if let cached = surfaceCache[parsed.surfaceID] {
                    surface = cached
                } else {
                    surface = try reader.parseSurface(parsed.surfaceID, scale: scale, contextID: contextID)
                    surfaceCache[parsed.surfaceID] = surface
                }
                try tessellateFace(face.id, parsed: parsed, surface: surface, shellFlipped: face.flipped,
                                   edges: edgeByID, into: &mesh)
                if failed > 0 && !keepPartial {
                    // The body is already lost. Faces are still run so that every problem is
                    // reported, not just the first, but their triangles are thrown away at once.
                    triangleBudget += mesh.triangleCount
                    mesh = STEP.BodyMesh(id: body.id)
                }
            } catch let error as STEP.ParseError {
                if failed == 0 && !keepPartial {
                    // First failure: give back what this body already took from the budget.
                    triangleBudget += mesh.triangleCount
                    mesh = STEP.BodyMesh(id: body.id)
                }
                failed += 1
                failedIDs.append(face.id)
                let type = surfaceID.flatMap { reader.surfaceTypeName($0) }
                let reason = explain(error.description, edges: edges)
                surfaces.faceFailures.append(STEP.FaceFailure(bodyID: body.id, faceID: face.id, surfaceID: surfaceID,
                                                              surfaceType: type, reason: reason))
                let on = type.map { " on \($0)" + (surfaceID.map { " #\($0)" } ?? "") } ?? ""
                diagnose(face.id, "Face #\(face.id)\(on) not tessellated: \(reason)", .skipped, code: "face-failed")
            }
        }

        surfaces.failedFaceCount += failed
        if failed > 0 && (!keepPartial || mesh.triangleCount == 0) {
            surfaces.unsurfacedBodies.append(body.id)
            let why = keepPartial
                ? "all \(faces.count) faces could not be tessellated"
                : "\(failed) of \(faces.count) faces could not be tessellated, so the whole body is left unfilled"
            diagnose(body.id.entityID, "No filled faces for body #\(body.id.entityID): \(why) (edges are still drawn)",
                     .skipped, code: "body-unfilled")
        } else if mesh.triangleCount > 0 {
            surfaces.tessellatedFaceCount += faces.count - failed
            mesh.failedFaceIDs = failedIDs
            surfaces.bodies.append(mesh)
            if failed > 0 {
                diagnose(body.id.entityID,
                         "Body #\(body.id.entityID) is partly filled: \(failed) of \(faces.count) faces could not be tessellated and are left out of the mesh (edges behind them are not hidden)",
                         .warning, code: "body-partial")
            }
        } else {
            diagnose(body.id.entityID, "Body #\(body.id.entityID): all \(faces.count) faces tessellated to zero triangles",
                     .warning, code: "zero-triangles")
        }
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
                guard simd_distance(last, first) <= tolerances.connection else {
                    throw STEP.ParseError("Face loop is not connected at edge #\(edgeID)")
                }
                for point in piece.dropFirst() {
                    if simd_distance(point, points[points.count - 1]) > 1e-12 { points.append(point) }
                }
            } else {
                points = piece
            }
        }
        guard points.count >= 2, simd_distance(points[0], points[points.count - 1]) <= tolerances.connection else {
            throw STEP.ParseError("Face loop is not closed")
        }
        points.removeLast()
        guard points.count >= 3 else {
            throw STEP.ParseError("Face loop is degenerate: only \(points.count) distinct sample points (every edge in the loop was sampled as a single chord)")
        }
        // A bound with orientation .F runs against its loop.
        return boundOrientation == "T" ? points : points.reversed()
    }

    /// Removes zero-width spikes from a closed loop: where it runs out along some path and comes
    /// straight back (a seam edge used once in each direction). `tips` are the far ends of the
    /// spikes, which is how a pole inside the face shows up.
    private static func cancelSpikes(_ input: [SIMD3<Double>]) -> (points: [SIMD3<Double>], tips: [SIMD3<Double>]) {
        var stack: [SIMD3<Double>] = []
        var tips: [SIMD3<Double>] = []
        stack.reserveCapacity(input.count)
        for point in input {
            if stack.count >= 2, simd_distance(stack[stack.count - 2], point) <= STEPTolerances.retrace {
                tips.append(stack.removeLast())
                continue
            }
            stack.append(point)
        }
        // The loop is cyclic: a spike can straddle its first point.
        while stack.count >= 4, simd_distance(stack[stack.count - 1], stack[1]) <= STEPTolerances.retrace {
            tips.append(stack.removeFirst())
            stack.removeLast()
        }
        return (stack, tips)
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
        // Each point starts its search from the one before it, so a loop stays on one sheet of a
        // surface that crosses itself.
        var raw: [STEP.Surface.Parameters] = []
        raw.reserveCapacity(points.count)
        for point in points { raw.append(surface.parameters(of: point, near: raw.last)) }
        // Analytic surfaces project exactly. A B-spline's inverse is searched for, and a boundary
        // that does not lie on it (a damaged file, or a search that missed) would be meshed
        // somewhere else, so it fails with the distance instead.
        if let worst = raw.map({ $0.distance }).max(), worst > tolerance {
            throw STEP.ParseError("Face boundary lies \((worst * 1000).rounded() / 1000) mm off its \(surface.kindName)")
        }
        let periodU = surface.periodU
        let periodV = surface.periodV

        // A vertex on a pole (or cone apex) has no longitude. Seen from (u, v) the boundary runs
        // along the pole's parallel there, from the longitude of the previous vertex to that of
        // the next: one point becomes two, and the segment between them is a point in space.
        var entries: [(u: Double, v: Double, position: SIMD3<Double>)] = []
        entries.reserveCapacity(raw.count + 2)
        let count = raw.count
        guard raw.contains(where: { !$0.isPole }) else { throw STEP.ParseError("Face loop is degenerate") }
        for i in 0..<count {
            guard raw[i].isPole else {
                entries.append((raw[i].u, raw[i].v, points[i]))
                continue
            }
            if raw[(i + count - 1) % count].isPole { continue } // inside a run of pole samples
            var before = (i + count - 1) % count
            while raw[before].isPole { before = (before + count - 1) % count }
            var after = (i + 1) % count
            while raw[after].isPole { after = (after + 1) % count }
            if surface.isPeriodicU {
                var turn = raw[after].u - raw[before].u
                turn -= periodU * (turn / periodU).rounded()
                guard abs(turn) < 0.5 * periodU - 1e-3 else {
                    throw STEP.ParseError("Face turns by half a turn or more at a pole of its \(surface.kindName); not supported yet")
                }
            }
            entries.append((raw[before].u, raw[i].v, points[i]))
            entries.append((raw[after].u, raw[i].v, points[i]))
        }
        var u = entries.map { $0.u }
        var v = entries.map { $0.v }
        for i in 1..<entries.count {
            if surface.isPeriodicU { u[i] += periodU * ((u[i - 1] - u[i]) / periodU).rounded() }
            if surface.isPeriodicV { v[i] += periodV * ((v[i - 1] - v[i]) / periodV).rounded() }
        }
        var closingU = u[0]
        var closingV = v[0]
        if surface.isPeriodicU { closingU += periodU * ((u[u.count - 1] - u[0]) / periodU).rounded() }
        if surface.isPeriodicV { closingV += periodV * ((v[v.count - 1] - v[0]) / periodV).rounded() }
        guard (u + v + [closingU, closingV]).allSatisfy({ $0.isFinite }) else {
            throw STEP.ParseError("Face loop has nonfinite parameters")
        }
        var vertices: [STEPSlabTriangulator.Vertex] = []
        vertices.reserveCapacity(entries.count)
        for i in entries.indices {
            vertices.append(STEPSlabTriangulator.Vertex(u: u[i], v: v[i], position: entries[i].position))
        }
        return ParamLoop(vertices: vertices,
                         closing: STEPSlabTriangulator.Vertex(u: closingU, v: closingV, position: entries[0].position),
                         windingU: Int(((closingU - u[0]) / periodU).rounded()),
                         windingV: Int(((closingV - v[0]) / periodV).rounded()))
    }

    // MARK: Face geometry

    private func tessellateFace(_ id: Int, parsed: STEPFaceReader.ParsedFace, surface: STEP.Surface, shellFlipped: Bool,
                                edges: [Int: STEP.Edge], into mesh: inout STEP.BodyMesh) throws {
        guard !parsed.boundIDs.isEmpty else { throw STEP.ParseError("Face has no boundary") }
        var loops: [ParamLoop] = []
        // Poles the face contains in its interior, found where a seam edge runs out to one and back.
        var poles: [STEPSlabTriangulator.Vertex] = []
        for bound in parsed.boundIDs {
            let loop = Self.cancelSpikes(try loopPoints(bound: bound, edges: edges))
            guard loop.points.count >= 3 else { throw STEP.ParseError("Face loop is degenerate") }
            for tip in loop.tips {
                let parameters = surface.parameters(of: tip)
                if parameters.isPole {
                    poles.append(STEPSlabTriangulator.Vertex(u: 0, v: parameters.v, position: tip))
                }
            }
            loops.append(try parametrize(loop.points, on: surface))
        }
        var planar: STEPSlabTriangulator.Result?
        if case .plane = surface, poles.isEmpty {
            planar = try triangulatePlane(loops)
        }
        let result: STEPSlabTriangulator.Result
        if let planar {
            result = planar
        } else {
            let segments = try boundarySegments(loops, poles: poles, surface: surface, sameSense: parsed.sameSense)
            let vValues = segments.flatMap { [$0.a.v, $0.b.v] }
            guard let vLow = vValues.min(), let vHigh = vValues.max() else { throw STEP.ParseError("Face has no boundary") }
            result = try STEPSlabTriangulator.triangulate(segments,
                                                          sampling: sampling(for: surface, vRange: vLow...vHigh),
                                                          triangleLimit: triangleBudget)
        }
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

    /// A plane needs no interior points, so its region is triangulated from the boundary alone:
    /// the largest loop is the outer one and every other loop a hole. `nil` when that fails (loops
    /// that touch or cross); the caller then uses the slab sweep, which copes with those.
    private func triangulatePlane(_ loops: [ParamLoop]) throws -> STEPSlabTriangulator.Result? {
        guard let outerIndex = loops.indices.max(by: {
            abs(STEPPolygonTriangulator.signedArea(loops[$0].vertices))
                < abs(STEPPolygonTriangulator.signedArea(loops[$1].vertices))
        }) else { return nil }
        var holes: [[STEPSlabTriangulator.Vertex]] = []
        for index in loops.indices where index != outerIndex { holes.append(loops[index].vertices) }
        do {
            return try STEPPolygonTriangulator.triangulate(outer: loops[outerIndex].vertices, holes: holes,
                                                           triangleLimit: triangleBudget)
        } catch let error as STEP.ParseError {
            // Running out of triangles is the same answer from the slab sweep, so it is not retried.
            if error.description.contains("Triangle limit") { throw error }
            return nil
        }
    }

    /// The face's region as plain segments in (u, v): every closed loop as it is, or, for a face
    /// that goes all the way round its axis, the two wrapping loops cut to one period.
    private func boundarySegments(_ loops: [ParamLoop], poles knownPoles: [STEPSlabTriangulator.Vertex],
                                  surface: STEP.Surface, sameSense: Bool) throws -> [STEPSlabTriangulator.Segment] {
        guard loops.allSatisfy({ $0.windingV == 0 }) else {
            throw STEP.ParseError("Face wraps round the \(surface.kindName)'s tube; not supported yet")
        }
        let wrapping = loops.filter { $0.windingU != 0 }
        let plain = loops.filter { $0.windingU == 0 }
        var poles = knownPoles
        // A cap written as one circle with no seam edge (a dome, a cone's tip) does not say which
        // pole it contains; the loop's direction and the face's sense do.
        if poles.isEmpty, wrapping.count == 1, abs(wrapping[0].windingU) == 1,
           let pole = Self.enclosedPole(of: wrapping[0], on: surface, sameSense: sameSense) {
            poles = [pole]
        }

        if wrapping.isEmpty, surface.isPeriodicU, poles.count >= 2,
           let low = poles.min(by: { $0.v < $1.v }), let high = poles.max(by: { $0.v < $1.v }), high.v - low.v > 1e-6 {
            // A sphere (or similar) with both poles inside the face and only holes in it: seam
            // spikes to each pole, loops that close on themselves. The region is the whole
            // strip between the two pole parallels, minus the holes. The strip's ends are the
            // seam, so it starts in a gap between the holes where no hole straddles it.
            let period = surface.periodU
            var covered: [(Double, Double)] = []
            for loop in plain {
                let range = loop.uRange
                let width = range.upperBound - range.lowerBound
                guard width < period else {
                    throw STEP.ParseError("Face contains the poles of its \(surface.kindName) with a hole that spans a whole turn; not supported yet")
                }
                let start = range.lowerBound - (range.lowerBound / period).rounded(.down) * period
                covered.append((start, start + width))
                if start + width > period { covered.append((start - period, start + width - period)) }
            }
            covered.sort { $0.0 < $1.0 }
            var start = 0.0
            if !covered.isEmpty {
                // The widest gap between holes, taken cyclically; its middle is where the seam goes.
                var bestGap = -1.0
                var reach = covered[0].1
                for interval in covered.dropFirst() {
                    if interval.0 > reach, interval.0 - reach > bestGap {
                        bestGap = interval.0 - reach
                        start = (reach + interval.0) / 2
                    }
                    reach = max(reach, interval.1)
                }
                let wrapGap = covered[0].0 + period - reach
                if wrapGap > bestGap { bestGap = wrapGap; start = reach + wrapGap / 2 }
                guard bestGap > 1e-6 else {
                    throw STEP.ParseError("Face contains the poles of its \(surface.kindName) with holes that leave no room for its seam; not supported yet")
                }
            }
            let window = start...(start + period)
            var bottomFrom = low, bottomTo = low, topFrom = high, topTo = high
            bottomFrom.u = window.lowerBound; bottomTo.u = window.upperBound
            topFrom.u = window.lowerBound; topTo.u = window.upperBound
            var segments = [STEPSlabTriangulator.Segment(a: bottomFrom, b: bottomTo),
                            STEPSlabTriangulator.Segment(a: topFrom, b: topTo)]
            for loop in plain {
                segments.append(contentsOf: try align(loop, surface: surface, referenceU: window,
                                                      referenceV: low.v...high.v).segments)
            }
            return segments
        }

        if !poles.isEmpty {
            // A loop that goes once round the axis with the pole inside it (a hemisphere, a cap):
            // the region lies between the loop and the pole's parallel, which closes it.
            guard poles.count == 1, wrapping.count == 1, abs(wrapping[0].windingU) == 1 else {
                throw STEP.ParseError("Face contains a pole or apex of its \(surface.kindName) in a way that is not supported yet")
            }
            let period = surface.periodU
            let start = wrapping[0].vertices[0].u
            let window = start...(start + period)
            var from = poles[0]
            var to = poles[0]
            from.u = window.lowerBound
            to.u = window.upperBound
            var segments = Self.cut(wrapping[0], to: window, period: period)
            segments.append(STEPSlabTriangulator.Segment(a: from, b: to))
            let vLow = min(wrapping[0].vRange.lowerBound, poles[0].v)
            let vHigh = max(wrapping[0].vRange.upperBound, poles[0].v)
            for loop in plain {
                segments.append(contentsOf: try align(loop, surface: surface, referenceU: window, referenceV: vLow...vHigh).segments)
            }
            return segments
        }

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
        let period = surface.periodU
        let start = wrapping[0].vertices[0].u
        let window = start...(start + period)
        let vLow = min(wrapping[0].vRange.lowerBound, wrapping[1].vRange.lowerBound)
        let vHigh = max(wrapping[0].vRange.upperBound, wrapping[1].vRange.upperBound)
        var segments: [STEPSlabTriangulator.Segment] = []
        for loop in wrapping { segments.append(contentsOf: Self.cut(loop, to: window, period: period)) }
        for loop in plain {
            segments.append(contentsOf: try align(loop, surface: surface, referenceU: window, referenceV: vLow...vHigh).segments)
        }
        return segments
    }

    /// The pole (sphere) or apex (cone) inside a face whose only wrapping loop goes once round the
    /// axis. A face keeps its interior on the left of its boundary when seen from the side its
    /// normal points to, and (u, v) is drawn so that is the side `∂P/∂u × ∂P/∂v` points to; so for
    /// `same_sense` true a loop running towards +u has +v on its left, and for false the reverse.
    /// `nil` when the surface has no pole on that side (a cylinder, a torus, a cone whose apex is
    /// behind the loop), which leaves the face unsupported as before.
    private static func enclosedPole(of loop: ParamLoop, on surface: STEP.Surface,
                                     sameSense: Bool) -> STEPSlabTriangulator.Vertex? {
        let towardPositiveV = (loop.windingU > 0) == sameSense
        let poleV: Double
        switch surface {
            case .sphere:
                poleV = towardPositiveV ? 0.5 * .pi : -0.5 * .pi
            case .cone(_, let radius, let halfAngle):
                let slope = tan(halfAngle)
                guard abs(slope) > 1e-9 else { return nil }
                poleV = -radius / slope
                // The apex must lie beyond the whole loop, on the side the face is on.
                let slack = 1e-6 * max(1, abs(poleV))
                if towardPositiveV {
                    guard poleV >= loop.vRange.upperBound - slack else { return nil }
                } else {
                    guard poleV <= loop.vRange.lowerBound + slack else { return nil }
                }
            default:
                return nil
        }
        guard poleV.isFinite else { return nil }
        return STEPSlabTriangulator.Vertex(u: 0, v: poleV, position: surface.point(u: 0, v: poleV))
    }

    private static func area(_ loop: ParamLoop) -> Double {
        let u = loop.uRange
        let v = loop.vRange
        return (u.upperBound - u.lowerBound) * (v.upperBound - v.lowerBound)
    }

    /// Moves a closed loop by whole turns into the reference's range and checks it fits.
    private func align(_ loop: ParamLoop, surface: STEP.Surface, referenceU: ClosedRange<Double>,
                       referenceV: ClosedRange<Double>) throws -> ParamLoop {
        let periodU = surface.periodU
        let periodV = surface.periodV
        func mid(_ range: ClosedRange<Double>) -> Double { (range.lowerBound + range.upperBound) / 2 }
        var du = 0.0
        var dv = 0.0
        if surface.isPeriodicU { du = periodU * ((mid(referenceU) - mid(loop.uRange)) / periodU).rounded() }
        if surface.isPeriodicV { dv = periodV * ((mid(referenceV) - mid(loop.vRange)) / periodV).rounded() }
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
    private static func cut(_ loop: ParamLoop, to window: ClosedRange<Double>,
                            period: Double) -> [STEPSlabTriangulator.Segment] {
        let range = loop.uRange
        let first = Int(((window.lowerBound - range.upperBound) / period).rounded(.up))
        let last = Int(((window.upperBound - range.lowerBound) / period).rounded(.down))
        guard first <= last else { return [] }
        let base = loop.segments
        var result: [STEPSlabTriangulator.Segment] = []
        for k in first...last {
            let shift = Double(k) * period
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
