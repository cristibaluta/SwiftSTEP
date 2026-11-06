import Foundation
import simd

extension STEP {

    /// Thrown for problems with the file as a whole. `description` is the message.
    public struct ParseError: Error, CustomStringConvertible, Sendable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// A note about one entity: an unsupported curve, a skipped edge, a sampling cap.
    public struct Diagnostic: Sendable {
        public let entityID: Int?
        public let message: String
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
    }

    public struct Edge: Sendable {
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
        public var chordError: Double = 0
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

    /// The stored edges of every supported body.
    public struct EdgeModel: Sendable {
        public let importID: UUID
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

        public init(assumedUnitScaleToMM: Double? = nil, chordToleranceMM: Double = 0.01) {
            self.assumedUnitScaleToMM = assumedUnitScaleToMM
            self.chordToleranceMM = chordToleranceMM
        }
    }

    /// Both stages of an import: the wireframe and, per body, the triangles that hide its edges.
    public struct Geometry: Sendable {
        public let edges: EdgeModel
        public let surfaces: SurfaceModel
    }
}
