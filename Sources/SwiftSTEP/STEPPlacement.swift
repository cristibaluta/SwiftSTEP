import Foundation
import simd

/// A part's placement in its assembly: a rotation, a translation (millimetres) and, rarely, a
/// uniform scale. STEP's `ITEM_DEFINED_TRANSFORMATION` and `MAPPED_ITEM` can only produce these;
/// a matrix that is not one (skewed, mirrored) is refused, because the exact curve and surface
/// descriptors (`Edge.Curve`, `Surface`) could not follow it.
struct STEPPlacement {
    let matrix: simd_double4x4
    /// Orthonormal, right-handed columns.
    let rotation: simd_double3x3
    let translation: SIMD3<Double>
    let scale: Double

    /// `nil` when `matrix` is not a rotation with uniform positive scale and a translation.
    init?(_ matrix: simd_double4x4) {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        guard columns.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }) else { return nil }
        // Affine: the last row is (0, 0, 0, 1).
        guard columns[0].w == 0, columns[1].w == 0, columns[2].w == 0, columns[3].w == 1 else { return nil }
        let x = SIMD3<Double>(columns[0].x, columns[0].y, columns[0].z)
        let y = SIMD3<Double>(columns[1].x, columns[1].y, columns[1].z)
        let z = SIMD3<Double>(columns[2].x, columns[2].y, columns[2].z)
        let scale = simd_length(x)
        guard scale > 1e-12 else { return nil }
        let tolerance = 1e-6
        guard abs(simd_length(y) - scale) <= tolerance * scale, abs(simd_length(z) - scale) <= tolerance * scale else {
            return nil
        }
        let ux = x / scale
        let uy = y / scale
        let uz = z / scale
        guard abs(simd_dot(ux, uy)) <= tolerance, abs(simd_dot(ux, uz)) <= tolerance, abs(simd_dot(uy, uz)) <= tolerance,
              simd_dot(simd_cross(ux, uy), uz) > 1 - tolerance else { return nil }
        self.matrix = matrix
        self.rotation = simd_double3x3(columns: (ux, uy, uz))
        self.translation = SIMD3<Double>(columns[3].x, columns[3].y, columns[3].z)
        self.scale = scale
    }

    /// The matrix whose columns are the frame's axes (times `scale`) and its origin.
    static func matrix(origin: SIMD3<Double>, x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>,
                       scale: Double = 1) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4<Double>(x * scale, 0), SIMD4<Double>(y * scale, 0),
                                 SIMD4<Double>(z * scale, 0), SIMD4<Double>(origin, 1)))
    }

    var isIdentity: Bool {
        let identity = matrix_identity_double4x4
        return simd_length(matrix.columns.0 - identity.columns.0) < 1e-12
            && simd_length(matrix.columns.1 - identity.columns.1) < 1e-12
            && simd_length(matrix.columns.2 - identity.columns.2) < 1e-12
            && simd_length(matrix.columns.3 - identity.columns.3) < 1e-12
    }

    func point(_ p: SIMD3<Double>) -> SIMD3<Double> {
        rotation * (p * scale) + translation
    }

    /// A unit direction stays a unit direction: the scale does not apply to it.
    func direction(_ d: SIMD3<Double>) -> SIMD3<Double> {
        rotation * d
    }

    func frame(_ frame: STEP.Frame) -> STEP.Frame {
        STEP.Frame(origin: point(frame.origin), x: direction(frame.x), y: direction(frame.y), z: direction(frame.z))
    }
}
