import Foundation
import simd

extension STEP {

    /// Thrown for problems with the file as a whole. `description` is the message; branch on
    /// `kind` rather than on its text.
    public struct ParseError: Error, CustomStringConvertible, Sendable {
        public enum Kind: Sendable, Equatable {
            /// Not a Part 21 file: the `ISO-10303-21;` header is missing.
            case notSTEP
            /// The file ends before its structure does.
            case truncated
            /// Anything else wrong with the file's content. Per-edge and per-face errors use this.
            case malformed
            /// The file places part instances (assemblies), which are not supported yet.
            case assembly
            /// The length unit of a representation context could not be resolved, and
            /// `Options.assumedUnitScaleToMM` was not set.
            case unresolvedUnits(contextID: Int)
            /// A safety cap was hit: entity count, nesting depth, token size.
            case limitExceeded
            /// `Options` holds a value that cannot be used.
            case invalidOptions
        }

        public let kind: Kind
        public let description: String

        public init(_ description: String, kind: Kind = .malformed) {
            self.description = description
            self.kind = kind
        }
    }

    /// A note about one entity: an unsupported curve, a skipped edge, a sampling cap.
    public struct Diagnostic: Sendable, Equatable, CustomStringConvertible {
        public enum Severity: Sendable, Equatable {
            /// Worth knowing, nothing was lost.
            case info
            /// The result is usable but approximate or assumed.
            case warning
            /// Something was left out: an edge, a face or a whole body.
            case skipped
        }

        public let entityID: Int?
        public let message: String
        public let severity: Severity
        /// Short stable identifier of the kind of note, e.g. `unsupported-curve` or `chord-cap`.
        public let code: String

        public init(entityID: Int?, message: String, severity: Severity = .warning, code: String = "unspecified") {
            self.entityID = entityID
            self.message = message
            self.severity = severity
            self.code = code
        }

        public var description: String { entityID.map { "#\($0): \(message)" } ?? message }
    }

    /// No assembly instances yet: a representation/body pair identifies one occurrence.
    public struct BodyID: Hashable, Sendable {
        public let representationID: Int
        public let entityID: Int

        public init(representationID: Int, entityID: Int) {
            self.representationID = representationID
            self.entityID = entityID
        }
    }

    /// Stable only for the same source and import `importID`.
    public struct EdgeID: Hashable, Sendable {
        public let importID: UUID
        public let bodyID: BodyID
        /// The EDGE_CURVE `#id`.
        public let entityID: Int

        public init(importID: UUID, bodyID: BodyID, entityID: Int) {
            self.importID = importID
            self.bodyID = bodyID
            self.entityID = entityID
        }
    }

    public struct BodyInfo: Sendable {
        public let id: BodyID
        public let contextID: Int
        public let unitScaleToMM: Double
        public let unitsAssumed: Bool
        /// The distance accuracy the file declares for this body's context, in mm. `nil` when it
        /// declares none; the importer then uses its own defaults.
        public let uncertaintyMM: Double?
        /// Min/max over this body's own edge points, mm, source coordinates. `nil` when none of
        /// its edges could be extracted. `EdgeModel.bounds` is the union over all bodies.
        public let bounds: Bounds?
        /// The name string of the body entity (`MANIFOLD_SOLID_BREP('name', ...)`), as written in
        /// the file. `nil` when it is `$` or empty. `\X2\...\X0\` style escapes are not decoded.
        public let name: String?

        public init(id: BodyID, contextID: Int, unitScaleToMM: Double, unitsAssumed: Bool, uncertaintyMM: Double? = nil,
                    bounds: Bounds? = nil, name: String? = nil) {
            self.id = id
            self.contextID = contextID
            self.unitScaleToMM = unitScaleToMM
            self.unitsAssumed = unitsAssumed
            self.uncertaintyMM = uncertaintyMM
            self.bounds = bounds
            self.name = name
        }
    }

    public struct Edge: Sendable, Identifiable {
        public enum CurveKind: Sendable {
            case line
            /// Partial circular arc, sampled to a polyline.
            case arc
            /// Full closed circle, sampled to a polyline.
            case circle
            case ellipse
            case ellipticalArc
            /// A file polyline, cut to the edge's extent.
            case polyline
            case bspline
        }

        /// Analytic description of the curve the polyline samples, where the importer keeps one.
        /// Everything is millimetres and radians, in source coordinates.
        public enum Curve: Sendable, Equatable {
            /// A straight edge; `points` holds its two end points.
            case line
            /// A circle or a circular arc. The edge runs from `startAngle` through `sweep`, both
            /// measured in the frame (angle 0 along `frame.x`, positive towards `frame.y`), so the
            /// centre is `frame.origin` and the axis `frame.z`. `sweep` is signed: negative runs
            /// clockwise about `frame.z`. A full circle has `abs(sweep) == 2π`.
            case circle(frame: Frame, radius: Double, startAngle: Double, sweep: Double)
            /// Reserved for ellipses and elliptical arcs. Not filled in yet: they report `.other`.
            case ellipse(frame: Frame, semiAxisX: Double, semiAxisY: Double, startAngle: Double, sweep: Double)
            /// B-splines, polylines, ellipses (for now): only `points` describes them.
            case other
        }

        public let id: EdgeID
        public let kind: CurveKind
        /// Polyline in millimetres, source coordinates. At least two points; `first` and `last`
        /// are the scaled start and end vertices. A closed circle, ellipse or lap has first == last.
        public let points: [SIMD3<Double>]
        public let startVertexID: Int
        public let endVertexID: Int
        /// ADVANCED_FACE / FACE_SURFACE entity IDs that use the edge (sorted, de-duplicated).
        public let adjacentFaceIDs: [Int]
        /// Distance (mm) between the sampled polyline and the true curve: a bound for circles
        /// and ellipses, a probed estimate for B-splines. 0 for lines and file polylines.
        public let chordError: Double
        /// True when one face uses the edge twice, once in each direction: the seam of a cylinder,
        /// cone, sphere or torus that wraps round its axis. A seam is not a real boundary between
        /// two surfaces.
        public let isSeam: Bool
        /// The exact curve behind `points`; see `Curve`.
        public let curve: Curve

        public init(id: EdgeID, kind: CurveKind, points: [SIMD3<Double>], startVertexID: Int, endVertexID: Int,
                    adjacentFaceIDs: [Int], chordError: Double = 0, isSeam: Bool = false, curve: Curve = .other) {
            self.id = id
            self.kind = kind
            self.points = points
            self.startVertexID = startVertexID
            self.endVertexID = endVertexID
            self.adjacentFaceIDs = adjacentFaceIDs
            self.chordError = chordError
            self.isSeam = isSeam
            self.curve = curve
        }
    }

    public struct Bounds: Sendable {
        public var min: SIMD3<Double>
        public var max: SIMD3<Double>

        public init(min: SIMD3<Double>, max: SIMD3<Double>) {
            self.min = min
            self.max = max
        }

        public mutating func include(_ point: SIMD3<Double>) {
            for axis in 0..<3 {
                min[axis] = Swift.min(min[axis], point[axis])
                max[axis] = Swift.max(max[axis], point[axis])
            }
        }

        public var size: SIMD3<Double> { max - min }

        /// Where a viewer places the part like a workpiece: min X, min Y and the top (max Z).
        /// `SurfaceModel.origin` uses the same point, so triangles and edges stay registered.
        public var workpieceOrigin: SIMD3<Double> { SIMD3<Double>(min.x, min.y, max.z) }
    }

    /// The file's `FILE_DESCRIPTION`, `FILE_NAME` and `FILE_SCHEMA` header records. Fields a file
    /// leaves out, or writes as `$` or `''`, are empty or `nil`.
    public struct Header: Sendable, Equatable {
        /// FILE_SCHEMA schema identifiers, e.g. `AUTOMOTIVE_DESIGN { 1 0 10303 214 ... }`.
        public var schemas: [String] = []
        /// FILE_DESCRIPTION description lines.
        public var descriptions: [String] = []
        public var implementationLevel: String?
        /// FILE_NAME name, usually the name the exporter gave the file.
        public var name: String?
        /// FILE_NAME time stamp, ISO 8601 as written.
        public var timestamp: String?
        public var authors: [String] = []
        public var organizations: [String] = []
        public var preprocessorVersion: String?
        /// The CAD system that wrote the file.
        public var originatingSystem: String?
        public var authorization: String?

        public init() {}
    }

    /// The stored edges of every supported body.
    public struct EdgeModel: Sendable {
        public let importID: UUID
        public internal(set) var header = Header()
        /// Deterministic order: by body, then EDGE_CURVE entity ID.
        public internal(set) var edges: [Edge] = []
        public internal(set) var bodies: [BodyInfo] = []
        /// Min/max over all emitted points, mm. `nil` when there are no edges.
        public internal(set) var bounds: Bounds?
        public internal(set) var diagnostics: [Diagnostic] = []
        public internal(set) var indexedEntityCount = 0
        /// Distinct edges reachable from the supported bodies (not every EDGE_CURVE in the file).
        public internal(set) var reachableEdgeCount = 0
        public var skippedEdgeCount: Int { reachableEdgeCount - edges.count }
    }

    public struct Options: Sendable {
        /// Explicit opt-in only; unresolved units otherwise fail the import. Recorded in
        /// `BodyInfo.unitsAssumed` and in the diagnostics.
        public var assumedUnitScaleToMM: Double?
        /// Maximum sagitta (mm) of sampled curves. Display geometry only: a sampled polyline
        /// is not a machining contour. Must be finite and positive.
        public var chordToleranceMM: Double
        /// Most entities a file may define before the import is refused. Protects against runaway
        /// or hostile files; raise it for very large assemblies.
        public var maximumEntityCount: Int

        public init(assumedUnitScaleToMM: Double? = nil, chordToleranceMM: Double = 0.01,
                    maximumEntityCount: Int = 2_000_000) {
            self.assumedUnitScaleToMM = assumedUnitScaleToMM
            self.chordToleranceMM = chordToleranceMM
            self.maximumEntityCount = maximumEntityCount
        }
    }

    /// Both stages of an import: the wireframe and, per body, the triangles that hide its edges.
    public struct Geometry: Sendable {
        public let edges: EdgeModel
        public let surfaces: SurfaceModel
    }
}

extension STEP.Geometry {

    /// A readable account of the import: what was drawn, and for every body left without filled
    /// faces, which faces failed, on what kind of surface and why. Print it when a model shows
    /// only wireframe.
    public var report: String {
        var lines: [String] = []
        lines.append("Edges: \(edges.edges.count) extracted, \(edges.skippedEdgeCount) skipped "
                     + "(\(edges.reachableEdgeCount) reachable), \(edges.bodies.count) bod\(edges.bodies.count == 1 ? "y" : "ies")")
        let faces = surfaces
        lines.append("Faces: \(faces.tessellatedFaceCount) filled, \(faces.failedFaceCount) failed, "
                     + "\(faces.reachableFaceCount) reachable; \(faces.triangleCount) triangles")

        for note in edges.diagnostics {
            lines.append("  edge note \(note)")
        }

        if !faces.unsurfacedBodies.isEmpty {
            lines.append("")
            lines.append("\(faces.unsurfacedBodies.count) bod\(faces.unsurfacedBodies.count == 1 ? "y has" : "ies have") no filled faces "
                         + "(one failing face drops its whole body, because a partial mesh would hide the wrong edges):")
        }
        for body in faces.unsurfacedBodies {
            let failures = faces.faceFailures.filter { $0.bodyID == body }
            lines.append("  Body #\(body.entityID)")
            // Group faces that fail for the same reason on the same kind of surface.
            var groups: [String: [STEP.FaceFailure]] = [:]
            var order: [String] = []
            for failure in failures {
                let key = "\(failure.surfaceType ?? "-")|\(Self.normalized(failure.reason))"
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(failure)
            }
            for key in order {
                let group = groups[key]!
                let first = group[0]
                let ids = group.compactMap { $0.faceID }.prefix(8).map { "#\($0)" }.joined(separator: ", ")
                let more = group.count > 8 ? ", …" : ""
                let kind = first.surfaceType.map { " on \($0)" } ?? ""
                if first.faceID == nil {
                    lines.append("    body unusable: \(first.reason)")
                } else {
                    lines.append("    \(group.count) face\(group.count == 1 ? "" : "s")\(kind): \(first.reason)")
                    lines.append("      faces \(ids)\(more)")
                }
                if let hint = Self.hint(for: first.reason, surfaceType: first.surfaceType) {
                    lines.append("      → \(hint)")
                }
            }
        }

        let other = faces.diagnostics.filter { note in
            !faces.faceFailures.contains { $0.faceID == note.entityID && $0.faceID != nil }
                && !faces.unsurfacedBodies.contains { $0.entityID == note.entityID }
        }
        for note in other { lines.append("  surface note \(note)") }
        return lines.joined(separator: "\n")
    }

    /// Entity numbers stripped, so "at #12" and "at #40" group together.
    private static func normalized(_ reason: String) -> String {
        reason.replacingOccurrences(of: #"#\d+"#, with: "#_", options: .regularExpression)
    }

    private static func hint(for reason: String, surfaceType: String?) -> String? {
        if reason.contains("Unsupported surface type") {
            return "SwiftSTEP only meshes planes, cylinders, cones, spheres, tori and B-spline surfaces. "
                + "Re-export the part with swept/offset/revolved surfaces converted to NURBS if your CAD can."
        }
        if reason.contains("has no extracted geometry") {
            return "An edge of this face was skipped while reading the wireframe (see the edge note); fix that curve and the face follows."
        }
        if reason.contains("pole or apex") {
            return "The face touches a sphere pole or cone tip in a way the loop handling cannot resolve (no seam edge to say which pole is inside, or two poles). Not implemented yet."
        }
        if reason.contains("wraps round") {
            return "The face goes around a torus tube or in an unusual way round an axis. Not implemented yet."
        }
        if reason.contains("seam") {
            return "The face's boundary crosses the surface's periodic seam in a way the loop alignment cannot resolve."
        }
        if reason.contains("Face loop is degenerate") {
            return "The face's loop has fewer than three distinct sample points, so it has no area to fill."
        }
        if reason.contains("not connected") || reason.contains("not closed") || reason.contains("degenerate") {
            return "The face's edges do not form a closed loop within the connection tolerance (1e-6 mm, or the file's declared accuracy): a gap in the file, or an edge that was resampled differently."
        }
        if reason.contains("off its") {
            return "The boundary does not lie on the face's surface within the chord tolerance; the file may be damaged or use a loose tolerance."
        }
        if reason.contains("Triangle limit") {
            return "The model exceeds the 1,000,000 triangle cap; raise `chordToleranceMM` to coarsen the sampling."
        }
        if reason.contains("B-spline") {
            return "Only B-spline surfaces with explicit knots and no side collapsed to a point are supported."
        }
        if reason.contains("Unsupported face type") || reason.contains("Unsupported face bound") || reason.contains("Unsupported loop type") {
            return "Only ADVANCED_FACE / FACE_SURFACE faces with EDGE_LOOP boundaries are supported (no ORIENTED_FACE, vertex or poly loops)."
        }
        return nil
    }
}
