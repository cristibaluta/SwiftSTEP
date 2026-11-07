import Foundation
import simd

extension STEP {
    /// Right-handed orthonormal frame from an AXIS2_PLACEMENT_3D, in millimetres.
    public struct Frame: Sendable, Equatable {
        public let origin: SIMD3<Double>
        public let x: SIMD3<Double>
        public let y: SIMD3<Double>
        public let z: SIMD3<Double>

        public init(origin: SIMD3<Double>, x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>) {
            self.origin = origin
            self.x = x
            self.y = y
            self.z = z
        }
    }

    /// Surface descriptors retained next to the triangle mesh. Steps 7 and 8
    /// (face picking, feature recognition) need exact radii, axes and normals, not just
    /// triangles. All lengths are millimetres, angles radians, in source coordinates.
    ///
    /// Every surface is parametrised so that `∂P/∂u × ∂P/∂v` is the STEP surface normal.
    /// That makes triangles that run counter-clockwise in (u, v) face along the surface
    /// normal, and the tessellator only has to flip them for a face with `same_sense = .F`.
    public enum Surface: Sendable {
        case plane(Frame)
        /// Radius about the frame's Z axis; v is the distance along that axis.
        case cylinder(Frame, radius: Double)
        /// Radius at v = 0 and half-angle, so the radius at v is `radius + v·tan(halfAngle)`.
        case cone(Frame, radius: Double, halfAngle: Double)
        /// u is longitude, v latitude in [-π/2, π/2].
        case sphere(Frame, radius: Double)
        /// u runs round the main axis, v round the tube.
        case torus(Frame, major: Double, minor: Double)
        /// Freeform (NURBS) patch. u and v are the spline's own knot parameters; it has no frame.
        case bspline(BSplineSurface)

        struct Parameters {
            var u: Double
            var v: Double
            /// u is meaningless here: on the sphere's poles or at a cone's apex.
            var isPole: Bool
            /// How far the point is from the surface (mm). Exactly 0 for analytic surfaces, whose
            /// inverse is a projection; a B-spline's is found numerically and can miss.
            var distance: Double = 0
        }

        /// The placement of an analytic surface; `nil` for a B-spline surface.
        public var frame: Frame? {
            switch self {
                case .plane(let frame): return frame
                case .cylinder(let frame, _): return frame
                case .cone(let frame, _, _): return frame
                case .sphere(let frame, _): return frame
                case .torus(let frame, _, _): return frame
                case .bspline: return nil
            }
        }

        public var kindName: String {
            switch self {
                case .plane: return "plane"
                case .cylinder: return "cylinder"
                case .cone: return "cone"
                case .sphere: return "sphere"
                case .torus: return "torus"
                case .bspline: return "B-spline surface"
            }
        }

        /// True when u wraps every `periodU`: round surfaces, and a B-spline that closes in u.
        public var isPeriodicU: Bool {
            switch self {
                case .plane: return false
                case .bspline(let spline): return spline.closedU
                case .cylinder, .cone, .sphere, .torus: return true
            }
        }

        /// True when v wraps every `periodV`: the torus, and a B-spline that closes in v.
        public var isPeriodicV: Bool {
            switch self {
                case .torus: return true
                case .bspline(let spline): return spline.closedV
                case .plane, .cylinder, .cone, .sphere: return false
            }
        }

        /// One turn in u: 2π for the analytic surfaces, the knot span for a closed B-spline.
        /// Only meaningful when `isPeriodicU`.
        public var periodU: Double {
            if case .bspline(let spline) = self { return spline.uDomain.upperBound - spline.uDomain.lowerBound }
            return STEPAngle.twoPi
        }

        /// One turn in v. Only meaningful when `isPeriodicV`.
        public var periodV: Double {
            if case .bspline(let spline) = self { return spline.vDomain.upperBound - spline.vDomain.lowerBound }
            return STEPAngle.twoPi
        }

        private static func radial(_ frame: Frame, _ u: Double) -> SIMD3<Double> {
            cos(u) * frame.x + sin(u) * frame.y
        }

        public func point(u: Double, v: Double) -> SIMD3<Double> {
            switch self {
                case .plane(let f):
                    return f.origin + u * f.x + v * f.y
                case .cylinder(let f, let radius):
                    return f.origin + radius * Self.radial(f, u) + v * f.z
                case .cone(let f, let radius, let halfAngle):
                    return f.origin + (radius + v * tan(halfAngle)) * Self.radial(f, u) + v * f.z
                case .sphere(let f, let radius):
                    return f.origin + radius * (cos(v) * Self.radial(f, u) + sin(v) * f.z)
                case .torus(let f, let major, let minor):
                    return f.origin + (major + minor * cos(v)) * Self.radial(f, u) + minor * sin(v) * f.z
                case .bspline(let spline):
                    return spline.point(u: u, v: v)
            }
        }

        /// Unit normal along the STEP surface normal (before any face `same_sense`).
        public func normal(u: Double, v: Double) -> SIMD3<Double> {
            switch self {
                case .plane(let f):
                    return f.z
                case .cylinder(let f, _):
                    return Self.radial(f, u)
                case .cone(let f, _, let halfAngle):
                    let slope = tan(halfAngle)
                    return (Self.radial(f, u) - slope * f.z) / (1 + slope * slope).squareRoot()
                case .sphere(let f, _), .torus(let f, _, _):
                    return cos(v) * Self.radial(f, u) + sin(v) * f.z
                case .bspline(let spline):
                    return spline.normal(u: u, v: v)
            }
        }

        /// A point in a frame's coordinates, with its distance from the axis and its longitude.
        private static func local(_ frame: Frame, _ point: SIMD3<Double>)
            -> (x: Double, y: Double, z: Double, radial: Double, u: Double) {
            let offset = point - frame.origin
            let x = simd_dot(offset, frame.x)
            let y = simd_dot(offset, frame.y)
            let z = simd_dot(offset, frame.z)
            return (x, y, z, (x * x + y * y).squareRoot(), atan2(y, x))
        }

        /// Inverse of `point`, for points on (or very near) the surface.
        func parameters(of point: SIMD3<Double>) -> Parameters {
            switch self {
                case .plane(let f):
                    let l = Self.local(f, point)
                    return Parameters(u: l.x, v: l.y, isPole: false)
                case .cylinder(let f, let radius):
                    let l = Self.local(f, point)
                    return Parameters(u: l.u, v: l.z, isPole: l.radial < 1e-9 * max(1, radius))
                case .cone(let f, let radius, _):
                    let l = Self.local(f, point)
                    return Parameters(u: l.u, v: l.z, isPole: l.radial < 1e-9 * max(1, radius, abs(l.z)))
                case .sphere(let f, let radius):
                    let l = Self.local(f, point)
                    return Parameters(u: l.u, v: atan2(l.z, l.radial), isPole: l.radial < 1e-9 * max(1, radius))
                case .torus(let f, let major, _):
                    let l = Self.local(f, point)
                    return Parameters(u: l.u, v: atan2(l.z, l.radial - major), isPole: false)
                case .bspline(let spline):
                    let projected = spline.parameters(of: point)
                    return Parameters(u: projected.u, v: projected.v, isPole: false, distance: projected.distance)
            }
        }

        /// Radius of the widest circle of constant v over `vRange`; it sets how finely u must be
        /// subdivided. `nil` for the plane and for B-splines (which have their own density rule).
        func widestRadius(vRange: ClosedRange<Double>) -> Double? {
            switch self {
                case .plane, .bspline: return nil
                case .cylinder(_, let radius): return radius
                case .cone(_, let radius, let halfAngle):
                    let slope = tan(halfAngle)
                    return max(abs(radius + vRange.lowerBound * slope), abs(radius + vRange.upperBound * slope))
                case .sphere(_, let radius): return radius
                case .torus(_, let major, let minor): return major + minor
            }
        }

        /// Radius of curvature along v where the surface is not ruled in v (sphere, torus tube).
        /// `nil` where straight lines in v lie on the surface (plane, cylinder, cone) and for
        /// B-splines.
        var radiusAlongV: Double? {
            switch self {
                case .plane, .cylinder, .cone, .bspline: return nil
                case .sphere(_, let radius): return radius
                case .torus(_, _, let minor): return minor
            }
        }
    }
}
