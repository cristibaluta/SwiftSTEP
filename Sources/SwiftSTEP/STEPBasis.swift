import Foundation

/// B-spline basis functions, shared by the curve and the surface evaluators.
///
/// A point on a B-spline is a weighted sum of `degree + 1` control points, and the weights (the
/// basis functions) depend only on the knots and the parameter, not on the control points. Computing
/// them once and summing is much cheaper than running de Boor on the control points, which repeats
/// the same knot arithmetic for every row of a surface, and it needs no heap memory: everything lives
/// in a small caller-provided buffer. Rational curves and surfaces use the same weights on
/// homogeneous control points `(x·w, y·w, z·w, w)`.
enum STEPBasis {
    /// Doubles of scratch `evaluate` needs for a given degree: values, derivatives and its own work space.
    static func scratchCount(degree: Int) -> Int { 5 * (degree + 1) }

    /// Fills `values[0...degree]` with the non-zero basis functions at `t` for the knot span `k`
    /// (`knots[k] <= t < knots[k + 1]`, and `degree <= k`), and, when `derivatives` is given, with
    /// their derivatives with respect to `t`. `work` must hold `3 * (degree + 1)` doubles.
    ///
    /// The values are the standard triangular recurrence. The derivatives come from the same
    /// recurrence one degree lower, which it passes through on the way: with `N` the degree
    /// `degree - 1` values,
    /// `N'[i] = degree * (N[i-1] / (knots[k+i] - knots[k-degree+i]) - N[i] / (knots[k+i+1] - knots[k-degree+i+1]))`,
    /// where a term with a zero knot difference (a repeated knot) is left out.
    @inline(__always)
    static func evaluate(degree p: Int, knots: UnsafeBufferPointer<Double>, span k: Int, at t: Double,
                         values: UnsafeMutablePointer<Double>, derivatives: UnsafeMutablePointer<Double>?,
                         work: UnsafeMutablePointer<Double>) {
        let left = work
        let right = work + (p + 1)
        let lower = work + 2 * (p + 1)
        values[0] = 1
        let wantsDerivatives = derivatives != nil
        if wantsDerivatives && p == 1 { lower[0] = 1 }
        for j in 1...p {
            left[j] = t - knots[k + 1 - j]
            right[j] = knots[k + j] - t
            var saved = 0.0
            for r in 0..<j {
                let temp = values[r] / (right[r + 1] + left[j - r])
                values[r] = saved + right[r + 1] * temp
                saved = left[j - r] * temp
            }
            values[j] = saved
            if wantsDerivatives && j == p - 1 {
                for s in 0..<p { lower[s] = values[s] }
            }
        }
        guard let derivatives else { return }
        for r in 0...p {
            var sum = 0.0
            if r >= 1 {
                let difference = knots[k + r] - knots[k - p + r]
                if difference > 0 { sum += lower[r - 1] / difference }
            }
            if r <= p - 1 {
                let difference = knots[k + r + 1] - knots[k - p + r + 1]
                if difference > 0 { sum -= lower[r] / difference }
            }
            derivatives[r] = Double(p) * sum
        }
    }
}
