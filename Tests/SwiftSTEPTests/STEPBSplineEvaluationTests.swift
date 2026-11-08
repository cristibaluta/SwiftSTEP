import Testing
import Foundation
import simd
@testable import SwiftSTEP

// T55: the allocation-free spline evaluators (STEPBasis) against the textbook definition of
// the basis functions, computed the slow recursive way, which shares no code with them.

/// Small deterministic generator, so a failure repeats.
private struct Lcg {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * next()
    }
}

/// Cox-de Boor: `N(i, p, t)` straight from the definition, half-open spans.
private func basisFunction(_ i: Int, _ p: Int, _ t: Double, _ knots: [Double]) -> Double {
    if p == 0 { return knots[i] <= t && t < knots[i + 1] ? 1 : 0 }
    var value = 0.0
    let first = knots[i + p] - knots[i]
    if first > 0 { value += (t - knots[i]) / first * basisFunction(i, p - 1, t, knots) }
    let second = knots[i + p + 1] - knots[i + 1]
    if second > 0 { value += (knots[i + p + 1] - t) / second * basisFunction(i + 1, p - 1, t, knots) }
    return value
}

/// All basis functions at `t`. At the very end of the domain the last span is closed, as the
/// evaluators do.
private func basisFunctions(count: Int, degree: Int, _ t: Double, _ knots: [Double]) -> [Double] {
    let end = knots[count]
    let evaluationPoint = t >= end ? end - 1e-13 * max(1, abs(end)) : t
    return (0..<count).map { basisFunction($0, degree, evaluationPoint, knots) }
}

/// A knot description in the file's form: distinct values and multiplicities.
private struct Knots {
    var values: [Double]
    var multiplicities: [Int]
    var expanded: [Double] { zip(values, multiplicities).flatMap { Array(repeating: $0, count: $1) } }

    /// `spans` equal spans over [0, spans]; `creaseAt` gives that interior knot multiplicity `degree`.
    init(degree: Int, spans: Int, creaseAt: Int? = nil) {
        values = (0...spans).map(Double.init)
        multiplicities = (0...spans).map { index in
            if index == 0 || index == spans { return degree + 1 }
            return index == creaseAt ? degree : 1
        }
    }
    var controlPointCount: Int { multiplicities.reduce(0, +) }
}

private struct SurfaceCase {
    let uDegree: Int, vDegree: Int
    let uKnots: Knots, vKnots: Knots
    let rational: Bool
    let controls: [[SIMD3<Double>]]
    let weights: [[Double]]?

    init(uDegree: Int, vDegree: Int, uSpans: Int, vSpans: Int, rational: Bool,
         uCrease: Int? = nil, vCrease: Int? = nil, seed: UInt64) {
        self.uDegree = uDegree
        self.vDegree = vDegree
        self.rational = rational
        uKnots = Knots(degree: uDegree, spans: uSpans, creaseAt: uCrease)
        vKnots = Knots(degree: vDegree, spans: vSpans, creaseAt: vCrease)
        let uCount = uKnots.controlPointCount - uDegree - 1
        let vCount = vKnots.controlPointCount - vDegree - 1
        var random = Lcg(state: seed)
        controls = (0..<uCount).map { i in
            (0..<vCount).map { j in
                // A gently curved sheet with some noise, so no two evaluations agree by accident.
                SIMD3(Double(i) * 3 + random.next(in: -1...1), Double(j) * 3 + random.next(in: -1...1),
                      4 * sin(Double(i) * 0.7) * cos(Double(j) * 0.5) + random.next(in: -1...1))
            }
        }
        weights = rational ? (0..<uCount).map { _ in (0..<vCount).map { _ in random.next(in: 0.5...2) } } : nil
    }

    func make() throws -> STEP.BSplineSurface {
        try STEP.BSplineSurface(uDegree: uDegree, vDegree: vDegree, controlPoints: controls, weights: weights,
                                uMultiplicities: uKnots.multiplicities, uKnotValues: uKnots.values,
                                vMultiplicities: vKnots.multiplicities, vKnotValues: vKnots.values)
    }

    /// The point from the definition: the double sum over every control point.
    func reference(u: Double, v: Double) -> SIMD3<Double> {
        let nu = basisFunctions(count: controls.count, degree: uDegree, u, uKnots.expanded)
        let nv = basisFunctions(count: controls[0].count, degree: vDegree, v, vKnots.expanded)
        var sum = SIMD3<Double>()
        var total = 0.0
        for i in controls.indices {
            for j in controls[i].indices {
                let w = (weights?[i][j] ?? 1) * nu[i] * nv[j]
                sum += w * controls[i][j]
                total += w
            }
        }
        return sum / total
    }
}

private let surfaceCases: [(name: String, spec: SurfaceCase)] = [
    ("bilinear", SurfaceCase(uDegree: 1, vDegree: 1, uSpans: 3, vSpans: 2, rational: false, seed: 1)),
    ("quadratic rational", SurfaceCase(uDegree: 2, vDegree: 2, uSpans: 4, vSpans: 3, rational: true, seed: 2)),
    ("cubic by quadratic", SurfaceCase(uDegree: 3, vDegree: 2, uSpans: 5, vSpans: 3, rational: false, seed: 3)),
    ("degree 9 by 2, rational, like the loft sample", SurfaceCase(uDegree: 9, vDegree: 2, uSpans: 4, vSpans: 2, rational: true, seed: 4)),
    ("a crease in u", SurfaceCase(uDegree: 3, vDegree: 3, uSpans: 4, vSpans: 2, rational: true, uCrease: 2, seed: 5)),
    ("a crease in both", SurfaceCase(uDegree: 2, vDegree: 3, uSpans: 3, vSpans: 3, rational: false, uCrease: 1, vCrease: 2, seed: 6))
]

@Suite("B-spline evaluation")
struct STEPBSplineEvaluationTests {

    @Test(arguments: surfaceCases.indices)
    func aSurfacePointMatchesTheDefinition(index: Int) throws {
        let (name, spec) = surfaceCases[index]
        let surface = try spec.make()
        var random = Lcg(state: UInt64(100 + index))
        let uEnd = surface.uDomain.upperBound
        let vEnd = surface.vDomain.upperBound
        var parameters: [(Double, Double)] = [(0, 0), (uEnd, 0), (0, vEnd), (uEnd, vEnd)]
        for _ in 0..<40 {
            parameters.append((random.next(in: 0...uEnd), random.next(in: 0...vEnd)))
        }
        // Exactly on knots, where the span changes.
        for knot in spec.uKnots.values { parameters.append((knot, random.next(in: 0...vEnd))) }
        for knot in spec.vKnots.values { parameters.append((random.next(in: 0...uEnd), knot)) }
        for (u, v) in parameters {
            let expected = spec.reference(u: u, v: v)
            let actual = surface.point(u: u, v: v)
            #expect(simd_distance(actual, expected) < 1e-8 * max(1, simd_length(expected)),
                    "\(name) at (\(u), \(v)): \(actual) vs \(expected)")
        }
    }

    @Test(arguments: surfaceCases.indices)
    func theExactDerivativesMatchCentralDifferences(index: Int) throws {
        let (name, spec) = surfaceCases[index]
        let surface = try spec.make()
        var random = Lcg(state: UInt64(200 + index))
        let uEnd = surface.uDomain.upperBound
        let vEnd = surface.vDomain.upperBound
        let h = 1e-6
        var checked = 0
        while checked < 40 {
            let u = random.next(in: 0.01...(uEnd - 0.01))
            let v = random.next(in: 0.01...(vEnd - 0.01))
            // A crease makes the two sides differ; the difference quotient straddles it.
            if spec.uKnots.values.contains(where: { abs($0 - u) < 10 * h }) { continue }
            if spec.vKnots.values.contains(where: { abs($0 - v) < 10 * h }) { continue }
            let du = (surface.point(u: u + h, v: v) - surface.point(u: u - h, v: v)) / (2 * h)
            let dv = (surface.point(u: u, v: v + h) - surface.point(u: u, v: v - h)) / (2 * h)
            let exact = surface.derivatives(u: u, v: v)
            let scale = max(1, simd_length(du), simd_length(dv))
            #expect(simd_distance(exact.du, du) < 1e-5 * scale, "\(name) du at (\(u), \(v))")
            #expect(simd_distance(exact.dv, dv) < 1e-5 * scale, "\(name) dv at (\(u), \(v))")
            checked += 1
        }
    }

    @Test func theFrameAgreesWithThePointAndTheNormalIsTheUnitCross() throws {
        let surface = try surfaceCases[3].spec.make()
        var random = Lcg(state: 7)
        for _ in 0..<30 {
            let u = random.next(in: 0...4)
            let v = random.next(in: 0...2)
            let frame = surface.frame(u: u, v: v)
            #expect(simd_distance(frame.point, surface.point(u: u, v: v)) < 1e-12)
            let normal = surface.normal(u: u, v: v)
            #expect(abs(simd_length(normal) - 1) < 1e-12)
            let cross = simd_normalize(simd_cross(frame.du, frame.dv))
            #expect(simd_distance(normal, cross) < 1e-9)
        }
    }

    @Test func aDerivativeAtTheEndOfTheDomainIsTheOneSidedOne() throws {
        let surface = try surfaceCases[2].spec.make()
        let end = surface.uDomain.upperBound
        let h = 1e-6
        let exact = surface.derivatives(u: end, v: 1.3)
        let oneSided = (surface.point(u: end, v: 1.3) - surface.point(u: end - h, v: 1.3)) / h
        #expect(simd_distance(exact.du, oneSided) < 1e-4 * max(1, simd_length(oneSided)))
        let start = surface.derivatives(u: 0, v: 1.3)
        let forward = (surface.point(u: h, v: 1.3) - surface.point(u: 0, v: 1.3)) / h
        #expect(simd_distance(start.du, forward) < 1e-4 * max(1, simd_length(forward)))
    }

    @Test func projectionStillFindsThePointsItEvaluated() throws {
        // The projection now runs on the exact derivatives: it must still land on the same (u, v).
        let surface = try surfaceCases[3].spec.make()
        var random = Lcg(state: 11)
        for _ in 0..<20 {
            let u = random.next(in: 0.2...3.8)
            let v = random.next(in: 0.2...1.8)
            let target = surface.point(u: u, v: v)
            let found = surface.parameters(of: target)
            #expect(found.distance < 1e-5)
            #expect(simd_distance(surface.point(u: found.u, v: found.v), target) < 1e-5)
        }
    }

    // MARK: Curves

    private struct CurveCase {
        let degree: Int
        let knots: Knots
        let controls: [SIMD3<Double>]
        let weights: [Double]?

        init(degree: Int, spans: Int, rational: Bool, crease: Int? = nil, seed: UInt64) {
            self.degree = degree
            knots = Knots(degree: degree, spans: spans, creaseAt: crease)
            var random = Lcg(state: seed)
            let count = knots.controlPointCount - degree - 1
            controls = (0..<count).map { i in
                SIMD3(Double(i) * 2 + random.next(in: -1...1), 3 * sin(Double(i) * 0.6) + random.next(in: -1...1),
                      random.next(in: -2...2))
            }
            weights = rational ? (0..<count).map { _ in random.next(in: 0.5...2) } : nil
        }

        func make() throws -> STEPBSpline {
            try STEPBSpline(degree: degree, controlPoints: controls, weights: weights,
                            multiplicities: knots.multiplicities, knotValues: knots.values)
        }

        func reference(_ t: Double) -> SIMD3<Double> {
            let n = basisFunctions(count: controls.count, degree: degree, t, knots.expanded)
            var sum = SIMD3<Double>()
            var total = 0.0
            for i in controls.indices {
                let w = (weights?[i] ?? 1) * n[i]
                sum += w * controls[i]
                total += w
            }
            return sum / total
        }
    }

    @Test(arguments: [(1, 4, false, Optional<Int>.none), (2, 5, true, nil), (3, 6, false, nil), (3, 4, true, 2), (9, 4, true, nil), (9, 3, false, 1)])
    func aCurvePointMatchesTheDefinition(degree: Int, spans: Int, rational: Bool, crease: Int?) throws {
        let spec = CurveCase(degree: degree, spans: spans, rational: rational, crease: crease, seed: UInt64(degree * 10 + spans))
        let curve = try spec.make()
        var random = Lcg(state: 5)
        var parameters = [0.0, Double(spans)]
        for _ in 0..<60 { parameters.append(random.next(in: 0...Double(spans))) }
        parameters += spec.knots.values
        for t in parameters {
            let expected = spec.reference(t)
            let actual = curve.point(at: t)
            #expect(simd_distance(actual, expected) < 1e-8 * max(1, simd_length(expected)),
                    "degree \(degree), rational \(rational), t = \(t)")
        }
        // Outside the domain the parameter is clamped, as before.
        #expect(simd_distance(curve.point(at: -5), curve.point(at: 0)) < 1e-12)
        #expect(simd_distance(curve.point(at: Double(spans) + 5), curve.point(at: Double(spans))) < 1e-12)
    }

    @Test func theHighestSupportedDegreeReproducesALine() throws {
        // Degree 25 is the limit and needs the most scratch space. Control points at the Greville
        // abscissae (the average of `degree` consecutive knots) make the curve the straight line
        // P(t) = t, whatever the degree: a check that needs no reference implementation.
        let degree = 25
        let knots = Knots(degree: degree, spans: 2)
        let expanded = knots.expanded
        let count = knots.controlPointCount - degree - 1
        let controls = (0..<count).map { i -> SIMD3<Double> in
            SIMD3((1...degree).reduce(0.0) { $0 + expanded[i + $1] } / Double(degree), 0, 0)
        }
        let curve = try STEPBSpline(degree: degree, controlPoints: controls, weights: nil,
                                    multiplicities: knots.multiplicities, knotValues: knots.values)
        for t in stride(from: 0.0, through: 2.0, by: 0.125) {
            #expect(abs(curve.point(at: t).x - t) < 1e-9, "t = \(t)")
        }
    }
}
