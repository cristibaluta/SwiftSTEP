import simd

/// Orthographic turntable camera, trimmed from the Stratum CNC app's `Camera`.
///
/// `orientation` is a quaternion whose columns are the camera's right, up and back (target to
/// eye) directions in world space; the identity looks straight down the Z axis, X to the right,
/// Y up the screen. Orbiting spins the scene around world Z (so Z stays up on screen) and tilts
/// around the camera's own X axis, stopping at straight-up/down so the view never rolls over.
final class Camera {
    var target = SIMD3<Float>.zero
    /// Half the visible height in world units: the orthographic zoom.
    private(set) var halfHeight: Float = 50
    var aspect: Float = 1
    var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    private var zoomLimits: ClosedRange<Float> = 0.001...100_000
    // The eye sits `standoff` from the target; the clip range is wide enough that panning or
    // orbiting about an off-centre target never clips the model.
    private var standoff: Float = 1000
    private var nearZ: Float = 1
    private var farZ: Float = 2000

    static let worldUp = SIMD3<Float>(0, 0, 1)

    var right: SIMD3<Float> { orientation.act(SIMD3<Float>(1, 0, 0)) }
    var up: SIMD3<Float> { orientation.act(SIMD3<Float>(0, 1, 0)) }
    var back: SIMD3<Float> { orientation.act(SIMD3<Float>(0, 0, 1)) }

    /// Direction toward the light: a headlight up and to the left of the view direction, so
    /// faces square to the view still show form.
    var headlight: SIMD3<Float> {
        simd_normalize(back * 0.6 + up * 0.6 - right * 0.5)
    }

    /// Frames a sphere: centres on it and sizes the view and clip range to its radius.
    func fit(center: SIMD3<Float>, radius: Float, padding: Float = 1.2) {
        guard radius.isFinite, radius > 0, aspect.isFinite, aspect > 0 else { return }
        standoff = radius * 20
        nearZ = radius
        farZ = radius * 40
        zoomLimits = (radius * 0.001)...(radius * 100)
        target = center
        halfHeight = min(max(radius * padding / min(aspect, 1), zoomLimits.lowerBound), zoomLimits.upperBound)
    }

    /// `yaw` spins the scene around world Z, `pitch` tilts it around the camera's X axis (radians).
    func orbit(yaw: Float, pitch: Float) {
        var q = orientation
        if yaw != 0 {
            q = simd_mul(simd_quatf(angle: yaw, axis: Camera.worldUp), q)
        }
        if pitch != 0 {
            // Tilting by φ moves the camera's up vector to cos φ·up + sin φ·back, whose height
            // along Z is A·cos φ + B·sin φ. Keep it ≥ 0 so the camera never turns upside down.
            let a = simd_dot(q.act(SIMD3<Float>(0, 1, 0)), Camera.worldUp)
            let b = simd_dot(q.act(SIMD3<Float>(0, 0, 1)), Camera.worldUp)
            var tilt = pitch
            if (a * a + b * b).squareRoot() > 1e-6 {
                let centre = atan2(b, a)
                tilt = min(max(tilt, centre - .pi / 2), centre + .pi / 2)
            }
            q = simd_mul(q, simd_quatf(angle: tilt, axis: SIMD3<Float>(1, 0, 0)))
        }
        orientation = simd_normalize(q)
    }

    /// Slides the target in the view plane so the scene follows the pointer 1:1 at any zoom.
    /// `translation` is in view points, x right and y up.
    func pan(by translation: SIMD2<Float>, viewportHeight: Float) {
        let worldPerPoint = 2 * halfHeight / viewportHeight
        target -= right * (translation.x * worldPerPoint) + up * (translation.y * worldPerPoint)
    }

    /// Changes the zoom while keeping the world point under `ndc` (-1...1, centre 0, +1 right/top)
    /// fixed on screen.
    func zoom(to newHalfHeight: Float, towards ndc: SIMD2<Float>) {
        let new = min(max(newHalfHeight, zoomLimits.lowerBound), zoomLimits.upperBound)
        let oldHalfWidth = halfHeight * aspect
        let newHalfWidth = new * aspect
        target += right * (ndc.x * (oldHalfWidth - newHalfWidth))
                + up * (ndc.y * (halfHeight - new))
        halfHeight = new
    }

    func viewProjection() -> simd_float4x4 {
        let eye = target + back * standoff
        let view = Camera.lookAt(eye: eye, target: target, up: up)
        let halfWidth = halfHeight * aspect
        let projection = Camera.orthographic(left: -halfWidth, right: halfWidth,
                                             bottom: -halfHeight, top: halfHeight,
                                             nearZ: nearZ, farZ: farZ)
        return simd_mul(projection, view)
    }

    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        let t = SIMD3<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye))
        return simd_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        )
    }

    /// Metal clip space: depth 0...1.
    private static func orthographic(left: Float, right: Float, bottom: Float, top: Float,
                                     nearZ: Float, farZ: Float) -> simd_float4x4 {
        let xScale = 2 / (right - left)
        let yScale = 2 / (top - bottom)
        let zScale = 1 / (farZ - nearZ)
        return simd_float4x4(
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, -zScale, 0),
            SIMD4<Float>(-(right + left) / (right - left), -(top + bottom) / (top - bottom), -nearZ * zScale, 1)
        )
    }
}
