import Foundation
import simd

extension STEP {

    /// The triangles of one face inside its body's mesh.
    public struct FaceMesh: Sendable {
        /// ADVANCED_FACE / FACE_SURFACE entity ID.
        public let faceID: Int
        /// Exact surface data for picking and feature recognition.
        public let surface: Surface
        /// The face's own `same_sense` flag (not the shell orientation).
        public let sameSense: Bool
        /// Triangle numbers (index `3 * n ..< 3 * n + 3` in `indices`) that belong to this face.
        public let triangles: Range<Int>

        public init(faceID: Int, surface: Surface, sameSense: Bool, triangles: Range<Int>) {
            self.faceID = faceID
            self.surface = surface
            self.sameSense = sameSense
            self.triangles = triangles
        }
    }

    /// One body's triangle mesh. Positions are Float, millimetres relative to
    /// `SurfaceModel.origin`, so they line up with wireframe points moved by the same origin.
    /// Normals follow the face (analytic, never averaged across a sharp edge) and point out of
    /// the material. The winding of every triangle agrees with its normal.
    public struct BodyMesh: Sendable {
        public let id: BodyID
        public internal(set) var positions: [SIMD3<Float>] = []
        public internal(set) var normals: [SIMD3<Float>] = []
        public internal(set) var indices: [UInt32] = []
        /// Sorted by triangle range, so a triangle number finds its face by binary search.
        public internal(set) var faces: [FaceMesh] = []
        /// ADVANCED_FACE / FACE_SURFACE IDs of the faces that could not be tessellated and are
        /// missing from `faces`. `FaceFailure` in `SurfaceModel.faceFailures` says why.
        public internal(set) var failedFaceIDs: [Int] = []
        /// True when some faces of the body are missing from the mesh. Such a mesh can only
        /// under-occlude: an edge behind a missing face is not hidden.
        public var isPartial: Bool {
            !failedFaceIDs.isEmpty
        }

        public var triangleCount: Int {
            indices.count / 3
        }

        /// The face a triangle belongs to.
        public func face(ofTriangle triangle: Int) -> FaceMesh? {
            var low = 0
            var high = faces.count
            while low < high {
                let middle = (low + high) / 2
                if faces[middle].triangles.upperBound <= triangle {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low < faces.count, faces[low].triangles.contains(triangle) else {
                return nil
            }
            return faces[low]
        }

        /// Three points per triangle moved by `offset`.
        public func occluderTriangles(offset: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
            var result: [SIMD3<Float>] = []
            result.reserveCapacity(indices.count)
            for index in indices { result.append(positions[Int(index)] + offset) }
            return result
        }
    }

    /// Why one face (or, with `faceID == nil`, a whole body) could not be tessellated.
    public struct FaceFailure: Sendable {
        public let bodyID: BodyID
        /// ADVANCED_FACE / FACE_SURFACE entity ID; `nil` when the body itself was unusable.
        public let faceID: Int?
        /// The face's underlying surface entity, when it could be read.
        public let surfaceID: Int?
        /// STEP type of that surface, e.g. `CYLINDRICAL_SURFACE` or `SURFACE_OF_REVOLUTION`.
        public let surfaceType: String?
        public let reason: String
    }

    public struct SurfaceModel: Sendable {
        /// Origin the Float positions are relative to (`Bounds.workpieceOrigin`).
        public internal(set) var origin: SIMD3<Double>
        /// Bodies with at least one tessellated face. A body with failed faces is here too, with
        /// `BodyMesh.isPartial` set, unless `Options.keepPartialSurfaces` is false.
        public internal(set) var bodies: [BodyMesh] = []
        /// Bodies without any mesh: every face failed, the body itself was unusable, or a face
        /// failed with `Options.keepPartialSurfaces` off.
        public internal(set) var unsurfacedBodies: [BodyID] = []
        /// Bodies in `bodies` that are missing some faces.
        public var partialBodies: [BodyID] {
            bodies.filter { $0.isPartial }.map { $0.id }
        }
        public internal(set) var diagnostics: [Diagnostic] = []
        /// One entry per face that failed, with the surface type and reason. Feeds `Geometry.report`.
        public internal(set) var faceFailures: [FaceFailure] = []
        /// Distinct faces reachable from the supported bodies.
        public internal(set) var reachableFaceCount = 0
        /// Faces that could not be tessellated (each has a diagnostic).
        public internal(set) var failedFaceCount = 0
        /// Faces inside `bodies` (a partial body counts only the faces it has).
        public internal(set) var tessellatedFaceCount = 0
        public var triangleCount: Int {
            bodies.reduce(0) { $0 + $1.triangleCount }
        }

        public init(origin: SIMD3<Double> = .zero) {
            self.origin = origin
        }

        public func mesh(for id: BodyID) -> BodyMesh? {
            bodies.first { $0.id == id }
        }
    }
}
