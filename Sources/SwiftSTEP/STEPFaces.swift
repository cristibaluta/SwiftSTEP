import Foundation
import simd

// MARK: - Shared face and surface reading

/// Finds the faces of a body and reads the surface under each one. Shared by the tessellator
/// (which fills the faces with triangles) and the topology output (which lists them).
/// Task-confined like `STEPFile`.
final class STEPFaceReader {
    private let file: STEPFile
    private let chordTolerance: Double

    private static let bodyTypes: Set<String> = ["MANIFOLD_SOLID_BREP", "BREP_WITH_VOIDS", "SHELL_BASED_SURFACE_MODEL"]
    private static let surfaceTypes: Set<String> = ["PLANE", "CYLINDRICAL_SURFACE", "CONICAL_SURFACE",
                                                    "SPHERICAL_SURFACE", "TOROIDAL_SURFACE"]

    init(file: STEPFile, chordTolerance: Double) {
        self.file = file
        self.chordTolerance = chordTolerance
    }

    /// A wireframe body (`GEOMETRIC_CURVE_SET`) has curves and no faces.
    func isWireframe(_ bodyID: Int) -> Bool { file.hasType(bodyID, "GEOMETRIC_CURVE_SET") }

    /// The STEP type name of a surface entity, for messages ("CYLINDRICAL_SURFACE", "SURFACE_OF_REVOLUTION").
    func surfaceTypeName(_ id: Int) -> String? {
        guard let components = try? file.components(id) else { return nil }
        return components.map { $0.type }.first(where: { !Self.surfaceMixins.contains($0) }) ?? components.first?.type
    }

    /// Faces of the body's shells, each with whether its shell is reversed (the void shells of
    /// a BREP_WITH_VOIDS are ORIENTED_CLOSED_SHELL with orientation .F). Sorted by face ID.
    func collectFaces(bodyID: Int) throws -> [(id: Int, flipped: Bool)] {
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

    struct ParsedFace {
        let boundIDs: [Int]
        let surfaceID: Int
        let sameSense: Bool
    }

    func parseFace(_ id: Int) throws -> ParsedFace {
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

    func parseSurface(_ id: Int, scale: Double, contextID: Int) throws -> STEP.Surface {
        let components = try file.components(id)
        if components.contains(where: { $0.type == "B_SPLINE_SURFACE_WITH_KNOTS" }) {
            return try parseBSplineSurface(id, components: components, scale: scale)
        }
        if let revolution = components.first(where: { $0.type == "SURFACE_OF_REVOLUTION" }) {
            return try parseSurfaceOfRevolution(id, parameters: revolution.parameters, scale: scale)
        }
        guard let part = components.first(where: { Self.surfaceTypes.contains($0.type) }) else {
            // A complex record starts with mixins such as BOUNDED_SURFACE; name the real kind.
            let kind = components.map { $0.type }.first(where: { !Self.surfaceMixins.contains($0) })
                ?? components.first?.type ?? "unknown"
            throw STEP.ParseError("Unsupported surface type \(kind) at #\(id)")
        }
        let p = part.parameters
        // Only the frame helper is used: the resolver scales the placement's origin.
        let resolver = STEPCurveResolver(file: file, scaleToMM: scale, chordTolerance: chordTolerance,
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

    // MARK: Surface of revolution

    /// A B-spline curve revolved about an axis, rebuilt exactly as a rational B-spline surface:
    /// every control point turns into a nine-point quadratic circle, so u is the angle (0...2π,
    /// counter-clockwise about the axis) and v the curve's own parameter, as STEP defines it.
    /// This also covers the self-intersecting ("spindle") tori CAD systems write this way.
    /// Only a B-spline profile in a plane through the axis is supported.
    private func parseSurfaceOfRevolution(_ id: Int, parameters p: [STEPValue], scale: Double) throws -> STEP.Surface {
        guard let curveID = try p.argument(1).reference, let axisID = try p.argument(2).reference else {
            throw STEP.ParseError("Invalid SURFACE_OF_REVOLUTION at #\(id)")
        }
        guard (try? file.components(curveID))?.contains(where: { $0.type == "B_SPLINE_CURVE_WITH_KNOTS" }) == true else {
            let kind = surfaceTypeName(curveID) ?? "curve"
            throw STEP.ParseError("Unsupported SURFACE_OF_REVOLUTION at #\(id): only B-spline profiles are supported, found \(kind)")
        }
        let resolver = STEPCurveResolver(file: file, scaleToMM: scale, chordTolerance: chordTolerance,
                                         angleScaleToRadians: { 1 })
        let profile = try resolver.splineGeometry(curveID)

        let axisParameters = try file.parameters(axisID, type: "AXIS1_PLACEMENT")
        let origin = try cartesianPoint(try axisParameters.reference(at: 1), scale: scale)
        var axis = SIMD3<Double>(0, 0, 1)
        if let directionID = try axisParameters.argument(2).reference {
            let direction = try file.parameters(directionID, type: "DIRECTION")
            guard let ratios = try direction.argument(1).list else { throw STEP.ParseError("Invalid axis direction at #\(axisID)") }
            let values = ratios.compactMap { $0.number }
            guard values.count == 3 else { throw STEP.ParseError("Invalid axis direction at #\(axisID)") }
            axis = SIMD3(values[0], values[1], values[2])
        }
        let axisLength = simd_length(axis)
        guard axisLength.isFinite, axisLength > 0 else { throw STEP.ParseError("Zero-length revolution axis at #\(axisID)") }
        axis /= axisLength

        // The radial direction where the angle is zero, from the first point off the axis.
        let extent = profile.controlPoints.map { simd_length($0 - origin) }.max() ?? 1
        var zero: SIMD3<Double>?
        for point in profile.controlPoints {
            let radial = (point - origin) - axis * simd_dot(point - origin, axis)
            if simd_length(radial) > 1e-9 * extent { zero = radial / simd_length(radial); break }
        }
        guard let e1 = zero else { throw STEP.ParseError("SURFACE_OF_REVOLUTION #\(id) lies on its axis") }
        let e2 = simd_cross(axis, e1)

        let quarter = 0.5.squareRoot()
        let circleWeights = [1, quarter, 1, quarter, 1, quarter, 1, quarter, 1]
        let circleOffsets: [(Double, Double)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0)]
        var net: [[SIMD3<Double>]] = []
        var weights: [[Double]] = []
        for (offset, circleWeight) in zip(circleOffsets, circleWeights) {
            var row: [SIMD3<Double>] = []
            var weightRow: [Double] = []
            for (index, point) in profile.controlPoints.enumerated() {
                let along = simd_dot(point - origin, axis)
                let centre = origin + axis * along
                let radial = point - centre
                // The profile must lie in the plane through the axis that holds angle zero. Its radius
                // is signed: a spindle torus's profile crosses the axis, and the revolution is still
                // exact because the circle's control points scale linearly with that radius.
                let radius = simd_dot(radial, e1)
                guard simd_length(radial - e1 * radius) <= 1e-6 * extent else {
                    throw STEP.ParseError("SURFACE_OF_REVOLUTION #\(id): profile is not in a plane through the axis")
                }
                row.append(centre + (e1 * offset.0 + e2 * offset.1) * radius)
                weightRow.append((profile.weights?[index] ?? 1) * circleWeight)
            }
            net.append(row)
            weights.append(weightRow)
        }
        // Distinct knot values and their multiplicities, from the expanded vector.
        var knotValues: [Double] = []
        var multiplicities: [Int] = []
        for knot in profile.knots {
            if let last = knotValues.last, last == knot { multiplicities[multiplicities.count - 1] += 1 } else {
                knotValues.append(knot)
                multiplicities.append(1)
            }
        }
        let spline = try STEP.BSplineSurface(uDegree: 2, vDegree: profile.degree, controlPoints: net, weights: weights,
                                            uMultiplicities: [3, 2, 2, 2, 3],
                                            uKnotValues: [0, 0.5 * .pi, .pi, 1.5 * .pi, 2 * .pi],
                                            vMultiplicities: multiplicities, vKnotValues: knotValues)
        if let limitation = spline.limitation {
            throw STEP.ParseError("SURFACE_OF_REVOLUTION #\(id) \(limitation); not supported yet")
        }
        return .bspline(spline)
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
}

// MARK: - Face topology output

extension STEP {

    /// One use of an edge by a face loop: the EDGE_CURVE and the direction the loop runs along it.
    public struct OrientedEdgeRef: Sendable, Equatable {
        /// Matches `Edge.id` for the same import. An edge that was skipped while reading the
        /// wireframe has no entry in `EdgeModel.edges`, but is still named here.
        public let edge: EdgeID
        /// True when the loop runs along the edge from its start vertex to its end vertex.
        public let isForward: Bool

        public init(edge: EdgeID, isForward: Bool) {
            self.edge = edge
            self.isForward = isForward
        }
    }

    /// A B-rep face: its surface and its boundary, without triangles. `id` matches the values in
    /// `Edge.adjacentFaceIDs` and `FaceMesh.faceID`.
    public struct Face: Sendable {
        /// ADVANCED_FACE / FACE_SURFACE entity ID.
        public let id: Int
        public let bodyID: BodyID
        /// The face's own `same_sense` flag: false means the face's front is against the surface normal.
        public let sameSense: Bool
        /// True for a face of a void shell of a BREP_WITH_VOIDS, whose front is turned the other way
        /// again. The material side of a face is `surface` normal, flipped when exactly one of
        /// `sameSense == false` and `isShellReversed` holds.
        public let isShellReversed: Bool
        /// Exact surface data; `nil` when the surface is a kind SwiftSTEP cannot read (a swept
        /// surface, say) or its definition is damaged. The face is listed either way.
        public let surface: Surface?
        /// STEP type of the surface entity, e.g. `PLANE` or `SURFACE_OF_REVOLUTION`. Set even when
        /// `surface` is `nil`; `nil` only when the entity cannot be found.
        public let surfaceTypeName: String?
        /// The face's boundaries, each in the direction it runs round the face (a bound written
        /// with orientation `.F` is reversed, with every edge use flipped). Empty when a bound
        /// could not be read (see `Topology.diagnostics`): vertex loops and poly loops are not
        /// supported.
        public let loops: [[OrientedEdgeRef]]
        /// Index into `loops` of the FACE_OUTER_BOUND. `nil` when no bound is marked as outer: some
        /// exporters write every bound as a plain FACE_BOUND, and nothing is guessed from geometry.
        public let outerLoopIndex: Int?

        public init(id: Int, bodyID: BodyID, sameSense: Bool, isShellReversed: Bool = false, surface: Surface?,
                    surfaceTypeName: String?, loops: [[OrientedEdgeRef]] = [], outerLoopIndex: Int? = nil) {
            self.id = id
            self.bodyID = bodyID
            self.sameSense = sameSense
            self.isShellReversed = isShellReversed
            self.surface = surface
            self.surfaceTypeName = surfaceTypeName
            self.loops = loops
            self.outerLoopIndex = outerLoopIndex
        }

        /// The outer loop, when the file marks one.
        public var outerLoop: [OrientedEdgeRef]? { outerLoopIndex.map { loops[$0] } }
    }

    /// The wireframe plus the faces of every body, without any triangles.
    public struct Topology: Sendable {
        /// The same edges `STEP.read` returns for the same `importID`.
        public let edges: EdgeModel
        /// By body, then face entity ID. A face the importer could not read at all is left out and
        /// explained in `diagnostics`; a face with an unsupported surface is listed with `surface == nil`.
        public internal(set) var faces: [Face] = []
        /// Notes about faces and surfaces. Edge notes stay in `edges.diagnostics`.
        public internal(set) var diagnostics: [Diagnostic] = []

        public init(edges: EdgeModel) { self.edges = edges }

        public func faces(of body: BodyID) -> [Face] { faces.filter { $0.bodyID == body } }
    }
}

/// Lists the faces of every body found by the edge pass: surface, sense and boundary loops.
/// Task-confined like `STEPFile`; use through `STEPEdgeImporter.parseTopology`.
final class STEPTopologyExtractor {
    private let file: STEPFile
    private let model: STEP.EdgeModel
    private let reader: STEPFaceReader
    private var topology: STEP.Topology

    init(file: STEPFile, model: STEP.EdgeModel, options: STEP.Options) {
        self.file = file
        self.model = model
        reader = STEPFaceReader(file: file, chordTolerance: options.chordToleranceMM)
        topology = STEP.Topology(edges: model)
    }

    func extract() throws -> STEP.Topology {
        try Task.checkCancellation()
        for body in model.bodies {
            try Task.checkCancellation()
            try read(body: body)
        }
        return topology
    }

    private func diagnose(_ id: Int?, _ message: String, _ severity: STEP.Diagnostic.Severity, code: String) {
        topology.diagnostics.append(STEP.Diagnostic(entityID: id, message: message, severity: severity, code: code))
    }

    private func read(body: STEP.BodyInfo) throws {
        if reader.isWireframe(body.id.entityID) { return }
        let faceList: [(id: Int, flipped: Bool)]
        do {
            faceList = try reader.collectFaces(bodyID: body.id.entityID)
        } catch let error as STEP.ParseError {
            diagnose(body.id.entityID, "No faces listed for body #\(body.id.entityID): \(error.description)",
                     .skipped, code: "body-unfaced")
            return
        }
        var surfaceCache: [Int: Result<STEP.Surface, STEP.ParseError>] = [:]

        for entry in faceList {
            try Task.checkCancellation()
            let parsed: STEPFaceReader.ParsedFace
            do {
                parsed = try reader.parseFace(entry.id)
            } catch let error as STEP.ParseError {
                diagnose(entry.id, "Face #\(entry.id) skipped: \(error.description)", .skipped, code: "face-skipped")
                continue
            }

            let outcome: Result<STEP.Surface, STEP.ParseError>
            if let cached = surfaceCache[parsed.surfaceID] {
                outcome = cached
            } else {
                do {
                    outcome = .success(try reader.parseSurface(parsed.surfaceID, scale: body.unitScaleToMM,
                                                                contextID: body.contextID))
                } catch let error as STEP.ParseError {
                    outcome = .failure(error)
                }
                surfaceCache[parsed.surfaceID] = outcome
            }
            let surface: STEP.Surface?
            switch outcome {
                case .success(let value):
                    surface = value
                case .failure(let error):
                    surface = nil
                    diagnose(entry.id, "Face #\(entry.id): no surface data: \(error.description)", .warning,
                             code: "unsupported-surface")
            }

            var loops: [[STEP.OrientedEdgeRef]] = []
            var outerIndex: Int?
            do {
                (loops, outerIndex) = try readLoops(parsed.boundIDs, body: body.id)
            } catch let error as STEP.ParseError {
                loops = []
                outerIndex = nil
                diagnose(entry.id, "Face #\(entry.id): boundary loops not listed: \(error.description)", .warning,
                         code: "face-loops-unreadable")
            }

            topology.faces.append(STEP.Face(id: entry.id, bodyID: body.id, sameSense: parsed.sameSense,
                                            isShellReversed: entry.flipped, surface: surface,
                                            surfaceTypeName: reader.surfaceTypeName(parsed.surfaceID),
                                            loops: loops, outerLoopIndex: outerIndex))
        }
    }

    /// Every bound of a face as a loop of oriented edge references. All or nothing: a face with
    /// one unreadable bound would otherwise look like a face with fewer holes.
    private func readLoops(_ boundIDs: [Int], body: STEP.BodyID) throws -> (loops: [[STEP.OrientedEdgeRef]], outer: Int?) {
        var loops: [[STEP.OrientedEdgeRef]] = []
        var outer: Int?
        for boundID in boundIDs {
            try Task.checkCancellation()
            let components = try file.components(boundID)
            guard let bound = components.first(where: { $0.type == "FACE_BOUND" || $0.type == "FACE_OUTER_BOUND" }) else {
                throw STEP.ParseError("Unsupported face bound #\(boundID)")
            }
            let loopID = try bound.parameters.reference(at: 1)
            guard let orientation = try bound.parameters.argument(2).enumeration,
                  orientation == "T" || orientation == "F" else {
                throw STEP.ParseError("Invalid face bound orientation at #\(boundID)")
            }
            guard file.hasType(loopID, "EDGE_LOOP") else {
                throw STEP.ParseError("Unsupported loop type at #\(loopID)")
            }
            var uses: [STEP.OrientedEdgeRef] = []
            for use in try file.parameters(loopID, type: "EDGE_LOOP").references(at: 1) {
                let oriented = try file.parameters(use, type: "ORIENTED_EDGE")
                let edgeID = try oriented.reference(at: 3)
                guard file.hasType(edgeID, "EDGE_CURVE") else {
                    throw STEP.ParseError("Unsupported edge element at #\(edgeID)")
                }
                guard let direction = try oriented.argument(4).enumeration, direction == "T" || direction == "F" else {
                    throw STEP.ParseError("Invalid ORIENTED_EDGE orientation at #\(use)")
                }
                uses.append(STEP.OrientedEdgeRef(edge: STEP.EdgeID(importID: model.importID, bodyID: body, entityID: edgeID),
                                                 isForward: direction == "T"))
            }
            if orientation == "F" {
                // A bound with orientation .F runs against its loop.
                uses = uses.reversed().map { STEP.OrientedEdgeRef(edge: $0.edge, isForward: !$0.isForward) }
            }
            if bound.type == "FACE_OUTER_BOUND", outer == nil { outer = loops.count }
            loops.append(uses)
        }
        return (loops, outer)
    }
}
