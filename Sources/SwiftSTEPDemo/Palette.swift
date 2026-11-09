import SwiftUI
import simd

/// Colours for the bodies of an assembly. The index is per distinct part, so every placement of the
/// same part (the four dice mapped from one die) shares a colour.
enum BodyPalette {
    private static let colors: [SIMD3<Float>] = [
        SIMD3(0.55, 0.62, 0.72),   // steel blue
        SIMD3(0.86, 0.58, 0.38),   // copper
        SIMD3(0.47, 0.70, 0.54),   // green
        SIMD3(0.74, 0.52, 0.72),   // violet
        SIMD3(0.80, 0.73, 0.40),   // brass
        SIMD3(0.42, 0.68, 0.78),   // teal
    ]

    /// Shown instead of the part colour for the body selected in the list.
    static let selection = SIMD4<Float>(1.0, 0.80, 0.25, 1)

    static func rgba(_ index: Int) -> SIMD4<Float> {
        let c = colors[index % colors.count]
        return SIMD4(c.x, c.y, c.z, 1)
    }

    static func swiftUI(_ index: Int) -> Color {
        let c = colors[index % colors.count]
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
