import Foundation
import simd

extension STEP {
    /// Tensor-product B-spline surface (optionally rational) in millimetres, for freeform faces.
    ///
    /// Control points, knots and weights come straight from the file; `init` decides whether they
    /// are usable. Evaluation is de Boor in homogeneous coordinates in v, then u, over only the
    /// `(degree + 1)` control points that matter at (u, v), so rational surfaces need no separate
    /// path and one evaluation is cheap enough for projecting every boundary point of a face.
    ///
    /// The parametrisation is the file's own: u and v run over the knot domains, and
    /// `∂P/∂u × ∂P/∂v` is the STEP surface normal, like every other `STEP.Surface`.
    ///
    /// A surface that closes on itself in u or v (`closedU`, `closedV`) is periodic there, with the
    /// knot domain as its period: a boundary point on the seam projects to either end, and the
    /// tessellator unwraps the loop by whole periods. Not supported (reported through `limitation`,
    /// so the face fails with a reason instead of getting a wrong mesh): surfaces with a side
    /// collapsed to a point, where a boundary point has no unique (u, v).
    public struct BSplineSurface: Sendable {
        static let maximumDegree = 25
        static let maximumControlPoints = 500_000

        public let uDegree: Int
        public let vDegree: Int
        let uCount: Int
        let vCount: Int
        public let uDomain: ClosedRange<Double>
        public let vDomain: ClosedRange<Double>
        /// Diagonal of the control points' bounding box (mm): the scale for tolerances.
        let size: Double
        /// Why this surface cannot carry a trimmed face yet, or `nil`.
        private(set) var limitation: String?
        /// The surface's low and high sides coincide, so the surface is periodic in that direction.
        public private(set) var closedU = false
        public private(set) var closedV = false

        /// Weighted control points `(x·w, y·w, z·w, w)`, row-major in u: index `i * vCount + j`.
        private let controls: [SIMD4<Double>]
        private let uKnots: [Double]
        private let vKnots: [Double]

        /// Coarse surface samples that seed the projection of a point onto the surface.
        private var tableU: [Double] = []
        private var tableV: [Double] = []
        private var tablePoints: [SIMD3<Double>] = []

        init(uDegree: Int, vDegree: Int, controlPoints: [[SIMD3<Double>]], weights: [[Double]]?,
             uMultiplicities: [Int], uKnotValues: [Double],
             vMultiplicities: [Int], vKnotValues: [Double]) throws {
            guard (1...Self.maximumDegree).contains(uDegree), (1...Self.maximumDegree).contains(vDegree) else {
                throw STEP.ParseError("Unsupported B-spline surface degree \(uDegree) x \(vDegree)")
            }
            let uCount = controlPoints.count
            guard uCount >= uDegree + 1, let vCount = controlPoints.first?.count, vCount >= vDegree + 1,
                  controlPoints.allSatisfy({ $0.count == vCount }) else {
                throw STEP.ParseError("B-spline surface needs a rectangular net of at least \(uDegree + 1) x \(vDegree + 1) control points")
            }
            guard uCount <= Self.maximumControlPoints, vCount <= Self.maximumControlPoints,
                  uCount * vCount <= Self.maximumControlPoints else {
                throw STEP.ParseError("B-spline surface has too many control points")
            }
            if let weights {
                guard weights.count == uCount,
                      weights.allSatisfy({ row in row.count == vCount && row.allSatisfy { $0.isFinite && $0 > 0 } }) else {
                    throw STEP.ParseError("B-spline surface weights must be positive and match the control points")
                }
            }
            let expandedU = try Self.expandKnots(degree: uDegree, count: uCount, multiplicities: uMultiplicities,
                                                 values: uKnotValues, axis: "u")
            let expandedV = try Self.expandKnots(degree: vDegree, count: vCount, multiplicities: vMultiplicities,
                                                 values: vKnotValues, axis: "v")

            var flat: [SIMD4<Double>] = []
            flat.reserveCapacity(uCount * vCount)
            var low = SIMD3<Double>(repeating: .infinity)
            var high = SIMD3<Double>(repeating: -.infinity)
            for i in 0..<uCount {
                for j in 0..<vCount {
                    let p = controlPoints[i][j]
                    guard (0..<3).allSatisfy({ p[$0].isFinite }) else { throw STEP.ParseError("Nonfinite B-spline surface control point") }
                    let w = weights?[i][j] ?? 1
                    flat.append(SIMD4(p.x * w, p.y * w, p.z * w, w))
                    low = pointwiseMin(low, p)
                    high = pointwiseMax(high, p)
                }
            }
            let diagonal = simd_distance(low, high)
            guard diagonal.isFinite, diagonal > 0 else { throw STEP.ParseError("B-spline surface is degenerate") }

            self.uDegree = uDegree
            self.vDegree = vDegree
            self.uCount = uCount
            self.vCount = vCount
            self.controls = flat
            self.uKnots = expandedU
            self.vKnots = expandedV
            uDomain = expandedU[uDegree]...expandedU[uCount]
            vDomain = expandedV[vDegree]...expandedV[vCount]
            size = diagonal

            limitation = findLimitation()
            buildTable()
        }

        // MARK: Knots

        private static func expandKnots(degree: Int, count: Int, multiplicities: [Int], values: [Double],
                                        axis: String) throws -> [Double] {
            guard multiplicities.count == values.count, values.count >= 2 else {
                throw STEP.ParseError("B-spline surface \(axis) knot and multiplicity lists disagree")
            }
            var expanded: [Double] = []
            expanded.reserveCapacity(count + degree + 1)
            for (index, value) in values.enumerated() {
                guard value.isFinite, index == 0 || value > values[index - 1] else {
                    throw STEP.ParseError("B-spline surface \(axis) knots must be finite and strictly increasing")
                }
                let isEnd = index == 0 || index == values.count - 1
                // An interior knot of multiplicity degree + 1 would cut the surface in two.
                guard multiplicities[index] >= 1, multiplicities[index] <= (isEnd ? degree + 1 : degree) else {
                    throw STEP.ParseError("Invalid B-spline surface \(axis) knot multiplicity \(multiplicities[index]) at knot \(index)")
                }
                expanded.append(contentsOf: repeatElement(value, count: multiplicities[index]))
                guard expanded.count <= count + degree + 1 else {
                    throw STEP.ParseError("B-spline surface \(axis) knot multiplicities exceed \(count + degree + 1)")
                }
            }
            guard expanded.count == count + degree + 1 else {
                throw STEP.ParseError("B-spline surface needs \(count + degree + 1) \(axis) knots for \(count) control points of degree \(degree), found \(expanded.count)")
            }
            guard expanded[degree] < expanded[count] else {
                throw STEP.ParseError("B-spline surface has an empty \(axis) parameter domain")
            }
            return expanded
        }

        /// Index k of the span [knots[k], knots[k+1]) holding `t`, never a zero-length one.
        private static func span(_ knots: [Double], degree: Int, count: Int, at t: Double) -> Int {
            var low = degree
            var high = count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if knots[middle] <= t { low = middle } else { high = middle - 1 }
            }
            while low > degree && knots[low] == knots[low + 1] { low -= 1 }
            return low
        }

        /// de Boor over the `degree + 1` homogeneous points `d` that belong to control indices
        /// `k - degree ... k`.
        private static func deBoor(degree: Int, knots: [Double], span k: Int, at t: Double,
                                   _ d: inout [SIMD4<Double>]) -> SIMD4<Double> {
            for r in 1...degree {
                for j in stride(from: degree, through: r, by: -1) {
                    let i = j + k - degree
                    let denominator = knots[i + degree + 1 - r] - knots[i]
                    let alpha = denominator == 0 ? 0 : (t - knots[i]) / denominator
                    d[j] = (1 - alpha) * d[j - 1] + alpha * d[j]
                }
            }
            return d[degree]
        }

        // MARK: Evaluation

        /// Surface point; parameters outside the domain are clamped to it.
        public func point(u: Double, v: Double) -> SIMD3<Double> {
            let uc = min(max(u, uDomain.lowerBound), uDomain.upperBound)
            let vc = min(max(v, vDomain.lowerBound), vDomain.upperBound)
            let ku = Self.span(uKnots, degree: uDegree, count: uCount, at: uc)
            let kv = Self.span(vKnots, degree: vDegree, count: vCount, at: vc)
            var column: [SIMD4<Double>] = []
            column.reserveCapacity(uDegree + 1)
            for a in 0...uDegree {
                let row = (ku - uDegree + a) * vCount
                var local: [SIMD4<Double>] = []
                local.reserveCapacity(vDegree + 1)
                for b in 0...vDegree { local.append(controls[row + kv - vDegree + b]) }
                column.append(Self.deBoor(degree: vDegree, knots: vKnots, span: kv, at: vc, &local))
            }
            let h = Self.deBoor(degree: uDegree, knots: uKnots, span: ku, at: uc, &column)
            return SIMD3(h.x, h.y, h.z) / h.w
        }

        /// Central differences over a step of 1e-5 of the domain, one-sided at its edges.
        func derivatives(u: Double, v: Double) -> (du: SIMD3<Double>, dv: SIMD3<Double>) {
            let uLength = uDomain.upperBound - uDomain.lowerBound
            let vLength = vDomain.upperBound - vDomain.lowerBound
            let u0 = max(u - 1e-5 * uLength, uDomain.lowerBound)
            let u1 = min(u + 1e-5 * uLength, uDomain.upperBound)
            let v0 = max(v - 1e-5 * vLength, vDomain.lowerBound)
            let v1 = min(v + 1e-5 * vLength, vDomain.upperBound)
            return ((point(u: u1, v: v) - point(u: u0, v: v)) / (u1 - u0),
                    (point(u: u, v: v1) - point(u: u, v: v0)) / (v1 - v0))
        }

        /// Unit `∂P/∂u × ∂P/∂v`. Where that vanishes (a singular point) the normal is taken a
        /// hair toward the domain centre instead; the sides of a surface that has a collapsed side
        /// are refused in `limitation`, so this only softens isolated singular points.
        public func normal(u: Double, v: Double) -> SIMD3<Double> {
            func unitNormal(_ u: Double, _ v: Double) -> SIMD3<Double>? {
                let d = derivatives(u: u, v: v)
                let cross = simd_cross(d.du, d.dv)
                let length = simd_length(cross)
                // Relative to the tangents, so the size of the parameter domain does not matter.
                let scale = simd_length(d.du) * simd_length(d.dv)
                return scale > 0 && length > 1e-9 * scale ? cross / length : nil
            }
            if let direct = unitNormal(u, v) { return direct }
            let centreU = (uDomain.lowerBound + uDomain.upperBound) / 2
            let centreV = (vDomain.lowerBound + vDomain.upperBound) / 2
            return unitNormal(u + 1e-3 * (centreU - u), v + 1e-3 * (centreV - v)) ?? SIMD3(0, 0, 1)
        }

        // MARK: Projection

        /// Parameters of the surface point nearest `target`, and how far away it is (mm). Exact
        /// for points on the surface; points far off it only need to be reported as far away.
        ///
        /// A coarse table over every knot span picks the start, then Gauss-Newton on the distance
        /// with backtracking, clamped to the domain. Results within 1e-9 of a domain end snap to it,
        /// so boundary points that belong to a side get the side's exact parameter.
        func parameters(of target: SIMD3<Double>) -> (u: Double, v: Double, distance: Double) {
            var best = 0
            var bestSquared = Double.infinity
            for (index, sample) in tablePoints.enumerated() {
                let squared = simd_distance_squared(sample, target)
                if squared < bestSquared { best = index; bestSquared = squared }
            }
            var u = tableU[best / tableV.count]
            var v = tableV[best % tableV.count]
            var current = simd_distance_squared(point(u: u, v: v), target)
            let uLength = uDomain.upperBound - uDomain.lowerBound
            let vLength = vDomain.upperBound - vDomain.lowerBound

            for _ in 0..<50 {
                let residual = point(u: u, v: v) - target
                let d = derivatives(u: u, v: v)
                let a = simd_dot(d.du, d.du)
                let b = simd_dot(d.du, d.dv)
                let c = simd_dot(d.dv, d.dv)
                let gradientU = simd_dot(d.du, residual)
                let gradientV = simd_dot(d.dv, residual)
                // A tiny ridge keeps the 2 x 2 system solvable where the surface is nearly singular.
                let ridge = 1e-12 * (a + c)
                let determinant = (a + ridge) * (c + ridge) - b * b
                guard determinant.isFinite, determinant > 0 else { break }
                let stepU = -((c + ridge) * gradientU - b * gradientV) / determinant
                let stepV = -((a + ridge) * gradientV - b * gradientU) / determinant

                var scale = 1.0
                var moved = false
                for _ in 0..<12 {
                    // A direction that closes on itself wraps round its seam instead of stopping at the
                    // domain end: a seam point can belong at either end, and the search may start at
                    // the wrong one.
                    let nextU = Self.advance(u + scale * stepU, in: uDomain, periodic: closedU)
                    let nextV = Self.advance(v + scale * stepV, in: vDomain, periodic: closedV)
                    let squared = simd_distance_squared(point(u: nextU, v: nextV), target)
                    if squared <= current {
                        moved = abs(nextU - u) > 1e-14 * uLength || abs(nextV - v) > 1e-14 * vLength
                        u = nextU
                        v = nextV
                        current = squared
                        break
                    }
                    scale /= 2
                }
                if !moved { break }
            }
            u = Self.snapped(u, to: uDomain)
            v = Self.snapped(v, to: vDomain)
            return (u, v, simd_distance(point(u: u, v: v), target))
        }

        /// `value` kept inside `domain`: wrapped by whole periods when the surface is periodic
        /// there, clamped to the nearest end otherwise.
        private static func advance(_ value: Double, in domain: ClosedRange<Double>, periodic: Bool) -> Double {
            if periodic {
                let length = domain.upperBound - domain.lowerBound
                var wrapped = domain.lowerBound + (value - domain.lowerBound).truncatingRemainder(dividingBy: length)
                if wrapped < domain.lowerBound { wrapped += length }
                return wrapped
            }
            return min(max(value, domain.lowerBound), domain.upperBound)
        }

        private static func snapped(_ value: Double, to domain: ClosedRange<Double>) -> Double {
            let slack = 1e-9 * (domain.upperBound - domain.lowerBound)
            if abs(value - domain.lowerBound) < slack { return domain.lowerBound }
            if abs(value - domain.upperBound) < slack { return domain.upperBound }
            return value
        }

        private mutating func buildTable() {
            tableU = Self.sampleParameters(knots: uKnots, degree: uDegree, count: uCount)
            tableV = Self.sampleParameters(knots: vKnots, degree: vDegree, count: vCount)
            var points: [SIMD3<Double>] = []
            points.reserveCapacity(tableU.count * tableV.count)
            for u in tableU {
                for v in tableV { points.append(point(u: u, v: v)) }
            }
            tablePoints = points
        }

        /// Four samples per knot span (fewer when there are very many spans), ends included.
        private static func sampleParameters(knots: [Double], degree: Int, count: Int) -> [Double] {
            var breaks = [knots[degree]]
            for value in knots[degree...count] where value > breaks[breaks.count - 1] { breaks.append(value) }
            let spans = breaks.count - 1
            let perSpan = max(2, min(4, 48 / max(1, spans)))
            var result: [Double] = []
            for (low, high) in zip(breaks, breaks.dropFirst()) {
                for step in 0..<perSpan { result.append(low + (high - low) * Double(step) / Double(perSpan)) }
            }
            result.append(breaks[breaks.count - 1])
            return result
        }

        // MARK: Sampling density

        /// Subdivisions along u and along v so that straight chords of the surface's iso-curves
        /// stay within `tolerance` (mm). Each knot span starts as `degree` pieces, so no piece
        /// holds a whole S-bend that midpoint flatness would accept, then the count doubles while
        /// probes at 1/4, 1/2 and 3/4 of every piece still miss. Capped at `cap` per direction.
        func divisions(tolerance: Double, cap: Int = 256) -> (u: Int, v: Int) {
            (divisionCount(alongU: true, tolerance: tolerance, cap: cap),
             divisionCount(alongU: false, tolerance: tolerance, cap: cap))
        }

        private func divisionCount(alongU: Bool, tolerance: Double, cap: Int) -> Int {
            let degree = alongU ? uDegree : vDegree
            let count = alongU ? uCount : vCount
            let knots = alongU ? uKnots : vKnots
            let domain = alongU ? uDomain : vDomain
            let other = alongU ? vDomain : uDomain
            let length = domain.upperBound - domain.lowerBound

            var spans = 0
            var previous = domain.lowerBound
            for value in knots[degree...count] where value > previous {
                spans += 1
                previous = value
            }
            var pieces = min(cap, max(1, spans) * degree)
            let lines = 9
            while true {
                var worst = 0.0
                for line in 0..<lines {
                    let fixed = other.lowerBound + (other.upperBound - other.lowerBound) * Double(line) / Double(lines - 1)
                    func at(_ t: Double) -> SIMD3<Double> { alongU ? point(u: t, v: fixed) : point(u: fixed, v: t) }
                    var start = at(domain.lowerBound)
                    for piece in 0..<pieces {
                        let t0 = domain.lowerBound + length * Double(piece) / Double(pieces)
                        let t1 = domain.lowerBound + length * Double(piece + 1) / Double(pieces)
                        let end = at(t1)
                        for fraction in [0.25, 0.5, 0.75] {
                            worst = max(worst, STEPSegment.closest(to: at(t0 + (t1 - t0) * fraction), start, end).distance)
                        }
                        start = end
                    }
                }
                if worst <= tolerance || pieces >= cap { return pieces }
                pieces = min(cap, pieces * 2)
            }
        }

        // MARK: Limits

        /// Sets `closedU` and `closedV`, and returns why the surface cannot carry a trimmed face when
        /// it has a side collapsed to a point: a pole belongs to many (u, v) positions.
        private mutating func findLimitation() -> String? {
            let probes = 9
            let coincident = 1e-6 * size
            func sides(_ fixedU: Bool, _ bound: Double) -> [SIMD3<Double>] {
                (0..<probes).map { index in
                    let fraction = Double(index) / Double(probes - 1)
                    return fixedU
                        ? point(u: bound, v: vDomain.lowerBound + (vDomain.upperBound - vDomain.lowerBound) * fraction)
                        : point(u: uDomain.lowerBound + (uDomain.upperBound - uDomain.lowerBound) * fraction, v: bound)
                }
            }
            let uLow = sides(true, uDomain.lowerBound)
            let uHigh = sides(true, uDomain.upperBound)
            let vLow = sides(false, vDomain.lowerBound)
            let vHigh = sides(false, vDomain.upperBound)
            for side in [uLow, uHigh, vLow, vHigh] {
                if side.allSatisfy({ simd_distance($0, side[0]) <= coincident }) {
                    return "has a side collapsed to a point"
                }
            }
            closedU = zip(uLow, uHigh).allSatisfy { simd_distance($0, $1) <= coincident }
            closedV = zip(vLow, vHigh).allSatisfy { simd_distance($0, $1) <= coincident }
            return nil
        }
    }
}
